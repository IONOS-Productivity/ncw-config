#!/bin/sh

set -e

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# This script assumes to be located in /IONOS as submodule within the Nextcloud server
# repository.

# --- colors
_color_bold="\033[1m"
_color_red="\033[0;31m"
_color_green="\033[0;32m"
_color_yellow="\033[0;33m"
_color_blue="\033[0;34m"
_color_reset="\033[0m"
# ---

BDIR="$( dirname "${0}" )"

NEXTCLOUD_DIR="${BDIR}/.."

# Read app lists from .list files
read_app_list() {
	# Read app list from file, ignoring comments and empty lines
	# Usage: read_app_list <file_path>
	_list_file="${1}"
	if [ ! -f "${_list_file}" ]; then
		echo ""
		return
	fi
	grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${_list_file}" | tr '\n' ' '
}

DISABLED_APPS=$( read_app_list "${BDIR}/disabled-apps.list" )
ENABLED_CORE_APPS=$( read_app_list "${BDIR}/enabled-core-apps.list" )
ALWAYS_ENABLED_APPS=$( read_app_list "${BDIR}/always-enabled-apps.list" )
REMOVED_APPS=$( read_app_list "${BDIR}/removed-apps.txt" )

execute_occ_command() {
	php "${NEXTCLOUD_DIR}/occ" \
		"${@}"
}

# Log info message
# Usage: log_info <message>
log_info() {
	printf "${_color_blue}[i] %s${_color_reset}\n" "${*}"
}

# Log success message
# Usage: log_success <message>
log_success() {
	printf "${_color_green}[✓] %s${_color_reset}\n" "${*}"
}

# Log warning message
# Usage: log_warn <message>
log_warn() {
	printf "${_color_yellow}[!] %s${_color_reset}\n" "${*}"
}

# Log fatal error message and exit with failure code
# Usage: log_fatal <message>
log_fatal() {
	printf "${_color_red}[x] Fatal Error: %s${_color_reset}\n" "${*}" >&2
	exit 1
}

enable_app() {
	# Enable app and check if it was enabled
	# Return 1 if enabling the app failed, 0 if successful
	#
	app_name="${1}"
	log_info "Enable app '${app_name}' ..."

	if ! execute_occ_command app:enable "${app_name}"
	then
		log_warn "Enabling app \"${app_name}\" failed."
		return 1
	fi
	log_success "App \"${app_name}\" enabled."
	return 0
}

disable_app() {
	# Disable app and check if it was disabled
	# Fail if disabling the app failed
	#
	app_name="${1}"
	log_info "Disable app '${app_name}' ..."

		if ! execute_occ_command app:disable "${app_name}"
		then
			log_fatal "Disable app \"${app_name}\" failed."
		fi
		log_success "App \"${app_name}\" disabled."
}

disable_removed_apps() {
	# Disable apps from removed-apps.txt (always disable without checking state)
	#
	_count=0

	if [ -z "${REMOVED_APPS}" ]; then
		log_info "No removed apps to disable."
		return
	fi

	log_info "Disabling removed apps..."
	for app in ${REMOVED_APPS}; do
		printf "${_color_blue}[i] Disabling removed app: %s${_color_reset}\n" "${app}"
		disable_app "${app}"
		_count=$(( _count + 1 ))
	done

	log_success "Disabled ${_count} removed apps."
	echo
}

ensure_app_states() {
	# Ensure apps are in the desired state (enabled/disabled)
	#
	_enabled_apps_count=0
	_disabled_apps_count=0

	log_info "Check app states..."

	if ! apps_json=$(execute_occ_command app:list --output json); then
		log_fatal "Failed to get app list"
	fi

	if ! enabled_apps=$(echo "${apps_json}" | jq -r '.enabled | keys | .[]' 2>/dev/null); then
		log_fatal "Failed to parse enabled apps JSON. Output was: ${apps_json}"
	fi

	if ! disabled_apps=$(echo "${apps_json}" | jq -r '.disabled | keys | .[]' 2>/dev/null); then
		log_fatal "Failed to parse disabled apps JSON. Output was: ${apps_json}"
	fi

	# Ensure apps are disabled
	for app in ${DISABLED_APPS}; do
		printf "${_color_blue}[i] Checking app to disable: %s${_color_reset}" "${app}"
		if echo "${enabled_apps}" | grep -q -w "${app}"; then
			printf " - currently enabled - disabling\n"
			disable_app "${app}"
			_disabled_apps_count=$(( _disabled_apps_count + 1 ))
		else
			printf " - already disabled - skip\n"
		fi
	done

	# Ensure core apps are enabled
	for app in ${ENABLED_CORE_APPS}; do
		printf "${_color_blue}[i] Checking core app to enable: %s${_color_reset}" "${app}"
		if echo "${DISABLED_APPS}" | grep -q -w "${app}"; then
			printf " - is in DISABLED_APPS list - skipping\n"
			continue
		fi

		if echo "${disabled_apps}" | grep -q -w "${app}"; then
			printf " - currently disabled - enabling\n"
			if enable_app "${app}"; then
				_enabled_apps_count=$(( _enabled_apps_count + 1 ))
			fi
		else
			printf " - already enabled - skip\n"
		fi
	done

	# Ensure always-enabled apps are enabled (typically external apps)
	for app in ${ALWAYS_ENABLED_APPS}; do
		printf "${_color_blue}[i] Checking always-enabled app to enable: %s${_color_reset}" "${app}"
		if echo "${DISABLED_APPS}" | grep -q -w "${app}"; then
			printf " - is in DISABLED_APPS list - skipping\n"
			continue
		fi

		if echo "${disabled_apps}" | grep -q -w "${app}"; then
			printf " - currently disabled - enabling\n"
			if enable_app "${app}"; then
				_enabled_apps_count=$(( _enabled_apps_count + 1 ))
			fi
		else
			printf " - already enabled - skip\n"
		fi
	done

	echo
	log_success "Disabled ${_disabled_apps_count} apps."
	log_success "Enabled ${_enabled_apps_count} core apps."
	log_success "Done."
}

main() {
	if ! jq --version >/dev/null 2>&1; then
		log_fatal "Error: jq is required"
	fi

	log_info "Ensuring app states..."
	disable_removed_apps
	ensure_app_states
}

main
