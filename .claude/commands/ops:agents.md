---
description: Audit skills/agents/frameworks for format compliance and quality improvements
---

# Capability Audit

Validate skill and agent definitions against current standards, identify areas needing improvement, and flag obsolete capabilities for deletion.

**Feature:** #377 - Add capability audit system to validate skill/framework improvements

## Usage

```
/audit-capabilities                  # Audit all capabilities
/audit-capabilities --skills-only    # Audit skills only
/audit-capabilities --agents-only    # Audit agents only
/audit-capabilities --obsolete       # Include obsolescence check
```

## Steps

### 1. Run Capability Audit

```bash
./scripts/capability-audit.sh [options]
```

**Options:**
- `--skills` - Audit skills only
- `--agents` - Audit agents only
- `--format json|markdown|text` - Output format (default: text)
- `--check-obsolete` - Check for obsolete capabilities
- `--report FILE` - Save report to file

**Returns:**
- Validation results for each capability
- Format compliance issues
- Improvement recommendations
- Obsolete capability flags

### 2. Review Audit Results

The audit checks for:

**Skills:**
- ✓ YAML frontmatter with required fields (description)
- ✓ Kebab-case file naming (e.g., `issue-triage.md`)
- ✓ Content after frontmatter
- ✓ Key sections (Usage, Steps, Token Optimization)
- ✓ Data script references (best practice)
- ✓ Permissions block (Issue #203)
- ✓ Relative script paths (`./scripts/`)

**Agents:**
- ✓ YAML frontmatter with required fields (name, description, model)
- ✓ Kebab-case file naming
- ✓ Name field matches filename
- ✓ Model field is valid (sonnet, opus, haiku)
- ✓ System prompt content
- ✓ Key sections (ROLE, OBJECTIVES, BOUNDARIES)

**Obsolescence:**
- Capabilities marked as deprecated/obsolete
- No references and no companion scripts
- Unused capabilities

### 3. Interpret Results

**Score Calculation:**
- Base: 100 points
- -20 per error (format violations)
- -5 per warning (missing best practices)

**Status:**
- `passed` (score ≥ 80) - Compliant, no errors
- `failed` (score < 80) - Has validation errors

### 4. Apply Improvements

Review recommendations and apply fixes:

```bash
# Example: Add missing Token Optimization section
# Edit skill file to add:
## Token Optimization

This skill is optimized for minimal token usage:
- Data gathered via script: ./scripts/skill-name-data.sh
- Structured JSON output reduces parsing overhead
- Token savings: ~X%
```

```bash
# Example: Create companion data script
cat > scripts/skill-name-data.sh << 'EOF'
#!/bin/bash
# Data gathering for skill-name
set -e

# Gather data
data=$(gh api ...)

# Output structured JSON
echo "$data" | jq '...'
EOF

chmod +x scripts/skill-name-data.sh
```

## Output Format

### Text Output (default)

```
╔══════════════════════════════════════════════════════════════╗
║         CAPABILITY AUDIT REPORT                              ║
╚══════════════════════════════════════════════════════════════╝

Summary:
  Total Audited:    45
  Passed:           38
  Failed:           3
  Warnings:         12
  Obsolete:         2

━━━ Failed Capabilities ━━━
  • skill-name (core/commands/skill-name.md)
    Errors: Missing YAML frontmatter, Missing 'description' field

━━━ Warnings ━━━
  • another-skill:
    - Missing '## Token Optimization' section
    - Use relative paths for scripts: ./scripts/

━━━ Improvement Recommendations ━━━
  • skill-name:
    - Add permissions block for auto-approval (Issue #203)
    - Consider creating data script: scripts/skill-name-data.sh
    - Add '## Token Optimization' section documenting efficiency

━━━ Obsolete Capabilities (Consider Deletion) ━━━
  • old-skill (skill)
    Reason: Marked as obsolete/deprecated in file
    References: 0

══════════════════════════════════════════════════════════════
✓ All capability audits passed
══════════════════════════════════════════════════════════════
```

### JSON Output

```json
{
  "summary": {
    "total_audited": 45,
    "passed": 38,
    "failed": 3,
    "warnings": 12,
    "obsolete": 2
  },
  "skills": [
    {
      "name": "skill-name",
      "path": "core/commands/skill-name.md",
      "type": "skill",
      "score": 60,
      "status": "failed",
      "errors": ["Missing YAML frontmatter"],
      "warnings": [],
      "improvements": ["Add Token Optimization section"]
    }
  ],
  "agents": [...],
  "obsolete": [
    {
      "name": "old-skill",
      "path": "core/commands/old-skill.md",
      "type": "skill",
      "reason": "Marked as obsolete/deprecated in file",
      "reference_count": 0,
      "has_script": false
    }
  ],
  "timestamp": "2024-01-15T12:00:00Z"
}
```

### Markdown Output

```markdown
# Capability Audit Report

**Generated:** 2024-01-15 12:00:00 UTC

## Summary

| Metric | Count |
|--------|-------|
| Total Audited | 45 |
| Passed | 38 |
| Failed | 3 |
| Warnings | 12 |
| Obsolete | 2 |

## Failed Capabilities

### skill-name

**Path:** core/commands/skill-name.md

**Errors:**
- Missing YAML frontmatter
- Missing 'description' field

## Improvement Recommendations

### another-skill

- Add permissions block for auto-approval (Issue #203)
- Consider creating data script: scripts/another-skill-data.sh

## Obsolete Capabilities

### old-skill (skill)

**Path:** core/commands/old-skill.md
**Reason:** Marked as obsolete/deprecated in file
**References:** 0
```

## Integration with PR Validation

The audit can run as part of local CI validation:

```bash
# In scripts/ci/validate-local.sh or similar
./scripts/capability-audit.sh --format json > audit-results.json

# Check exit code
if [ $? -ne 0 ]; then
  echo "Capability audit failed - review audit-results.json"
  exit 1
fi
```

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/capability-audit.sh` performs all validation
- Script uses bash/jq for efficient file parsing
- Validation logic runs server-side, not in Claude
- Returns structured JSON with pre-calculated scores

**Token savings:**
- Before: ~3,000 tokens (read all files, validate in Claude, calculate scores)
- After: ~600 tokens (single structured JSON response with validation results)
- Savings: **80%**

**Key optimizations:**
- ✅ All validation logic in bash script
- ✅ Pattern matching with grep/sed (not Claude parsing)
- ✅ Score calculations done server-side
- ✅ Claude receives only structured results
- ✅ Batch processing of all capabilities

## Notes

- **READ-ONLY OPERATION**: This skill queries and validates only
- Run regularly to ensure capability quality
- Use `--check-obsolete` to identify unused capabilities
- Apply improvements manually or via dedicated issues
- **NO GitHub Actions**: This is a LOCAL CI script per #377 requirements

**Related:**
- Issue #377 - Capability audit system
- Issue #292 - Parent feature
- Issue #203 - Skill permissions block
- `/audit-skills` - Token efficiency audit
- `scripts/validate/validate-agents.sh` - Agent validation
