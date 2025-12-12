#!/bin/bash
# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# This script validates that apps are only in one list and not duplicated by hardcoded targets
# Arguments: FULL_BUILD_APPS COMPOSER_ONLY_APPS COMPOSER_NO_SCRIPTS_APPS COMPOSER_NO_SCRIPTS_WITH_NPM_APPS NOTHING_TO_BUILD_APPS SPECIAL_BUILD_APPS MAKEFILE_PATH

FULL_BUILD_APPS="$1"
COMPOSER_ONLY_APPS="$2"
COMPOSER_NO_SCRIPTS_APPS="$3"
COMPOSER_NO_SCRIPTS_WITH_NPM_APPS="$4"
NOTHING_TO_BUILD_APPS="$5"
SPECIAL_BUILD_APPS="$6"
MAKEFILE_PATH="$7"

echo "[i] Validating app list uniqueness..."

validation_failed=0

# Combine all apps into one list
all_apps="$FULL_BUILD_APPS $COMPOSER_ONLY_APPS $COMPOSER_NO_SCRIPTS_APPS $COMPOSER_NO_SCRIPTS_WITH_NPM_APPS $NOTHING_TO_BUILD_APPS $SPECIAL_BUILD_APPS"

echo "[i] Checking for duplicate apps across lists..."
echo ""

# Check each app to see if it appears in multiple lists
for app in $all_apps; do
		count=0
		locations=""

		# Check FULL_BUILD_APPS
		for fb_app in $FULL_BUILD_APPS; do
				if [ "$app" = "$fb_app" ]; then
						count=$((count + 1))
						locations="$locations FULL_BUILD_APPS"
						break
				fi
		done

		# Check COMPOSER_ONLY_APPS
		for co_app in $COMPOSER_ONLY_APPS; do
				if [ "$app" = "$co_app" ]; then
						count=$((count + 1))
						locations="$locations COMPOSER_ONLY_APPS"
						break
				fi
		done

	# Check COMPOSER_NO_SCRIPTS_APPS
	for cns_app in $COMPOSER_NO_SCRIPTS_APPS; do
			if [ "$app" = "$cns_app" ]; then
					count=$((count + 1))
					locations="$locations COMPOSER_NO_SCRIPTS_APPS"
					break
			fi
	done

	# Check COMPOSER_NO_SCRIPTS_WITH_NPM_APPS
	for cnswn_app in $COMPOSER_NO_SCRIPTS_WITH_NPM_APPS; do
			if [ "$app" = "$cnswn_app" ]; then
					count=$((count + 1))
					locations="$locations COMPOSER_NO_SCRIPTS_WITH_NPM_APPS"
					break
			fi
	done

	# Check NOTHING_TO_BUILD_APPS
	for ntb_app in $NOTHING_TO_BUILD_APPS; do
				if [ "$app" = "$ntb_app" ]; then
						count=$((count + 1))
						locations="$locations NOTHING_TO_BUILD_APPS"
						break
				fi
		done

		# Check SPECIAL_BUILD_APPS
		for sb_app in $SPECIAL_BUILD_APPS; do
				if [ "$app" = "$sb_app" ]; then
						count=$((count + 1))
						locations="$locations SPECIAL_BUILD_APPS"
						break
				fi
		done

		if [ $count -gt 1 ]; then
				echo "❌ ERROR: App \"$app\" appears in multiple lists:$locations"
				validation_failed=1
		fi
done

# Remove duplicates from the combined list for next check
unique_apps=$(echo "$all_apps" | tr " " "\n" | sort -u | tr "\n" " ")

echo "[i] Checking for hardcoded build targets that conflict with app lists..."
echo ""

# Find all hardcoded build_*_app targets in the Makefile
hardcoded_targets=$(grep -E "^build_[a-z_]+_app:" "$MAKEFILE_PATH" | sed "s/^build_//;s/_app:.*//")

# Exclude known special targets that should have hardcoded implementations
excluded_hardcoded="notify_push theming"

for target in $hardcoded_targets; do
		# Skip if this is an excluded target
		is_excluded=0
		for excluded in $excluded_hardcoded; do
				if [ "$target" = "$excluded" ]; then
						is_excluded=1
						break
				fi
		done

		if [ $is_excluded -eq 1 ]; then
				continue
		fi

		# Check if this target also appears in one of the dynamic lists
		for app in $unique_apps; do
				if [ "$target" = "$app" ]; then
						echo "❌ ERROR: App \"$app\" has a hardcoded build_${app}_app target but is also in a dynamic list"
						echo "   💡 Either remove the hardcoded target and rely on dynamic rules, or move the app to SPECIAL_BUILD_APPS"
						validation_failed=1
						break
				fi
		done
done

# Check that apps in SPECIAL_BUILD_APPS actually have hardcoded targets
echo ""
echo "[i] Checking that SPECIAL_BUILD_APPS have corresponding hardcoded targets..."
echo ""

for app in $SPECIAL_BUILD_APPS; do
		found_target=0
		for target in $hardcoded_targets; do
				if [ "$app" = "$target" ]; then
						found_target=1
						break
				fi
		done

		if [ $found_target -eq 0 ]; then
				echo "⚠️  WARNING: App \"$app\" is in SPECIAL_BUILD_APPS but has no hardcoded build_${app}_app target"
				echo "   💡 Either add a hardcoded target or move the app to an appropriate dynamic list"
				validation_failed=1
		fi
done

echo ""
echo "=== APP LIST UNIQUENESS VALIDATION SUMMARY ==="
if [ $validation_failed -eq 0 ]; then
		echo "✅ All apps are uniquely categorized with no conflicts"
		echo "✅ No hardcoded targets conflict with dynamic lists"
		echo "✅ All special build apps have corresponding targets"
else
	echo "❌ Validation failed - please fix the issues above"
	echo ""
	echo "📋 GUIDELINES:"
	echo "1. Each app must appear in ONLY ONE of these lists:"
	echo "   - FULL_BUILD_APPS"
	echo "   - COMPOSER_ONLY_APPS"
	echo "   - COMPOSER_NO_SCRIPTS_APPS"
	echo "   - COMPOSER_NO_SCRIPTS_WITH_NPM_APPS"
	echo "   - NOTHING_TO_BUILD_APPS"
	echo "   - SPECIAL_BUILD_APPS"
	echo ""
	echo "2. Apps in FULL_BUILD_APPS, COMPOSER_ONLY_APPS, COMPOSER_NO_SCRIPTS_APPS,"
	echo "   COMPOSER_NO_SCRIPTS_WITH_NPM_APPS, and NOTHING_TO_BUILD_APPS"
	echo "   use dynamic build rules and should NOT have hardcoded build_<app>_app targets"
	echo ""
	echo "3. Apps in SPECIAL_BUILD_APPS require custom build logic and MUST have"
	echo "   a hardcoded build_<app>_app target in the Makefile"
	echo ""
	echo "4. Currently excluded from conflict checks (known special cases):"
	echo "   - notify_push (has both hardcoded target and SPECIAL_BUILD_APPS entry)"
	echo "   - theming (core app with special handling)"
	exit 1
fi
