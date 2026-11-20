# SPDX-FileCopyrightText: 2026 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

# Project configuration for "kodas" (proof of concept: placeholder app set).
# Selected via PROJECT=kodas, see IONOS/Makefile.

TARGET_PACKAGE_NAME = ncw-kodas.zip
PROJECT_NAME = ncw-kodas

# Only the apps listed below are shipped from the shared apps-external folder.
ONLY_LISTED_APPS = true

# Placeholder selection from the shared base; kodas-only apps go into apps-kodas
# and are mapped with <app>_APP_DIR = apps-kodas.
FULL_BUILD_APPS = \
	text \
	viewer

COMPOSER_ONLY_APPS =
COMPOSER_NO_SCRIPTS_APPS =
COMPOSER_NO_SCRIPTS_WITH_NPM_APPS =
NOTHING_TO_BUILD_APPS =
SPECIAL_BUILD_APPS =

# Shared base first, then the project folder (see configs/app-paths.config.php)
APP_FOLDERS_TO_SHIP = \
	apps-external \
	apps-kodas
