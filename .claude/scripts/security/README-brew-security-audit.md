# Homebrew Security Audit Tool

A comprehensive security auditing script for Homebrew formulae and casks that validates package reputation, maintenance status, and security posture.

## Features

- ✅ **Package Enumeration**: Scans all installed Homebrew formulae and casks
- ✅ **Reputation Validation**: Checks if packages are from official vs third-party taps
- ✅ **GitHub Metrics**: Analyzes repository stars, activity, and maintenance status
- ✅ **Outdated Package Detection**: Identifies packages with available updates
- ✅ **Archive Detection**: Flags unmaintained/archived repositories
- ✅ **Audit Integration**: Leverages `brew audit` for formula validation
- ✅ **Detailed Reporting**: Generates comprehensive security reports with remediation steps
- ✅ **CVE Awareness**: Provides guidance for manual CVE checking

## Installation

1. Download the script:
```bash
curl -O https://raw.githubusercontent.com/your-repo/brew-security-audit.sh
chmod +x brew-security-audit.sh
```

2. Or place it in your PATH:
```bash
sudo cp brew-security-audit.sh /usr/local/bin/brew-security-audit
sudo chmod +x /usr/local/bin/brew-security-audit
```

## Usage

### Basic Usage

Run a basic security audit:
```bash
./brew-security-audit.sh
```

### Verbose Mode

Get detailed output during the scan:
```bash
./brew-security-audit.sh --verbose
```

### JSON Output

Output results in JSON format (for automation/parsing):
```bash
./brew-security-audit.sh --json
```

### Help

Display usage information:
```bash
./brew-security-audit.sh --help
```

## Exit Codes

- `0` - Success, no issues found
- `1` - Warnings detected (outdated packages, third-party taps, etc.)
- `2` - Critical issues detected (archived repositories, severe security concerns)

## Report Interpretation

### Critical Issues ❌

These require immediate attention:
- **Archived Repositories**: Package is no longer maintained
- **Severe Security Vulnerabilities**: Known exploits or CVEs

### Warnings ⚠️

These should be reviewed:
- **Third-Party Taps**: Not from official Homebrew repositories
- **Low GitHub Stars**: May indicate limited community vetting (<100 stars)
- **Outdated Packages**: Updates available that may contain security fixes
- **Stale Updates**: No updates in over 365 days

### Checks Performed

1. **Official Tap Verification**
   - Validates packages are from `homebrew/core` or `homebrew/cask`
   - Flags third-party taps for manual review

2. **GitHub Repository Analysis**
   - Star count (popularity indicator)
   - Archive status (maintenance indicator)
   - Last update timestamp (activity indicator)

3. **Package Currency**
   - Identifies outdated formulae and casks
   - Suggests updates that may contain security patches

4. **Formula Audit**
   - Runs `brew audit` on installed packages
   - Checks for formula issues and violations

## Remediation Guide

### For Outdated Packages

Update all packages:
```bash
brew update && brew upgrade
```

Update specific package:
```bash
brew upgrade <package-name>
```

### For Third-Party Taps

Review tap source:
```bash
brew tap-info <tap-name>
```

Remove untrusted tap:
```bash
brew untap <tap-name>
```

### For Archived/Unmaintained Packages

Find alternatives:
```bash
brew search <similar-package-name>
```

Remove package:
```bash
brew uninstall <package-name>
```

### For Security Advisories

Check Homebrew security advisories:
- https://github.com/Homebrew/homebrew-core/security/advisories

Check National Vulnerability Database:
- https://nvd.nist.gov

## Configuration

You can modify these thresholds in the script:

```bash
MIN_GITHUB_STARS=100          # Minimum stars for "reputable" project
MIN_DAYS_SINCE_UPDATE=365     # Maximum days since last update
```

## Limitations

- **GitHub API Rate Limiting**: Unauthenticated requests limited to 60/hour
  - For higher limits, consider adding GitHub token authentication
- **CVE Detection**: Basic implementation recommends manual checks
  - Full automation would require NVD API integration with proper version matching
- **Version Matching**: Does not currently map package versions to specific CVEs
- **Date Parsing**: macOS date command used (may need adjustment for Linux)

## Advanced Usage

### Automation

Schedule regular audits with cron:
```bash
# Run weekly security audit
0 9 * * 1 /usr/local/bin/brew-security-audit.sh > ~/brew-audit-$(date +\%Y\%m\%d).log 2>&1
```

### CI/CD Integration

Use exit codes for automated checks:
```bash
#!/bin/bash
if ! ./brew-security-audit.sh; then
    echo "Security issues detected in Homebrew packages"
    exit 1
fi
```

### Filtering Results

Filter for specific issues:
```bash
./brew-security-audit.sh 2>&1 | grep "CRITICAL"
./brew-security-audit.sh 2>&1 | grep "Third-party"
```

## Security Best Practices

1. **Regular Updates**: Run `brew update && brew upgrade` weekly
2. **Tap Hygiene**: Only add taps from trusted sources
3. **Minimal Installation**: Only install necessary packages
4. **Periodic Audits**: Run this script monthly or after major installations
5. **CVE Monitoring**: Subscribe to security advisories for critical packages
6. **Review Before Install**: Check package reputation before installing

## Troubleshooting

### jq not installed

Install jq for JSON parsing:
```bash
brew install jq
```

### Permission Denied

Make script executable:
```bash
chmod +x brew-security-audit.sh
```

### GitHub API Rate Limit

Wait for rate limit reset or add authentication:
```bash
# Set GitHub token (optional, for higher rate limits)
export GITHUB_TOKEN="your_token_here"
```

## Contributing

Contributions welcome! Areas for improvement:
- Full NVD CVE API integration with version matching
- GitHub token authentication for higher rate limits
- Linux compatibility improvements
- Additional security checks (checksums, signatures, etc.)
- JSON output format implementation

## License

MIT License - Feel free to use and modify

## Disclaimer

This tool provides security guidance but is not a complete security solution. Always:
- Verify findings manually
- Keep systems and packages updated
- Follow security best practices
- Consult official security advisories

## Support

For issues or questions:
- Open an issue on GitHub
- Check Homebrew documentation: https://docs.brew.sh
- Review security best practices: https://brew.sh/security
