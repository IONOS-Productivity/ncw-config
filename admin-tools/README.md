<!--
SPDX-License-Identifier: AGPL-3.0-or-later
SPDX-FileCopyrightText: 2026 STRATO GmbH
-->

# IONOS Admin Tools

This directory contains operational scripts for Nextcloud Workspace administrators. These tools provide a standardized interface for common administrative tasks with proper error handling and logging.

## Purpose

These scripts serve as an abstraction layer over Nextcloud's OCC commands, providing:
- **Consistent interface**: Standardized CLI parameters, exit codes, and output format
- **Better error handling**: Comprehensive validation and error reporting
- **Future compatibility**: Abstraction from internal Nextcloud command syntax changes
- **Complex workflows**: Support for multi-step operations with logic between OCC calls

## Available Scripts

### resend-welcome-mail-user.sh

Resend welcome email to a specific user.

```bash
./resend-welcome-mail-user.sh [OPTIONS] <username>

# Examples:
./resend-welcome-mail-user.sh john.doe
./resend-welcome-mail-user.sh --dry-run jane.smith
./resend-welcome-mail-user.sh --quiet admin
```

**Options:**
- `-h, --help`: Show help message
- `-v, --version`: Show version information
- `--dry-run`: Preview actions without executing
- `-q, --quiet`: Suppress informational output

### update-user-email.sh

Update the email address for a Nextcloud user. This is particularly useful when the initial admin user had a typo in their email address and needs to receive welcome emails.

```bash
./update-user-email.sh [OPTIONS] <username> <new_email>

# Examples:
./update-user-email.sh admin admin@example.com
./update-user-email.sh --resend-welcome admin corrected@example.com
./update-user-email.sh --dry-run john.doe newemail@example.com
./update-user-email.sh --quiet jane.smith updated@example.com
```

**Arguments:**
- `username`: Nextcloud username
- `new_email`: New email address to set

**Options:**
- `-h, --help`: Show help message
- `-v, --version`: Show version information
- `--dry-run`: Preview actions without executing
- `-q, --quiet`: Suppress informational output
- `-w, --resend-welcome`: Resend welcome email after updating

**What it does:**
1. Validates that the user exists
2. Checks if the email address has changed (skips update if already set)
3. Updates the user's email setting if changed (`user:setting` - OCC validates the email format)
4. Optionally resends the welcome email

**Use case:** When an initial admin user had a typo in their email address during setup, support can use this tool to correct the email and optionally trigger a new welcome email.

### update-mail-accounts-on-domain-change.sh

Update email addresses in Nextcloud mail app configuration when a customer's email domain changes (e.g., domain cancellation, email parking). This script updates the email address, IMAP username, and SMTP username for all matching mail accounts.

```bash
./update-mail-accounts-on-domain-change.sh <user_id> <old_email> <new_email>

# Examples:
./update-mail-accounts-on-domain-change.sh john.doe foo@example.com foo@parked-emails.com
./update-mail-accounts-on-domain-change.sh jane.smith user@old-domain.com user@new-domain.com
```

**Arguments:**
- `user_id`: Nextcloud user ID
- `old_email`: Current email address configured in the mail app
- `new_email`: New email address to update to

**What it updates:**
- Email field (display email)
- Inbound user (IMAP username)
- Outbound user (SMTP username)

**Note:** Users may need to refresh their mail app to see the changes.

### check-app-migrations.php

Read-only check of an app's migrations against the database. Reports migrations that were **never applied** (no row in `oc_migrations`) and migrations that are **applied but not in effect** (row exists, but the columns, tables or indexes they create are missing, or what they drop is still there). Example: Talk failing with `Unknown column 'r.last_pinned_id'` although `23000Date20251030090219` is recorded as applied.

The expected migrations are the `Version*.php` files in the app's `lib/Migration`, i.e. what is deployed there. No git is used. Schema effects (`addColumn`, `createTable`, `addIndex`, `setPrimaryKey`, `dropColumn`, `dropTable`, `dropIndex`, `renameColumn`) are extracted statically from `changeSchema()`. `hasColumn`-style guards are understood. Effects that a later applied migration overrides are skipped. A `changeSchema()` whose every `return` is `return null;` is reported as not verifiable with a note: Nextcloud applies the schema only when a schema wrapper is returned, so such a migration never makes its changes (a defect in the app) and re-running it cannot fix them. `if` guards are only trusted in the exact forms `if (!hasX('n')) { add n }` and `if (hasX('n')) { drop n }` (and `hasTable('t')` for effects on that table); other conditions, `if (false)`, early returns under runtime conditions, helper calls that receive the schema and computed names make the affected migrations (and earlier effects on the same tables) not verifiable. Indexes are compared with their uniqueness. Anything it cannot parse (data changes in `preSchemaChange`/`postSchemaChange`, loops, helper calls, non-guard conditions, computed names) is listed under "Not verifiable" and never guessed.

The database connection is taken from the Nextcloud config (`config/config.php` plus `config/*.config.php`); nothing is passed on the command line.

```bash
# On the instance: the app directory is found automatically
./check-app-migrations.php --app spreed --db

# sqlite dev instance whose datadirectory is a container path
./check-app-migrations.php --db --sqlite-file data/owncloud.db

# Every app that has rows in oc_migrations (core included; apps not on disk are skipped)
./check-app-migrations.php --all --db

# Only what an upgrade from Nextcloud 31 (31 -> 32 -> 33) should have run
./check-app-migrations.php --all --db --since-nc 31

# Check elsewhere from dumps taken in the pod
./check-app-migrations.php --db --dump-applied > applied.txt
./check-app-migrations.php --db --dump-schema  > schema.txt
./check-app-migrations.php --applied applied.txt --schema schema.txt
```

**Options:** `--app` (default `spreed`), `--all` (all apps; an overview table and details only for apps with findings, `--verbose` shows the rest), `--app-path` (default: looked up via `apps_paths` in the Nextcloud config, else `apps/`, `apps-external/`, `custom_apps/`), `--config DIR` (default: `NEXTCLOUD_CONFIG_DIR`, else the `config/` of the Nextcloud root the script lives in, not the current directory), `--sqlite-file FILE`, `--since-nc N` (only migrations written after Nextcloud N was branched, e.g. `31`; derived from the date stamp in the migration version, so approximate for apps that are branched on their own schedule), `--strict` (also fail on "not verifiable"), `--verbose` (list verified and superseded effects).

When something is found, the report ends with a "Suggested fix" block. A replay runs the whole migration again, not only the missing part, so the block only lists `NC_debug=true occ migrations:execute <app> <version>` for migrations that are safe to run: never applied ones, and applied ones without a drop that a later migration undid and without data changes in `preSchemaChange()`/`postSchemaChange()`. The rest is listed under "Review by hand" with the reason. `migrations:execute` only exists with debug on, so `NC_debug=true` enables it for that one command and not for the instance. The script only prints all this and never runs anything.

The schema dump starts with a `prefix=` line, so a dump from an instance with another table prefix works as is; `--prefix` is for hand-made files.

**Exit codes:** 0 nothing wrong, 1 never applied or not in effect found, 2 usage/input error. Output contains only versions and table, column and index names. Sessions are read-only (`SET SESSION TRANSACTION READ ONLY` / `PRAGMA query_only`), and connection errors are reported by code only so no credentials leak.

**Requires:** PHP with `pdo_mysql` or `pdo_sqlite` (for `--db`). No git needed.


## Standard Interface

All scripts in this directory follow these conventions:

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (operation failed) |
| 2 | Invalid usage (wrong arguments, missing parameters) |

### Common Options

- `--help, -h`: Display help message and exit
- `--version, -v`: Display version information and exit
- `--dry-run`: Show what would be done without executing
- `--quiet, -q`: Suppress informational output (errors still shown)

### Output Format

Scripts use color-coded logging:
- 🔵 **[INFO]**: Informational messages (blue)
- 🟢 **[SUCCESS]**: Successful operations (green)
- 🟡 **[WARNING]**: Warnings (yellow)
- 🔴 **[ERROR]**: Errors (red)
- 🔴 **[FATAL]**: Fatal errors that cause script exit (red)

## Common Functions Library

The `common.sh` library provides shared functionality:

### Logging Functions
- `log_info()`: Informational messages
- `log_success()`: Success messages
- `log_warning()`: Warning messages
- `log_error()`: Error messages
- `log_fatal()`: Fatal errors (exits with code 1)

### OCC Command Execution
- `execute_occ_command()`: Execute OCC with error handling
- `execute_occ_command_or_die()`: Execute OCC and exit on failure

### Validation Functions
- `check_occ_available()`: Verify OCC command exists
- `check_nextcloud_installed()`: Verify Nextcloud is installed
- `user_exists()`: Check if user exists

### Helper Functions
- `require_argument()`: Validate required arguments
- `print_help_header()`: Standardized help header
- `print_help_footer()`: Standardized help footer

## Creating New Admin Tools

To create a new admin tool:

1. **Copy a template** (use `resend-welcome-mail-user.sh` as reference)
2. **Source common.sh**:
  ```bash
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${SCRIPT_DIR}/common.sh"
  ```
3. **Follow naming conventions**: Use descriptive names with hyphens
4. **Implement standard options**: `--help`, `--version`, `--dry-run`, `--quiet`
5. **Use standard exit codes**: 0 (success), 1 (error), 2 (invalid usage)
6. **Add SPDX headers**:
  ```bash
  # SPDX-License-Identifier: AGPL-3.0-or-later
  # SPDX-FileCopyrightText: 2026 STRATO GmbH
  ```
7. **Make it executable**: `chmod +x your-script.sh`
8. **Update this README** with documentation

## Usage from Container

When using the development container, run scripts with:

```bash
# From host
../nc-docs-and-tools/container/dev /var/www/html/IONOS/admin-tools/resend-welcome-mail-user.sh john.doe

# Inside container
cd /var/www/html
./IONOS/admin-tools/resend-welcome-mail-user.sh john.doe
```

## Best Practices

1. **Always use --dry-run first** when testing new scripts
2. **Check exit codes** in automation scripts
3. **Read help messages** (`--help`) before using unfamiliar scripts
4. **Test in development** environment before production
5. **Review logs** for troubleshooting failed operations
6. **Use --quiet** for automation/cron jobs (reduces noise)

## Dependencies

- **Bash** 4.0 or higher
- **PHP** (for OCC command execution)
- **jq** (for JSON parsing in some scripts)
- **Nextcloud** properly installed and configured

## Troubleshooting

### "OCC command not found"
- Ensure you're running from the correct directory
- Check that Nextcloud is properly installed at `../../` relative to script location

### "Nextcloud is not installed or not accessible"
- Run `php occ status` manually to verify installation
- Check file permissions and PHP configuration

### Script exits with code 2
- Review command syntax: missing or incorrect arguments
- Use `--help` to see proper usage

### Welcome emails not received
- Check mail configuration: `php occ config:list mail`
- Verify SMTP settings in Nextcloud admin panel
- Check mail server logs for delivery issues

## Support

For issues or questions:
1. Check this README first
2. Review script help: `script-name.sh --help`
3. Consult IONOS documentation
4. Contact IONOS support team

## License

All scripts in this directory are licensed under AGPL-3.0-or-later.
See `../../COPYING` for full license text.
