<!--
  - SPDX-FileCopyrightText: 2025 STRATO GmbH
  - SPDX-License-Identifier: AGPL-3.0-or-later
-->
# IONOS Nextcloud Workspace configuration

## Projects

One checkout builds several products ("projects"). Each project lives in `IONOS/projects/<key>/`:

| File | Purpose |
|------|---------|
| `project.mk` | package name, app lists, `APP_FOLDERS_TO_SHIP`, optional `<app>_APP_DIR` and `ONLY_LISTED_APPS` |
| `removed-apps.txt`, `disabled-apps.list`, `always-enabled-apps.list`, `enabled-core-apps.list` | app lists, see below |
| `configs/*.config.php` | config partials copied to `config/` after the shared `IONOS/configs/` ones |
| `app-config/` | app configuration files read by `configure.sh` |

Select a project with `PROJECT=<key>` (default `workspace`):

```bash
make -f IONOS/Makefile PROJECT=kodas build_release
```

The version.json of a build records the `projectKey`, so the runtime scripts (`configure.sh`, `apps-enable.sh`) use the same project. They can be overridden with the `PROJECT` or `PROJECT_DIR` environment variables.

### Adding a project

1. Copy `projects/workspace/` to `projects/<key>/` and adjust `project.mk` and the lists.
2. Apps shared by all projects stay in `apps-external/`. Apps that belong to one project go into their own folder, for example `apps-<key>/`:
   - add the folder to `APP_FOLDERS_TO_SHIP` and set `<app>_APP_DIR = apps-<key>` for each app in it,
   - register it in `projects/<key>/configs/app-paths.config.php` (`apps_paths` is replaced, not merged, so list every path).
3. Set `ONLY_LISTED_APPS = true` if apps in the shared folders that the project does not list must not be packaged.

`validate_external_apps` still only looks at `apps-external/`.

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

The app lists below live in `projects/<key>/`.

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
