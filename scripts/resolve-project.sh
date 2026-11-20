# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Sourced (POSIX sh) by runtime scripts to find their project directory.
#
# Input:  IONOS_DIR  - the IONOS directory (the one containing projects/)
# Output: PROJECT_KEY, PROJECT_DIR
#
# Resolution order: $PROJECT_DIR (explicit), $PROJECT, "projectKey" in the build's
# version.json (one level above IONOS_DIR), then "workspace".

if [ -z "${PROJECT_DIR:-}" ]; then
	if [ -z "${PROJECT:-}" ] && [ -f "${IONOS_DIR}/../version.json" ] && command -v jq >/dev/null 2>&1; then
		PROJECT="$(jq -r '.projectKey // empty' "${IONOS_DIR}/../version.json" 2>/dev/null)"
	fi
	PROJECT_KEY="${PROJECT:-workspace}"
	PROJECT_DIR="${IONOS_DIR}/projects/${PROJECT_KEY}"
else
	PROJECT_KEY="$(basename "${PROJECT_DIR}")"
fi

if [ ! -d "${PROJECT_DIR}" ]; then
	printf 'Fatal Error: project directory not found: %s\n' "${PROJECT_DIR}" >&2
	exit 1
fi
