# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Project configuration for "workspace".
# Selected via PROJECT=workspace (default), see IONOS/Makefile.

# Build configuration
TARGET_PACKAGE_NAME = ncw-server.zip
PROJECT_NAME = ncw-server

# App directories that need full build (composer + npm + build)
FULL_BUILD_APPS = \
	activity \
	assistant \
	bruteforcesettings \
	calendar \
	collectives \
	contacts \
	deck \
	end_to_end_encryption \
	eurooffice \
	files_pdfviewer \
	groupfolders \
	integration_openai \
	mail \
	ncw_apps_menu \
	notes \
	notifications \
	spreed \
	tables \
	tasks \
	text \
	user_oidc \
	user_saml \
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
