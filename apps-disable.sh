#!/bin/sh
set -e

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

################################################################################
# Nextcloud Apps Configuration Script
################################################################################
#
# DESCRIPTION:
#   This script manages Nextcloud app configurations by:
#   1. Removing specified apps from the shipped.json file (disabling them)
#   2. Adding specified apps to the alwaysEnabled array (forcing them enabled)
#
#   It modifies the 'defaultEnabled' and 'alwaysEnabled' arrays in core/shipped.json
#   to control which apps are shipped with the installation and which cannot be
#   disabled by administrators.
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
#   The script reads app names from:
#   - disabled-apps.list: Apps to remove from shipped.json (one per line)
#   - always-enabled-apps.list: Apps to add to alwaysEnabled array (one per line)
#
# PREREQUISITES:
#   - jq (JSON processor) must be installed
#   - disabled-apps.list must exist in the same directory
#   - always-enabled-apps.list is optional but will be processed if present
#   - ../core/shipped.json must exist and be valid JSON
#
# INPUT FILES:
#   - disabled-apps.list: List of app names to disable (one per line)
#     * Supports comments (lines starting with #)
#     * Ignores empty lines and whitespace
#
#   ⚠️  NOTE: always-enabled-apps.list is NO LONGER processed by this script.
#   It is now handled at runtime by update-shipped-json.sh to avoid errors
#   when external apps aren't yet installed during fresh installations.
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
#   - Apps in always-enabled-apps.list are only added if not already present
#   - ⚠️ This script ONLY processes disabled-apps.list at build time
#   - Removes apps from both 'defaultEnabled' (prevents auto-enable on install)
#     and 'alwaysEnabled' (allows manual enabling if desired)
#   - All changes are validated before and after processing
#   - ⚠️  IMPORTANT: This script runs during Docker image build, NOT at runtime
#   - For always-enabled apps, use update-shipped-json.sh at runtime instead

# Configuration: Base directory and file paths
BDIR="$(dirname "${0}")"
SHIPPED_JSON="${BDIR}/../core/shipped.json"
DISABLED_APPS_FILE="${BDIR}/disabled-apps.list"
ALWAYS_ENABLED_APPS_FILE="${BDIR}/always-enabled-apps.list"

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

# Add an app to the shippedApps, defaultEnabled, and alwaysEnabled arrays in shipped.json
# Adds the specified app to all three arrays if not already present in the shipped.json file
# using jq for safe JSON manipulation.
# This ensures that:
#   - The app is marked as shipped (shippedApps) - hides it from app settings UI
#   - The app is enabled by default on fresh installations (defaultEnabled)
#   - The app cannot be disabled by administrators (alwaysEnabled)
# Usage: ship_app <app_name>
# Arguments:
#   $1 - Name of the app to add to all three arrays
# Side Effects:
#   - Creates a temporary file (shipped.json.tmp)
#   - Modifies shipped.json in place
#   - Logs success message
# Exit: Calls log_fatal on jq processing errors
ship_app() {
	app="${1}"
	temp_file="${SHIPPED_JSON}.tmp"

	# Use jq to safely add the app to shippedApps, defaultEnabled, and alwaysEnabled arrays
	# The filter checks if the app is already in each array before adding
	if ! jq --arg app "${app}" \
		'if (.shippedApps | index($app)) then . else .shippedApps += [$app] end |
		if (.defaultEnabled | index($app)) then . else .defaultEnabled += [$app] end |
		if (.alwaysEnabled | index($app)) then . else .alwaysEnabled += [$app] end' \
		"${SHIPPED_JSON}" > "${temp_file}"; then
		log_fatal "Failed to process ${app} with jq"
	fi

	# Atomically replace the original file
	mv "${temp_file}" "${SHIPPED_JSON}"
	log_info "Shipped app '${app}' (shipped, default enabled, and always enabled)"
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

	log_info "Processing apps configuration..."

	# Load disabled apps list
	DISABLED_APPS=$(read_app_list "${DISABLED_APPS_FILE}")

	# NOTE: always-enabled-apps.list is NOT processed during build anymore
	# External apps should be added to shipped.json at runtime via update-shipped-json.sh
	# This prevents errors when apps aren't yet enabled during installation
	ALWAYS_ENABLED_APPS=""

	# Process disabled apps - remove from shipped list
	disabled_count=0
	if [ -n "${DISABLED_APPS}" ]; then
		log_info "Removing apps from 'shipped' list..."
		for app in ${DISABLED_APPS}; do
			unship_app "${app}"
			disabled_count=$((disabled_count + 1))
		done
	fi

	# Process always-enabled apps - add to alwaysEnabled array
	enabled_count=0
	if [ -n "${ALWAYS_ENABLED_APPS}" ]; then
		log_info "Adding apps to 'alwaysEnabled' list..."
		for app in ${ALWAYS_ENABLED_APPS}; do
			ship_app "${app}"
			enabled_count=$((enabled_count + 1))
		done
	fi

	# Validate shipped.json after processing to ensure we didn't corrupt it
	validate_shipped_json

	log_info "Successfully processed ${disabled_count} disabled apps and ${enabled_count} always-enabled apps"
}

# Execute main function
main
