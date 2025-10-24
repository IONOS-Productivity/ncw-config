#!/bin/sh
set -e

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

################################################################################
# Nextcloud Apps Disable Script
################################################################################
#
# DESCRIPTION:
#   This script removes specified Nextcloud apps from the shipped.json file,
#   allowing them to be disabled. It modifies both the 'defaultEnabled' and
#   'alwaysEnabled' arrays in core/shipped.json to prevent certain apps from
#   being forcefully enabled.
#
# LOCATION:
#   This script is located in /IONOS as a submodule within the Nextcloud
#   server repository.
#
# EXECUTION CONTEXT:
#   ⚠️  IMPORTANT: This script should be executed during the Docker image build
#   process, NOT at runtime in Kubernetes pods. Since we do not use PVCs
#   (Persistent Volume Claims), runtime execution would require applying
#   changes to each nc-pod individually, which is inefficient and error-prone.
#
# USAGE:
#   ./apps-disable.sh
#
#   The script reads app names from disabled-apps.list (one per line) and
#   removes them from ../core/shipped.json.
#
# PREREQUISITES:
#   - jq (JSON processor) must be installed
#   - disabled-apps.list must exist in the same directory
#   - ../core/shipped.json must exist and be valid JSON
#
# INPUT FILES:
#   - disabled-apps.list: List of app names to disable (one per line)
#     * Supports comments (lines starting with #)
#     * Ignores empty lines and whitespace
#
# OUTPUT:
#   - Modifies ../core/shipped.json in place
#   - Logs progress and results to stdout/stderr
#
# EXIT CODES:
#   0 - Success
#   1 - Fatal error (missing dependencies, invalid files, or processing errors)
#
# EXAMPLE disabled-apps.list:
#   # Core apps to disable
#   dashboard
#   weather_status
#
#   # Optional apps
#   recommendations
#
# NOTES:
#   - The 'alwaysEnabled' attribute is the critical one - it determines which
#     apps cannot be disabled by administrators
#   - The 'defaultEnabled' attribute only affects new installations, not updates
#   - All changes are validated before and after processing
#
# AUTHOR: IONOS Nextcloud Customization Team
# LICENSE: See LICENSES/ directory
#
################################################################################

# Configuration: Base directory and file paths
BDIR="$(dirname "${0}")"
SHIPPED_JSON="${BDIR}/../core/shipped.json"
DISABLED_APPS_FILE="${BDIR}/disabled-apps.list"

################################################################################
# Logging Functions
################################################################################

log_info() {
	printf "\033[0;32m[✓]\033[0m %s\n" "${*}"
}

log_warn() {
	printf "\033[0;33m[!]\033[0m %s\n" "${*}" >&2
}

log_fatal() {
	printf "\033[1;31m[✗]\033[0m Fatal Error: %s\n" "${*}" >&2
	exit 1
}

################################################################################
# Utility Functions
################################################################################

command_exists() {
	command -v "${1}" >/dev/null 2>&1
}

# Read app lists from .list files
read_app_list() {
	# Read app list from file, ignoring comments and empty lines
	# Usage: read_app_list <file_path>
	_list_file="${1}"
	if [ ! -f "${_list_file}" ]; then
		echo ""
		return
	fi
	grep -v '^[[:space:]]*#' "${_list_file}" | grep -v '^[[:space:]]*$' | tr '\n' ' '
}

################################################################################
# Core Functions
################################################################################

# Remove an app from shipped.json
# Removes the specified app from both defaultEnabled and alwaysEnabled arrays
# in the shipped.json file using jq for safe JSON manipulation
# Usage: unship_app <app_name>
# Arguments:
#   $1 - Name of the app to remove from shipped.json
# Side Effects:
#   - Creates a temporary file (shipped.json.tmp)
#   - Modifies shipped.json in place
#   - Logs success message
# Exit: Calls log_fatal on jq processing errors
unship_app() {
	app="${1}"
	temp_file="${SHIPPED_JSON}.tmp"

	# Use jq to safely remove the app from both arrays
	# The filter deletes matching entries from defaultEnabled and alwaysEnabled
	if ! jq --arg app "${app}" \
		'del(.defaultEnabled[] | select(. == $app)) | del(.alwaysEnabled[] | select(. == $app))' \
		"${SHIPPED_JSON}" > "${temp_file}"; then
		log_fatal "Failed to process ${app} with jq"
	fi

	# Atomically replace the original file
	mv "${temp_file}" "${SHIPPED_JSON}"
	log_info "Unshipped app '${app}'"
}

# Validate that shipped.json is valid JSON
# Performs a validation check on shipped.json using jq
# Usage: validate_shipped_json
# Exit: Calls log_fatal if JSON is invalid
validate_shipped_json() {
	if ! jq empty "${SHIPPED_JSON}" 2>/dev/null; then
		log_fatal "Invalid JSON in ${SHIPPED_JSON}"
	fi
}

main() {
	# Check prerequisites
	if ! command_exists jq; then
		log_fatal "jq is required but not installed"
	fi

	if [ ! -f "${SHIPPED_JSON}" ]; then
		log_fatal "Shipped JSON file not found: ${SHIPPED_JSON}"
	fi

	if [ ! -f "${DISABLED_APPS_FILE}" ]; then
		log_fatal "Disabled apps file not found: ${DISABLED_APPS_FILE}"
	fi

	# Validate shipped.json before processing
	validate_shipped_json

	# NOTE: alwaysEnabled should be the only attribute in this json file which
	# really matters, since it is the only attribute which is checked to
	# determine which apps can be disabled or not.
	# defaultEnabled is only used during installation, but not for updates.

	log_info "Removing apps from 'shipped' list..."

	# Load disabled apps list
	DISABLED_APPS=$(read_app_list "${DISABLED_APPS_FILE}")

	# Process each app in the list
	app_count=0
	for app in ${DISABLED_APPS}; do
		# Process the app
		unship_app "${app}"
		app_count=$((app_count + 1))
	done

	# Validate shipped.json after processing to ensure we didn't corrupt it
	validate_shipped_json

	log_info "Successfully processed ${app_count} apps"
}

# Execute main function
main
