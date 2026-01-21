#!/bin/sh
# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

SCRIPT_DIR="$(dirname "${0}")"
readonly SCRIPT_DIR
NEXTCLOUD_DIR="${SCRIPT_DIR}/.."
readonly NEXTCLOUD_DIR
LOGO_ABSOLUTE_DIR="$(cd "${NEXTCLOUD_DIR}/IONOS" && pwd)"
readonly LOGO_ABSOLUTE_DIR

# Global flag for verbose command logging
VERBOSE_OCC_LOGGING=false

# Log file for OCC commands (only used when VERBOSE_OCC_LOGGING=true)
OCC_LOG_FILE=""

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

DISABLED_APPS=$( read_app_list "${BDIR}/disabled-apps.list" )

#===============================================================================
# Configuration Constants
#===============================================================================

# Admin delegation map: defines which app settings classes should be delegated
# Format: app_name:full_class_path (one per line)
# Each entry maps an app to its admin settings class that will be delegated
# Note: Entries are sorted by app name before processing to ensure apps with
#       multiple delegations are only enabled/disabled once
readonly ADMIN_DELEGATION_MAP="
groupfolders:OCA\\GroupFolders\\Settings\\Admin
mail:OCA\\Mail\\Settings\\AdminSettings
oauth2:OCA\\OAuth2\\Settings\\Admin
password_policy:OCA\\Password_Policy\\Settings\\Settings
settings:OCA\\Settings\\Settings\\Admin\\Security
systemtags:OCA\\SystemTags\\Settings\\Admin
user_ldap:OCA\\User_LDAP\\Settings\\Admin
"

#===============================================================================
# Logging Functions
#===============================================================================

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

# Log success message
# Usage: log_success <message>
log_success() {
	echo "\033[1;32m[✓] ${*}\033[0m"
}

#===============================================================================
# Helper Functions
#===============================================================================

# Execute NextCloud OCC command with error handling
# Usage: execute_occ_command <command> [args...]
execute_occ_command() {
	# Check if this is a config:system:set command and warn about partial config
	if [ "${1}" = "config:system:set" ]; then
		log_warning "config:system:set should be avoided. Use PHP <foo>.config.php files in configs/ directory instead. Command: ${*}"
	fi

	if [ "${VERBOSE_OCC_LOGGING}" = "true" ]; then
		# Check if command contains --sensitive flag to obscure sensitive values
		_log_command="${*}"
		if echo "${*}" | grep -q -- "--sensitive"; then
			# Obscure the value after --sensitive flag
			_log_command=$(echo "${*}" | sed -E 's/(--value[= ])[^ ]+( .*--sensitive)/\1***REDACTED***\2/g; s/(--sensitive.*--value[= ])[^ ]+/\1***REDACTED***/g')
		fi

		# Log to stderr to avoid interfering with command output capture
		echo "[i] Executing OCC command: ${_log_command}" >&2
		# Write command to log file (also obscured)
		echo "occ ${_log_command}" >> "${OCC_LOG_FILE}" 2>&1
	fi

	if ! php occ "${@}"; then
		log_error "Failed to execute OCC command: ${*}"
		return 1
	fi
}

# Validate required environment variables
# Usage: validate_env_vars <var1> <var2> ...
# Returns: 0 if all variables are set, 1 otherwise
validate_env_vars() {
	_validation_failed=false

	for _var in "${@}"; do
		eval "_value=\${${_var}}"
		if [ -z "${_value}" ]; then
			log_warning "${_var} environment variable is not set"
			_validation_failed=true
		fi
	done

	if [ "${_validation_failed}" = "true" ]; then
		return 1
	fi
	return 0
}

# Set app config value with automatic type checking and correction
# Usage: set_app_config_typed <app> <key> <value> <expected_type> [additional_flags...]
# Expected types: string, integer, float, boolean, array
# This function checks if the key exists with wrong type and deletes it before setting
# Additional flags like --sensitive can be passed as extra arguments
set_app_config_typed() {
	_app="${1}"
	_key="${2}"
	_value="${3}"
	_expected_type="${4}"
	shift 4  # Remove first 4 args, leaving any additional flags
	
	# Get current config value with type information from JSON output
	_current_json=$(php occ config:list "${_app}" --private 2>/dev/null)
	_current_value=$(echo "${_current_json}" | jq -r ".apps.\"${_app}\".\"${_key}\" // empty" 2>/dev/null)
	
	if [ -n "${_current_value}" ]; then
		# Check if value has quotes (string) or not (integer/boolean/float) in raw JSON
		_raw_value=$(echo "${_current_json}" | jq ".apps.\"${_app}\".\"${_key}\"" 2>/dev/null)
		
		# Check if value has quotes (string) or not (integer/boolean/float)
		case "${_expected_type}" in
			string|array)
				# String/array should have quotes in JSON output: "key": "value"
				if ! echo "${_raw_value}" | grep -q '^"'; then
					log_info "Config key ${_key} exists with wrong type (current: ${_current_value}, expected: ${_expected_type}), deleting..."
					execute_occ_command config:app:delete "${_app}" "${_key}"
				fi
				;;
			integer|float|boolean)
				# Integer/float/boolean should NOT have quotes: "key": 1000
				if echo "${_raw_value}" | grep -q '^"'; then
					log_info "Config key ${_key} exists with wrong type (current: ${_current_value}, expected: ${_expected_type}), deleting..."
					execute_occ_command config:app:delete "${_app}" "${_key}"
				fi
				;;
		esac
	fi
	
	# Set with correct type (pass through any additional flags like --sensitive)
	execute_occ_command config:app:set --value "${_value}" --type "${_expected_type}" "$@" "${_app}" "${_key}"
}

# Enable a Nextcloud app with logging
# Usage: enable_app <app_name> [display_name]
enable_app() {
	_app_name="${1}"
	_display_name="${2:-${1}}"

	log_info "Enable ${_display_name} app"
	execute_occ_command app:enable "${_app_name}"
}

# Check if required dependencies are available
# Usage: check_dependencies
check_dependencies() {
	if ! which php >/dev/null 2>&1; then
		log_fatal "php is required but not found in PATH"
	fi

	if ! which jq >/dev/null 2>&1; then
		log_fatal "jq is required but not found in PATH"
	fi
}

# Verify Nextcloud Workspace installation status
# Usage: verify_nextcloud_installation
verify_nextcloud_installation() {
	log_info "Verifying Nextcloud Workspace installation status..."
	_main_status="$(execute_occ_command status 2>/dev/null | grep 'installed: ' | sed -r 's/^.*installed: (.+)$/\1/')"

	# Parse validation
	if [ "${_main_status}" != "true" ] && [ "${_main_status}" != "false" ]; then
		log_info "Error testing Nextcloud install status. This is the output of occ status:"
		execute_occ_command status
		log_fatal "Nextcloud is not installed, abort"
	elif [ "${_main_status}" != "true" ]; then
		log_fatal "Nextcloud is not installed, abort"
	fi
}

#===============================================================================
# Configuration Functions
#===============================================================================

# Configure Nextcloud Workspace theming
# Usage: configure_theming
configure_theming() {
	log_info "Configuring Nextcloud Workspace theming..."

	execute_occ_command theming:config imprintUrl ""
	execute_occ_command theming:config privacyUrl ""
	execute_occ_command theming:config primary_color "#003D8F"
	execute_occ_command config:app:set --value "#ffffff" -- theming background_color
	execute_occ_command theming:config disable-user-theming yes
	execute_occ_command theming:config disable_admin_theming yes
	#execute_occ_command theming:config favicon "${FAVICON_DIR}/favicon.ico"
	execute_occ_command config:app:set theming backgroundMime --value backgroundColor
	execute_occ_command theming:config url ""
	execute_occ_command config:app:set settings display_documentation_link --type boolean --value false

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

	if [ "${COLLABORA_WOPI_ALLOWLIST}" ]; then
		execute_occ_command config:app:set richdocuments wopi_allowlist --value="${COLLABORA_WOPI_ALLOWLIST}"
	else
		log_warning "COLLABORA_WOPI_ALLOWLIST environment variable is not set. Collabora WOPI allowlist will not be configured."
	fi

	# Configure SSL certificate verification
	if [ "${COLLABORA_SELF_SIGNED}" = "true" ]; then
		execute_occ_command config:app:set richdocuments disable_certificate_verification --value="yes"
	else
		execute_occ_command config:app:set richdocuments disable_certificate_verification --value="no"
	fi

	execute_occ_command richdocuments:activate-config
}

# Configure notify_push app
# Usage: configure_notify_push_app
configure_notify_push_app() {
	log_info "Configuring notify_push app..."
	execute_occ_command app:enable notify_push

	log_info "Retrieving base URL for notify_push endpoint..."
	_base_url=$(execute_occ_command config:system:get overwrite.cli.url)

	if [ -z "${_base_url}" ]; then
		log_warning "Base URL (overwrite.cli.url) is not set. notify_push base_endpoint cannot be configured."
		return 0
	fi

	_notify_push_endpoint="${_base_url}/push"
	log_info "Setting notify_push base_endpoint: ${_notify_push_endpoint}"

	execute_occ_command config:app:set --value "${_notify_push_endpoint}" --type string -- notify_push base_endpoint
}

# Configure files_antivirus app
# Usage: configure_files_antivirus_app
configure_files_antivirus_app() {
	log_info "Configuring files_antivirus app..."

	execute_occ_command app:disable files_antivirus

	# Validate required environment variables
	if ! validate_env_vars CLAMAV_HOST CLAMAV_PORT CLAMAV_MAX_FILE_SIZE CLAMAV_MAX_STREAM_LENGTH; then
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

# Configure whiteboard app
# Usage: configure_whiteboard_app
configure_whiteboard_app() {
	log_info "Configuring whiteboard app..."
	execute_occ_command config:app:set whiteboard collabBackendUrl --value="${APP_WHITEBOARD_COLLABBACKEND_URL}:${APP_WHITEBOARD_COLLABBACKEND_PORT:-3002}"
	execute_occ_command config:app:set whiteboard jwt_secret_key --sensitive --value="${APP_WHITEBOARD_JWT_SECRET}"
}

# Configure spreed app
# Usage: configure_spreed_app
configure_spreed_app() {
	log_info "Configuring spreed (talk) app..."

	# Validate required environment variables
	if ! validate_env_vars HPB_URL HPB_SECRET TURN_SERVER_TCP_URL TURN_SERVER_SECRET; then
		log_warning "spreed app configuration skipped due to missing environment variables"
		execute_occ_command app:disable spreed
		return 0
	fi

	enable_app spreed "Spreed"

	# Configure High Performance Backend (HPB) signaling
	log_info "Configuring talk signaling server: ${HPB_URL}"

	# Remove existing signaling servers
	_server_list=$(execute_occ_command talk:signaling:list --output=json_pretty | jq -r '.servers[].server' 2>/dev/null | sort -u || echo "")
	echo "_server_list: $_server_list"

	if [ -z "${_server_list}" ]; then
		log_info "No existing signaling servers found"
	else
		echo "${_server_list}" | while IFS= read -r _existing_server; do
			if [ -n "${_existing_server}" ]; then
				log_info "Removing existing signaling server: ${_existing_server}"
				execute_occ_command talk:signaling:delete "${_existing_server}" || log_warning "Failed to delete signaling server: ${_existing_server}"
			fi
		done
	fi

	# Add new signaling server
	execute_occ_command talk:signaling:add "${HPB_URL}" "${HPB_SECRET}"

	# Configure TURN servers
	turnList=$(execute_occ_command talk:turn:list --output=json_pretty 2>/dev/null || echo "")
	if [ -z "${turnList}" ]; then
		log_info "Existing TURN servers found. Proceeding with deletion..."
		echo "$turnList" | \
		jq -r '.[] | [.schemes, .server, .protocols] | @tsv' | \
		xargs -n 3 execute_occ_command talk:turn:delete
	else
		log_info "No existing TURN servers found. Nothing to delete."
	fi

	log_info "Configuring new TURN server: ${TURN_SERVER_TCP_URL}"
	execute_occ_command talk:turn:add turn "${TURN_SERVER_TCP_URL}" tcp --secret "${TURN_SERVER_SECRET}"

	if [ "${TURN_SERVER_UDP_URL}" ]; then
		log_info "Configuring TURN server: ${TURN_SERVER_UDP_URL}"
		execute_occ_command talk:turn:add turn "${TURN_SERVER_UDP_URL}" udp --secret "${TURN_SERVER_SECRET}"
	else
		log_info "Skipping TURN server configuration (TURN_SERVER_UDP_URL not set)"
	fi

	log_info "spreed app configured successfully with HPB: ${HPB_URL}, TURN: ${TURN_SERVER_TCP_URL}"
}

# Configure viewer app
# Usage: configure_viewer_app
configure_viewer_app() {
	log_info "Configuring viewer app..."
	execute_occ_command config:app:set --value yes --type string viewer always_show_viewer
}

# Configure admin delegation
# Usage: configure_admin_delegation
configure_admin_delegation() {
	log_info "Configuring admin delegation..."

	# Check if settings.only-delegated-settings is true
	_delegated_settings_status=$(execute_occ_command config:system:get settings.only-delegated-settings 2>/dev/null)

	if [ "${_delegated_settings_status}" = "true" ]; then
		log_info "settings.only-delegated-settings is properly configured as: ${_delegated_settings_status}"
	else
		log_error "settings.only-delegated-settings is not set to true (current value: ${_delegated_settings_status})"
		log_error "Admin delegation configuration requires settings.only-delegated-settings to be enabled"
	fi

	# Get app list as JSON
	_app_list_json=$(execute_occ_command app:list --output json)
	_occ_status=$?
	if [ "${_occ_status}" -ne 0 ] || [ -z "${_app_list_json}" ]; then
		log_error "Failed to retrieve app list as JSON. Aborting admin delegation configuration."
		return 1
	fi

	# Use the delegation map defined at script start
	_app_delegation_map="${ADMIN_DELEGATION_MAP}"

	# Sort the delegation map by app name to ensure apps with multiple delegations
	# are processed together (enabling/disabling each app only once)
	_app_delegation_map=$(echo "${_app_delegation_map}" | grep -v '^[[:space:]]*$' | sort)

	# Parse delegation map and group by app
	_current_app=""
	_delegations_for_app=""

	for _entry in ${_app_delegation_map}; do
		# Skip empty lines
		[ -z "${_entry}" ] && continue

		# Validate entry format: must contain exactly one colon
		if [ "$(echo "${_entry}" | awk -F':' '{print NF-1}')" -ne 1 ]; then
			log_error "Invalid delegation entry format (expected 'app:class'): '${_entry}'"
			continue
		fi

		# Extract app and class from entry (format: app:class)
		_app=$(echo "${_entry}" | cut -d':' -f1)
		_class=$(echo "${_entry}" | cut -d':' -f2-)

		# Check if this is a new app
		if [ "${_current_app}" != "${_app}" ] && [ -n "${_current_app}" ]; then
			# Check if current app is enabled using jq
			_is_enabled=$(echo "${_app_list_json}" | jq -r ".enabled.\"${_current_app}\" // empty" 2>/dev/null)
			# Process delegations for previous app
			_process_app_delegations "${_current_app}" "${_delegations_for_app}" "${_is_enabled}"
			_delegations_for_app=""
		fi

		_current_app="${_app}"
		# Accumulate classes using newline as separator to preserve backslashes
		if [ -z "${_delegations_for_app}" ]; then
			_delegations_for_app="${_class}"
		else
			# keep next line as multiline in order to preserve the newlines
			_delegations_for_app="${_delegations_for_app}
${_class}"
		fi
	done

	# Process last app's delegations
	if [ -n "${_current_app}" ]; then
		_is_enabled=$(echo "${_app_list_json}" | jq -r ".enabled.\"${_current_app}\" // empty" 2>/dev/null)
		_process_app_delegations "${_current_app}" "${_delegations_for_app}" "${_is_enabled}"
	fi
}

# Helper function to process delegations for a single app
# Usage: _process_app_delegations <app_name> <delegation_classes> <is_enabled>
_process_app_delegations() {
	_app_name="${1}"
	_delegation_classes="${2}"
	_is_enabled="${3}"

	_should_disable=false
	if [ -z "${_is_enabled}" ]; then
		log_info "App '${_app_name}' is disabled, enabling temporarily for delegation..."
		if execute_occ_command app:enable "${_app_name}"; then
			_should_disable=true
		else
			log_error "Failed to enable app '${_app_name}'. Skipping delegation configuration for this app."
			return 1
		fi
	else
		log_info "App '${_app_name}' is already enabled"
	fi

	# Add delegations for this app
	# Use newline as delimiter to properly handle class names with backslashes
	echo "${_delegation_classes}" | while IFS= read -r _class; do
		# Skip empty lines
		if [ -n "${_class}" ]; then
			log_info "Adding delegation for class: ${_class}"
			execute_occ_command admin-delegation:add "${_class}" admin
		fi
	done

	# Disable app if it was temporarily enabled
	if [ "${_should_disable}" = true ]; then
		log_info "Disabling app '${_app_name}' after delegation configuration..."
		if ! execute_occ_command app:disable "${_app_name}"; then
			log_warning "Failed to disable app '${_app_name}' after delegation configuration. App may remain enabled."
		fi
	fi
}

# Configure IONOS mailconfig api with API credentials
# Usage: configure_ionos_mailconfig_api
configure_ionos_mailconfig_api() {
	log_info "Configuring IONOS mailconfig API with credentials..."

	execute_occ_command config:app:set --value no --type string mail ionos-mailconfig-enabled

	# Check required environment variables
	if ! validate_env_vars IONOS_MAILCONFIG_API_URL IONOS_MAILCONFIG_API_USER IONOS_MAILCONFIG_API_PASS EXT_REF CUSTOMER_DOMAIN; then
		log_warning "Skipping mailconfig API configuration due to missing environment variables"
		return 0
	fi

	log_info "EXT_REF: ${EXT_REF}"
	log_info "CUSTOMER_DOMAIN: ${CUSTOMER_DOMAIN}"

	execute_occ_command config:app:set --value "${IONOS_MAILCONFIG_API_URL}" --type string mail ionos_mailconfig_api_base_url
	execute_occ_command config:app:set --value "${IONOS_MAILCONFIG_API_USER}" --type string mail ionos_mailconfig_api_auth_user
	execute_occ_command config:app:set --value "${IONOS_MAILCONFIG_API_PASS}" --sensitive --type string mail ionos_mailconfig_api_auth_pass

	execute_occ_command config:app:set --value yes --type string mail ionos-mailconfig-enabled
}

# Configure IONOS AI Model Hub with API credentials
# Usage: configure_ionos_ai_model_hub
configure_ionos_ai_model_hub() {
	log_info "Configuring IONOS AI Model Hub with API credentials..."

	# Check required environment variables
	if ! validate_env_vars IONOSAI_URL IONOSAI_TOKEN; then
		log_warning "Skipping AI Model Hub configuration due to missing environment variables"
		return 0
	fi

	log_info "Configuring IONOS AI Model Hub with URL: ${IONOSAI_URL}"

	# Configure AI Model Hub settings for integration_openai app
	# Using Bearer token authentication (JWT format)
	execute_occ_command config:app:set --value "${IONOSAI_URL}" --type string integration_openai url
	execute_occ_command config:app:set --value "${IONOSAI_TOKEN}" --sensitive --type string integration_openai api_key

	# Configure max_tokens (app stores as string internally)
	_max_tokens="${IONOSAI_MAX_TOKENS:-1000}"
	set_app_config_typed integration_openai max_tokens "${_max_tokens}" string

	# Set use_max_completion_tokens_param (1=enabled, 0=disabled)
	# Default is 0 for non-OpenAI services (app stores as string '1' or '0')
	_use_max_completion_tokens_param="${IONOSAI_USE_MAX_COMPLETION_TOKENS_PARAM:-0}"
	set_app_config_typed integration_openai use_max_completion_tokens_param "${_use_max_completion_tokens_param}" string

	# Configure default text-to-text model
	_text_model="${IONOSAI_TEXT_MODEL:-openai/gpt-oss-120b}"
	execute_occ_command config:app:set --value "${_text_model}" --type string integration_openai default_completion_model_id

	# Configure default text-to-image model
	_image_model="${IONOSAI_IMAGE_MODEL:-black-forest-labs/FLUX.1-schnell}"
	execute_occ_command config:app:set --value "${_image_model}" --type string integration_openai default_image_model_id

	# Set AI assistant settings
	log_info "Configuring AI Assistant settings... "
	execute_occ_command config:app:set --value false settings ai.taskprocessing_guests

	_deactivated_tasks="
		core:generateemoji
		core:audio2text
		assistant:text2sticker
		integration_openai:text2speech
		integration_openai:analyze-images
		"
	_activated_tasks="
		core:contextagent:interaction
		core:contextwrite
		core:text2image
		core:text2text
		core:text2text:changetone
		core:text2text:chat
		core:text2text:chatwithtools
		core:text2text:headline
		core:text2text:proofread
		core:text2text:reformulation
		core:text2text:summary
		core:text2text:topics
		core:text2text:translate
		core:text2text:formalization
		"

	for _task in ${_deactivated_tasks}; do
		# Skip empty lines
		[ -n "${_task}" ] && execute_occ_command taskprocessing:task-type:set-enabled -q "${_task}" 0
		log_info "Disabled ${_task}"
	done

	for _task in ${_activated_tasks}; do
		[ -n "${_task}" ] && execute_occ_command taskprocessing:task-type:set-enabled -q "${_task}" 1
		log_info "Enabled ${_task}"
	done

	log_info "IONOS AI Model Hub configuration completed successfully"
}

#===============================================================================
# App Management Functions
#===============================================================================

# Disable a single Nextcloud app with error handling
# Usage: disable_single_app <app_name>
disable_single_app() {
	# Disable app and check if it was disabled
	# Fail if disabling the app failed
	#
	_app_name="${1}"
	if [ -z "${_app_name}" ]; then
		log_fatal "App name is required for disable_single_app function"
	fi

	log_info "Disabling app '${_app_name}'..."

	if ! execute_occ_command app:disable "${_app_name}"
	then
		log_fatal "Disable app \"${_app_name}\" failed."
	fi
}

# Disable multiple apps based on the DISABLED_APPS list
# Usage: disable_configured_apps
disable_configured_apps() {
	log_info "Processing app disabling..."

	_enabled_apps=$(execute_occ_command app:list --enabled --output json | jq -j '.enabled | keys | join("\n")')
	_disabled_apps_count=0

	for _app_name in ${DISABLED_APPS}; do
		printf "[?] Checking app: %s" "${_app_name}"
		if echo "${_enabled_apps}" | grep -q -w "${_app_name}"; then
			echo " - currently enabled - disabling"
			disable_single_app "${_app_name}"
			_disabled_apps_count=$((_disabled_apps_count + 1))
		else
			echo " - not enabled - skip"
		fi
	done

	log_info "Disabled ${_disabled_apps_count} apps."
}

# Enable and configure all Nextcloud apps
# Usage: configure_apps
configure_apps() {
	log_info "Configuring Nextcloud apps..."

	# Enable core productivity apps
	enable_app calendar "Calendar"
	enable_app circles "Circles"
	enable_app activity "Activity"
	enable_app contacts "Contacts"
	enable_app twofactor_totp "Two-Factor AuthenticationTOTP"
	enable_app end_to_end_encryption "End-to-End Encryption"
	enable_app mail "Mail"
	enable_app notifications "Notifications"
	enable_app tasks "Tasks"
	enable_app text "Text"
	enable_app ncw_apps_menu "NCW Apps Menu"

	# Configure specialized apps

	# currently disabled; enable again after removal from removed-apps.txt
	# configure_files_antivirus_app

	configure_viewer_app
	configure_collabora_app
	configure_notify_push_app
	configure_whiteboard_app
	configure_spreed_app

	# Enable additional apps
	enable_app ncw_mailtemplate "NCW Mail Template"
	enable_app groupfolders "Group Folders"
	enable_app assistant "Assistant"
	enable_app integration_openai "OpenAI Integration"
	enable_app ncw_tools "Task Processing"

	# Configure admin features
	configure_admin_delegation
	configure_ionos_ai_model_hub
}

#===============================================================================
# Main Execution Function
#===============================================================================

# Parse command line arguments
# Usage: parse_arguments [args...]
parse_arguments() {
	while [ $# -gt 0 ]; do
		case "${1}" in
			-v|--verbose)
				VERBOSE_OCC_LOGGING=true
				# Set log file path with timestamp
				OCC_LOG_FILE="${SCRIPT_DIR}/occ-commands-$(date +%Y%m%d-%H%M%S).log"
				log_info "Verbose OCC command logging enabled"
				log_info "OCC commands will be logged to: ${OCC_LOG_FILE}"
				# Initialize log file with header
				echo "==============================================================================" > "${OCC_LOG_FILE}"
				echo "OCC Command Log - $(date '+%Y-%m-%d %H:%M:%S')" >> "${OCC_LOG_FILE}"
				echo "==============================================================================" >> "${OCC_LOG_FILE}"
				echo "" >> "${OCC_LOG_FILE}"
				shift
				;;
			-h|--help)
				echo "Usage: ${0} [OPTIONS]"
				echo ""
				echo "Configure Nextcloud Workspace installation"
				echo ""
				echo "Options:"
				echo "  -v, --verbose    Enable verbose OCC command logging"
				echo "                   Logs will be saved to: occ-commands-<timestamp>.log"
				echo "  -h, --help       Display this help message"
				echo ""
				exit 0
				;;
			*)
				log_warning "Unknown option: ${1}"
				shift
				;;
		esac
	done
}

# Main function to orchestrate Nextcloud Workspace configuration
# Usage: main [args...]
main() {
	# Parse command line arguments first
	parse_arguments "${@}"

	log_info "Starting Nextcloud Workspace configuration process..."

	# Perform initial checks
	check_dependencies
	verify_nextcloud_installation

	# Execute configuration steps
	configure_theming
	disable_configured_apps
	configure_apps
	configure_ionos_mailconfig_api

	log_success "Nextcloud Workspace configuration completed successfully!"
}

# Execute main function with all script arguments
main "${@}"
