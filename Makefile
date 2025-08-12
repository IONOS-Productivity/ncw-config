# SPDX-FileCopyrightText: 2025 STRATO AG
# SPDX-License-Identifier: AGPL-3.0-or-later

# Build configuration
TARGET_PACKAGE_NAME = ncw-server.zip

# Core build targets
.PHONY: help
# Main Nextcloud build
.PHONY: build_ncw
# Applications
.PHONY: build_all_external_apps build_richdocuments_app build_core_app_theming
# Configuration and packaging
.PHONY: add_config_partials version.json zip_dependencies
# Meta targets
.PHONY: build_release build_locally

help: ## This help.
	@echo "Usage: make [target]"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.DEFAULT_GOAL := help

build_core_app_theming: ## Build theming app
	@echo "[i] Building theming app..."
	cd apps/theming/composer && \
		composer dump-autoload --optimize


build_ncw: build_core_app_theming ## Build Nextcloud Workspace
#	composer install --no-dev -o && \
#	npm ci && \
#	NODE_OPTIONS="--max-old-space-size=4096" npm run build
	@echo "[i] No need to re-build right now. Will use version from repository"

build_richdocuments_app: ## Install and build richdocuments viewer app
	cd apps-external/richdocuments && \
	composer install --no-dev -o && \
	npm ci && \
	npm run build

add_config_partials: ## Copy custom config files to Nextcloud config
	@echo "[i] Copying config files..."
	cp IONOS/configs/*.config.php config/

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
	-x "apps-*/*/src**" \
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

build_all_external_apps: build_richdocuments_app ## Build all external apps
	@echo "[i] All external apps built successfully"

build_release: build_ncw build_all_external_apps add_config_partials zip_dependencies ## Build a release package (build, copy configs and package)
	@echo "[i] Everything done for a release"

build_locally: build_ncw build_all_external_apps ## Build all for local development
	@echo "[i] Everything done for local/dev"
