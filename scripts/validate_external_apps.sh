#!/bin/bash
# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

# This script validates external apps and suggests proper categorization
# Arguments: FULL_BUILD_APPS COMPOSER_ONLY_APPS COMPOSER_NO_SCRIPTS_APPS COMPOSER_NO_SCRIPTS_WITH_NPM_APPS NOTHING_TO_BUILD_APPS SPECIAL_BUILD_APPS

FULL_BUILD_APPS="$1"
COMPOSER_ONLY_APPS="$2"
COMPOSER_NO_SCRIPTS_APPS="$3"
COMPOSER_NO_SCRIPTS_WITH_NPM_APPS="$4"
NOTHING_TO_BUILD_APPS="$5"
SPECIAL_BUILD_APPS="$6"

echo "[i] Analyzing external apps to suggest proper build configuration..."
echo "[i] Checking all apps in apps-external directory..."

validation_failed=0
unconfigured_apps=0
missing_submodules=0
submodule_issues=0
missing_submodule_list=""
unconfigured_app_list=""
error_app_list=""
review_app_list=""
submodule_issue_list=""

# First check git submodule status for all submodules
echo ""
echo "[i] Checking git submodule status..."

if command -v git >/dev/null 2>&1; then
		submodule_status_output=$(git submodule status 2>/dev/null || echo "")
		if [ -n "$submodule_status_output" ]; then
				while IFS= read -r line; do
						if [ -n "$line" ]; then
								status_char=${line:0:1}
								submodule_path=$(echo "$line" | awk "{print \$2}")
								commit_hash=$(echo "$line" | awk "{print \$1}" | sed "s/^.//")
								app_name=$(basename "$submodule_path")

								case "$status_char" in
										" ")
												echo "  ✓ $app_name: submodule is up to date"
												;;
										"+")
												echo "  ⚠️  $app_name: submodule has uncommitted changes"
												echo "    💡 Run: cd $submodule_path && git add . && git commit -m \"Update changes\""
												;;
										"-")
												echo "  ❌ $app_name: submodule not initialized ($commit_hash)"
												echo "    💡 Run: git submodule update --init $submodule_path"
												submodule_issues=$((submodule_issues + 1))
												submodule_issue_list="$submodule_issue_list $app_name"
												validation_failed=1
												;;
										"U")
												echo "  ❌ $app_name: submodule has merge conflicts"
												echo "    💡 Run: cd $submodule_path && git status && resolve conflicts"
												submodule_issues=$((submodule_issues + 1))
												submodule_issue_list="$submodule_issue_list $app_name"
												validation_failed=1
												;;
										*)
												echo "  ❓ $app_name: unknown submodule status ($status_char)"
												;;
								esac
						fi
				done <<< "$submodule_status_output"
		else
				echo "  ℹ️  No git submodules found or git submodule command failed"
		fi
else
		echo "  ⚠️  Git command not available - skipping submodule status check"
fi

# Check if any configured apps are missing as submodules
echo ""
echo "[i] Checking configured apps for missing submodules..."

for app in $FULL_BUILD_APPS $COMPOSER_ONLY_APPS $COMPOSER_NO_SCRIPTS_APPS $COMPOSER_NO_SCRIPTS_WITH_NPM_APPS $NOTHING_TO_BUILD_APPS $SPECIAL_BUILD_APPS; do
		if [ ! -d "apps-external/$app" ]; then
				echo "  ❌ ERROR: App $app is configured but directory does not exist"
				validation_failed=1
				missing_submodules=$((missing_submodules + 1))
				missing_submodule_list="$missing_submodule_list $app"
		elif ! git submodule status "apps-external/$app" >/dev/null 2>&1; then
				echo "  ❌ ERROR: App $app is configured but not a git submodule"
				validation_failed=1
				missing_submodules=$((missing_submodules + 1))
				missing_submodule_list="$missing_submodule_list $app"
		else
				echo "  ✓ $app is properly configured as submodule"
		fi
done

# Then check all existing submodules for proper configuration
echo ""
echo "[i] Checking existing submodules for proper configuration..."

all_apps=$(ls -1 apps-external/ 2>/dev/null || echo "")
for app in $all_apps; do
		if [ -d "apps-external/$app" ]; then
				# Check if this directory is a git submodule
				if ! git submodule status "apps-external/$app" >/dev/null 2>&1; then
						echo ""
						echo "[i] Skipping $app (not a git submodule)"
						continue
				fi

				echo ""
				echo "[i] Analyzing $app app..."

				# Check what files exist
				has_composer=0
				has_package=0
				has_build_script=0
				is_configured=0
				current_config=""
				needs_no_scripts=0

				if [ -f "apps-external/$app/composer.json" ]; then
						echo "  ✓ composer.json found"
						has_composer=1

						# Check if app needs --no-scripts due to bamarni plugin in require-dev only
						if grep -q "@composer bin" "apps-external/$app/composer.json" 2>/dev/null; then
								has_plugin_in_require=$(jq -r '.require // {} | keys[] | select(. == "bamarni/composer-bin-plugin")' "apps-external/$app/composer.json" 2>/dev/null || echo "")
								has_plugin_in_reqdev=$(jq -r '."require-dev" // {} | keys[] | select(. == "bamarni/composer-bin-plugin")' "apps-external/$app/composer.json" 2>/dev/null || echo "")
								if [ -z "$has_plugin_in_require" ] && [ -n "$has_plugin_in_reqdev" ]; then
										needs_no_scripts=1
										echo "  ⚠️  Uses @composer bin but plugin only in require-dev - needs --no-scripts"
								fi
						fi
				fi

				if [ -f "apps-external/$app/package.json" ]; then
						echo "  ✓ package.json found"
						has_package=1
						if grep -q "\"build\"" "apps-external/$app/package.json" 2>/dev/null; then
								build_script=$(jq -r ".scripts.build // empty" "apps-external/$app/package.json" 2>/dev/null)
								echo "  ✓ build script found: $build_script"
								has_build_script=1
						fi
				fi

				# Check current configuration
				for full_app in $FULL_BUILD_APPS; do
						if [ "$app" = "$full_app" ]; then
								current_config="FULL_BUILD_APPS"
								is_configured=1
								break
						fi
				done

				if [ $is_configured -eq 0 ]; then
						for composer_app in $COMPOSER_ONLY_APPS; do
								if [ "$app" = "$composer_app" ]; then
										current_config="COMPOSER_ONLY_APPS"
										is_configured=1
										break
								fi
						done
				fi

			if [ $is_configured -eq 0 ]; then
					for composer_no_scripts_app in $COMPOSER_NO_SCRIPTS_APPS; do
							if [ "$app" = "$composer_no_scripts_app" ]; then
									current_config="COMPOSER_NO_SCRIPTS_APPS"
									is_configured=1
									break
							fi
					done
			fi

			if [ $is_configured -eq 0 ]; then
					for composer_no_scripts_with_npm_app in $COMPOSER_NO_SCRIPTS_WITH_NPM_APPS; do
							if [ "$app" = "$composer_no_scripts_with_npm_app" ]; then
									current_config="COMPOSER_NO_SCRIPTS_WITH_NPM_APPS"
									is_configured=1
									break
							fi
					done
			fi

			if [ $is_configured -eq 0 ]; then
					for nothing_app in $NOTHING_TO_BUILD_APPS; do
							if [ "$app" = "$nothing_app" ]; then
									current_config="NOTHING_TO_BUILD_APPS"
									is_configured=1
									break
							fi
					done
			fi

				# Check for special apps with dedicated targets
				if [ $is_configured -eq 0 ]; then
						# Check if there is a dedicated build_<app>_app target in the Makefile
						if grep -q "^build_${app}_app:" "IONOS/Makefile" 2>/dev/null; then
								current_config="SPECIAL (build_${app}_app)"
								is_configured=1
						fi
				fi

				# Analyze and suggest proper configuration
				echo "  📊 Analysis:"
				if [ $is_configured -eq 1 ]; then
						echo "    Current: $current_config"
				else
						echo "    Current: ❌ NOT CONFIGURED"
						unconfigured_apps=$((unconfigured_apps + 1))
						unconfigured_app_list="$unconfigured_app_list $app"
				fi

				# Determine recommendation
				recommendation=""
				reasoning=""
				category_recommendation=""

			if [ $has_composer -eq 0 ]; then
					recommendation="⚠️  ERROR"
					reasoning="No composer.json found - all apps must have composer.json"
					category_recommendation="FIX REQUIRED"
					validation_failed=1
					error_app_list="$error_app_list $app"
			elif [ $needs_no_scripts -eq 1 ]; then
					# If app needs --no-scripts, check if it also needs npm build
					if [ $has_package -eq 1 ] && [ $has_build_script -eq 1 ]; then
							recommendation="✅ COMPOSER_NO_SCRIPTS_WITH_NPM_APPS"
							category_recommendation="COMPOSER_NO_SCRIPTS_WITH_NPM_APPS"
							reasoning="Has @composer bin command but bamarni plugin only in require-dev + needs npm build"
					else
							recommendation="✅ COMPOSER_NO_SCRIPTS_APPS"
							category_recommendation="COMPOSER_NO_SCRIPTS_APPS"
							reasoning="Has @composer bin command but bamarni plugin only in require-dev - needs --no-scripts flag"
					fi
			elif [ $has_composer -eq 1 ] && [ $has_package -eq 0 ]; then
					recommendation="✅ COMPOSER_ONLY_APPS"
					category_recommendation="COMPOSER_ONLY_APPS"
					reasoning="Has composer.json but no package.json - PHP-only app"
			elif [ $has_composer -eq 1 ] && [ $has_package -eq 1 ]; then
					if [ $has_build_script -eq 1 ]; then
							recommendation="✅ FULL_BUILD_APPS"
							category_recommendation="FULL_BUILD_APPS"
							reasoning="Has composer.json + package.json + build script - requires full build pipeline"
					else
							recommendation="✅ COMPOSER_ONLY_APPS"
							category_recommendation="COMPOSER_ONLY_APPS"
							reasoning="Has package.json but no build script - likely dev dependencies only, treat as PHP-only"
					fi
			fi

				echo "    Recommended Category: $recommendation"
				echo "    Reasoning: $reasoning"

			# Check if current config matches recommendation
			config_correct=0
			if [ "$current_config" = "FULL_BUILD_APPS" ] && [ "$category_recommendation" = "FULL_BUILD_APPS" ]; then
					config_correct=1
			elif [ "$current_config" = "COMPOSER_ONLY_APPS" ] && [ "$category_recommendation" = "COMPOSER_ONLY_APPS" ]; then
					config_correct=1
			elif [ "$current_config" = "COMPOSER_NO_SCRIPTS_APPS" ] && [ "$category_recommendation" = "COMPOSER_NO_SCRIPTS_APPS" ]; then
					config_correct=1
			elif [ "$current_config" = "COMPOSER_NO_SCRIPTS_WITH_NPM_APPS" ] && [ "$category_recommendation" = "COMPOSER_NO_SCRIPTS_WITH_NPM_APPS" ]; then
					config_correct=1
			elif [ "$current_config" = "COMPOSER_NO_SCRIPTS_APPS" ]; then
					# COMPOSER_NO_SCRIPTS_APPS are always considered correctly configured (special case for composer script issues)
					config_correct=1
			elif [ "$current_config" = "COMPOSER_NO_SCRIPTS_WITH_NPM_APPS" ]; then
					# COMPOSER_NO_SCRIPTS_WITH_NPM_APPS are always considered correctly configured
					config_correct=1
			elif [ "$current_config" = "NOTHING_TO_BUILD_APPS" ]; then
					# NOTHING_TO_BUILD_APPS are always considered correctly configured
					config_correct=1
			elif echo "$current_config" | grep -q "SPECIAL"; then
					# Special apps with dedicated targets are always considered correctly configured
					config_correct=1
			fi

				if [ $is_configured -eq 0 ]; then
						echo "    🚨 ACTION REQUIRED: Add to Makefile"
						validation_failed=1
				elif [ $config_correct -eq 1 ]; then
						echo "    ✅ Configuration is correct"
				else
						echo "    ⚠️  Incorrect configuration - needs to be moved"
						validation_failed=1
						# Only suggest moving if the recommendation is different from current config
						if echo "$recommendation" | grep -q "FULL_BUILD_APPS\|COMPOSER_ONLY_APPS"; then
								if [ "$current_config" != "$category_recommendation" ]; then
										echo "    💡 Move from $current_config to $recommendation"
										review_app_list="$review_app_list $app"
								fi
						fi
				fi
		fi
done

echo ""
echo "=== VALIDATION SUMMARY ==="
if [ $submodule_issues -gt 0 ]; then
		echo "❌ Found $submodule_issues submodule issue(s):$submodule_issue_list"
fi
if [ $missing_submodules -gt 0 ]; then
		echo "❌ Found $missing_submodules missing submodule(s):$missing_submodule_list"
fi
if [ $unconfigured_apps -gt 0 ]; then
		echo "❌ Found $unconfigured_apps unconfigured app(s):$unconfigured_app_list"
fi
if [ -n "$error_app_list" ]; then
		echo "❌ Apps with errors:$error_app_list"
fi
if [ -n "$review_app_list" ]; then
		echo "⚠️  Apps that may need review:$review_app_list"
fi

if [ $validation_failed -eq 0 ]; then
		echo "✅ All apps are properly configured"
else
		echo "🔧 Some apps need configuration updates"
		echo ""
		echo "📋 DEVELOPER ACTIONS:"
		if [ $submodule_issues -gt 0 ]; then
				echo "1. Fix git submodule issues:$submodule_issue_list"
				echo "   For uninitialized submodules (marked with -):"
				echo "   - Run: git submodule update --init --recursive"
				echo "   - Or individually: git submodule update --init apps-external/APP_NAME"
				echo "   For merge conflicts (marked with U):"
				echo "   - cd apps-external/APP_NAME"
				echo "   - git status (check conflict files)"
				echo "   - Resolve conflicts and commit"
				echo ""
		fi
		if [ $missing_submodules -gt 0 ]; then
				echo "2. Fix missing submodules:$missing_submodule_list"
				echo "   - Remove apps from FULL_BUILD_APPS/COMPOSER_ONLY_APPS if no longer needed"
				echo "   - Add missing apps as git submodules if they should exist"
		fi
		if [ $unconfigured_apps -gt 0 ]; then
			echo "3. Review apps marked as ACTION REQUIRED:$unconfigured_app_list"
			echo "   Add these unconfigured apps to appropriate categories in the Makefile:"
			echo ""
			echo "   For FULL_BUILD_APPS (apps with composer + npm + build script):"
			echo "   Add to line 29: FULL_BUILD_APPS = \\"
			echo "        existing_app \\"
			echo "        your_new_app \\"
			echo "        another_app"
			echo ""
			echo "   For COMPOSER_ONLY_APPS (PHP-only apps):"
			echo "   Add to line 53: COMPOSER_ONLY_APPS = \\"
			echo "        existing_app \\"
			echo "        your_new_app \\"
			echo "        another_app"
			echo ""
			echo "   For COMPOSER_NO_SCRIPTS_APPS (apps with composer scripts issues, no npm):"
			echo "   Add to line 60: COMPOSER_NO_SCRIPTS_APPS = \\"
			echo "        existing_app \\"
			echo "        your_new_app"
			echo "   (Use this for apps with @composer bin commands but bamarni plugin only in require-dev)"
			echo ""
			echo "   For COMPOSER_NO_SCRIPTS_WITH_NPM_APPS (apps with composer scripts issues + npm build):"
			echo "   Add to line 67: COMPOSER_NO_SCRIPTS_WITH_NPM_APPS = \\"
			echo "        existing_app \\"
			echo "        your_new_app"
			echo "   (Use this for apps with @composer bin/bamarni issues that also need npm build)"
			echo ""
			echo "   For NOTHING_TO_BUILD_APPS (no build steps needed):"
			echo "   Add to line 73: NOTHING_TO_BUILD_APPS = \\"
			echo "        existing_app \\"
			echo "        your_new_app"
		fi
		if [ -n "$error_app_list" ]; then
				echo "4. Fix apps with errors:$error_app_list"
				echo "   These apps are missing required composer.json files"
		fi
		if [ -n "$review_app_list" ]; then
				echo "5. Review apps with potential configuration issues:$review_app_list"
				echo "   These apps may be in the wrong category based on their structure"
		fi
		exit 1
fi
