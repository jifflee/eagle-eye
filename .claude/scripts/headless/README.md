# Headless Mode Scripts

This directory contains scripts optimized for headless (non-interactive) Claude execution. These scripts are designed to run routine maintenance tasks and generate structured reports that can be consumed by Claude in headless mode without requiring a full interactive session.

## Overview

Headless mode allows you to run Claude tasks non-interactively, ideal for:
- Automated documentation checks
- Periodic backlog analysis
- Routine maintenance tasks
- CI/CD integration
- Scheduled audits

## Available Scripts

### 1. `doc-consistency.sh`

Scans all markdown files for consistency issues and stale references.

**What it checks:**
- Stale port number references (e.g., ports in docs but not in config)
- Broken internal links (references to non-existent files)
- Outdated version numbers
- Potentially stale hostname/VM references
- Common documentation inconsistencies

**Usage:**

```bash
# Basic usage (JSON output)
./scripts/headless/doc-consistency.sh

# Markdown format
./scripts/headless/doc-consistency.sh --format markdown

# Custom output file
./scripts/headless/doc-consistency.sh --output-file /tmp/doc-report.json

# Only show high/critical issues
./scripts/headless/doc-consistency.sh --severity-threshold high

# Verbose mode
./scripts/headless/doc-consistency.sh --verbose
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--output-file FILE` | Path to write JSON report | `doc-consistency-report.json` |
| `--format FORMAT` | Output format: `json` or `markdown` | `json` |
| `--severity-threshold LVL` | Minimum severity: `critical`, `high`, `medium`, `low` | `medium` |
| `--verbose` | Verbose output | `false` |
| `--help` | Show help message | - |

**Exit Codes:**

- `0` - No critical/high issues found
- `1` - Critical or high issues found
- `2` - Fatal error

### 2. `backlog-triage.sh`

Analyzes the issue backlog and generates prioritized recommendations.

**What it analyzes:**
- Priority distribution (P0-P3)
- Type breakdown (bugs, features, tech debt, etc.)
- Stale issues (not updated in N days)
- Issues missing labels (needs triage)
- Blocked issues
- Top priority issues by score

**Usage:**

```bash
# Analyze active milestone
./scripts/headless/backlog-triage.sh

# Specific milestone
./scripts/headless/backlog-triage.sh --milestone "sprint-0226-1"

# Markdown format
./scripts/headless/backlog-triage.sh --format markdown

# Custom stale threshold (default: 30 days)
./scripts/headless/backlog-triage.sh --stale-days 45

# Include closed issues
./scripts/headless/backlog-triage.sh --include-closed

# Verbose mode
./scripts/headless/backlog-triage.sh --verbose
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--milestone NAME` | Specific milestone to analyze | Active milestone |
| `--output-file FILE` | Path to write JSON report | `backlog-triage-report.json` |
| `--format FORMAT` | Output format: `json` or `markdown` | `json` |
| `--stale-days N` | Consider issues stale after N days | `30` |
| `--include-closed` | Include closed issues | `false` |
| `--verbose` | Verbose output | `false` |
| `--help` | Show help message | - |

**Exit Codes:**

- `0` - No issues requiring attention
- `1` - Issues found requiring attention
- `2` - Fatal error

## Headless Mode Usage

### Method 1: Direct Execution with Pipe

Generate a report and send it to Claude headless mode:

```bash
./scripts/headless/doc-consistency.sh --format markdown | claude -p -
```

### Method 2: Generate Report, Then Process

Generate a report first, then have Claude analyze it:

```bash
# Generate report
./scripts/headless/backlog-triage.sh --output-file /tmp/triage.json

# Process with Claude
claude -p "Review the backlog triage report at /tmp/triage.json and provide recommendations"
```

### Method 3: Scheduled Execution

Add to cron for periodic checks:

```bash
# Check docs daily at 9am
0 9 * * * /path/to/scripts/headless/doc-consistency.sh --output-file /var/log/doc-check.json

# Triage backlog weekly on Monday
0 9 * * 1 /path/to/scripts/headless/backlog-triage.sh --output-file /var/log/backlog-triage.json
```

### Method 4: CI/CD Integration

Use in GitHub Actions or other CI systems:

```yaml
- name: Run doc consistency check
  run: |
    ./scripts/headless/doc-consistency.sh --format json
  continue-on-error: true

- name: Upload report
  uses: actions/upload-artifact@v3
  with:
    name: doc-consistency-report
    path: doc-consistency-report.json
```

## Output Formats

### JSON Format

Structured data suitable for programmatic consumption:

```json
{
  "scan_type": "documentation_consistency",
  "timestamp": "2026-02-22T10:30:00Z",
  "severity_threshold": "medium",
  "summary": {
    "total_findings": 5,
    "by_severity": {
      "critical": 0,
      "high": 2,
      "medium": 3,
      "low": 0
    }
  },
  "findings": [
    {
      "id": "DC-1",
      "type": "broken_link",
      "severity": "high",
      "file": "./docs/README.md",
      "line": 42,
      "description": "Broken internal link: ../missing.md",
      "suggestion": "Update link to correct path or remove if obsolete"
    }
  ]
}
```

### Markdown Format

Human-readable format suitable for Claude headless consumption:

```markdown
# Documentation Consistency Report

**Generated:** 2026-02-22 10:30:00
**Severity Threshold:** medium

## Summary

- **Total Findings:** 5
- **Critical:** 0
- **High:** 2
- **Medium:** 3
- **Low:** 0

## Findings

### [HIGH] broken_link

**File:** `./docs/README.md:42`

**Description:** Broken internal link: ../missing.md

**Suggestion:** Update link to correct path or remove if obsolete
```

## Integration Examples

### Example 1: Automated Documentation Maintenance

```bash
#!/bin/bash
# weekly-doc-maintenance.sh

# Run consistency check
./scripts/headless/doc-consistency.sh --format markdown > /tmp/doc-report.md

# If issues found, send to Claude for review
if [ $? -eq 1 ]; then
  claude -p - <<EOF
Please review this documentation consistency report and suggest fixes:

$(cat /tmp/doc-report.md)

For each issue, provide:
1. Root cause analysis
2. Recommended fix
3. Prevention strategy
EOF
fi
```

### Example 2: Sprint Planning Assistant

```bash
#!/bin/bash
# sprint-planning-assistant.sh

# Generate backlog triage
./scripts/headless/backlog-triage.sh --format markdown > /tmp/triage.md

# Get recommendations from Claude
claude -p - <<EOF
Based on this backlog triage report, please:

1. Identify the top 5 issues to prioritize this sprint
2. Flag any issues that should be de-prioritized
3. Suggest which stale issues should be closed

$(cat /tmp/triage.md)
EOF
```

### Example 3: Daily Health Check

```bash
#!/bin/bash
# daily-health-check.sh

echo "## Daily Repository Health Check - $(date)" > /tmp/health.md
echo "" >> /tmp/health.md

# Documentation consistency
echo "### Documentation Consistency" >> /tmp/health.md
./scripts/headless/doc-consistency.sh --format markdown >> /tmp/health.md

echo "" >> /tmp/health.md

# Backlog health
echo "### Backlog Health" >> /tmp/health.md
./scripts/headless/backlog-triage.sh --format markdown >> /tmp/health.md

# Send to Claude for summary
claude -p "Summarize this daily health check and highlight any critical issues: $(cat /tmp/health.md)"
```

## Best Practices

1. **Use JSON for automation**: JSON output is easier to parse programmatically
2. **Use Markdown for Claude**: Markdown output is optimized for headless Claude consumption
3. **Set appropriate thresholds**: Adjust severity and staleness thresholds based on your needs
4. **Schedule regular runs**: Use cron or CI/CD to run these checks periodically
5. **Archive reports**: Keep historical reports to track trends over time
6. **Combine with alerts**: Integrate with alerting systems for critical findings

## Troubleshooting

### "GitHub CLI not authenticated"

Run `gh auth login` to authenticate the GitHub CLI.

### "Required command not found"

Install missing dependencies:

```bash
# macOS
brew install jq gh

# Ubuntu/Debian
apt-get install jq gh
```

### Script exits with code 2

Check verbose output for specific error:

```bash
./scripts/headless/doc-consistency.sh --verbose
```

### Empty reports

- **doc-consistency.sh**: Ensure there are `.md` files in the repository
- **backlog-triage.sh**: Ensure there are open issues in GitHub

## Contributing

When adding new headless scripts:

1. Follow the existing script structure
2. Use the `common.sh` library for utilities
3. Support both JSON and Markdown output formats
4. Include comprehensive help text
5. Use appropriate exit codes
6. Add documentation to this README
7. Test with both direct execution and headless mode

## See Also

- [Containerized Workflow Guide](../../docs/CONTAINERIZED_WORKFLOW.md)
- [Scripts Directory](../README.md)
- [Claude CLI Documentation](https://docs.anthropic.com/claude/docs)
