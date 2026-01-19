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

There are two mechanisms for processing this file:

1. **Build-time (Docker image build):**
  - The `apps-disable.sh` script processes `disabled-apps.list` during Docker image build to modify `core/shipped.json` and make listed apps disableable.
  - Run:
    ```bash
    ./apps-disable.sh
    ```
  - This script must run during Docker image build, **NOT** in Kubernetes pods at runtime.

2. **Runtime (Kubernetes after upgrade):**
  - The `configure.sh` script calls `disable_configured_apps()` at runtime (e.g., in k8s pods after upgrade) to ensure listed apps are disableable in a running environment.
  - This is useful for upgrades or dynamic configuration changes.

**Note:**  
- Use `apps-disable.sh` for build-time modifications to shipped.json.  
- Use `configure.sh` for runtime enforcement after upgrades in Kubernetes.

**alwaysEnabled vs defaultEnabled:**
  - `alwaysEnabled` - Critical: Prevents admins from disabling the app (checked during operations)
  - `defaultEnabled` - Only affects new installations, not updates
**Validation:** The script validates JSON before and after modifications to prevent corruption

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
### always-enabled-apps.list

This file contains apps that must **stay enabled** and **cannot be disabled** by administrators.

**Purpose:**
- Enforces critical apps remain enabled (security, IONOS customizations, core functionality)
- Prevents disabling via OCC or UI by adding apps to `alwaysEnabled` array in `shipped.json`

**How it Works:**
1. `enforce-always-enabled-apps.sh` runs at startup/after updates
2. Adds apps to `core/shipped.json`'s `alwaysEnabled` array
3. Enables each app via OCC
4. Nextcloud's AppManager prevents disabling apps in `alwaysEnabled`

**Usage:**
```bash
# Manual execution
./IONOS/enforce-always-enabled-apps.sh

# Automatically via configure.sh
./IONOS/configure.sh
```

**Kubernetes Integration:**
Add as init container:
```yaml
initContainers:
  - name: enforce-apps
    command: ["/bin/sh", "-c", "./IONOS/enforce-always-enabled-apps.sh"]
```

**Verification:**
```bash
# Try to disable (should fail)
php occ app:disable ncw_apps_menu
# Expected: Exception: "ncw_apps_menu can't be disabled."
```

**Currently Always-Enabled Apps:**
- `files_trashbin`, `user_status`, `webhook_listeners` - Core apps
- `ncw_apps_menu`, `ncw_mailtemplate` - IONOS customizations
- `notify_push`, `password_policy`, `text`, `twofactor_totp` - Essential features
