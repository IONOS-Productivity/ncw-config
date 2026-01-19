#!/bin/sh
set -e

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

################################################################################
# Runtime Always-Enabled Apps Enforcement Script
################################################################################
#
# DESCRIPTION:
#   This script enforces that specific Nextcloud apps remain enabled and
#   cannot be disabled by administrators. Unlike the build-time approach
#   (apps-disable.sh), this script runs at RUNTIME and survives updates.
#
# WHY THIS APPROACH:
#   - The alwaysEnabled array in shipped.json is only checked during initial
#     installation, not during updates
#   - Modifying shipped.json at build time doesn't persist across Nextcloud
#     core updates
#   - This runtime approach ensures apps stay enabled regardless of updates
#
# HOW IT WORKS:
#   1. Reads app list from always-enabled-apps.list
#   2. Adds apps to the alwaysEnabled array in core/shipped.json
#   3. Force-enables each app using OCC (php occ app:enable)
#   4. Nextcloud's AppManager prevents disabling apps in alwaysEnabled array
#
# EXECUTION CONTEXT:
#   ✅ Run this script:
#   - During Nextcloud installation/first run
#   - After Nextcloud updates
#   - On pod startup (in Kubernetes init containers or startup scripts)
#   - Periodically via cron (optional, for extra safety)
#
# USAGE:
#   ./enforce-always-enabled-apps.sh
#
# PREREQUISITES:
#   - Nextcloud must be installed
#   - OCC command must be available
#   - always-enabled-apps.list must exist in the same directory
#
# INPUT FILES:
#   - always-enabled-apps.list: Apps to force enable (one per line)
#
# OUTPUT:
#   - Logs progress to stdout/stderr
#   - Enables apps via OCC
#
# EXIT CODES:
#   0 - Success
#   1 - Fatal error
#
# NOTES:
#   - This script is safe to run multiple times (idempotent)
#   - Already enabled apps are skipped gracefully
#   - Missing apps are logged as warnings, not fatal errors
#   - Apps are enabled globally (for all users)
#
################################################################################

# Configuration
BDIR="$(dirname "${0}")"
ALWAYS_ENABLED_APPS_FILE="${BDIR}/always-enabled-apps.list"
OCC_CMD="${BDIR}/../occ"
SHIPPED_JSON="${BDIR}/../core/shipped.json"

################################################################################
# Logging Functions
################################################################################

log_info() {
	printf "\033[0;34m[i]\033[0m %s\n" "${*}"
}

log_success() {
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

# Add an app to the alwaysEnabled array in shipped.json
# Usage: add_to_always_enabled <app_id>
add_to_always_enabled() {
	_app_id="${1}"
	_temp_file="${SHIPPED_JSON}.tmp"

	# Check if shipped.json exists
	if [ ! -f "${SHIPPED_JSON}" ]; then
		log_warn "shipped.json not found at ${SHIPPED_JSON}"
		return 1
	fi

	# Check if app is already in alwaysEnabled array
	if jq -e --arg app "${_app_id}" '.alwaysEnabled | index($app)' "${SHIPPED_JSON}" >/dev/null 2>&1; then
		return 0  # Already in array, skip
	fi

	# Add app to alwaysEnabled array using jq
	if ! jq --arg app "${_app_id}" \
		'if (.alwaysEnabled | index($app)) then . else .alwaysEnabled += [$app] end' \
		"${SHIPPED_JSON}" > "${_temp_file}"; then
		log_warn "Failed to add '${_app_id}' to alwaysEnabled array"
		rm -f "${_temp_file}"
		return 1
	fi

	# Replace original file
	mv "${_temp_file}" "${SHIPPED_JSON}"
	return 0
}

# Execute OCC command with error handling
# Usage: execute_occ_command <command> [args...]
execute_occ_command() {
	if ! php "${OCC_CMD}" "$@" 2>&1; then
		return 1
	fi
	return 0
}

# Read app list from .list file
read_app_list() {
	_list_file="${1}"
	if [ ! -f "${_list_file}" ]; then
		echo ""
		return
	fi
	grep -v '^[[:space:]]*#' "${_list_file}" | grep -v '^[[:space:]]*$' | tr '\n' ' '
}

# Check if an app is installed
# Usage: app_exists <app_id>
# Returns: 0 if app exists, 1 if not
app_exists() {
	_app_id="${1}"
	execute_occ_command app:list --output=json | grep -q "\"${_app_id}\""
}

# Check if an app is enabled
# Usage: app_is_enabled <app_id>
# Returns: 0 if enabled, 1 if not
app_is_enabled() {
	_app_id="${1}"
	_enabled_apps=$(execute_occ_command app:list --enabled --output=json | grep -o "\"${_app_id}\"" || true)
	[ -n "${_enabled_apps}" ]
}

# Force-enable an app
# Usage: force_enable_app <app_id>
force_enable_app() {
	_app_id="${1}"

	# Check if app exists
	if ! app_exists "${_app_id}"; then
		log_warn "App '${_app_id}' is not installed, skipping"
		return 1
	fi

	# Check if already enabled
	if app_is_enabled "${_app_id}"; then
		log_info "App '${_app_id}' is already enabled, skipping"
		return 0
	fi

	# Enable the app
	log_info "Force-enabling app '${_app_id}'..."
	if execute_occ_command app:enable "${_app_id}"; then
		log_success "App '${_app_id}' enabled successfully"
		return 0
	else
		log_warn "Failed to enable app '${_app_id}'"
		return 1
	fi
}

################################################################################
# Main Function
################################################################################

main() {
	# Check prerequisites
	if ! command_exists php; then
		log_fatal "PHP is required but not installed"
	fi

	if ! command_exists jq; then
		log_fatal "jq is required but not installed"
	fi

	if [ ! -f "${OCC_CMD}" ]; then
		log_fatal "OCC command not found at ${OCC_CMD}"
	fi

	if [ ! -f "${SHIPPED_JSON}" ]; then
		log_fatal "shipped.json not found at ${SHIPPED_JSON}"
	fi

	if [ ! -f "${ALWAYS_ENABLED_APPS_FILE}" ]; then
		log_warn "Always-enabled apps list not found at ${ALWAYS_ENABLED_APPS_FILE}"
		log_info "Nothing to enforce, exiting"
		exit 0
	fi

	# Check if Nextcloud is installed
	if ! execute_occ_command status --output=json | grep -q '"installed":true'; then
		log_fatal "Nextcloud is not installed. Please install Nextcloud first."
	fi

	log_info "Starting always-enabled apps enforcement..."
	log_info "Reading app list from ${ALWAYS_ENABLED_APPS_FILE}"

	# Read the app list
	APPS_TO_ENABLE=$(read_app_list "${ALWAYS_ENABLED_APPS_FILE}")

	if [ -z "${APPS_TO_ENABLE}" ]; then
		log_info "No apps to enforce, exiting"
		exit 0
	fi

	# Count apps for summary
	_total_apps=$(echo "${APPS_TO_ENABLE}" | wc -w)
	_enabled_count=0
	_already_enabled_count=0
	_failed_count=0
	_missing_count=0
	_added_to_always_enabled=0

	log_info "Found ${_total_apps} apps to enforce"
	echo

	# First, add all apps to alwaysEnabled array in shipped.json
	log_info "Adding apps to alwaysEnabled array in shipped.json..."
	for app_id in ${APPS_TO_ENABLE}; do
		if add_to_always_enabled "${app_id}"; then
			_added_to_always_enabled=$((_added_to_always_enabled + 1))
		fi
	done
	log_success "Added ${_added_to_always_enabled} apps to alwaysEnabled array"
	echo

	# Then, enable each app
	log_info "Enabling apps..."
	for app_id in ${APPS_TO_ENABLE}; do
		printf "[→] Processing app: %s" "${app_id}"

		# Check if app exists
		if ! app_exists "${app_id}"; then
			printf " - NOT INSTALLED\n"
			_missing_count=$((_missing_count + 1))
			log_warn "App '${app_id}' is not installed"
			continue
		fi

		# Check if already enabled
		if app_is_enabled "${app_id}"; then
			printf " - already enabled ✓\n"
			_already_enabled_count=$((_already_enabled_count + 1))
			continue
		fi

		# Try to enable
		printf " - enabling..."
		if execute_occ_command app:enable "${app_id}" >/dev/null 2>&1; then
			printf " ✓\n"
			_enabled_count=$((_enabled_count + 1))
		else
			printf " ✗\n"
			_failed_count=$((_failed_count + 1))
			log_warn "Failed to enable app '${app_id}'"
		fi
	done

	echo
	log_info "============================================"
	log_info "Always-Enabled Apps Enforcement Summary"
	log_info "============================================"
	log_success "Total apps in list: ${_total_apps}"
	log_success "Added to alwaysEnabled: ${_added_to_always_enabled}"
	log_success "Already enabled: ${_already_enabled_count}"
	log_success "Newly enabled: ${_enabled_count}"
	if [ ${_missing_count} -gt 0 ]; then
		log_warn "Not installed: ${_missing_count}"
	fi
	if [ ${_failed_count} -gt 0 ]; then
		log_warn "Failed to enable: ${_failed_count}"
	fi
	log_info "============================================"

	if [ ${_failed_count} -gt 0 ]; then
		log_warn "Some apps could not be enabled. Check logs above for details."
		exit 1
	fi

	log_success "Always-enabled apps enforcement completed successfully"
	exit 0
}

main
