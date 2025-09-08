#!/bin/sh
# SPDX-FileCopyrightText: 2025 STRATO AG
# SPDX-License-Identifier: AGPL-3.0-or-later

SCRIPT_DIR="$(dirname "${0}")"
readonly SCRIPT_DIR
NEXTCLOUD_DIR="${SCRIPT_DIR}/.."
readonly NEXTCLOUD_DIR
LOGO_ABSOLUTE_DIR="$(cd "${NEXTCLOUD_DIR}/IONOS" && pwd)"
readonly LOGO_ABSOLUTE_DIR

# Execute NextCloud OCC command with error handling
# Usage: execute_occ_command <command> [args...]
execute_occ_command() {
	if ! php occ "${@}"; then
		log_error "Failed to execute OCC command: ${*}"
		return 1
	fi
}

# Log error message to stderr
# Usage: log_error <message>
log_error() {
	echo "\033[1;31m[e] Error: ${*}\033[0m" >&2
}

# Log fatal error message and exit with failure code
# Usage: log_fatal <message>
log_fatal() {
	echo "\033[1;31m[x] Fatal Error: ${*}\033[0m" >&2
	exit 1
}

# Log warning message with yellow color
# Usage: log_warning <message>
log_warning() {
	echo "\033[1;33m[w] Warning: ${*}\033[0m" >&2
}

# Log info message
# Usage: log_info <message>
log_info() {
	echo "[i] ${*}"
}

# Check if required dependencies are available
# Usage: check_dependencies
check_dependencies() {
	if ! which php >/dev/null 2>&1; then
		log_fatal "php is required but not found in PATH"
	fi
}

# Verify Nextcloud Workspace installation status
# Usage: verify_nextcloud_installation
verify_nextcloud_installation() {
	log_info "Verifying Nextcloud Workspace installation status..."
	_main_status="$( execute_occ_command status 2>/dev/null | grep 'installed: ' | sed -r 's/^.*installed: (.+)$/\1/' )"

	# Parse validation
	if [ "${_main_status}" != "true" ] && [ "${_main_status}" != "false" ]; then
		log_info "Error testing Nextcloud install status. This is the output of occ status:"
		execute_occ_command status
		log_fatal "Nextcloud is not installed, abort"
	elif [ "${_main_status}" != "true" ]; then
		log_fatal "Nextcloud is not installed, abort"
	fi
}

# Configure basic Nextcloud Workspace server settings
# Usage: configure_server_basics
configure_server_basics() {
	log_info "[i] Configuring Nextcloud Workspace server basics..."

	execute_occ_command config:system:set lookup_server --value=""
}

configure_theming() {
	log_info "Configuring Nextcloud Workspace theming..."

	execute_occ_command theming:config imprintUrl " "
	execute_occ_command theming:config privacyUrl " "
	execute_occ_command theming:config primary_color "#003D8F"
	execute_occ_command config:app:set --value "#ffffff"  -- theming background_color
	execute_occ_command theming:config disable-user-theming yes
	execute_occ_command theming:config disable_admin_theming yes
	#execute_occ_command theming:config favicon "${FAVICON_DIR}/favicon.ico"
	execute_occ_command config:app:set theming backgroundMime --value backgroundColor

	# Set homepage URL if configured
	_ionos_homepage=$(execute_occ_command config:system:get ionos_homepage)
	if [ -n "${_ionos_homepage}" ]; then
		execute_occ_command theming:config url "${_ionos_homepage}"
	fi
}

# Configure Collabora/richdocuments integration
# Usage: configure_collabora_app
configure_collabora_app() {
	log_info "Configuring Collabora integration..."
	# Disable app initially
	execute_occ_command app:disable richdocuments

	# Validate required environment variables
	if ! [ "${COLLABORA_WOPI_URL}" ]; then
		log_fatal "COLLABORA_WOPI_URL environment variable is not set"
	fi

	# Configure and enable Collabora
	execute_occ_command app:enable richdocuments
	execute_occ_command config:app:set richdocuments wopi_url --value="${COLLABORA_WOPI_URL}"
	execute_occ_command config:app:set richdocuments public_wopi_url --value="${COLLABORA_WOPI_URL}"
	execute_occ_command config:app:set richdocuments enabled --value='yes'

	# Configure SSL certificate verification
	if [ "${COLLABORA_SELF_SIGNED}" = "true" ]; then
		execute_occ_command config:app:set richdocuments disable_certificate_verification --value="yes"
	else
		execute_occ_command config:app:set richdocuments disable_certificate_verification --value="no"
	fi

	execute_occ_command richdocuments:activate-config
}

# Configure files_antivirus app
# Usage: configure_files_antivirus_app
configure_files_antivirus_app() {
	log_info "Configure files_antivirus app"

	execute_occ_command app:disable files_antivirus

	# Validate required environment variables
	_validation_failed=false

	if [ -z "${CLAMAV_HOST}" ]; then
		log_warning "CLAMAV_HOST environment variable is not set"
		_validation_failed=true
	fi

	if [ -z "${CLAMAV_PORT}" ]; then
		log_warning "CLAMAV_PORT environment variable is not set"
		_validation_failed=true
	fi

	if [ -z "${CLAMAV_MAX_FILE_SIZE}" ]; then
		log_warning "CLAMAV_MAX_FILE_SIZE environment variable is not set"
		_validation_failed=true
	fi

	if [ -z "${CLAMAV_MAX_STREAM_LENGTH}" ]; then
		log_warning "CLAMAV_MAX_STREAM_LENGTH environment variable is not set"
		_validation_failed=true
	fi

	# Only proceed if all variables are set
	if [ "${_validation_failed}" = "true" ]; then
		log_warning "files_antivirus app configuration skipped due to missing environment variables"
		return 0
	fi

	# Configure clamav with validated values
	execute_occ_command config:app:set files_antivirus av_mode --value="daemon"
	execute_occ_command config:app:set files_antivirus av_host --value="${CLAMAV_HOST:-clamav.clamav}"
	execute_occ_command config:app:set files_antivirus av_port --value="${CLAMAV_PORT:-3310}"
	execute_occ_command config:app:set files_antivirus av_max_file_size --value="${CLAMAV_MAX_FILE_SIZE:-314572800}"
	execute_occ_command config:app:set files_antivirus av_stream_max_length --value="${CLAMAV_MAX_STREAM_LENGTH:-314572800}"

	execute_occ_command app:enable files_antivirus

	log_info "files_antivirus app configured successfully with host: ${CLAMAV_HOST}, port: ${CLAMAV_PORT}"
}

config_apps() {
	log_info "Configure apps ..."

	log_info "Enable calendar app"
	execute_occ_command app:enable calendar

	log_info "Enable Contacts app"
	execute_occ_command app:enable contacts

	configure_files_antivirus_app

	log_info "Configure viewer app"
	execute_occ_command config:app:set --value yes --type string viewer always_show_viewer

	configure_collabora_app

}

#===============================================================================
# Main Execution Function
#===============================================================================

# Main function to orchestrate Nextcloud Workspace configuration
# Usage: main [args...]
main() {
	log_info "Starting Nextcloud Workspace configuration process..."

	# Perform initial checks
	check_dependencies
	verify_nextcloud_installation

	# Execute configuration steps
	configure_theming
	config_apps

	echo "\033[1;32m[i] Nextcloud Workspace configuration completed successfully!\033[0m"
}

# Execute main function with all script arguments
main "${@}"
