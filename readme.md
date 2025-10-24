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

### disabled-apps.list

This file contains a list of Nextcloud apps that should be made **disableable** by removing them from the `shipped.json` configuration.

**Purpose:**
- Allows administrators to disable specific Nextcloud apps that would normally be forced to stay enabled
- Modifies `core/shipped.json` to remove apps from both `alwaysEnabled` and `defaultEnabled` arrays

**Key Difference from removed-apps.txt:**
| File | Action | Result |
|------|--------|--------|
| `removed-apps.txt` | **Removes** apps entirely from distribution | Apps are not installed at all |
| `disabled-apps.list` | **Allows disabling** of apps | Apps are installed but can be disabled by admins |

**Usage:**

The `apps-disable.sh` script processes this file during **Docker image build** (not at runtime):

```bash
./apps-disable.sh
```

**⚠️ Important Notes:**

1. **Execution Timing:** This script must run during Docker image build, NOT in Kubernetes pods at runtime
2. **alwaysEnabled vs defaultEnabled:**
  - `alwaysEnabled` - Critical: Prevents admins from disabling the app (checked during operations)
  - `defaultEnabled` - Only affects new installations, not updates
3. **Validation:** The script validates JSON before and after modifications to prevent corruption

**Example:**

To make the `dashboard` app disableable:
```
# UI customization
dashboard
weather_status

# Optional features
recommendations
```

Then the app can be disabled via:
```bash
occ app:disable dashboard
```

**Currently Disabled Apps:**
- `workflowengine` - Workflow automation engine
