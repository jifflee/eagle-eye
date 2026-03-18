# SAST Integration with Semgrep

## Overview

This directory contains the SAST (Static Application Security Testing) scanner integration using [Semgrep](https://semgrep.dev/), an open-source code analysis tool that performs AST-based pattern matching to detect security vulnerabilities.

## What is SAST?

SAST analyzes source code without executing it to identify security vulnerabilities, bugs, and code quality issues. Unlike pattern-based scanners (like `security-scan.sh`), SAST tools understand code structure and semantics, enabling detection of complex vulnerabilities like:

- **Injection attacks** - SQL, command, XSS, LDAP injection
- **Authentication bypasses** - Weak auth, hardcoded credentials
- **Cryptographic issues** - Weak algorithms, insecure random
- **Insecure deserialization** - pickle, YAML unsafe loads
- **Path traversal & SSRF** - File access, request forgery
- **Authorization flaws** - Missing access controls

## Why Semgrep?

Semgrep was chosen over CodeQL for this repository because:

1. **Lightweight** - Python-based, no heavy dependencies
2. **Fast** - Scans 100K+ LoC in seconds
3. **Multi-language** - Supports 30+ languages including Bash, Python, TypeScript
4. **Easy to customize** - Simple YAML rule syntax
5. **Open source** - Free for all use cases
6. **CI-friendly** - Designed for CI/CD pipelines

**CodeQL** is GitHub's enterprise SAST tool, excellent for large organizations but:
- Requires GitHub Actions (we can't modify workflows per constraint)
- Heavier resource requirements
- More complex setup for custom rules

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    CI Pipeline (run-pipeline.sh)            │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ├─ pre-commit (lightweight, staged files only)
                         ├─ pre-pr (full scan, all files)
                         ├─ pre-merge (validation)
                         └─ pre-release (comprehensive)
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│              sast-scan.sh (wrapper script)                  │
│  • Validates Semgrep installation                           │
│  • Loads custom rules config                                │
│  • Executes scan with severity filtering                    │
│  • Parses and reports findings                              │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                      Semgrep Engine                         │
│  • AST-based code analysis                                  │
│  • Pattern matching with semantic understanding             │
│  • Multi-language support                                   │
│  • Community + custom rules                                 │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│               sast-report.json (output)                     │
│  • Findings with file:line locations                        │
│  • Severity levels (ERROR, WARNING, INFO)                   │
│  • CWE/OWASP mappings                                       │
│  • Remediation guidance                                     │
└─────────────────────────────────────────────────────────────┘
```

## Files

### Core Scripts

- **`sast-scan.sh`** - Main SAST scanner wrapper
  - Validates Semgrep installation
  - Loads configuration
  - Executes scans with proper arguments
  - Parses and reports findings
  - Integrates with CI pipeline

### Configuration

- **`config/semgrep-rules.yml`** - Custom security rules
  - Language-specific rules (Bash, Python, TypeScript)
  - Generic rules (API keys, private keys)
  - Severity classifications
  - CWE/OWASP mappings

### Tests

- **`tests/scripts/ci/validators/test-sast-scan.sh`** - Integration tests
  - Script functionality tests
  - Vulnerability detection tests
  - Multi-language support tests
  - Report format validation

## Usage

### Basic Scan

```bash
# Scan repository with default settings
./scripts/ci/validators/sast-scan.sh
```

### Custom Configuration

```bash
# Use custom rules config
./scripts/ci/validators/sast-scan.sh --config config/my-rules.yml

# Set minimum severity threshold
./scripts/ci/validators/sast-scan.sh --severity high

# Output to specific file
./scripts/ci/validators/sast-scan.sh --output security-findings.json
```

### Output Formats

```bash
# JSON format (default)
./scripts/ci/validators/sast-scan.sh --format json

# SARIF format (for GitHub Code Scanning)
./scripts/ci/validators/sast-scan.sh --format sarif

# GitLab SAST format
./scripts/ci/validators/sast-scan.sh --format gitlab-sast

# Human-readable text
./scripts/ci/validators/sast-scan.sh --format text
```

### CI Integration

```bash
# CI mode: fail on high severity
./scripts/ci/validators/sast-scan.sh --severity high

# Warning mode: report but don't fail
./scripts/ci/validators/sast-scan.sh --no-fail
```

## Installation

### Install Semgrep

```bash
# Install via pip (recommended)
pip3 install --user semgrep

# Or install automatically with script
./scripts/ci/validators/sast-scan.sh --install

# Verify installation
semgrep --version
```

### Add to PATH (if needed)

```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"
```

## Exit Codes

| Code | Meaning                           | Action                |
|------|-----------------------------------|-----------------------|
| 0    | No security findings              | ✅ Pass               |
| 1    | Low/medium findings detected      | ⚠️  Warning           |
| 2    | Critical/high findings detected   | ❌ Block CI           |

## Severity Levels

Findings are classified by severity:

- **ERROR (Critical/High)** - Blocks CI, immediate fix required
  - SQL injection, command injection
  - eval() usage, insecure deserialization
  - Hardcoded secrets, private keys

- **WARNING (Medium)** - Should fix, may block PR review
  - Weak cryptography (MD5, SHA1)
  - Missing input validation
  - Security misconfigurations

- **INFO (Low)** - Best practices, optional improvements
  - Code style security suggestions
  - Potential improvements

## Supported Languages

### Primary Support
- **Bash** - Shell script security
- **Python** - Injection, deserialization, crypto
- **TypeScript/JavaScript** - XSS, injection, DOM security

### Generic Rules
- **All files** - Secrets detection (API keys, tokens, private keys)

### Future Support (extensible)
- Go, Rust, Java, Ruby, PHP, etc.

## Custom Rules

Add custom rules to `config/semgrep-rules.yml`:

```yaml
rules:
  - id: my-custom-rule
    pattern: dangerous_function($ARG)
    message: |
      Avoid using dangerous_function() as it can lead to security issues.
      Use safe_function() instead.
    languages: [python]
    severity: ERROR
    metadata:
      category: security
      cwe: "CWE-xxx"
```

## Integration with Existing Security Tools

SAST complements existing security scanning:

| Tool                    | Type           | Focus                          | Overlap |
|-------------------------|----------------|--------------------------------|---------|
| **sast-scan.sh**        | SAST (AST)     | Code-level vulnerabilities     | 🆕 New  |
| security-scan.sh        | Pattern-based  | Secrets, OWASP patterns        | 20%     |
| osv-scan.sh             | Dependency     | Known CVEs in dependencies     | 0%      |
| dep-audit.sh            | Dependency     | npm/pip vulnerabilities        | 0%      |
| sensitivity-scan.sh     | Pattern-based  | Internal data exposure         | 10%     |

**Recommended flow:**
1. SAST (this tool) - Find code-level bugs
2. Secret scanning - Detect hardcoded credentials
3. Dependency scanning - Check libraries for CVEs

## Performance

Semgrep is designed for CI speed:

- **Small repo (< 10K LoC)**: < 10 seconds
- **Medium repo (10K-100K LoC)**: 10-60 seconds
- **Large repo (> 100K LoC)**: 1-3 minutes

This repository (~624 files):
- Expected scan time: **15-30 seconds**
- Suitable for pre-commit hooks (with `--severity high`)
- Suitable for PR validation (full scan)

## Troubleshooting

### Semgrep not found

```bash
# Install Semgrep
pip3 install --user semgrep

# Or let script install it
./scripts/ci/validators/sast-scan.sh --install
```

### Timeout in CI

```bash
# Increase timeout (default: 120s for pre-commit)
CI_TIMEOUT_PRE_COMMIT=180 ./scripts/ci/run-pipeline.sh --pre-commit
```

### Too many false positives

```bash
# Increase severity threshold
./scripts/ci/validators/sast-scan.sh --severity high

# Or customize rules in config/semgrep-rules.yml
```

### Missing language support

```bash
# Semgrep supports 30+ languages by default
# Check: semgrep --help

# For new languages, add custom rules to config/semgrep-rules.yml
```

## References

- **Semgrep Docs**: https://semgrep.dev/docs/
- **Rule Library**: https://semgrep.dev/explore
- **CWE Database**: https://cwe.mitre.org/
- **OWASP Top 10**: https://owasp.org/Top10/

## Related Issues

- #1042 - Add SAST integration with Semgrep or CodeQL
- #1030 - Security improvements (parent epic)

## Maintenance

### Updating Rules

```bash
# Edit config/semgrep-rules.yml
vim config/semgrep-rules.yml

# Validate rules
semgrep --config config/semgrep-rules.yml --validate

# Test against vulnerable code samples
./tests/scripts/ci/validators/test-sast-scan.sh
```

### Updating Semgrep

```bash
# Upgrade to latest version
pip3 install --user --upgrade semgrep

# Verify
semgrep --version
```

## License

This SAST integration uses:
- **Semgrep**: LGPL 2.1 (open source)
- **Custom rules**: Repository license (follows main repo)
