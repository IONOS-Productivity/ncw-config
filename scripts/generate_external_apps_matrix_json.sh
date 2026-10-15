#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2025 STRATO AG
# SPDX-License-Identifier: AGPL-3.0-or-later

# Generate a JSON matrix of external apps for GitHub Actions.
# Works without submodule checkouts: presence is determined via git ls-tree (mode 160000)
# so the prepare-matrix job can call this without fetching any submodule content.
# When submodules are already checked out (local/dev builds), the directory check also
# accepts them.
#
# has_npm / has_composer are intentionally omitted: the build job detects them from
# disk after checking out only the specific app it needs to build.
#
# Usage: generate_external_apps_matrix_json.sh <FULL_BUILD_APPS> <COMPOSER_ONLY_APPS> \
#            <COMPOSER_NO_SCRIPTS_APPS> <COMPOSER_NO_SCRIPTS_WITH_NPM_APPS> \
#            <NOTHING_TO_BUILD_APPS> <SPECIAL_BUILD_APPS>
# Each argument is a space-separated list of app names.

set -euo pipefail

ALL_CONFIGURED_APPS="${1:-} ${2:-} ${3:-} ${4:-} ${5:-} ${6:-}"

echo "[i] Generating external apps matrix JSON file..." >&2

first=true
found_any=false
echo "["

for app in $ALL_CONFIGURED_APPS; do
    [ -z "$app" ] && continue

    # Accept the app when it is a registered submodule in the git index (mode 160000)
    # or an already-checked-out directory. git ls-tree returns a gitlink entry without
    # requiring a submodule checkout, so prepare-matrix can call this with submodules: false.
    is_submodule=$(git ls-tree HEAD "apps-external/$app" 2>/dev/null | grep -c "^160000" || true)
    is_dir=0
    [ -d "apps-external/$app" ] && is_dir=1

    if [ "$is_submodule" -gt 0 ] || [ "$is_dir" -gt 0 ]; then
        found_any=true
        if [ "$first" = true ]; then
            first=false
        else
            echo "  },"
        fi
        echo "  {"
        echo "    \"name\": \"$app\","
        echo "    \"path\": \"apps-external/$app\","
        makefile_target="build_${app}_app"
        echo "    \"makefile_target\": \"$makefile_target\""
    fi
done

if [ "$found_any" = true ]; then
    echo "  }"
fi
echo "]"
