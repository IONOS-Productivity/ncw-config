# SPDX-FileCopyrightText: 2025 STRATO AG
# SPDX-License-Identifier: AGPL-3.0-or-later

TARGET_PACKAGE_NAME=ncw-server.zip

.PHONY: help .build_deps add_config_partials build_release build_locally zip_dependencies version.json

help: ## This help.
	@echo "Usage: make [target]"
	@echo ""
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
# HELP
# This will output the help for each task
# thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.DEFAULT_GOAL := help

.remove_node_modules: ## Remove node_modules
	rm -rf node_modules

build_core_app_theming: ## Build theming app
	cd apps/theming/composer && \
		composer dump-autoload --optimize


build_ncw: build_core_app_theming ## Build Nextcloud Workspace
#	composer install --no-dev -o && \
#	npm ci && \
#	NODE_OPTIONS="--max-old-space-size=4096" npm run build
	@echo "[i] No need to re-build right now. Will use version from repository"

add_config_partials: ## Copy custom config files to Nextcloud config
	cp IONOS/configs/*.config.php config/

version.json: ## Generate version file
	buildDate=$$(date +%s) && \
	buildRef=$$(git rev-parse --short HEAD) && \
	ncVersion=$$(php -r 'include("version.php");echo implode(".", $$OC_Version);') && \
	jq -n --arg buildDate $$buildDate --arg buildRef $$buildRef  --arg ncVersion $$ncVersion '{buildDate: $$buildDate, buildRef: $$buildRef, ncVersion: $$ncVersion}' > version.json && \
	echo "version.json created" && \
	jq . version.json

zip_dependencies: version.json ## Zip relevant files
	@echo "zip relevant files to $(TARGET_PACKAGE_NAME)" && \
	zip -r "$(TARGET_PACKAGE_NAME)" \
		IONOS/ \
		3rdparty/ \
		apps/ \
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
	-x "**/cypress/**" \
	-x "*.git*" \
	-x "*.editorconfig*" \
	-x ".tx" \
	-x "composer.json" \
	-x "composer.lock" \
	-x "composer.phar" \
	-x "package.json" \
	-x "package-lock.json"

build_release: build_ncw add_config_partials zip_dependencies ## Build a release package (build, copy configs and package)
	@echo "Everything done for a release"

build_locally: .remove_node_modules build_ncw ## Build all for local development
	@echo "Everything done for local/dev"
