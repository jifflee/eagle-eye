# SBOM Generation - Quick Reference

## Overview

The `generate-sbom.sh` script creates Software Bill of Materials (SBOM) for dependency tracking, compliance, and vulnerability management.

## Quick Start

```bash
# Generate SBOM (auto-installs syft if missing)
./scripts/ci/validators/generate-sbom.sh --install-tools

# Output: .sbom/sbom.spdx.json and .sbom/sbom.cyclonedx.json
```

## Common Use Cases

### Local Development

```bash
# Generate and validate SBOM
./scripts/ci/validators/generate-sbom.sh --validate

# View package count
jq '.packages | length' .sbom/sbom.spdx.json
```

### CI/CD Pipeline

```bash
# Pre-PR: Generate SBOM for review
./scripts/ci/validators/generate-sbom.sh --quiet

# Pre-release: Generate, validate, and archive
./scripts/ci/validators/generate-sbom.sh --validate --upload
```

### Specific Ecosystems

```bash
# npm only
./scripts/ci/validators/generate-sbom.sh --ecosystems npm

# Python only
./scripts/ci/validators/generate-sbom.sh --ecosystems python
```

## Integration with Existing CI Tools

### With Dependency Audit

```bash
# Complete dependency workflow
./scripts/ci/validators/generate-sbom.sh --validate
./scripts/ci/validators/dep-audit.sh --full
```

### With Security Scan

```bash
# Security + SBOM workflow
./scripts/ci/validators/security-scan.sh --full
./scripts/ci/validators/generate-sbom.sh --upload
```

## Output Formats

| Format | File | Use Case |
|--------|------|----------|
| SPDX JSON | `.sbom/sbom.spdx.json` | Enterprise compliance, NTIA requirements |
| CycloneDX JSON | `.sbom/sbom.cyclonedx.json` | Security analysis, vulnerability tracking |
| SPDX Tag-Value | `.sbom/sbom.spdx` | Human-readable format (optional) |
| CycloneDX XML | `.sbom/sbom.cyclonedx.xml` | Legacy tools (optional) |

## Tool Installation

### Automatic

```bash
./scripts/ci/validators/generate-sbom.sh --install-tools
```

### Manual

```bash
# syft (recommended)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b ~/.local/bin

# Add to PATH
export PATH="$HOME/.local/bin:$PATH"
```

## Troubleshooting

**Problem:** `syft: command not found`

```bash
# Install syft
./scripts/ci/validators/generate-sbom.sh --install-tools
```

**Problem:** Empty SBOM (0 packages)

```bash
# Verify dependencies are installed
npm install
pip install -r requirements.txt

# Re-run
./scripts/ci/validators/generate-sbom.sh --verbose
```

**Problem:** Validation failed

```bash
# Check SBOM content
jq . .sbom/sbom.spdx.json

# Run with verbose output
./scripts/ci/validators/generate-sbom.sh --validate --verbose
```

## CI/CD Integration Examples

### Add to Pre-PR Pipeline

Edit `.state/.ci-config.json`:

```json
{
  "modes": {
    "pre-pr": {
      "checks": [
        {"name": "sbom-generation", "script": "validators/generate-sbom.sh", "args": "--validate --quiet"}
      ]
    }
  }
}
```

### Add to Pre-Release Pipeline

```json
{
  "modes": {
    "pre-release": {
      "checks": [
        {"name": "sbom-generation", "script": "validators/generate-sbom.sh", "args": "--validate --upload"}
      ]
    }
  }
}
```

### Manual Integration

```bash
# Add to existing gate script
./scripts/ci/validators/generate-sbom.sh --validate --upload
if [ $? -ne 0 ]; then
  echo "SBOM generation failed"
  exit 1
fi
```

## Further Reading

- **Full Documentation**: [docs/SBOM_GENERATION.md](../../../docs/SBOM_GENERATION.md)
- **Issue**: #1038 - Add SBOM generation to CI builds
- **Epic**: #1030 - CI/CD infrastructure improvements
- **Related**: [dep-audit.sh](./dep-audit.sh), [security-scan.sh](./security-scan.sh)

## Standards Compliance

✅ **NTIA Minimum Elements** - Federal SBOM requirements
✅ **SPDX 2.3** - ISO/IEC 5962:2021 standard
✅ **CycloneDX 1.4+** - OWASP SBOM standard
✅ **CISA Guidelines** - Federal cybersecurity compliance

## Support

For issues or questions:

- **Bug reports**: Create issue with `bug`, `component:ci-cd` labels
- **Feature requests**: Create issue with `enhancement`, `component:ci-cd` labels
- **Documentation**: See [SBOM_GENERATION.md](../../../docs/SBOM_GENERATION.md)
