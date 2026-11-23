#!/bin/sh
# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

SCRIPT_DIR="$(dirname "${0}")"
readonly SCRIPT_DIR

# Global flag for verbose command logging
VERBOSE_OCC_LOGGING=false

# Log file for OCC commands (only used when VERBOSE_OCC_LOGGING=true)
OCC_LOG_FILE=""

# Plain output mode: no ANSI color codes (default on; use --color to enable colors)
PLAIN_OUTPUT=true

# Count of non-fatal errors accumulated via log_error; main() exits non-zero if > 0
_ERROR_COUNT=0

# Temp file for per-command timing data; populated in main()
TIMING_LOG_FILE=""

# Script start time in milliseconds; set in main() for total wall-time reporting
SCRIPT_START_MS=""

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

DISABLED_APPS=$( read_app_list "${SCRIPT_DIR}/disabled-apps.list" )

#===============================================================================
# Configuration Constants
#===============================================================================

# App config fragments (JSON) imported with ionos:config:import. The configure_*
# functions queue the fragments that apply to this deployment, apply_app_config_import
# imports them all in one occ call. Secrets are never part of a fragment, they are
# read from the environment by the import.
APP_CONFIG_DIR="${SCRIPT_DIR}/app-config"
IMPORT_FRAGMENTS=""
# Temporary fragments generated at runtime, removed on exit
IMPORT_TEMP_FILES=""

#===============================================================================
# Logging Functions
#===============================================================================

# Log error message to stderr
# Usage: log_error <message>
log_error() {
	_ERROR_COUNT=$(( _ERROR_COUNT + 1 ))
	if [ "${PLAIN_OUTPUT}" = "false" ]; then
		printf '\033[1;31m[e] Error: %s\033[0m\n' "${*}" >&2
	else
		printf '[e] Error: %s\n' "${*}" >&2
	fi
}

# Log fatal error message and exit with failure code
# Usage: log_fatal <message>
log_fatal() {
	if [ "${PLAIN_OUTPUT}" = "false" ]; then
		echo "\033[1;31m[x] Fatal Error: ${*}\033[0m" >&2
	else
		echo "[x] Fatal Error: ${*}" >&2
	fi
	exit 1
}

# Log warning message with yellow color
# Usage: log_warning <message>
log_warning() {
	if [ "${PLAIN_OUTPUT}" = "false" ]; then
		echo "\033[1;33m[w] Warning: ${*}\033[0m" >&2
	else
		echo "[w] Warning: ${*}" >&2
	fi
}

# Log info message
# Usage: log_info <message>
log_info() {
	echo "[i] ${*}"
}

# Log success message
# Usage: log_success <message>
log_success() {
	if [ "${PLAIN_OUTPUT}" = "false" ]; then
		echo "\033[1;32m[ok] ${*}\033[0m"
	else
		echo "[ok] ${*}"
	fi
}

#===============================================================================
# Helper Functions
#===============================================================================

# Append one timing record to TIMING_LOG_FILE (tab-separated: milliseconds<TAB>label)
# Usage: _record_timing <milliseconds> <label>
_record_timing() {
	[ -n "${TIMING_LOG_FILE}" ] && printf '%s\t%s\n' "${1}" "${2}" >> "${TIMING_LOG_FILE}"
}

# Return current time in milliseconds.
# Uses date +%s%3N (GNU date); falls back to seconds*1000 on busybox where %N is unsupported.
_get_ms() {
	_ts=$(date +%s%3N 2>/dev/null)
	case "${_ts}" in
		*[!0-9]*) printf '%d' "$(( $(date +%s) * 1000 ))" ;;
		*)         printf '%s' "${_ts}" ;;
	esac
}

#
# OCC Helper Conventions — Sensitive Data
# ----------------------------------------
# Two wrapper functions are available for running OCC commands:
#
#   execute_occ_command <subcommand> [args...]
#     General purpose. For commands that do NOT carry secrets.
#     Use execute_occ_secret_command for any command where an argument may be sensitive.
#
#   execute_occ_secret_command <subcommand> [args...]
#     For OCC commands that carry secrets. Arguments are NOT logged to prevent
#     accidental secret exposure. Only the subcommand name is recorded in logs.
#     Example: execute_occ_secret_command talk:signaling:add "${HPB_URL}" "${HPB_SECRET}"
#     Example: execute_occ_secret_command config:app:set app key --sensitive --value "${SECRET}"
#
# Rule: always call execute_occ_secret_command directly for sensitive commands.
#===============================================================================

# Execute NextCloud OCC command with error handling
# Usage: execute_occ_command <command> [args...]
execute_occ_command() {
	# Safety net: --secret/--sensitive means a secret is in the args; delegate to execute_occ_secret_command.
	# Must run before any logging that would expose ${*}.
	if echo "${*}" | grep -qE -- "--secret|--sensitive"; then
		log_warning "execute_occ_command called with --secret/--sensitive; use execute_occ_secret_command instead. Delegating."
		execute_occ_secret_command "${@}"
		return $?
	fi

	# Check if this is a config:system:set command and warn about partial config.
	# Safe to log ${*} here because secrets have already been intercepted above.
	if [ "${1}" = "config:system:set" ]; then
		log_warning "config:system:set should be avoided. Use PHP <foo>.config.php files in configs/ directory instead. Command: ${*}"
	fi

	if [ "${VERBOSE_OCC_LOGGING}" = "true" ]; then
		echo "[i] Executing OCC command: ${*}" >&2
		echo "occ ${*}" >> "${OCC_LOG_FILE}" 2>&1
	fi

	_t_start=$(_get_ms)
	php occ "${@}"
	_t_rc=$?
	_record_timing "$(( $(_get_ms) - _t_start ))" "${*}"
	if [ "${_t_rc}" -ne 0 ]; then
		log_error "Failed to execute OCC command: ${*}"
		return 1
	fi
}

# Execute any OCC command that contains sensitive data.
# Arguments are NOT logged to prevent accidental secret exposure.
# Only the subcommand name is recorded in logs.
# Usage: execute_occ_secret_command <subcommand> [args...]
execute_occ_secret_command() {
	if [ "${VERBOSE_OCC_LOGGING}" = "true" ]; then
		echo "[i] Executing sensitive OCC command: $1 [args not logged]" >&2
		echo "occ $1 [args not logged]" >> "${OCC_LOG_FILE}" 2>&1
	fi

	_t_start=$(_get_ms)
	php occ "${@}"
	_t_rc=$?
	_record_timing "$(( $(_get_ms) - _t_start ))" "${1}"
	if [ "${_t_rc}" -ne 0 ]; then
		log_error "Failed to execute sensitive OCC command: $1 [args not logged]"
		return 1
	fi
}

# Run an OCC command with up to 3 attempts on failure
# Returns: 0 on success, 1 after all attempts are exhausted
retry_occ() {
	_retry_attempt=1
	while [ "${_retry_attempt}" -le 3 ]; do
		if _RETRY_OUTPUT=$(php occ "${@}"); then
			return 0
		fi
		log_warning "occ ${1} failed (attempt ${_retry_attempt}/3)"
		_retry_attempt=$(( _retry_attempt + 1 ))
		[ "${_retry_attempt}" -le 3 ] && sleep 2
	done
	return 1
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

# Enable a Nextcloud app with logging
# Usage: enable_app <app_name> [display_name]
enable_app() {
	_app_name="${1}"
	_display_name="${2:-${1}}"

	log_info "Enable ${_display_name} app"
	execute_occ_command app:enable "${_app_name}"
}

# Queue an app config fragment for the import at the end of the run
# Usage: add_import_fragment <file name in app-config/>
add_import_fragment() {
	_fragment="${APP_CONFIG_DIR}/${1}"
	if [ ! -f "${_fragment}" ]; then
		log_fatal "App config fragment not found: ${_fragment}"
	fi
	IMPORT_FRAGMENTS="${IMPORT_FRAGMENTS} ${_fragment}"
}

# Import all queued fragments with one ionos:config:import call
# Usage: apply_app_config_import
apply_app_config_import() {
	if [ -z "${IMPORT_FRAGMENTS}" ]; then
		log_info "No app config fragments to import"
		return 0
	fi

	# The command ships with the server, make sure this build has it
	if ! php occ list ionos --raw 2>/dev/null | grep -q '^ionos:config:import '; then
		log_fatal "occ ionos:config:import is not available in this Nextcloud build"
	fi

	set --
	_names=""
	for _fragment in ${IMPORT_FRAGMENTS}; do
		set -- "${@}" "${_fragment}"
		_names="${_names} $(basename "${_fragment}")"
	done

	log_info "Importing app config:${_names}"
	# --allow-unverified-delegations: some apps with delegated settings are disabled on purpose
	execute_occ_command ionos:config:import --allow-unverified-delegations "${@}"
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

	# Set legal URLs based on market
	case "${MARKET}" in
		DE)
			IMPRINT_URL="https://wl.hidrive.com/ionos/0020"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0040"
			;;
		UK)
			IMPRINT_URL="https://wl.hidrive.com/ionos/0021"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0041"
			;;
		ES)
			IMPRINT_URL="https://wl.hidrive.com/ionos/0024"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0044"
			;;
		FR)
			IMPRINT_URL="https://wl.hidrive.com/ionos/0025"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0045"
			;;
		IT)
			IMPRINT_URL="https://wl.hidrive.com/ionos/0026"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0046"
			;;
		*)
			# Default to DE if MARKET is unset or invalid
			IMPRINT_URL="https://wl.hidrive.com/ionos/0020"
			PRIVACY_URL="https://wl.hidrive.com/ionos/0040"
			log_warning "MARKET not set or invalid (${MARKET}), defaulting to DE legal URLs"
			;;
	esac

	log_info "Setting legal URLs for market ${MARKET}: imprintUrl=${IMPRINT_URL}, privacyUrl=${PRIVACY_URL}"

	# The legal URLs are read from the environment by the theming fragment
	export IMPRINT_URL PRIVACY_URL
	add_import_fragment theming.json

	execute_occ_command theming:config primary_color "#003D8F"
	execute_occ_command theming:config disable_admin_theming yes
	#execute_occ_command theming:config favicon "${FAVICON_DIR}/favicon.ico"
	execute_occ_command theming:config url ""

	# Set homepage URL if configured
	# Use php occ directly: config:system:get exits 1 when the key is absent,
	# which is expected — routing through execute_occ_command would log a false error.
	_ionos_homepage=$(php occ config:system:get ionos_homepage 2>/dev/null || true)
	if [ -n "${_ionos_homepage}" ]; then
		execute_occ_command theming:config url "${_ionos_homepage}"
	fi
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

	NOTIFY_PUSH_BASE_ENDPOINT="${_base_url}/push"
	export NOTIFY_PUSH_BASE_ENDPOINT
	log_info "Setting notify_push base_endpoint: ${NOTIFY_PUSH_BASE_ENDPOINT}"
	add_import_fragment notify-push.json
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

	if ! validate_env_vars APP_WHITEBOARD_COLLABBACKEND_URL APP_WHITEBOARD_JWT_SECRET; then
		log_warning "whiteboard app configuration skipped due to missing environment variables"
		return 0
	fi

	# Fallback: Default value for port is "-" if port is not set
	_collab_backend_port="${APP_WHITEBOARD_COLLABBACKEND_PORT:-3002}"
	WHITEBOARD_COLLAB_BACKEND_URL="${APP_WHITEBOARD_COLLABBACKEND_URL}"
	if [ "${_collab_backend_port}" != "-" ]; then
		WHITEBOARD_COLLAB_BACKEND_URL="${WHITEBOARD_COLLAB_BACKEND_URL}:${_collab_backend_port}"
	fi
	export WHITEBOARD_COLLAB_BACKEND_URL
	add_import_fragment whiteboard.json
}

# Select and configure the document editor app based on DOCUMENT_APP env var.
# DOCUMENT_APP: "eurooffice" (default)
# Usage: configure_document_app
configure_document_app() {
	_selected_doc_app="${DOCUMENT_APP:-eurooffice}"
	log_info "Configuring document app (DOCUMENT_APP=${_selected_doc_app})..."

	disable_single_app richdocuments
	disable_single_app eurooffice

	case "${_selected_doc_app}" in
		eurooffice)
			configure_eurooffice_app
			;;
		*)
			log_error "Unknown DOCUMENT_APP value: '${_selected_doc_app}'. Valid values: eurooffice"
			return 1
			;;
	esac
}

# Configure eurooffice app
# Usage: configure_eurooffice_app
configure_eurooffice_app() {
	log_info "Configuring eurooffice app..."

	disable_single_app eurooffice "Euro-Office"

	if ! validate_env_vars APP_EUROOFFICE_DOCUMENT_SERVER_URL APP_EUROOFFICE_JWT_SECRET; then
		log_warning "eurooffice app configuration skipped due to missing environment variables"
		return 0
	fi

	enable_app eurooffice "Euro-Office"

	add_import_fragment eurooffice.json

	# defFormats and editFormats hold JSON as text. Their fragment is built from the readable
	# source files: jq fails on malformed JSON, and the import checks the result once more
	# ("format": "json-object") before anything is written.
	_formats_json='{}'
	for _pair in "defFormats:eurooffice-def-formats.json" "editFormats:eurooffice-edit-formats.json"; do
		_formats_key="${_pair%%:*}"
		_formats_file="${APP_CONFIG_DIR}/${_pair#*:}"
		if [ ! -f "${_formats_file}" ]; then
			log_warning "${_pair#*:} not found, skipping ${_formats_key} configuration"
			continue
		fi
		if ! _formats_text="$(jq -c . "${_formats_file}")"; then
			log_error "${_pair#*:} is not valid JSON, skipping ${_formats_key} configuration"
			continue
		fi
		_formats_json="$(printf '%s' "${_formats_json}" | jq -c --arg key "${_formats_key}" --arg text "${_formats_text}" '.[$key] = {value: $text, type: "mixed", format: "json-object"}')"
	done
	_formats_fragment="$(mktemp "${TMPDIR:-/tmp}/eurooffice-formats.XXXXXX")"
	IMPORT_TEMP_FILES="${IMPORT_TEMP_FILES} ${_formats_fragment}"
	printf '%s' "${_formats_json}" | jq '{apps: {eurooffice: .}}' > "${_formats_fragment}"
	IMPORT_FRAGMENTS="${IMPORT_FRAGMENTS} ${_formats_fragment}"

	# StorageUrl: URL the document server uses to fetch files from Nextcloud.
	# Set this when the document server cannot reach Nextcloud via the public URL
	# (e.g. dev: document server in pasta networking needs host.containers.internal).
	if [ -n "${APP_EUROOFFICE_STORAGE_URL:-}" ]; then
		log_info "Setting eurooffice StorageUrl: ${APP_EUROOFFICE_STORAGE_URL}"
		add_import_fragment eurooffice-storage-url.json
	fi

	log_info "eurooffice app configured with DocumentServerUrl: ${APP_EUROOFFICE_DOCUMENT_SERVER_URL}"
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
	if ! retry_occ talk:signaling:list --output=json_pretty; then
		log_error "Failed to retrieve signaling server list. Aborting signaling servers configuration"
		return 1
	fi
	_server_list=$(echo "${_RETRY_OUTPUT}" | jq -r '.servers[].server' | sort -u)
	echo "_server_list: $_server_list"

	if [ -z "${_server_list}" ]; then
		log_info "No existing signaling servers found"
	else
		# Use here-document (not pipe) so the loop runs in the current shell,
		# preserving variable mutations (e.g. _ERROR_COUNT) in the parent process.
		while IFS= read -r _existing_server; do
			if [ -n "${_existing_server}" ]; then
				log_info "Removing existing signaling server: ${_existing_server}"
				execute_occ_command talk:signaling:delete "${_existing_server}" || log_warning "Failed to delete signaling server: ${_existing_server}"
			fi
		done <<EOF
${_server_list}
EOF
	fi

	# Add new signaling server
	execute_occ_secret_command talk:signaling:add "${HPB_URL}" "${HPB_SECRET}"

	# Configure TURN servers
	# Propagate errors: if talk:turn:list fails we must not proceed, as we cannot
	# safely determine which servers to delete before adding new ones.
	if ! retry_occ talk:turn:list --output=json_pretty; then
		log_error "Failed to retrieve TURN server list. Aborting TURN server configuration"
		return 1
	fi
	turnList="${_RETRY_OUTPUT}"
	if [ -n "${turnList}" ]; then
		log_info "Existing TURN servers found. Proceeding with deletion..."
		while IFS="$(printf '\t')" read -r _schemes _server _protocols; do
			execute_occ_command talk:turn:delete "${_schemes}" "${_server}" "${_protocols}"
		done <<EOF
$(echo "$turnList" | jq -r '.[] | [.schemes, .server, .protocols] | @tsv')
EOF
	else
		log_info "No existing TURN servers found. Nothing to delete."
	fi

	log_info "Configuring new TURN server: ${TURN_SERVER_TCP_URL}"
	execute_occ_secret_command talk:turn:add turn "${TURN_SERVER_TCP_URL}" tcp --secret "${TURN_SERVER_SECRET}"

	if [ "${TURN_SERVER_UDP_URL}" ]; then
		log_info "Configuring TURN server: ${TURN_SERVER_UDP_URL}"
		execute_occ_secret_command talk:turn:add turn "${TURN_SERVER_UDP_URL}" udp --secret "${TURN_SERVER_SECRET}"
	else
		log_info "Skipping TURN server configuration (TURN_SERVER_UDP_URL not set)"
	fi

	log_info "spreed app configured successfully with HPB: ${HPB_URL}, TURN: ${TURN_SERVER_TCP_URL}"
}

# Configure viewer app
# Usage: configure_viewer_app
configure_viewer_app() {
	log_info "Configuring viewer app..."
	add_import_fragment viewer.json
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

	add_import_fragment delegation.json
}

# Configure IONOS mailconfig api with API credentials
# Usage: configure_ionos_mailconfig_api
configure_ionos_mailconfig_api() {
	log_info "Configuring IONOS mailconfig API with credentials..."

	# Exactly one fragment is queued: off in every early return below, on when everything is in place.
	# Disable mailconfig if brand is not "IONOS"
	log_info "BRAND: ${BRAND}"
	if [ "$BRAND" != "IONOS" ]; then
		log_info "Brand is not 'IONOS', ionos-mailconfig-enabled remains disabled"
		add_import_fragment mailconfig-off.json
		return 0
	fi

	log_info "FUNCTIONAL_MAILBOX_POSSIBLE: ${FUNCTIONAL_MAILBOX_POSSIBLE}"

	# This flag is set by PSS and reflects whether a customer domain is connected.
	if [ "${FUNCTIONAL_MAILBOX_POSSIBLE}" != '1' ]; then
		log_info "Mailbox creation not possible (FUNCTIONAL_MAILBOX_POSSIBLE is not '1'), ionos-mailconfig-enabled remains disabled"
		add_import_fragment mailconfig-off.json
		return 0
	fi

	if ! validate_env_vars IONOS_MAILCONFIG_API_URL IONOS_MAILCONFIG_API_USER IONOS_MAILCONFIG_API_PASS EXT_REF; then
		log_warning "Skipping mailconfig API configuration due to missing environment variables"
		add_import_fragment mailconfig-off.json
		return 0
	fi

	log_info "EXT_REF: ${EXT_REF}"
	# Credentials come from the environment, the fragment also enables the integration
	add_import_fragment mailconfig-on.json
}

# Configure mail app settings
# Usage: configure_mail_app
configure_mail_app() {
	log_info "Configuring mail app..."

	enable_app mail "Mail"
	# save allow_new_mail_aliases as mixed type in order to be compatible wih legacy code
	add_import_fragment mail.json
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

	# Settings of integration_openai (bearer token authentication) and of the AI assistant.
	# Models and limits have defaults in the fragment.
	add_import_fragment ai-model-hub.json

	log_info "Configuring AI Assistant task types... "

	_deactivated_tasks="
		core:generateemoji
		core:audio2text
		core:text2speech
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
	enable_app notifications "Notifications"
	enable_app tasks "Tasks"
	enable_app text "Text"
	enable_app ncw_apps_menu "NCW Apps Menu"

	# Configure specialized apps

	# currently disabled; enable again after removal from removed-apps.txt
	# configure_files_antivirus_app

	configure_mail_app
	configure_viewer_app
	configure_document_app
	configure_notify_push_app
	configure_whiteboard_app
	configure_spreed_app

	# Enable additional apps
	enable_app ncw_mailtemplate "NCW Mail Template"
	enable_app groupfolders "Group Folders"
	enable_app assistant "Assistant"
	enable_app integration_openai "OpenAI Integration"
	enable_app ncw_tools "Task Processing"
	enable_app files_pdfviewer "Files-PdfViewer"

	# Configure admin features
	configure_admin_delegation
	configure_ionos_ai_model_hub
}

#===============================================================================
# Main Execution Function
#===============================================================================

# Print timing summary: per-subcommand aggregates (calls, total, avg, max), sorted by total desc
# Usage: report_timing_stats
report_timing_stats() {
	[ -z "${TIMING_LOG_FILE}" ] || [ ! -s "${TIMING_LOG_FILE}" ] && return

	echo ""
	echo "=== OCC Command Timing ==="
	printf "%-44s %5s %8s %7s %7s\n" "subcommand" "calls" "total" "avg" "max"

	awk -F'\t' '
	{
		dur = $1 + 0
		split($2, parts, " "); cmd = parts[1]
		count[cmd]++
		total[cmd] += dur
		if (count[cmd] == 1 || dur > max[cmd]) max[cmd] = dur
	}
	END {
		for (cmd in count) {
			avg = int(total[cmd] / count[cmd])
			printf "%d\t%d\t%d\t%d\t%s\n", total[cmd], count[cmd], avg, max[cmd], cmd
		}
	}' "${TIMING_LOG_FILE}" | sort -rn | \
	awk -F'\t' '{ printf "%-44s %5d %7dms %6dms %6dms\n", $5, $2, $1, $3, $4 }'

	# Footer: total OCC time and total script wall time
	_total_occ_ms=$(awk '{s += $1} END {print s+0}' "${TIMING_LOG_FILE}")
	_total_script_ms="$(( $(_get_ms) - SCRIPT_START_MS ))"
	printf -- "--------------------------\n"
	printf "%-44s %5s %7dms\n" "total OCC time" "" "${_total_occ_ms}"
	printf "%-44s %5s %7dms\n" "total script time" "" "${_total_script_ms}"
	echo "=========================="
	rm -f "${TIMING_LOG_FILE}"
}

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
			--color)
				PLAIN_OUTPUT=false
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
				echo "      --color      Enable ANSI color output (default: plain, for k9s/log aggregators)"
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

	# Initialize timing log and record script start (always-on)
	SCRIPT_START_MS="$(_get_ms)"
	TIMING_LOG_FILE="/tmp/occ-timing-$$.log"
	trap 'rm -f "${TIMING_LOG_FILE}" ${IMPORT_TEMP_FILES}' EXIT INT TERM

	log_info "Starting Nextcloud Workspace configuration process..."

	# Perform initial checks
	check_dependencies
	verify_nextcloud_installation

	# Execute configuration steps
	configure_theming
	disable_configured_apps
	configure_apps
	configure_ionos_mailconfig_api
	apply_app_config_import

	report_timing_stats

	if [ "${_ERROR_COUNT}" -gt 0 ]; then
		log_fatal "Configuration finished with ${_ERROR_COUNT} error(s) — see [e] lines above."
	fi

	log_success "Nextcloud Workspace configuration completed successfully!"
}

# Execute main function with all script arguments
main "${@}"
