# OSV-Scanner Integration

## Overview

OSV-Scanner is integrated into the dependency audit pipeline to provide broader vulnerability database coverage across all ecosystems. It complements existing npm audit and pip-audit tools by aggregating vulnerability data from:

- Google's Open Source Vulnerabilities (OSV) database
- National Vulnerability Database (NVD)
- GitHub Security Advisories
- Ecosystem-specific databases (npm, PyPI, Go, Rust, etc.)

## Architecture

```
dep-audit.sh (orchestrator)
├── npm audit (JavaScript/Node.js)
├── pip-audit (Python)
├── safety (Python)
└── osv-scan.sh (All ecosystems via OSV database)
    └── osv-scanner (Google's OSV scanner tool)
```

## Integration Points

### 1. osv-scan.sh
- **Location**: `scripts/ci/validators/osv-scan.sh`
- **Purpose**: Standalone wrapper for OSV-Scanner
- **Usage**: Can be called directly or via dep-audit.sh
- **Output**: JSON report in `.dep-audit/osv-scanner.json`

### 2. dep-audit.sh
- **Integration**: Calls `run_osv_scanner()` function
- **Merging**: Results merged into unified dependency audit report
- **Exit codes**: Non-zero exit from osv-scanner contributes to overall failure

### 3. Test Coverage
- **Location**: `tests/test_osv_scan.sh`
- **Coverage**: Script existence, help output, directory creation, graceful degradation, JSON output, integration

## Usage

### Standalone
```bash
# Run OSV-Scanner directly
./scripts/ci/validators/osv-scan.sh

# Custom output directory
./scripts/ci/validators/osv-scan.sh --output-dir /tmp/scans

# Verbose output
./scripts/ci/validators/osv-scan.sh --verbose
```

### Via dep-audit.sh
```bash
# Full audit (includes OSV-Scanner)
./scripts/ci/validators/dep-audit.sh --full

# Skip OSV-Scanner
./scripts/ci/validators/dep-audit.sh --full --no-osv
```

## Installation

OSV-Scanner is optional. If not installed, the script gracefully skips scanning:

```bash
# Install OSV-Scanner
curl -sSfL https://raw.githubusercontent.com/google/osv-scanner/main/scripts/install.sh | sh

# Or via Go
go install github.com/google/osv-scanner/cmd/osv-scanner@latest
```

## Output Format

OSV-Scanner produces normalized JSON output compatible with dep-audit.sh:

```json
{
  "results": [
    {
      "package": "express",
      "version": "4.17.1",
      "ecosystem": "npm",
      "vulnerabilities": [
        {
          "id": "GHSA-xxxx-yyyy-zzzz",
          "summary": "Vulnerability description",
          "severity": "HIGH"
        }
      ]
    }
  ],
  "summary": {
    "total_packages": 150,
    "vulnerable_packages": 3,
    "total_vulnerabilities": 5
  }
}
```

## Supported Ecosystems

OSV-Scanner automatically detects and scans lockfiles for:

- **JavaScript/Node.js**: package-lock.json, yarn.lock, pnpm-lock.yaml
- **Python**: requirements.txt, poetry.lock, Pipfile.lock
- **Go**: go.sum
- **Rust**: Cargo.lock
- **Ruby**: Gemfile.lock (future)
- **Java**: pom.xml, build.gradle (future)

## Configuration

### Skip OSV-Scanner
```bash
# Via flag
./scripts/ci/validators/dep-audit.sh --no-osv

# Via environment (in CI config)
SKIP_OSV=true ./scripts/ci/validators/dep-audit.sh
```

### Custom Output Directory
```bash
./scripts/ci/validators/osv-scan.sh --output-dir .custom-audit/
```

## Exit Codes

- `0` - No vulnerabilities found (or osv-scanner not installed - graceful skip)
- `1` - Vulnerabilities found
- `2` - Tool error (jq missing, etc.)

## Integration with CI Pipeline

OSV-Scanner is automatically included in:

- **Pre-PR validation**: `--pre-pr` mode runs full audit including OSV
- **Pre-QA gate**: Full audit with OSV-Scanner
- **Pre-main gate**: Strict mode with OSV-Scanner

### Quick Mode
OSV-Scanner is skipped in `--quick` mode (pre-commit) for performance.

## Graceful Degradation

If osv-scanner is not installed:
- Script logs a warning
- Creates empty report: `{"results": [], "summary": {...}}`
- Exits with code 0 (does not block CI)
- dep-audit.sh continues with other tools

This allows gradual rollout without breaking existing workflows.

## Benefits Over Existing Tools

| Tool | Coverage | OSV-Scanner Advantage |
|------|----------|----------------------|
| npm audit | npm registry only | Aggregates from NVD, GitHub, OSV |
| pip-audit | PyPI only | Broader Python vulnerability sources |
| safety | Safety DB only | More comprehensive Python coverage |

OSV-Scanner complements (not replaces) these tools by:
1. Catching vulnerabilities missed by ecosystem-specific tools
2. Providing cross-ecosystem consistency
3. Aggregating multiple vulnerability databases

## Related Issues

- **Issue #1040**: Integrate OSV-Scanner for broader vulnerability coverage
- **Issue #1030**: Epic - Enhance dependency vulnerability scanning
- **Issue #968**: Add local CI dependency scanning

## References

- [OSV-Scanner Documentation](https://google.github.io/osv-scanner/)
- [OSV Database](https://osv.dev/)
- [Installation Guide](https://google.github.io/osv-scanner/installation/)
