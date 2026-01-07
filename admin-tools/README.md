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
