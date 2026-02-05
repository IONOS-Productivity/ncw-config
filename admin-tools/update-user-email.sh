#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 STRATO GmbH
#
# Update email address for a Nextcloud user
# Particularly useful when initial admin user had a typo in their email
# and needs to receive welcome emails

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Script configuration
readonly SCRIPT_NAME="update-user-email.sh"
readonly SCRIPT_VERSION="1.0.0"

# Global flags (set by parse_arguments)
DRY_RUN=false
# shellcheck disable=SC2034  # Used by log_*_if_not_quiet in common.sh
QUIET=false
RESEND_WELCOME=false
USERNAME=""
NEW_EMAIL=""

# Function to display help
show_help() {
	print_help_header "${SCRIPT_NAME}" "Update email address for a Nextcloud user"

	cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <username> <new_email>

Arguments:
	username              Username of the Nextcloud user
	new_email            New email address to set

Options:
	-h, --help           Show this help message and exit
	-v, --version        Show version information
	--dry-run            Show what would be done without executing
	-q, --quiet          Suppress informational output
	-w, --resend-welcome Resend welcome email after updating

Description:
	This script updates the email address for a Nextcloud user. It is particularly
	useful when the initial admin user had a typo in their email address and needs
	to receive welcome emails.

	The script will:
	1. Validate that the user exists
	2. Check if the email address has changed
	3. Update the user's email setting if changed (OCC validates the email format)
	4. Optionally resend the welcome email

Examples:
	${SCRIPT_NAME} admin admin@example.com
	${SCRIPT_NAME} --resend-welcome admin admin@example.com
	${SCRIPT_NAME} --dry-run john.doe corrected@example.com

EOF

	print_help_footer
}

# Function to display version
show_version() {
	echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
}

# Parse command line arguments
parse_arguments() {
	DRY_RUN=false
	QUIET=false
	RESEND_WELCOME=false
	USERNAME=""
	NEW_EMAIL=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)
				show_help
				exit "${EXIT_SUCCESS}"
				;;
			-v|--version)
				show_version
				exit "${EXIT_SUCCESS}"
				;;
			--dry-run)
				DRY_RUN=true
				shift
				;;
			-q|--quiet)
				# shellcheck disable=SC2034  # Used by log_*_if_not_quiet in common.sh
				QUIET=true
				shift
				;;
			-w|--resend-welcome)
				RESEND_WELCOME=true
				shift
				;;
			-*)
				log_error "Unknown option: $1"
				echo "Use --help for usage information" >&2
				exit "${EXIT_INVALID_USAGE}"
				;;
			*)
				if [[ -z "${USERNAME}" ]]; then
					USERNAME="$1"
					shift
				elif [[ -z "${NEW_EMAIL}" ]]; then
					NEW_EMAIL="$1"
					shift
				else
					log_error "Too many arguments. Expected username and new_email."
					exit "${EXIT_INVALID_USAGE}"
				fi
				;;
		esac
	done

	# Validate required arguments
	if [[ -z "${USERNAME}" ]]; then
		log_error "Username is required"
		echo "Use --help for usage information" >&2
		exit "${EXIT_INVALID_USAGE}"
	fi

	if [[ -z "${NEW_EMAIL}" ]]; then
		log_error "New email address is required"
		echo "Use --help for usage information" >&2
		exit "${EXIT_INVALID_USAGE}"
	fi
}

# Main function
main() {
	parse_arguments "$@"

	log_info_if_not_quiet "Starting ${SCRIPT_NAME}"

	# Check prerequisites
	check_occ_available
	check_nextcloud_installed

	# Verify user exists
	log_info_if_not_quiet "Checking if user '${USERNAME}' exists..."
	if ! user_exists "${USERNAME}"; then
		log_fatal "User '${USERNAME}' does not exist"
	fi

	# Get current email for comparison
	local current_email
	current_email=$(execute_occ_command user:setting "${USERNAME}" settings email 2>/dev/null || echo "")

	if [[ -n "${current_email}" ]]; then
		log_info_if_not_quiet "Current email: ${current_email}"
	else
		log_info_if_not_quiet "Current email: (not set)"
	fi

	# Check if email is already set to the new value
	if [[ "${current_email}" == "${NEW_EMAIL}" ]]; then
		log_warning "Email address is already set to '${NEW_EMAIL}' for user '${USERNAME}'"
		log_info_if_not_quiet "No changes needed"

		# Still allow resending welcome email if requested
		if [[ "${RESEND_WELCOME}" == true ]] && [[ "${DRY_RUN}" == false ]]; then
			log_info_if_not_quiet "Resending welcome email as requested..."

			if execute_occ_command user:welcome "${USERNAME}"; then
				log_success_if_not_quiet "Welcome email sent to user: '${USERNAME}' at ${NEW_EMAIL}"
			else
				log_error "Failed to send welcome email to user: '${USERNAME}'"
				exit "${EXIT_ERROR}"
			fi
		fi

		log_success_if_not_quiet "Operation completed successfully"
		exit "${EXIT_SUCCESS}"
	fi

	# Update email address
	if [[ "${DRY_RUN}" == true ]]; then
		log_info "[DRY RUN] Would execute: php occ user:setting '${USERNAME}' settings email '${NEW_EMAIL}'"
		log_success "[DRY RUN] Would update email for user '${USERNAME}' to: ${NEW_EMAIL}"

		if [[ "${RESEND_WELCOME}" == true ]]; then
			log_info "[DRY RUN] Would execute: php occ user:welcome '${USERNAME}'"
			log_success "[DRY RUN] Would resend welcome email to user: '${USERNAME}'"
		fi
	else
		log_info_if_not_quiet "Updating email address for user '${USERNAME}' to: ${NEW_EMAIL}"

		if execute_occ_command user:setting "${USERNAME}" settings email "${NEW_EMAIL}"; then
			log_success_if_not_quiet "Email address updated successfully for user: '${USERNAME}'"
		else
			log_fatal "Failed to update email address for user: '${USERNAME}'"
		fi

		# Optionally resend welcome email
		if [[ "${RESEND_WELCOME}" == true ]]; then
			log_info_if_not_quiet "Resending welcome email to user: '${USERNAME}'"

			if execute_occ_command user:welcome "${USERNAME}"; then
				log_success_if_not_quiet "Welcome email sent to user: '${USERNAME}' at ${NEW_EMAIL}"
			else
				log_error "Failed to send welcome email to user: '${USERNAME}'"
				log_warning "Email address was updated but welcome email could not be sent"
				exit "${EXIT_ERROR}"
			fi
		fi
	fi

	log_success_if_not_quiet "Operation completed successfully"
	exit "${EXIT_SUCCESS}"
}

# Run main function
main "$@"
