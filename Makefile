# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Build configuration
TARGET_PACKAGE_NAME = ncw-server.zip
# Set parallel jobs with load balancing to prevent system overload
# The following line sets MAKEFLAGS to use the number of available processors for parallel jobs,
# and sets the load average to 1.5 times the number of processors.
# It uses 'bc' for floating-point arithmetic; if 'bc' is not available, it falls back to using the integer value from 'nproc'.
# This ensures the build does not overload the system, even if 'bc' is missing.
MAKEFLAGS += --jobs=$(shell nproc) --load-average=$(shell echo "$(shell nproc) * 1.5" | bc 2>/dev/null || echo $(shell nproc))

# Architecture configuration
ARCHITECTURE = x86_64

# Common build commands
COMPOSER_INSTALL = composer install --no-dev -o --no-interaction
NPM_INSTALL = npm ci --prefer-offline --no-audit
NPM_BUILD = npm run build

# Variables for notify_push binary
NOTIFY_PUSH_DIR = apps-external/notify_push
NOTIFY_PUSH_BIN_DIR = $(NOTIFY_PUSH_DIR)/bin/$(ARCHITECTURE)
NOTIFY_PUSH_BINARY = $(NOTIFY_PUSH_BIN_DIR)/notify_push
NOTIFY_PUSH_VERSION = $(shell cd $(NOTIFY_PUSH_DIR) && grep -oP '(?<=<version>)[^<]+' appinfo/info.xml)
NOTIFY_PUSH_URL = https://github.com/nextcloud/notify_push/releases/download/v$(NOTIFY_PUSH_VERSION)/notify_push-$(ARCHITECTURE)-unknown-linux-musl

# App directories that need full build (composer + npm + build)
FULL_BUILD_APPS = \
	activity \
	assistant \
	calendar \
	collectives \
	contacts \
	deck \
	end_to_end_encryption \
	forms \
	groupfolders \
	integration_openai \
	mail \
	ncw_apps_menu \
	notes \
	notifications \
	richdocuments \
	spreed \
	tables \
	tasks \
	text \
	twofactor_totp \
	user_oidc \
	viewer \
	whiteboard \
	password_policy

# App directories that need only composer
COMPOSER_ONLY_APPS = \
	circles \
	ncw_mailtemplate

# App directories that need nothing to build (no changes made during build)
NOTHING_TO_BUILD_APPS = \

# Apps with special build targets (not in the standard categories above)
# These apps have dedicated build_<app>_app targets with custom build logic
SPECIAL_BUILD_APPS = \
	notify_push

# Apps to be removed from final package (read from removed-apps.txt)
REMOVE_UNWANTED_APPS = $(shell [ -f IONOS/removed-apps.txt ] && sed '/^#/d;/^$$/d;s/^/apps\//' IONOS/removed-apps.txt || echo "")

# Generate build targets dynamically
FULL_BUILD_TARGETS = $(patsubst %,build_%_app,$(FULL_BUILD_APPS))
COMPOSER_ONLY_TARGETS = $(patsubst %,build_%_app,$(COMPOSER_ONLY_APPS))
NOTHING_TO_BUILD_TARGETS = $(patsubst %,build_%_app,$(NOTHING_TO_BUILD_APPS))
SPECIAL_BUILD_TARGETS = $(patsubst %,build_%_app,$(SPECIAL_BUILD_APPS))

# Core build targets
.PHONY: help
# Main Nextcloud build
.PHONY: build_ncw
# Applications - dynamically generated
.PHONY: build_all_external_apps build_notify_push_binary build_core_app_theming $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(NOTHING_TO_BUILD_TARGETS) $(SPECIAL_BUILD_TARGETS)
# Configuration and packaging
.PHONY: add_config_partials patch_shipped_json version.json zip_dependencies
# Pipeline targets for GitLab workflow
.PHONY: build_after_external_apps package_after_build
# Meta targets
.PHONY: build_release build_locally clean
# Validation targets
.PHONY: validate_external_apps validate_all
# Matrix generation
.PHONY: generate_external_apps_matrix generate_external_apps_matrix_json

help: ## This help.
	@echo "Usage: make [target]"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "Individual app build targets:"
	@echo "  Full build apps (composer + npm + build):"
	@for app in $(FULL_BUILD_APPS); do printf "\033[36m%-30s\033[0m Build $$app app (full build)\n" "build_$${app}_app"; done
	@echo "  Composer-only apps:"
	@for app in $(COMPOSER_ONLY_APPS); do printf "\033[36m%-30s\033[0m Build $$app app (composer only)\n" "build_$${app}_app"; done
	@echo "  Nothing to build apps:"
	@for app in $(NOTHING_TO_BUILD_APPS); do printf "\033[36m%-30s\033[0m Nothing to build for $$app app\n" "build_$${app}_app"; done
	@echo ""
	@echo "Validation targets:"
	@echo "  validate_external_apps     Validate all external apps configuration"
	@echo "  validate_all               Run all validation tasks"
	@echo "Matrix generation targets:"
	@echo "  generate_external_apps_matrix  Generate external apps matrix YAML file"
	@echo "  generate_external_apps_matrix_json  Generate external apps matrix JSON file"
# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.DEFAULT_GOAL := help

# Common function to build apps with full build process
define build_full_app
	@echo "[i] Building $(1) app..."
	@cd apps-external/$(1) && \
		$(COMPOSER_INSTALL) && \
		$(NPM_INSTALL) && \
		$(NPM_BUILD)
	@echo "[✓] $(1) app built successfully"
endef

# Common function to build apps with composer only
define build_composer_app
	@echo "[i] Building $(1) app..."
	@cd apps-external/$(1) && \
		$(COMPOSER_INSTALL)
	@echo "[✓] $(1) app built successfully"
endef

build_core_app_theming: ## Build theming app
	@echo "[i] Building theming app..."
	cd apps/theming/composer && \
		composer dump-autoload --optimize
	@echo "[✓] theming app built successfully"

build_ncw: build_core_app_theming ## Build Nextcloud Workspace
#	composer install --no-dev -o && \
#	npm ci && \
#	NODE_OPTIONS="--max-old-space-size=4096" npm run build
	@echo "[i] No need to re-build right now. Will use version from repository"

# Dynamic rules for full build apps
$(FULL_BUILD_TARGETS): build_%_app:
	$(call build_full_app,$(patsubst build_%_app,%,$@))

# Dynamic rules for composer-only apps
$(COMPOSER_ONLY_TARGETS): build_%_app:
	$(call build_composer_app,$(patsubst build_%_app,%,$@))

# Dynamic rules for apps with nothing to build
$(NOTHING_TO_BUILD_TARGETS): build_%_app:
	@echo "[i] Nothing to build for $$(patsubst build_%_app,%,$@) app"

# notify_push binary target with checksum verification
$(NOTIFY_PUSH_BINARY): $(NOTIFY_PUSH_DIR)/appinfo/info.xml
	@echo "[i] Building notify_push binary target for version $(NOTIFY_PUSH_VERSION)..."
	@mkdir -p $(NOTIFY_PUSH_BIN_DIR)
	@echo "[i] Downloading notify_push binary version $(NOTIFY_PUSH_VERSION)..."
	curl -L -o $@ $(NOTIFY_PUSH_URL)
	@echo "[i] Verifying binary integrity..."
	@sha256sum $@ > $@.sha256
	@echo "[i] Binary SHA256: $$(sha256sum $@ | cut -d' ' -f1)"
	chmod +x $@
	@echo "[i] notify_push binary v$(NOTIFY_PUSH_VERSION) downloaded and verified successfully"

build_notify_push_app: $(NOTIFY_PUSH_DIR)/vendor/autoload.php $(NOTIFY_PUSH_BINARY) ## Install and build notify_push app
	@echo "[i] notify_push app built successfully"

$(NOTIFY_PUSH_DIR)/vendor/autoload.php: $(NOTIFY_PUSH_DIR)/composer.json
	@echo "[i] Installing notify_push PHP dependencies..."
	cd $(NOTIFY_PUSH_DIR) && composer install --no-dev -o

build_notify_push_binary: $(NOTIFY_PUSH_BINARY) ## Download notify_push binary
	@echo "[i] notify_push binary ready"

add_config_partials: ## Copy custom config files to Nextcloud config
	@echo "[i] Copying config files..."
	cp IONOS/configs/*.config.php config/
	@echo "[✓] Config files copied successfully"

patch_shipped_json: ## Patch shipped.json to make core apps disableable
	@echo "[i] Patching shipped.json..."
	IONOS/apps-disable.sh

version.json: ## Generate version file
	@echo "[i] Generating version.json..."
	buildDate=$$(date +%s) && \
	buildRef=$$(git rev-parse --short HEAD) && \
	ncVersion=$$(php -r 'include("version.php");echo implode(".", $$OC_Version);') && \
	jq -n --arg buildDate $$buildDate --arg buildRef $$buildRef  --arg ncVersion $$ncVersion '{buildDate: $$buildDate, buildRef: $$buildRef, ncVersion: $$ncVersion}' > version.json && \
	echo "[i] version.json created" && \
	jq . version.json

zip_dependencies: patch_shipped_json version.json ## Zip relevant files
	@echo "[i] zip relevant files to $(TARGET_PACKAGE_NAME)" && \
	zip -r "$(TARGET_PACKAGE_NAME)" \
		IONOS/ \
		3rdparty/ \
		apps/ \
		apps-external/ \
		config/ \
		core/ \
		dist/ \
		lib/ \
		ocs/ \
		ocs-provider/ \
		resources/ \
		themes/ \
		AUTHORS \
		composer.json \
		composer.lock \
		console.php \
		COPYING \
		cron.php \
		index.html \
		index.php \
		occ \
		public.php \
		remote.php \
		robots.txt \
		status.php \
		version.php \
		version.json  \
		.htaccess \
	-x "apps/theming/img/background/**" \
	-x "apps/*/tests/**" \
	-x "apps-*/*/.git" \
	-x "apps-*/*/composer.json" \
	-x "apps-*/*/composer.lock" \
	-x "apps-*/*/composer.phar" \
	-x "apps-*/*/.tx" \
	-x "apps-*/*/.github" \
	-x "apps-*/*/src" \
	-x "apps-*/*/node_modules**" \
	-x "apps-*/*/vendor-bin**" \
	-x "apps-*/*/tests**" \
	-x "**/cypress/**" \
	-x "*.git*" \
	-x "*.editorconfig*" \
	-x ".tx" \
	-x "composer.json" \
	-x "composer.lock" \
	-x "composer.phar" \
	-x "package.json" \
	-x "package-lock.json" \
	$(foreach app,$(REMOVE_UNWANTED_APPS),-x "$(app)/*")
	@echo "[i] Package $(TARGET_PACKAGE_NAME) created successfully"

# Parallel build targets
build_all_external_apps: $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(NOTHING_TO_BUILD_TARGETS) $(SPECIAL_BUILD_TARGETS) ## Build all external apps
	@echo "[i] All external apps built successfully"

build_after_external_apps: build_ncw add_config_partials ## Build NCW and add configs after external apps are done
	@echo "[i] NCW built and config files added"

package_after_build: zip_dependencies ## Create package after build is complete
	@echo "[i] Package created successfully"

build_release: build_ncw build_all_external_apps add_config_partials zip_dependencies ## Build a release package (build, copy configs and package)
	@echo "[i] Everything done for a release"

build_locally: build_ncw build_all_external_apps ## Build all for local development
	@echo "[i] Everything done for local/dev"

clean: ## Clean build artifacts
	@echo "[i] Cleaning build artifacts..."
	@rm -f $(TARGET_PACKAGE_NAME)
	@rm -f version.json
	@rm -f $(NOTIFY_PUSH_BINARY) $(NOTIFY_PUSH_BINARY).sha256
	@echo "[✓] Clean completed"

validate_external_apps: ## Validate and suggest proper categorization for external apps
	@echo "[i] Analyzing external apps to suggest proper build configuration..."
	@echo "[i] Checking all apps in apps-external directory..."
	@bash -c ' \
	validation_failed=0; \
	unconfigured_apps=0; \
	missing_submodules=0; \
	submodule_issues=0; \
	missing_submodule_list=""; \
	unconfigured_app_list=""; \
	error_app_list=""; \
	review_app_list=""; \
	submodule_issue_list=""; \
	\
	# First check git submodule status for all submodules \
	echo ""; \
	echo "[i] Checking git submodule status..."; \
	\
	if command -v git >/dev/null 2>&1; then \
		submodule_status_output=$$(git submodule status 2>/dev/null || echo ""); \
		if [ -n "$$submodule_status_output" ]; then \
			echo "$$submodule_status_output" | while IFS= read -r line; do \
				if [ -n "$$line" ]; then \
					status_char=$${line:0:1}; \
					submodule_path=$$(echo "$$line" | awk "{print \$$2}"); \
					commit_hash=$$(echo "$$line" | awk "{print \$$1}" | sed "s/^.//"); \
					app_name=$$(basename "$$submodule_path"); \
					\
					case "$$status_char" in \
						" ") \
							echo "  ✓ $$app_name: submodule is up to date"; \
							;; \
						"+") \
							echo "  ⚠️  $$app_name: submodule has uncommitted changes"; \
							echo "    💡 Run: cd $$submodule_path && git add . && git commit -m \"Update changes\""; \
							;; \
						"-") \
							echo "  ❌ $$app_name: submodule not initialized ($$commit_hash)"; \
							echo "    💡 Run: git submodule update --init $$submodule_path"; \
							submodule_issues=$$((submodule_issues + 1)); \
							submodule_issue_list="$$submodule_issue_list $$app_name"; \
							validation_failed=1; \
							;; \
						"U") \
							echo "  ❌ $$app_name: submodule has merge conflicts"; \
							echo "    💡 Run: cd $$submodule_path && git status && resolve conflicts"; \
							submodule_issues=$$((submodule_issues + 1)); \
							submodule_issue_list="$$submodule_issue_list $$app_name"; \
							validation_failed=1; \
							;; \
						*) \
							echo "  ❓ $$app_name: unknown submodule status ($$status_char)"; \
							;; \
					esac; \
				fi; \
			done; \
		else \
			echo "  ℹ️  No git submodules found or git submodule command failed"; \
		fi; \
	else \
		echo "  ⚠️  Git command not available - skipping submodule status check"; \
	fi; \
	\
	# Check if any configured apps are missing as submodules \
	echo ""; \
	echo "[i] Checking configured apps for missing submodules..."; \
	\
	for app in $(FULL_BUILD_APPS) $(COMPOSER_ONLY_APPS) $(NOTHING_TO_BUILD_APPS) $(SPECIAL_BUILD_APPS); do \
		if [ ! -d "apps-external/$$app" ]; then \
			echo "  ❌ ERROR: App $$app is configured but directory does not exist"; \
			validation_failed=1; \
			missing_submodules=$$((missing_submodules + 1)); \
			missing_submodule_list="$$missing_submodule_list $$app"; \
		elif ! git submodule status "apps-external/$$app" >/dev/null 2>&1; then \
			echo "  ❌ ERROR: App $$app is configured but not a git submodule"; \
			validation_failed=1; \
			missing_submodules=$$((missing_submodules + 1)); \
			missing_submodule_list="$$missing_submodule_list $$app"; \
		else \
			echo "  ✓ $$app is properly configured as submodule"; \
		fi; \
	done; \
	\
	# Then check all existing submodules for proper configuration \
	echo ""; \
	echo "[i] Checking existing submodules for proper configuration..."; \
	\
	all_apps=$$(ls -1 apps-external/); \
	for app in $$all_apps; do \
		if [ -d "apps-external/$$app" ]; then \
			# Check if this directory is a git submodule \
			if ! git submodule status "apps-external/$$app" >/dev/null 2>&1; then \
				echo ""; \
				echo "[i] Skipping $$app (not a git submodule)"; \
				continue; \
			fi; \
			\
			echo ""; \
			echo "[i] Analyzing $$app app..."; \
			\
			# Check what files exist \
			has_composer=0; \
			has_package=0; \
			has_build_script=0; \
			is_configured=0; \
			current_config=""; \
			\
			if [ -f "apps-external/$$app/composer.json" ]; then \
				echo "  ✓ composer.json found"; \
				has_composer=1; \
			fi; \
			\
			if [ -f "apps-external/$$app/package.json" ]; then \
				echo "  ✓ package.json found"; \
				has_package=1; \
				if grep -q "\"build\"" "apps-external/$$app/package.json" 2>/dev/null; then \
					build_script=$$(jq -r ".scripts.build // empty" "apps-external/$$app/package.json" 2>/dev/null); \
					echo "  ✓ build script found: $$build_script"; \
					has_build_script=1; \
				fi; \
			fi; \
			\
			# Check current configuration \
			for full_app in $(FULL_BUILD_APPS); do \
				if [ "$$app" = "$$full_app" ]; then \
					current_config="FULL_BUILD_APPS"; \
					is_configured=1; \
					break; \
				fi; \
			done; \
			\
			if [ $$is_configured -eq 0 ]; then \
				for composer_app in $(COMPOSER_ONLY_APPS); do \
					if [ "$$app" = "$$composer_app" ]; then \
						current_config="COMPOSER_ONLY_APPS"; \
						is_configured=1; \
						break; \
					fi; \
				done; \
			fi; \
			\
			if [ $$is_configured -eq 0 ]; then \
				for nothing_app in $(NOTHING_TO_BUILD_APPS); do \
					if [ "$$app" = "$$nothing_app" ]; then \
						current_config="NOTHING_TO_BUILD_APPS"; \
						is_configured=1; \
						break; \
					fi; \
				done; \
			fi; \
			\
			# Check for special apps with dedicated targets \
			if [ $$is_configured -eq 0 ]; then \
				# Check if there is a dedicated build_<app>_app target in this Makefile \
				if grep -q "^build_$${app}_app:" "$(MAKEFILE_LIST)" 2>/dev/null; then \
					current_config="SPECIAL (build_$${app}_app)"; \
					is_configured=1; \
				fi; \
			fi; \
			\
			# Analyze and suggest proper configuration \
			echo "  📊 Analysis:"; \
			if [ $$is_configured -eq 1 ]; then \
				echo "    Current: $$current_config"; \
			else \
				echo "    Current: ❌ NOT CONFIGURED"; \
				unconfigured_apps=$$((unconfigured_apps + 1)); \
				unconfigured_app_list="$$unconfigured_app_list $$app"; \
			fi; \
			\
			# Determine recommendation \
			recommendation=""; \
			reasoning=""; \
			category_recommendation=""; \
			\
			if [ $$has_composer -eq 0 ]; then \
				recommendation="⚠️  ERROR"; \
				reasoning="No composer.json found - all apps must have composer.json"; \
				category_recommendation="FIX REQUIRED"; \
				validation_failed=1; \
				error_app_list="$$error_app_list $$app"; \
			elif [ $$has_composer -eq 1 ] && [ $$has_package -eq 0 ]; then \
				recommendation="✅ COMPOSER_ONLY_APPS"; \
				category_recommendation="COMPOSER_ONLY_APPS"; \
				reasoning="Has composer.json but no package.json - PHP-only app"; \
			elif [ $$has_composer -eq 1 ] && [ $$has_package -eq 1 ]; then \
				if [ $$has_build_script -eq 1 ]; then \
					recommendation="✅ FULL_BUILD_APPS"; \
					category_recommendation="FULL_BUILD_APPS"; \
					reasoning="Has composer.json + package.json + build script - requires full build pipeline"; \
				else \
					recommendation="✅ COMPOSER_ONLY_APPS"; \
					category_recommendation="COMPOSER_ONLY_APPS"; \
					reasoning="Has package.json but no build script - likely dev dependencies only, treat as PHP-only"; \
				fi; \
			fi; \
			\
			echo "    Recommended Category: $$recommendation"; \
			echo "    Reasoning: $$reasoning"; \
			\
			# Check if current config matches recommendation \
			config_correct=0; \
			if [ "$$current_config" = "FULL_BUILD_APPS" ] && [ "$$category_recommendation" = "FULL_BUILD_APPS" ]; then \
				config_correct=1; \
			elif [ "$$current_config" = "COMPOSER_ONLY_APPS" ] && [ "$$category_recommendation" = "COMPOSER_ONLY_APPS" ]; then \
				config_correct=1; \
			elif [ "$$current_config" = "NOTHING_TO_BUILD_APPS" ]; then \
				# NOTHING_TO_BUILD_APPS are always considered correctly configured \
				config_correct=1; \
			elif echo "$$current_config" | grep -q "SPECIAL"; then \
				# Special apps with dedicated targets are always considered correctly configured \
				config_correct=1; \
			fi; \
			\
			if [ $$is_configured -eq 0 ]; then \
				echo "    🚨 ACTION REQUIRED: Add to Makefile"; \
				validation_failed=1; \
			elif [ $$config_correct -eq 1 ]; then \
				echo "    ✅ Configuration is correct"; \
			else \
				echo "    ⚠️  Incorrect configuration - needs to be moved"; \
				validation_failed=1; \
				# Only suggest moving if the recommendation is different from current config \
				if echo "$$recommendation" | grep -q "FULL_BUILD_APPS\|COMPOSER_ONLY_APPS"; then \
					if [ "$$current_config" != "$$category_recommendation" ]; then \
						echo "    💡 Move from $$current_config to $$recommendation"; \
						review_app_list="$$review_app_list $$app"; \
					fi; \
				fi; \
			fi; \
		fi; \
	done; \
	\
	echo ""; \
	echo "=== VALIDATION SUMMARY ==="; \
	if [ $$submodule_issues -gt 0 ]; then \
		echo "❌ Found $$submodule_issues submodule issue(s):$$submodule_issue_list"; \
	fi; \
	if [ $$missing_submodules -gt 0 ]; then \
		echo "❌ Found $$missing_submodules missing submodule(s):$$missing_submodule_list"; \
	fi; \
	if [ $$unconfigured_apps -gt 0 ]; then \
		echo "❌ Found $$unconfigured_apps unconfigured app(s):$$unconfigured_app_list"; \
	fi; \
	if [ -n "$$error_app_list" ]; then \
		echo "❌ Apps with errors:$$error_app_list"; \
	fi; \
	if [ -n "$$review_app_list" ]; then \
		echo "⚠️  Apps that may need review:$$review_app_list"; \
	fi; \
	\
	if [ $$validation_failed -eq 0 ]; then \
		echo "✅ All apps are properly configured"; \
	else \
		echo "🔧 Some apps need configuration updates"; \
		echo ""; \
		echo "📋 DEVELOPER ACTIONS:"; \
		if [ $$submodule_issues -gt 0 ]; then \
			echo "1. Fix git submodule issues:$$submodule_issue_list"; \
			echo "   For uninitialized submodules (marked with -):"; \
			echo "   - Run: git submodule update --init --recursive"; \
			echo "   - Or individually: git submodule update --init apps-external/APP_NAME"; \
			echo "   For merge conflicts (marked with U):"; \
			echo "   - cd apps-external/APP_NAME"; \
			echo "   - git status (check conflict files)"; \
			echo "   - Resolve conflicts and commit"; \
			echo ""; \
		fi; \
		if [ $$missing_submodules -gt 0 ]; then \
			echo "2. Fix missing submodules:$$missing_submodule_list"; \
			echo "   - Remove apps from FULL_BUILD_APPS/COMPOSER_ONLY_APPS if no longer needed"; \
			echo "   - Add missing apps as git submodules if they should exist"; \
		fi; \
		if [ $$unconfigured_apps -gt 0 ]; then \
			echo "3. Review apps marked as ACTION REQUIRED:$$unconfigured_app_list"; \
			echo "   Add these unconfigured apps to appropriate categories in the Makefile:"; \
			echo ""; \
			echo "   For FULL_BUILD_APPS (apps with composer + npm + build script):"; \
			echo "   Add to line ~25: FULL_BUILD_APPS = \\"; \
			echo "        existing_app \\"; \
			echo "        your_new_app \\"; \
			echo "        another_app"; \
			echo ""; \
			echo "   For COMPOSER_ONLY_APPS (PHP-only apps):"; \
			echo "   Add to line ~40: COMPOSER_ONLY_APPS = \\"; \
			echo "        existing_app \\"; \
			echo "        your_new_app \\"; \
			echo "        another_app"; \
			echo ""; \
			echo "   For NOTHING_TO_BUILD_APPS (no build steps needed):"; \
			echo "   Add to line ~47: NOTHING_TO_BUILD_APPS = \\"; \
			echo "        existing_app \\"; \
			echo "        your_new_app"; \
		fi; \
		if [ -n "$$error_app_list" ]; then \
			echo "4. Fix apps with errors:$$error_app_list"; \
			echo "   These apps are missing required composer.json files"; \
		fi; \
		if [ -n "$$review_app_list" ]; then \
			echo "5. Review apps with potential configuration issues:$$review_app_list"; \
			echo "   These apps may be in the wrong category based on their structure"; \
		fi; \
		exit 1; \
	fi'

validate_all: ## Run all validation tasks
	@echo "[i] Running validation..."
	@$(MAKE) -f IONOS/Makefile validate_external_apps
	@echo "[✓] Validation completed successfully"

generate_external_apps_matrix: ## Generate external-apps-matrix.yml file with app configuration details
	@echo "[i] Generating external apps matrix YAML file..." >&2
	@echo "apps-external:"
	@bash -c ' \
	# Process all configured apps \
	all_configured_apps="$(FULL_BUILD_APPS) $(COMPOSER_ONLY_APPS) $(NOTHING_TO_BUILD_APPS) $(SPECIAL_BUILD_APPS)"; \
	# Sort apps alphabetically \
	sorted_apps=$$(echo $$all_configured_apps | tr " " "\n" | sort | tr "\n" " "); \
	for app in $$sorted_apps; do \
		if [ -d "apps-external/$$app" ]; then \
			echo "  - name: $$app"; \
			echo "    path: apps-external/$$app"; \
			\
			# Check for npm (package.json) \
			if [ -f "apps-external/$$app/package.json" ]; then \
				echo "    has_npm: true"; \
			else \
				echo "    has_npm: false"; \
			fi; \
			\
			# Check for composer (composer.json) \
			if [ -f "apps-external/$$app/composer.json" ]; then \
				echo "    has_composer: true"; \
			else \
				echo "    has_composer: false"; \
			fi; \
			\
			# Determine makefile target \
			makefile_target="build_$${app}_app"; \
			echo "    makefile_target: $$makefile_target"; \
			echo ""; \
		fi; \
	done'

generate_external_apps_matrix_json: ## Generate external-apps-matrix.json file with app configuration details
	@echo "[i] Generating external apps matrix JSON file..." >&2
	@bash -c ' \
	# Process all configured apps \
	all_configured_apps="$(FULL_BUILD_APPS) $(COMPOSER_ONLY_APPS) $(NOTHING_TO_BUILD_APPS) $(SPECIAL_BUILD_APPS)"; \
	echo "["; \
	first=true; \
	found_any=false; \
	for app in $$all_configured_apps; do \
		if [ -d "apps-external/$$app" ]; then \
			found_any=true; \
			if [ "$$first" = true ]; then \
				first=false; \
			else \
				echo "  },"; \
			fi; \
			echo "  {"; \
			echo "    \"name\": \"$$app\","; \
			echo "    \"path\": \"apps-external/$$app\","; \
			\
			# Check for npm (package.json) \
			if [ -f "apps-external/$$app/package.json" ]; then \
				echo "    \"has_npm\": true,"; \
			else \
				echo "    \"has_npm\": false,"; \
			fi; \
			\
			# Check for composer (composer.json) \
			if [ -f "apps-external/$$app/composer.json" ]; then \
				echo "    \"has_composer\": true,"; \
			else \
				echo "    \"has_composer\": false,"; \
			fi; \
			\
			# Determine makefile target \
			makefile_target="build_$${app}_app"; \
			echo "    \"makefile_target\": \"$$makefile_target\""; \
		fi; \
	done; \
	if [ "$$found_any" = true ]; then \
		echo "  }"; \
	fi; \
	echo "]"' | jq 'sort_by(.name)'
