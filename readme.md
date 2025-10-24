<!--
  - SPDX-FileCopyrightText: 2025 STRATO GmbH
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->
# IONOS Nextcloud Workspace configuration

## Building for local development

```bash
make -f IONOS/Makefile build_locally
```

## Building a release package

```bash
make -f IONOS/Makefile build_release
```

## Configuration Files

### removed-apps.txt

This file contains a list of Nextcloud core apps that are excluded from the IONOS Nextcloud Workspace distribution.

**Purpose:**
- Excludes unwanted apps during the build/packaging process
- Used by helm deployment scripts to remove apps before updates

**Format:**
- One app name per line
- App names only (without `apps/` prefix)
- Comments start with `#`

**Usage:**

1. **During Build (Makefile):**
  - The Makefile reads this file and excludes listed apps from the final package
  - Apps are automatically excluded with the `apps/*/` pattern

2. **During Deployment (Helm):**
  - Helm before-update scripts use this file to remove unwanted apps
  - Ensures clean state before applying updates

**Example:**
To exclude the app located at `apps/example_app`, add:
```
example_app
```

**Currently Removed Apps:**
- `admin_audit` - Audit logging functionality
- `encryption` - Server-side encryption
- `files_reminders` - File reminder notifications
- `testing` - Testing app for development
- `updatenotification` - Update notification system
