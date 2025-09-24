#!/bin/sh
# SPDX-FileCopyrightText: 2025 STRATO GmbH
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

configure_notify_push_app() {
	log_info "Configure notify_push app"

	# Enable the notify_push app
	execute_occ_command app:enable notify_push
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

# Configure Elasticsearch integration
configure_fulltextsearch_apps() {
	log_info "Configuring Elasticsearch integration..."

	# Validate required environment variables
	_validation_failed=false

	if [ -z "${ELASTIC_NEXTCLOUD_USERNAME}" ]; then
		log_warning "ELASTIC_NEXTCLOUD_USERNAME environment variable is not set"
		_validation_failed=true
	fi

	if [ -z "${ELASTIC_NEXTCLOUD_PASSWORD}" ]; then
		log_warning "ELASTIC_NEXTCLOUD_PASSWORD environment variable is not set"
		_validation_failed=true
	fi

	if [ -z "${ELASTIC_SEARCH_INDEX_NAME}" ]; then
		log_warning "ELASTIC_SEARCH_INDEX_NAME environment variable is not set"
		_validation_failed=true
	fi

	if [ "${_validation_failed}" = "true" ]; then
		log_warning "fulltextsearch apps configuration skipped due to missing environment variables"
		return 0
	fi

	# Install fulltextsearch core app
	log_info "Enabling fulltextsearch core..."
	execute_occ_command app:enable fulltextsearch

	# Install files_fulltextsearch app
	log_info "Enabling files_fulltextsearch..."
	execute_occ_command app:enable files_fulltextsearch

	# Install fulltextsearch elasticsearch provider
	log_info "Enabling fulltextsearch_elasticsearch..."
	execute_occ_command app:enable fulltextsearch_elasticsearch

	# Install files fulltextsearch tesseract OCR support
	log_info "Enabling files_fulltextsearch_tesseract..."
	execute_occ_command app:enable files_fulltextsearch_tesseract

	# Configure fulltextsearch platform
	log_info "Configuring fulltextsearch platform..."
	execute_occ_command config:app:set fulltextsearch search_platform --value="OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"
	execute_occ_command config:app:set fulltextsearch app_navigation --value="1"

	# Configure Elasticsearch settings
	log_info "Configuring Elasticsearch settings..."
	execute_occ_command config:app:set fulltextsearch_elasticsearch elastic_host --value="https://${ELASTIC_NEXTCLOUD_USERNAME}:${ELASTIC_NEXTCLOUD_PASSWORD}@${ELASTIC_HOST:-elasticsearch.elasticsearch}:${ELASTIC_PORT:-9200}"
	execute_occ_command config:app:set fulltextsearch_elasticsearch elastic_index --value="${ELASTIC_SEARCH_INDEX_NAME}"
	execute_occ_command config:app:set fulltextsearch_elasticsearch analyzer_tokenizer --value="standard"
	execute_occ_command config:app:set fulltextsearch_elasticsearch elastic_ssl_cert --value="/etc/elasticsearch-certs/ca.crt"
	execute_occ_command config:app:set fulltextsearch_elasticsearch elastic_ssl_cert_verify --value="1"

	# Configure files_fulltextsearch settings
	log_info "Configuring files_fulltextsearch..."
	execute_occ_command config:app:set files_fulltextsearch files_audio --value="0"
	execute_occ_command config:app:set files_fulltextsearch files_encrypted --value="0"
	execute_occ_command config:app:set files_fulltextsearch files_external --value="1"
	execute_occ_command config:app:set files_fulltextsearch files_federated --value="0"
	execute_occ_command config:app:set files_fulltextsearch files_group_folders --value="1"
	execute_occ_command config:app:set files_fulltextsearch files_image --value="0"
	execute_occ_command config:app:set files_fulltextsearch files_local --value="1"
	execute_occ_command config:app:set files_fulltextsearch files_office --value="1"
	execute_occ_command config:app:set files_fulltextsearch files_pdf --value="1"
	execute_occ_command config:app:set files_fulltextsearch files_size --value="20"

	# Enable debug logging for fulltext search
	if [ "${ELASTIC_DEBUG_ENABLED}" = "1" ] || [ "${ELASTIC_DEBUG_ENABLED}" = "true" ]; then
		log_info "Enabling debug logging..."
		execute_occ_command config:system:set loglevel --value="0"
		execute_occ_command config:app:set fulltextsearch_elasticsearch debug --value="1"
		execute_occ_command config:app:set fulltextsearch debug --value="1"
	else
		log_info "Skipping debug logging (ELASTIC_DEBUG_ENABLED not set to 1/true)..."
	fi

	log_info "Fulltext search plugins installation and configuration completed"
}


config_apps() {
	log_info "Configure apps ..."

	log_info "Enable calendar app"
	execute_occ_command app:enable calendar

	log_info "Enable activity app"
	execute_occ_command app:enable activity

	log_info "Enable Contacts app"
	execute_occ_command app:enable contacts

	log_info "Enable mail app"
	execute_occ_command app:enable mail

	log_info "Enable tasks app"
	execute_occ_command app:enable tasks

	log_info "Enable Spreed app"
	execute_occ_command app:enable spreed

	log_info "Enable NCW Apps Menu app"
	execute_occ_command app:enable ncw_apps_menu

	configure_files_antivirus_app

	log_info "Configure viewer app"
	execute_occ_command config:app:set --value yes --type string viewer always_show_viewer

	configure_collabora_app
	configure_notify_push_app

	configure_fulltextsearch_apps

	log_info "Enable groupfolders app"
	execute_occ_command app:enable groupfolders
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
