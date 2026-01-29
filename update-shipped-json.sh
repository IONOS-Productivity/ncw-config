#!/bin/sh
set -e

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

################################################################################
# Update shipped.json at Runtime
################################################################################
#
# DESCRIPTION:
#   This script modifies core/shipped.json at RUNTIME (not during build) to add
#   apps from always-enabled-apps.list to the shippedApps and alwaysEnabled arrays.
#
#   This ensures apps are enabled FIRST (with DB tables created), THEN added
#   to shipped.json to prevent them from being disabled by users and hide them
#   from the app management UI.
#
# EXECUTION CONTEXT:
#   ⚠️  IMPORTANT: Run this AFTER apps are enabled (via configure.sh or apps-enable.sh)
#
#   Typical workflow:
#   1. Install Nextcloud (with original shipped.json)
#   2. Enable apps via configure.sh or apps-enable.sh
#   3. Run this script to lock apps in shipped.json
#
# USAGE:
#   ./update-shipped-json.sh
#
# PREREQUISITES:
#   - jq must be installed
#   - Apps listed in always-enabled-apps.list must be enabled
#   - core/shipped.json must exist and be writable
#
################################################################################

BDIR="$(dirname "${0}")"
SHIPPED_JSON="${BDIR}/../core/shipped.json"
ALWAYS_ENABLED_APPS_FILE="${BDIR}/always-enabled-apps.list"

# Logging functions
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

# Read app list from file
read_app_list() {
	_list_file="${1}"
	if [ ! -f "${_list_file}" ]; then
		echo ""
		return
	fi
	grep -v '^[[:space:]]*#' "${_list_file}" | grep -v '^[[:space:]]*$' | tr '\n' ' '
}

# Add an app to shipped.json arrays
add_app_to_shipped_json() {
	_app="${1}"
	_temp_file="${SHIPPED_JSON}.tmp"

	log_info "Adding ${_app} to shipped.json arrays..."

	# Add to shippedApps (hides from UI) and alwaysEnabled (prevents disabling)
	# Note: defaultEnabled is not updated as it only affects fresh installations
	if ! jq --arg app "${_app}" \
		'if (.shippedApps | index($app)) then . else .shippedApps += [$app] end |
		if (.alwaysEnabled | index($app)) then . else .alwaysEnabled += [$app] end' \
		"${SHIPPED_JSON}" > "${_temp_file}"; then
		log_fatal "Failed to process ${_app} with jq"
	fi

	# Atomically replace the original file
	mv "${_temp_file}" "${SHIPPED_JSON}"
}

# Validate shipped.json
validate_shipped_json() {
	if ! jq empty "${SHIPPED_JSON}" 2>/dev/null; then
		log_fatal "Invalid JSON in ${SHIPPED_JSON}"
	fi
}

main() {
	log_info "Updating shipped.json with always-enabled apps..."

	# Check prerequisites
	if ! which jq >/dev/null 2>&1; then
		log_fatal "jq is required but not installed"
	fi

	if [ ! -f "${SHIPPED_JSON}" ]; then
		log_fatal "shipped.json not found: ${SHIPPED_JSON}"
	fi

	if [ ! -f "${ALWAYS_ENABLED_APPS_FILE}" ]; then
		log_warn "always-enabled-apps.list not found: ${ALWAYS_ENABLED_APPS_FILE}"
		log_info "Nothing to do."
		exit 0
	fi

	# Validate before processing
	validate_shipped_json

	# Load apps list
	ALWAYS_ENABLED_APPS=$(read_app_list "${ALWAYS_ENABLED_APPS_FILE}")

	if [ -z "${ALWAYS_ENABLED_APPS}" ]; then
		log_info "No apps to add to shipped.json"
		exit 0
	fi

	# Process each app
	_count=0
	for app in ${ALWAYS_ENABLED_APPS}; do
		add_app_to_shipped_json "${app}"
		_count=$((_count + 1))
	done

	# Validate after processing
	validate_shipped_json

	log_info "Successfully added ${_count} apps to shipped.json"
	log_info "These apps are now locked and cannot be disabled by users."
}

main "${@}"
