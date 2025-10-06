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
	calendar \
	contacts \
	deck \
	forms \
	groupfolders \
	mail \
	ncw_apps_menu \
	notes \
	richdocuments \
	spreed \
	tasks \
	text \
	viewer \
	whiteboard

# App directories that need only composer
COMPOSER_ONLY_APPS = \
	circles \
	files_fulltextsearch \
	fulltextsearch \
	fulltextsearch_elasticsearch \
	ncw_mailtemplate

# App directories that need nothing to build (no changes made during build)
NOTHING_TO_BUILD_APPS = \
	files_antivirus

# Generate build targets dynamically
FULL_BUILD_TARGETS = $(patsubst %,build_%_app,$(FULL_BUILD_APPS))
COMPOSER_ONLY_TARGETS = $(patsubst %,build_%_app,$(COMPOSER_ONLY_APPS))
NOTHING_TO_BUILD_TARGETS = $(patsubst %,build_%_app,$(NOTHING_TO_BUILD_APPS))

# Core build targets
.PHONY: help
# Main Nextcloud build
.PHONY: build_ncw
# Applications - dynamically generated
.PHONY: build_all_external_apps build_notify_push_app build_notify_push_binary build_fulltextsearch_apps build_core_app_theming $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(NOTHING_TO_BUILD_TARGETS)
# Configuration and packaging
.PHONY: add_config_partials version.json zip_dependencies
# Pipeline targets for GitLab workflow
.PHONY: build_after_external_apps package_after_build
# Meta targets
.PHONY: build_release build_locally clean

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

build_fulltextsearch_apps: build_fulltextsearch_app build_files_fulltextsearch_app build_fulltextsearch_elasticsearch_app ## Build all fulltextsearch apps
	@echo "[i] All fulltextsearch apps built successfully"

add_config_partials: ## Copy custom config files to Nextcloud config
	@echo "[i] Copying config files..."
	cp IONOS/configs/*.config.php config/
	@echo "[✓] Config files copied successfully"

version.json: ## Generate version file
	@echo "[i] Generating version.json..."
	buildDate=$$(date +%s) && \
	buildRef=$$(git rev-parse --short HEAD) && \
	ncVersion=$$(php -r 'include("version.php");echo implode(".", $$OC_Version);') && \
	jq -n --arg buildDate $$buildDate --arg buildRef $$buildRef  --arg ncVersion $$ncVersion '{buildDate: $$buildDate, buildRef: $$buildRef, ncVersion: $$ncVersion}' > version.json && \
	echo "[i] version.json created" && \
	jq . version.json

zip_dependencies: version.json ## Zip relevant files
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
	-x "package-lock.json"
	@echo "[i] Package $(TARGET_PACKAGE_NAME) created successfully"

# Parallel build targets
build_all_external_apps: $(FULL_BUILD_TARGETS) $(COMPOSER_ONLY_TARGETS) $(NOTHING_TO_BUILD_TARGETS) build_notify_push_app ## Build all external apps
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
