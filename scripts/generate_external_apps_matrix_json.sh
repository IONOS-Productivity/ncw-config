#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2025 STRATO AG
# SPDX-License-Identifier: AGPL-3.0-or-later

# Generate a JSON matrix of external apps for GitHub Actions.
# Presence is determined via git ls-tree (mode 160000), so prepare-matrix can call this
# with submodules: false — no submodule content is required.
#
# has_npm / has_composer are intentionally omitted: the build job detects them from
# disk after checking out only the specific app it needs to build.
#
# Usage: generate_external_apps_matrix_json.sh <FULL_BUILD_APPS> <COMPOSER_ONLY_APPS> \
#            <COMPOSER_NO_SCRIPTS_APPS> <COMPOSER_NO_SCRIPTS_WITH_NPM_APPS> \
#            <NOTHING_TO_BUILD_APPS> <SPECIAL_BUILD_APPS>
# Each argument is a space-separated list of app names.
#
# APP_FOLDERS (env, space-separated, default "apps-external") lists the folders searched for
# each app; the first folder holding the app as a submodule wins.

set -euo pipefail

ALL_CONFIGURED_APPS="${1:-} ${2:-} ${3:-} ${4:-} ${5:-} ${6:-}"
APP_FOLDERS="${APP_FOLDERS:-apps-external}"

echo "[i] Generating external apps matrix JSON file..." >&2

first=true
found_any=false
echo "["

for app in $ALL_CONFIGURED_APPS; do
	[ -z "$app" ] && continue

	# git ls-tree returns a gitlink entry (mode 160000) without requiring a submodule
	# checkout, so prepare-matrix can call this with submodules: false.
	app_path=""
	for folder in $APP_FOLDERS; do
		if git ls-tree HEAD "$folder/$app" 2>/dev/null | grep -q "^160000"; then
			app_path="$folder/$app"
			break
		fi
	done

	if [ -n "$app_path" ]; then
		found_any=true
		if [ "$first" = true ]; then
			first=false
		else
			echo "  },"
		fi
		echo "  {"
		echo "    \"name\": \"$app\","
		echo "    \"path\": \"$app_path\","
		makefile_target="build_${app}_app"
		echo "    \"makefile_target\": \"$makefile_target\""
	fi
done

if [ "$found_any" = true ]; then
	echo "  }"
fi
echo "]"
