---
description: Validate framework artifacts (skills, hooks, actions) for compliance with standards
argument-hint: "[--skills] [--hooks] [--actions] [--fix]"
global: true
---

# Validate Framework Artifacts

Enforce that all Claude Code process artifacts — skills, hooks, and actions — conform to expected standards and detect deviations from framework requirements.

**Feature:** #1021 - Add enforcement guardrails for skills, hooks, and actions

## Usage

```
/validate:framework                # Validate all artifacts
/validate:framework --skills       # Validate skills only
/validate:framework --hooks        # Validate hooks only
/validate:framework --actions      # Validate actions/tier registry only
/validate:framework --fix          # Auto-fix simple issues (future enhancement)
```

## What Gets Validated

### Skills (`.claude/commands/*.md`)

- ✓ YAML frontmatter with required fields (`description`)
- ✓ Kebab-case file naming (e.g., `issue-triage.md`)
- ✓ Content after frontmatter
- ✓ Referenced scripts exist and are executable
- ✓ Best practice: `argument-hint` field present

### Hooks (`.claude/hooks/*` and `settings.json`)

- ✓ `settings.json` is valid JSON
- ✓ All registered hooks exist as files
- ✓ All hook files are executable
- ✓ Hooks have proper shebang lines
- ✓ Detection of orphaned hooks (files not registered)

### Actions (`tier-registry.json`)

- ✓ Valid JSON structure
- ✓ All tier assignments are valid (T0, T1, T2, T3)
- ✓ Naming conventions for operations (dot notation)
- ✓ All categories and operations properly defined

## Steps

### 1. Run Validation

```bash
./scripts/validate:framework-artifacts.sh [options]
```

**Options:**
- `--skills` - Validate skills only
- `--hooks` - Validate hooks only
- `--actions` - Validate actions only
- `--json` - Output as JSON
- `--fix` - Auto-fix simple issues (future)

### 2. Review Results

The validation script checks all artifacts and reports:

- **Errors** - Critical issues that must be fixed (e.g., missing frontmatter, non-existent scripts)
- **Warnings** - Best practice violations (e.g., missing argument-hint, orphaned hooks)
- **Summary** - Total checked, errors, warnings, and overall status

### 3. Fix Issues

Based on the validation results, fix any issues:

**Common fixes:**

```bash
# Add missing frontmatter to a skill
cat > .claude/commands/my-skill.md << 'EOF'
---
description: My skill description
argument-hint: "[--option]"
---

# My Skill Content
EOF

# Make a hook executable
chmod +x .claude/hooks/my-hook.sh

# Register an orphaned hook in settings.json
# Edit settings.json to add the hook to the appropriate hook type
```

### 4. Re-validate

After fixing issues, run validation again to ensure all issues are resolved:

```bash
./scripts/validate:framework-artifacts.sh
```

## Output Format

### Text Output (default)

```
Validating Skills...
✓ audit-capabilities
✓ issue-triage
✗ broken-skill
  ERROR: Missing YAML frontmatter
  ERROR: Referenced script does not exist: scripts/broken-data.sh

Validating Hooks...
✓ UserPromptSubmit: dynamic-loader.sh
✓ PreToolUse: block-secrets.py
⚠ Orphaned hook (not registered): old-hook.sh

Validating Actions (Tier Registry)...
✓ All tier assignments valid

═══════════════════════════════════════════════════════════
Framework Artifacts Validation Summary
═══════════════════════════════════════════════════════════
Total Checked:  45
Errors:         2
Warnings:       1
═══════════════════════════════════════════════════════════
✗ Validation failed with 2 errors
═══════════════════════════════════════════════════════════
```

### JSON Output (`--json`)

```json
{
  "skills": [
    {
      "name": "audit-capabilities",
      "path": ".claude/commands/audit-capabilities.md",
      "errors": [],
      "warnings": [],
      "script_references": ["scripts/capability-audit.sh"],
      "status": "passed"
    },
    {
      "name": "broken-skill",
      "path": ".claude/commands/broken-skill.md",
      "errors": [
        "Missing YAML frontmatter",
        "Referenced script does not exist: scripts/broken-data.sh"
      ],
      "warnings": [],
      "script_references": ["scripts/broken-data.sh"],
      "status": "failed"
    }
  ],
  "hooks": [
    {
      "name": "dynamic-loader.sh",
      "type": "UserPromptSubmit",
      "command": ".claude/hooks/dynamic-loader.sh",
      "path": "/workspace/repo/.claude/hooks/dynamic-loader.sh",
      "errors": [],
      "warnings": [],
      "status": "passed"
    }
  ],
  "actions": [
    {
      "category": "github",
      "operation": "issue.create",
      "tier": "T2",
      "errors": [],
      "warnings": [],
      "status": "passed"
    }
  ],
  "summary": {
    "total_checked": 45,
    "total_errors": 2,
    "total_warnings": 1,
    "status": "failed",
    "timestamp": "2026-02-22T12:00:00Z"
  }
}
```

## Integration with CI/CD

Add validation to your local CI pipeline:

```bash
# In scripts/ci/validators/validate:framework.sh
./scripts/validate:framework-artifacts.sh --json > validation-results.json

if [ $? -ne 0 ]; then
  echo "Framework artifact validation failed"
  exit 1
fi
```

## Enforcement via Hook

The validation is automatically enforced via a PreToolUse hook when modifying framework artifacts:

- Triggered on Write/Edit operations for files in `.claude/commands/`, `.claude/hooks/`, `.claude/agents/`
- Triggered on modifications to `settings.json` or `tier-registry.json`
- Blocks the operation if validation fails
- Provides clear error messages about what needs to be fixed

## Common Validation Errors

### Skills

**Missing frontmatter:**
```yaml
---
description: Your skill description here
argument-hint: "[--option]"
---
```

**Referenced script doesn't exist:**
- Create the script at the referenced path
- Make it executable: `chmod +x scripts/my-script.sh`

**Non-kebab-case name:**
- Rename file from `mySkill.md` to `my-skill.md`

### Hooks

**Hook not executable:**
```bash
chmod +x .claude/hooks/my-hook.sh
```

**Missing shebang:**
```bash
#!/bin/bash
# Add to first line of hook file
```

**Orphaned hook:**
- Register in `settings.json` under appropriate hook type, OR
- Delete the file if no longer needed

### Actions

**Invalid tier:**
- Change tier to one of: T0, T1, T2, T3
- Follow tier guidelines (T0=read, T1=safe write, T2=modify, T3=destructive)

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/validate:framework-artifacts.sh` performs all validation
- Validation logic runs server-side in bash, not in Claude
- Returns structured JSON with all findings
- Token savings: ~85%

**Key optimizations:**
- ✅ All validation logic in bash script
- ✅ File parsing with grep/jq/sed (not Claude)
- ✅ Claude receives only structured results
- ✅ Batch processing of all artifacts

## Notes

- **READ-ONLY OPERATION**: This skill queries and validates only
- **Auto-fix**: The `--fix` option is reserved for future enhancements
- **Pre-commit**: Consider adding to pre-commit hooks for automatic validation
- **CI Integration**: Can be integrated into local CI validation pipelines

**Related:**
- Issue #1021 - Enforcement guardrails for skills, hooks, and actions
- `/ops:agents` - Audit skill/agent format compliance
- `/ops:actions` - Review action audit log
- `scripts/capability-audit.sh` - Capability audit script
