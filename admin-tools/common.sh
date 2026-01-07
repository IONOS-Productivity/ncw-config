#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 STRATO GmbH
#
# Common functions for IONOS admin tools
# This library provides standardized logging, error handling, and OCC command execution

# Color codes for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_GREEN='\033[0;32m'

# Exit codes (exported for use by calling scripts)
# shellcheck disable=SC2034
readonly EXIT_SUCCESS=0
readonly EXIT_ERROR=1
# shellcheck disable=SC2034
readonly EXIT_INVALID_USAGE=2

# Script directory and Nextcloud root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NC_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OCC_CMD="${NC_ROOT}/occ"

# Logging functions
log_info() {
	echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $*" >&2
}

log_success() {
	echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*" >&2
}

log_warning() {
	echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*" >&2
}

log_error() {
	echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*" >&2
}

log_fatal() {
	echo -e "${COLOR_RED}[FATAL]${COLOR_RESET} $*" >&2
	exit "${EXIT_ERROR}"
}

# Conditional logging (respects QUIET flag set by calling scripts)
log_info_if_not_quiet() {
	[[ "${QUIET:-false}" == false ]] && log_info "$@"
	return 0
}

log_success_if_not_quiet() {
	[[ "${QUIET:-false}" == false ]] && log_success "$@"
	return 0
}

# Check if a command is available in PATH
# Usage: check_command_available <command_name> [error_message]
check_command_available() {
	local cmd="$1"
	local error_msg="${2:-}"

	if [[ -z "${error_msg}" ]]; then
			error_msg="Command '${cmd}' is not installed or not in PATH"
	fi

	if ! command -v "${cmd}" >/dev/null 2>&1; then
			log_fatal "${error_msg}"
	fi
}

# Check if OCC command is available
check_occ_available() {
	if [[ ! -f "${OCC_CMD}" ]]; then
			log_fatal "OCC command not found at: ${OCC_CMD}"
	fi
	if [[ ! -x "${OCC_CMD}" ]]; then
			log_fatal "OCC command is not executable: ${OCC_CMD}"
	fi
}

# Check if jq is installed
# Usage: check_jq_available
check_jq_available() {
	check_command_available "jq" "jq is required but not installed. Install it with: apt install jq (Debian/Ubuntu) or yum install jq (RHEL/CentOS)"
}

# Execute OCC command with error handling
# Usage: execute_occ_command [occ arguments...]
# Returns: OCC command exit code
execute_occ_command() {
	local output
	local exit_code

	log_info_if_not_quiet "Executing: php ${OCC_CMD}" "$@"

	output=$(php "${OCC_CMD}" "$@" 2>&1)
	exit_code=$?

	if [[ ${exit_code} -eq 0 ]]; then
			[[ -n "${output}" ]] && echo "${output}"
	else
			log_error "OCC command failed with exit code ${exit_code}"
			[[ -n "${output}" ]] && echo "${output}" >&2
	fi

	return ${exit_code}
}

# Execute OCC command and exit on failure
# Usage: execute_occ_command_or_die [occ arguments...]
execute_occ_command_or_die() {
	if ! execute_occ_command "$@"; then
			log_fatal "Critical OCC command failed, exiting"
	fi
}

# Check if Nextcloud is installed
check_nextcloud_installed() {
	if ! execute_occ_command status --output=json >/dev/null 2>&1; then
			log_fatal "Nextcloud is not installed or not accessible"
	fi
}

# Check if user exists
# Usage: user_exists <username>
# Returns: 0 if user exists, 1 otherwise
user_exists() {
	local username="$1"

	if [[ -z "${username}" ]]; then
			log_error "user_exists: username parameter is required"
			return 1
	fi

	if execute_occ_command user:info "${username}" >/dev/null 2>&1; then
			return 0
	else
			return 1
	fi
}

# Print standardized help header
# Usage: print_help_header <script_name> <description>
print_help_header() {
	local script_name="$1"
	local description="$2"

	cat << EOF
${script_name} - ${description}

IONOS Nextcloud Workspace Admin Tool

EOF
}

# Print standardized help footer
print_help_footer() {
	cat << EOF

Exit Codes:
	0  Success
	1  Error
	2  Invalid usage (missing arguments, etc.)

Examples and more information:
	See IONOS/admin-tools/README.md

EOF
}

# Validate required argument (utility for calling scripts)
# Usage: require_argument <value> <argument_name>
# Returns: 0 if value is non-empty, 1 otherwise
require_argument() {
	local value="$1"
	local arg_name="$2"

	if [[ -z "${value}" ]]; then
			log_error "Required argument missing: ${arg_name}"
			return 1
	fi
	return 0
}
