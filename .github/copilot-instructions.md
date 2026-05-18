# GitHub Copilot Instructions

## Project Overview

This project is the **IONOS Nextcloud Workspace configuration** package, which provides configuration partials and scripts for HiDrive Next. It's a PHP-based project that manages Nextcloud configurations for IONOS's cloud workspace solution.

## Project Context & Architecture

### Technology Stack
- **Language**: PHP 8.x
- **Framework**: Nextcloud configuration system
- **Package Manager**: Composer
- **Code Quality**: PHP-CS-Fixer with Nextcloud coding standards
- **License**: AGPL-3.0-or-later

### Project Structure
- `configs/` - PHP configuration files for Nextcloud workspace
- `LICENSES/` - License information
- `.github/workflows/` - CI/CD pipeline configurations
- `Makefile` - Build automation for local and release builds

## Coding Standards & Best Practices

### PHP Code Style
- Follow **Nextcloud Coding Standard** strictly
- Use `declare(strict_types=1);` at the top of all PHP files
- Apply PHP-CS-Fixer rules as defined in `.php-cs-fixer.dist.php`
- Use type declarations for all function parameters and return types
- Follow PSR-12 coding standard as extended by Nextcloud

### File Headers & Licensing
**CRITICAL**: Every file must include proper SPDX license headers:

```php
<?php

declare(strict_types=1);

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
```

For non-PHP files use HTML comment format:
```html
<!--
 - SPDX-FileCopyrightText: 2025 STRATO GmbH
 - SPDX-License-Identifier: AGPL-3.0-or-later
-->
```

### Code Quality Requirements
- All code must pass `php -l` syntax checking
- Code must be formatted with `php-cs-fixer fix`
- Follow defensive programming practices
- Use meaningful variable and function names
- Add appropriate PHPDoc comments for complex logic

## Configuration File Patterns

### Nextcloud Configuration Structure
Configuration files should follow this pattern:

```php
<?php

declare(strict_types=1);

# SPDX-FileCopyrightText: 2025 STRATO GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later

$CONFIG = [
    'key' => 'value',
    // Configuration options here
];
```

### Common Configuration Categories
- **App Management**: Enable/disable apps, app paths
- **Theme Configuration**: Custom theming for IONOS branding
- **Update Management**: Automatic update controls
- **Mail Templates**: Email template customizations
- **Preview Providers**: File preview configurations
- **Upgrade Settings**: System upgrade behaviors

## Development Workflow

### Local Development
- Use `make -f IONOS/Makefile build_locally` for local builds
- Run `composer cs:fix` before committing
- Validate with `composer lint` and `composer cs:check`

### Release Process
- Use `make -f IONOS/Makefile build_release` for production builds
- Ensure all CI checks pass (PHP lint, CS check, REUSE compliance)
- Follow conventional commit messages

### Git Workflow
- Use conventional commits format
- No fixup commits in main branch
- All commits must pass automated checks
- Submodule changes trigger downstream workflows

## Code Review Process

### Review Requirements
- **Mandatory Reviews**: All pull requests require at least one approval
- **Review Focus Areas**:
  - SPDX license header compliance
  - PHP-CS-Fixer formatting adherence
  - Nextcloud configuration syntax and structure
  - Security implications of configuration changes
  - Backward compatibility considerations
  - Performance impact on Nextcloud instances

### Code Review Guidelines

#### For Reviewers
- Verify all new files include proper SPDX headers
- Check that configuration changes follow Nextcloud patterns
- Ensure code passes all automated checks before manual review
- Test configuration changes in local Nextcloud environment when possible
- Review for potential security vulnerabilities or misconfigurations
- Validate that changes align with IONOS business requirements

#### For Authors
- Run `composer cs:fix` and `composer lint` before requesting review
- Provide clear description of configuration changes and their impact
- Include testing steps for reviewers
- Document any breaking changes or migration requirements
- Respond promptly to review feedback and address all concerns

### Conventional Comments in Reviews

Use standardized comment prefixes to improve review clarity and consistency:

#### Comment Types
- **`nitpick: (optional)`** - Minor style or formatting suggestions (non-blocking)
  ```
  nitpick (optional): Consider using more descriptive variable name here
  ```

- **`suggestion: (optional)`** - Recommended improvements or alternative approaches
  ```
  suggestion (optional): This configuration could be simplified using array_merge()
  ```

- **`issue:`** - Problems that must be addressed before merging
  ```
  issue: Missing SPDX header - this will fail REUSE compliance check
  ```

- **`question:`** - Requests for clarification or explanation
  ```
  question: Why is this configuration value different from the default?
  ```

- **`praise: (optional)`** - Positive feedback on good practices
  ```
  praise (optional): Excellent use of type declarations and clear documentation
  ```

- **`todo: (optional)`** - Items to address in future iterations (document as issues)
  ```
  todo (optional): Consider adding validation for this configuration option
  ```

- **`security:`** - Security-related concerns that need immediate attention
  ```
  security: This configuration exposes sensitive information - needs review
  ```

- **`performance: (optional)`** - Performance implications that should be considered
  ```
  performance (optional): This configuration might impact Nextcloud loading times
  ```

#### Review Response Guidelines
- Address all `issue:` and `security:` comments before merge
- Respond to `question:` comments with explanations
- Consider `suggestion:` and other `(optional)` comments - implement or explain why not
- `(optional)` comments don't block merging but should be acknowledged
- Acknowledge `praise:` comments to maintain positive team culture
- Create GitHub issues for `todo:` items that won't be addressed immediately

### Review Checklist
Before approving a pull request, ensure:
- [ ] All files have correct SPDX license headers
- [ ] Code passes PHP lint and CS fixer checks
- [ ] Configuration changes are tested and documented
- [ ] No hardcoded secrets or credentials
- [ ] Backward compatibility is maintained or migration path provided
- [ ] Changes align with Nextcloud best practices
- [ ] Performance implications are considered
- [ ] Security review completed for sensitive changes

## Testing & Quality Assurance

### Automated Checks
- **PHP Syntax**: `php -l` validation
- **Code Style**: PHP-CS-Fixer compliance
- **License Compliance**: REUSE tool validation
- **Shell Scripts**: ShellCheck validation
- **Commit Format**: Conventional commits enforcement

### Manual Testing
- Test configuration files in Nextcloud environment
- Verify app functionality with new configurations
- Validate theme changes in browser
- Check mail template rendering

## Security Considerations

### Configuration Security
- Never hardcode credentials or secrets
- Use environment variables for sensitive data
- Validate all configuration inputs
- Follow principle of least privilege

### File Permissions
- Configuration files should have appropriate permissions
- Avoid world-readable sensitive configurations
- Use proper file ownership in deployment

## Integration Points

### Nextcloud Integration
- Configuration files merge with Nextcloud's config system
- Follow Nextcloud's configuration precedence rules
- Ensure compatibility with target Nextcloud versions
- Test with IONOS-specific Nextcloud customizations

### IONOS Ecosystem
- Integrate with HiDrive storage backend
- Support IONOS branding requirements
- Maintain compatibility with IONOS infrastructure
- Follow STRATO/IONOS coding guidelines

## Common Patterns & Examples

### Adding New Configuration
When adding new configuration options:

1. Create appropriately named `.config.php` file in `configs/`
2. Include proper SPDX headers
3. Use descriptive configuration keys
4. Add inline comments for complex settings
5. Test with actual Nextcloud instance

### Modifying Existing Configs
- Maintain backward compatibility when possible
- Document breaking changes clearly
- Update related documentation
- Consider migration paths for existing installations

## Error Handling & Debugging

### Configuration Errors
- Use clear, descriptive error messages
- Log configuration issues appropriately
- Provide fallback values where sensible
- Document troubleshooting steps

### Development Debugging
- Use Nextcloud's logging system
- Enable debug mode for development
- Check Nextcloud logs for configuration issues
- Validate configuration syntax before deployment

## Documentation Standards

### Code Comments
- Use PHPDoc format for functions and classes
- Explain complex configuration logic
- Document any IONOS-specific requirements
- Include examples for usage patterns

### Commit Messages
Follow conventional commits:
- `feat:` for new features
- `fix:` for bug fixes
- `docs:` for documentation
- `style:` for formatting
- `refactor:` for code restructuring
- `test:` for test additions
- `chore:` for maintenance task
- `ci:` for CI/CD changes
- `build:` for build system changes
- `perf:` for performance improvements
- `revert:` for reverting changes
- `BREAKING CHANGE:` for incompatible changes

## Performance Considerations

### Configuration Loading
- Minimize configuration file size
- Avoid complex computations in config files
- Use efficient array structures
- Cache-friendly configuration patterns

### Build Optimization
- Optimize for fast build times
- Minimize dependencies in release builds
- Use appropriate compression for packages
- Consider deployment bundle size

## Troubleshooting Guide

### Common Issues
- **CS Fixer Errors**: Run `composer cs:fix` to auto-resolve
- **PHP Syntax Errors**: Use `composer lint` to identify issues
- **License Compliance**: Ensure all files have SPDX headers
- **Build Failures**: Check Makefile targets and dependencies

### Development Environment
- Ensure PHP 8.x is available
- Install Composer dependencies with `composer install --dev`
- Configure IDE for Nextcloud coding standards
- Set up local Nextcloud instance for testing

Remember: This is enterprise software for IONOS customers. Prioritize stability, security, and maintainability over rapid feature development. Always consider the impact on existing IONOS Nextcloud Workspace deployments.
