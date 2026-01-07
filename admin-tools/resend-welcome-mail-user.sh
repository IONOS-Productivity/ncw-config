#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 STRATO GmbH
#
# Resend welcome email to a specific user

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Script configuration
readonly SCRIPT_NAME="resend-welcome-mail-user.sh"
readonly SCRIPT_VERSION="1.0.0"

# Global flags (set by parse_arguments)
DRY_RUN=false
# shellcheck disable=SC2034  # Used by log_*_if_not_quiet in common.sh
QUIET=false
USERNAME=""

# Function to display help
show_help() {
	print_help_header "${SCRIPT_NAME}" "Resend welcome email to a specific user"

	cat << EOF
Usage: ${SCRIPT_NAME} [OPTIONS] <username>

Arguments:
	username              Username of the Nextcloud user

Options:
	-h, --help           Show this help message and exit
	-v, --version        Show version information
	--dry-run            Show what would be done without executing
	-q, --quiet          Suppress informational output

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
	USERNAME=""

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
					-*)
							log_error "Unknown option: $1"
							echo "Use --help for usage information" >&2
							exit "${EXIT_INVALID_USAGE}"
							;;
					*)
							if [[ -z "${USERNAME}" ]]; then
									USERNAME="$1"
									shift
							else
									log_error "Too many arguments. Expected one username."
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

	# Resend welcome email
	if [[ "${DRY_RUN}" == true ]]; then
			log_info "[DRY RUN] Would execute: php occ user:welcome '${USERNAME}'"
			log_success "[DRY RUN] Would resend welcome email to user: '${USERNAME}'"
	else
			log_info_if_not_quiet "Resending welcome email to user: '${USERNAME}'"

			if execute_occ_command user:welcome "${USERNAME}"; then
				log_success_if_not_quiet "Welcome email sent to user: '${USERNAME}'"
			else
					log_fatal "Failed to send welcome email to user: '${USERNAME}'"
			fi
	fi

	log_success_if_not_quiet "Operation completed successfully"
	exit "${EXIT_SUCCESS}"
}

# Run main function
main "$@"
