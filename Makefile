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
	user_oidc \
	viewer \
	whiteboard

# App directories that need only composer
COMPOSER_ONLY_APPS = \
	circles \
	ncw_mailtemplate \
	ncw_tools

# App directories that need only composer but with --no-scripts (to avoid dev-only composer script issues)
# These apps have @composer bin commands in post-install-cmd but the bamarni/composer-bin-plugin
# is only in require-dev, so it fails when running with --no-dev
# Intentionally left empty: currently, no apps require composer with --no-scripts only.
COMPOSER_NO_SCRIPTS_APPS =

# App directories that need composer with --no-scripts AND npm build
# These apps have composer script issues with --no-dev but still need npm build
COMPOSER_NO_SCRIPTS_WITH_NPM_APPS = \
	forms \
	password_policy \
	twofactor_totp

# App directories that need nothing to build (no changes made during build)
NOTHING_TO_BUILD_APPS = \

# Apps with special build targets (not in the standard categories above)
# These apps have dedicated build_<app>_app targets with custom build logic
SPECIAL_BUILD_APPS = \
	notify_push

# App folders to add to shipped.json (makes apps non-removable)
# Add additional app folders here to include them in the shipped apps list
APP_FOLDERS_TO_SHIP = \
	apps-external
	# apps-custom

# Apps to be removed from final package (read from removed-apps.txt)
REMOVE_UNWANTED_APPS = $(shell [ -f IONOS/removed-apps.txt ] && sed '/^#/d;/^$$/d;s/^/apps\//' IONOS/removed-apps.txt || echo "")

# Generate build targets dynamically
FULL_BUILD_TARGETS = $(patsubst %,build_%_app,$(FULL_BUILD_APPS))
COMPOSER_ONLY_TARGETS = $(patsubst %,build_%_app,$(COMPOSER_ONLY_APPS))
COMPOSER_NO_SCRIPTS_TARGETS = $(patsubst %,build_%_app,$(COMPOSER_NO_SCRIPTS_APPS))
COMPOSER_NO_SCRIPTS_WITH_NPM_TARGETS = $(patsubst %,build_%_app,$(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS))
NOTHING_TO_BUILD_TARGETS = $(patsubst %,build_%_app,$(NOTHING_TO_BUILD_APPS))
SPECIAL_BUILD_TARGETS = $(patsubst %,build_%_app,$(SPECIAL_BUILD_APPS))

# Core build targets
.PHONY: help .precheck
# Main Nextcloud build
.PHONY: build_ncw
# Applications - dynamically generated
.PHONY: build_all_external_apps build_notify_push_binary build_core_app_theming $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(COMPOSER_NO_SCRIPTS_TARGETS) $(COMPOSER_NO_SCRIPTS_WITH_NPM_TARGETS) $(NOTHING_TO_BUILD_TARGETS) $(SPECIAL_BUILD_TARGETS)
# Configuration and packaging
.PHONY: add_config_partials patch_shipped_json version.json zip_dependencies
# Pipeline targets for GitLab workflow
.PHONY: build_after_external_apps package_after_build
# Meta targets
.PHONY: build_release build_locally clean
# Validation targets
.PHONY: validate_external_apps validate_all validate_app_list_uniqueness
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
	@echo "  Composer-only apps (no scripts):"
	@for app in $(COMPOSER_NO_SCRIPTS_APPS); do printf "\033[36m%-30s\033[0m Build $$app app (composer no scripts)\n" "build_$${app}_app"; done
	@echo "  Composer (no scripts) + npm build apps:"
	@for app in $(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS); do printf "\033[36m%-30s\033[0m Build $$app app (composer no scripts + npm)\n" "build_$${app}_app"; done
	@echo "  Nothing to build apps:"
	@for app in $(NOTHING_TO_BUILD_APPS); do printf "\033[36m%-30s\033[0m Nothing to build for $$app app\n" "build_$${app}_app"; done
	@echo ""
	@echo "Validation targets:"
	@echo "  validate_app_list_uniqueness  Validate apps are in only one list with no conflicts"
	@echo "  validate_external_apps        Validate all external apps configuration"
	@echo "  validate_all                  Run all validation tasks"
	@echo "Matrix generation targets:"
	@echo "  generate_external_apps_matrix  Generate external apps matrix YAML file"
	@echo "  generate_external_apps_matrix_json  Generate external apps matrix JSON file"
# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.DEFAULT_GOAL := help

.precheck:
	@{ \
		if [ ! -d "apps-external" ]; then \
			echo ""; \
			echo "**********************************************************************"; \
			echo "ERROR: apps-external/ directory not found!"; \
			echo ""; \
			echo "This Makefile must be executed from the Nextcloud project root."; \
			echo "Usage: make -f IONOS/Makefile <target>"; \
			echo "**********************************************************************"; \
			echo ""; \
			exit 1; \
		fi; \
		if ! test -f "version.php" || ! test -d "lib" || ! test -d "core"; then \
			echo ""; \
			echo "**********************************************************************"; \
			echo "ERROR: Required Nextcloud directories/files not found!"; \
			echo ""; \
			echo "This doesn't appear to be a valid Nextcloud project directory."; \
			echo "Usage: make -f IONOS/Makefile <target>"; \
			echo "**********************************************************************"; \
			echo ""; \
			exit 1; \
		fi; \
		if ! command -v jq >/dev/null 2>&1; then \
			echo ""; \
			echo "**********************************************************************"; \
			echo "ERROR: jq is not installed!"; \
			echo ""; \
			echo "jq is required for JSON processing in this Makefile."; \
			echo "Please install jq:"; \
			echo "  - Ubuntu/Debian: sudo apt-get install jq"; \
			echo "  - macOS: brew install jq"; \
			echo "  - Other: https://jqlang.github.io/jq/download/"; \
			echo "**********************************************************************"; \
			echo ""; \
			exit 1; \
		fi; \
	} >&2

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

# Common function to build apps with composer only but skip scripts
define build_composer_no_scripts_app
	@echo "[i] Building $(1) app (no scripts)..."
	@cd apps-external/$(1) && \
		composer install --no-dev -o --no-interaction --no-scripts
	@echo "[✓] $(1) app built successfully"
endef

# Common function to build apps with composer (no scripts) plus npm build
define build_composer_no_scripts_with_npm_app
	@echo "[i] Building $(1) app (no scripts + npm)..."
	@cd apps-external/$(1) && \
		composer install --no-dev -o --no-interaction --no-scripts && \
		$(NPM_INSTALL) && \
		$(NPM_BUILD)
	@echo "[✓] $(1) app built successfully"
endef

build_core_app_theming: .precheck ## Build theming app
	@echo "[i] Building theming app..."
	cd apps/theming/composer && \
		composer dump-autoload --optimize
	@echo "[✓] theming app built successfully"

build_ncw: .precheck build_core_app_theming ## Build Nextcloud Workspace
	composer install --no-dev -o && \
	npm ci && \
	NODE_OPTIONS="--max-old-space-size=4096" npm run build
	@echo "[✓] Nextcloud core built successfully"

# Dynamic rules for full build apps
$(FULL_BUILD_TARGETS): build_%_app:
	$(call build_full_app,$(patsubst build_%_app,%,$@))

# Dynamic rules for composer-only apps
$(COMPOSER_ONLY_TARGETS): build_%_app:
	$(call build_composer_app,$(patsubst build_%_app,%,$@))

# Dynamic rules for composer-only apps with --no-scripts
$(COMPOSER_NO_SCRIPTS_TARGETS): build_%_app:
	$(call build_composer_no_scripts_app,$(patsubst build_%_app,%,$@))

# Dynamic rules for composer-only apps with --no-scripts plus npm build
$(COMPOSER_NO_SCRIPTS_WITH_NPM_TARGETS): build_%_app:
	$(call build_composer_no_scripts_with_npm_app,$(patsubst build_%_app,%,$@))

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

add_config_partials: .precheck ## Copy custom config files to Nextcloud config
	@echo "[i] Copying config files..."
	cp IONOS/configs/*.config.php config/
	@echo "[✓] Config files copied successfully"

patch_shipped_json: .precheck ## Patch shipped.json
	@echo "[i] Patching shipped.json..."

	@echo "[i] Making external apps non-removable (hiding remove buttons)..."
	IONOS/scripts/patch_shipped_json_add_shipped_apps.sh $(APP_FOLDERS_TO_SHIP)

	@echo "[i] Making core apps disableable and enforcing always-enabled apps..."
	IONOS/apps-disable.sh

version.json: .precheck ## Generate version file
	@echo "[i] Generating version.json..."
	buildDate=$$(date +%s) && \
	buildRef=$$(git rev-parse --short HEAD) && \
	ncVersion=$$(php -r 'include("version.php");echo implode(".", $$OC_Version);') && \
	jq -n --arg buildDate $$buildDate --arg buildRef $$buildRef  --arg ncVersion $$ncVersion '{buildDate: $$buildDate, buildRef: $$buildRef, ncVersion: $$ncVersion}' > version.json && \
	echo "[i] version.json created" && \
	jq . version.json

zip_dependencies: patch_shipped_json version.json ## Zip relevant files
	@echo "[i] Checking if .buildnumber exists..."
	@if [ ! -f .buildnumber ]; then \
		echo ""; \
		echo "**********************************************************************"; \
		echo "ERROR: .buildnumber file not found!"; \
		echo ""; \
		echo "The .buildnumber file must exist before creating the package."; \
		echo "Please create it first or run the appropriate build target."; \
		echo "**********************************************************************"; \
		echo ""; \
		exit 1; \
	fi
	@echo "[i] .buildnumber found: $$(cat .buildnumber)"
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
		.buildnumber \
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
	-x "**/*.map" \
	-x "**/*.md" \
	-x "**/README*" \
	-x "**/CHANGELOG*" \
	-x "**/LICENSE*" \
	-x "**/COPYING*" \
	-x "**/tests/**" \
	-x "**/test/**" \
	-x "**/__tests__/**" \
	-x "**/spec/**" \
	-x "**/*.test.js" \
	-x "**/*.spec.js" \
	-x "**/*.test.ts" \
	-x "**/*.spec.ts" \
	-x "**/.eslintrc*" \
	-x "**/.prettierrc*" \
	-x "**/.babelrc*" \
	-x "**/tsconfig*.json" \
	-x "**/.npmignore" \
	-x "**/.gitattributes" \
	-x "**/phpunit.xml*" \
	-x "**/.phpunit.result.cache" \
	-x "**/phpstan.neon*" \
	-x "**/.php_cs*" \
	-x "**/.php-cs-fixer*" \
	-x "**/docs/**" \
	-x "**/doc/**" \
	-x "**/documentation/**" \
	-x "**/examples/**" \
	-x "**/.gitlab-ci.yml" \
	-x "**/.travis.yml" \
	-x "**/Makefile" \
	-x "**/Gruntfile.js" \
	-x "**/webpack*.js" \
	-x "**/rollup*.js" \
	-x "**/vite*.js" \
	-x "**/.stylelintrc*" \
	-x "**/jest.config*" \
	-x "**/.jshintrc*" \
	-x "**/vendor/*/test/**" \
	-x "**/vendor/*/tests/**" \
	-x "**/vendor/*/Test/**" \
	-x "**/vendor/*/Tests/**" \
	$(foreach app,$(REMOVE_UNWANTED_APPS),-x "$(app)/*")
	@echo "[i] Package $(TARGET_PACKAGE_NAME) created successfully"

# Parallel build targets
build_all_external_apps: $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(COMPOSER_NO_SCRIPTS_TARGETS) $(COMPOSER_NO_SCRIPTS_WITH_NPM_TARGETS) $(NOTHING_TO_BUILD_TARGETS) $(SPECIAL_BUILD_TARGETS) ## Build all external apps
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
	@rm -f .buildnumber
	@rm -f $(NOTIFY_PUSH_BINARY) $(NOTIFY_PUSH_BINARY).sha256
	@echo "[✓] Clean completed"

validate_external_apps: .precheck ## Validate and suggest proper categorization for external apps
	@IONOS/scripts/validate_external_apps.sh \
		"$(FULL_BUILD_APPS)" \
		"$(COMPOSER_ONLY_APPS)" \
		"$(COMPOSER_NO_SCRIPTS_APPS)" \
		"$(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS)" \
		"$(NOTHING_TO_BUILD_APPS)" \
		"$(SPECIAL_BUILD_APPS)"

validate_app_list_uniqueness: .precheck ## Validate that apps are only in one list and not duplicated by hardcoded targets
	@IONOS/scripts/validate_app_list_uniqueness.sh \
		"$(FULL_BUILD_APPS)" \
		"$(COMPOSER_ONLY_APPS)" \
		"$(COMPOSER_NO_SCRIPTS_APPS)" \
		"$(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS)" \
		"$(NOTHING_TO_BUILD_APPS)" \
		"$(SPECIAL_BUILD_APPS)" \
		"$(MAKEFILE_LIST)"

validate_all: .precheck ## Run all validation tasks
	@echo "[i] Running validation..."
	@$(MAKE) -f IONOS/Makefile validate_app_list_uniqueness
	@$(MAKE) -f IONOS/Makefile validate_external_apps
	@echo "[✓] Validation completed successfully"

generate_external_apps_matrix: .precheck ## Generate external-apps-matrix.yml file with app configuration details
	@echo "[i] Generating external apps matrix YAML file..." >&2
	@echo "apps-external:"
	@bash -c ' \
	# Process all configured apps \
	all_configured_apps="$(FULL_BUILD_APPS) $(COMPOSER_ONLY_APPS) $(COMPOSER_NO_SCRIPTS_APPS) $(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS) $(NOTHING_TO_BUILD_APPS) $(SPECIAL_BUILD_APPS)"; \
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

generate_external_apps_matrix_json: .precheck ## Generate external-apps-matrix.json file with app configuration details
	@echo "[i] Generating external apps matrix JSON file..." >&2
	@bash -c ' \
	# Process all configured apps \
	all_configured_apps="$(FULL_BUILD_APPS) $(COMPOSER_ONLY_APPS) $(COMPOSER_NO_SCRIPTS_APPS) $(COMPOSER_NO_SCRIPTS_WITH_NPM_APPS) $(NOTHING_TO_BUILD_APPS) $(SPECIAL_BUILD_APPS)"; \
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
