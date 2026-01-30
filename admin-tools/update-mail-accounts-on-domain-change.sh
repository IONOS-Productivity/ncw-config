#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Update email addresses in Nextcloud mail app configuration using OCC commands
# When an email provider domain changes (e.g., domain cancellation, email parking)
# this script updates all configured mail accounts to use the new domain.

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# Script parameters
readonly USER_ID="${1:-}"
readonly OLD_EMAIL="${2:-}"
readonly NEW_EMAIL="${3:-}"

usage() {
	cat <<EOF
Usage: $(basename "$0") <user_id> <old_email> <new_email>

Update mail account email addresses in Nextcloud mail app configuration.

Arguments:
	user_id         Nextcloud user ID
	old_email       Current email address (e.g., foo@example.old)
	new_email       New email address (e.g., foo@parked-emails.old)

Example:
	$(basename "$0") john.doe foo@example.com foo@parked-emails.com

Description:
	When a customer's email domain is cancelled or parked on a different server,
	this script updates the mail app configuration to use the new email address.
	It updates:
		- email field (display email)
		- inbound_user (IMAP username)
		- outbound_user (SMTP username)

EOF
}

validate_params() {
	if [[ -z "${USER_ID}" ]] || [[ -z "${OLD_EMAIL}" ]] || [[ -z "${NEW_EMAIL}" ]]; then
		log_error "Missing required parameters"
		usage
		exit 1
	fi

	# Basic email format validation
	if ! [[ "${OLD_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
		log_error "Invalid old email address format: ${OLD_EMAIL}"
		exit 1
	fi

	if ! [[ "${NEW_EMAIL}" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
		log_error "Invalid new email address format: ${NEW_EMAIL}"
		exit 1
	fi
}

check_user_exists() {
	local user_id="$1"
	
	if ! php "${OCC_CMD}" user:info "${user_id}" >/dev/null 2>&1; then
		log_error "User '${user_id}' does not exist"
		exit 1
	fi
}

main() {
	log_info "Starting mail account email update"
	log_info "User: ${USER_ID}"
	log_info "Old email: ${OLD_EMAIL}"
	log_info "New email: ${NEW_EMAIL}"
	echo ""

	validate_params
	check_user_exists "${USER_ID}"

	log_info "Exporting mail accounts for user '${USER_ID}'..."
	
	# Export user's mail accounts
	# Note: We call OCC directly here to get clean JSON output without logging
	local accounts_json
	local export_exit_code
	accounts_json=$(php "${OCC_CMD}" mail:account:export "${USER_ID}" --output=json 2>&1)
	export_exit_code=$?
	
	if [[ ${export_exit_code} -ne 0 ]]; then
		log_error "Failed to export mail accounts: ${accounts_json}"
		exit 1
	fi

	if [[ -z "${accounts_json}" ]] || [[ "${accounts_json}" == "[]" ]]; then
		log_error "No mail accounts found for user '${USER_ID}'"
		exit 1
	fi

	# Find accounts matching the old email
	local matching_accounts
	matching_accounts=$(echo "${accounts_json}" | jq -r --arg old_email "${OLD_EMAIL}" '
		.[] | select(
			.email == $old_email or 
			.imap.user == $old_email or 
			.smtp.user == $old_email
		) | .id
	')

	if [[ -z "${matching_accounts}" ]]; then
		log_error "No mail accounts found for user '${USER_ID}' with email '${OLD_EMAIL}'"
		echo ""
		log_info "User '${USER_ID}' has the following email accounts configured:"
		echo "${accounts_json}" | jq -r '.[] | "  - \(.email) (IMAP: \(.imap.user), SMTP: \(.smtp.user))"'
		exit 1
	fi

	# Count accounts to update
	local account_count
	account_count=$(echo "${matching_accounts}" | wc -l)
	log_info "Found ${account_count} mail account(s) to update"
	echo ""

	# Update each matching account
	while IFS= read -r account_id; do
		if [[ -n "${account_id}" ]]; then
			log_info "Updating account ID: ${account_id}"
			
			# Get current account details
			local account_data
			account_data=$(echo "${accounts_json}" | jq -r --arg id "${account_id}" '.[] | select(.id == ($id | tonumber))')
			
			local current_email
			local current_imap_user
			local current_smtp_user
			
			current_email=$(echo "${account_data}" | jq -r '.email')
			current_imap_user=$(echo "${account_data}" | jq -r '.imap.user')
			current_smtp_user=$(echo "${account_data}" | jq -r '.smtp.user')
			
			log_info "  Current email: ${current_email}"
			log_info "  Current IMAP user: ${current_imap_user}"
			log_info "  Current SMTP user: ${current_smtp_user}"
			
			# Prepare update arguments
			local update_args=()
			
			# Update email if it matches
			if [[ "${current_email}" == "${OLD_EMAIL}" ]]; then
				update_args+=(--email="${NEW_EMAIL}")
			fi
			
			# Update IMAP user if it matches
			if [[ "${current_imap_user}" == "${OLD_EMAIL}" ]]; then
				update_args+=(--imap-user="${NEW_EMAIL}")
			fi
			
			# Update SMTP user if it matches
			if [[ "${current_smtp_user}" == "${OLD_EMAIL}" ]]; then
				update_args+=(--smtp-user="${NEW_EMAIL}")
			fi
			
			# Execute update if there are changes
			if [[ ${#update_args[@]} -gt 0 ]]; then
				if execute_occ_command mail:account:update "${account_id}" "${update_args[@]}"; then
					log_success "  ✓ Updated successfully"
				else
					log_error "  ✗ Failed to update account"
					exit 1
				fi
			else
				log_info "  → No changes needed"
			fi
			
			echo ""
		fi
	done <<< "${matching_accounts}"

	echo ""
	log_success "All mail accounts updated successfully!"
	log_info "Note: Users may need to refresh their mail app to see the changes."
}

# Show usage if help requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

main
