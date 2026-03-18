---
description: Audit Claude Code configuration files for deprecated capabilities and misconfigurations
argument-hint: "[--check-deprecated] [--format json|markdown|text]"
---

# Claude Config Audit

Validate Claude Code configuration files (hooks, settings.json, project-config.json, tier-registry.json) against current framework standards, detect deprecated features, obsolete patterns, and misconfigurations.

**Feature:** #990 - Add Claude config audit for deprecated capabilities

## Usage

```
/audit:config                       # Audit all configuration files
/audit:config --check-deprecated    # Include deprecated feature detection
/audit:config --format json         # Output as JSON
/audit:config --report audit.md     # Save report to file
```

## Steps

### 1. Run Configuration Audit

```bash
./scripts/config-audit.sh [options]
```

**Options:**
- `--format json|markdown|text` - Output format (default: text)
- `--check-deprecated` - Check for deprecated features and patterns
- `--report FILE` - Save report to file

**Returns:**
- Validation results for each configuration file
- Security issues (e.g., API keys in config files)
- Deprecated pattern detection
- Migration guidance

### 2. What Gets Audited

**Hooks (`.claude/hooks/`):**
- ✓ Executable permissions
- ✓ Proper shebang
- ✓ JSON input handling from stdin
- ✓ Error handling (set -e)
- ✓ Proper exit codes
- ✓ Deprecated hook formats (CLAUDE_HOOK_V1)
- ✓ Deprecated environment variables

**settings.json:**
- ✓ Valid JSON syntax
- ✓ Hook configuration structure
- ✓ Valid hook event names (PreToolUse, PostToolUse, UserPromptSubmit)
- ✓ Valid tool matchers (Bash, Read, Write, Edit, etc.)
- ✓ Hook command paths exist and are executable
- ✓ Deprecated hook events (PreApprovalHook, PostApprovalHook)
- ✓ Deprecated settings (approvalMode, sessionId)

**project-config.json:**
- ✓ Valid JSON syntax
- ✓ Recommended fields (github_repo, framework_repo)
- ✓ Deprecated fields (claude_version)
- ✓ Security: No API keys in config files

**tier-registry.json:**
- ✓ Valid JSON syntax
- ✓ Schema version compatibility
- ✓ Valid tier values (T0, T1, T2, T3)
- ✓ Deprecated categories or operations

**Deprecated Features:**
- Old actions directory (deprecated in favor of hooks)
- Commands without YAML frontmatter
- Old manifest format
- Deprecated hook event names
- Obsolete configuration patterns

### 3. Interpret Results

**Score Calculation:**
- Base: 100 points
- -20 per error (critical issues)
- -5 per warning (best practice violations)

**Status:**
- `passed` (score ≥ 80, no errors) - Configuration is valid
- `failed` (score < 80 or has errors) - Has validation errors

**Severity Levels:**
- `high` - Breaking changes, immediate action required
- `medium` - Deprecated features, should migrate soon
- `low` - Minor improvements, migrate when convenient

### 4. Apply Fixes

Review recommendations and apply fixes:

**Example: Fix deprecated hook event**

```json
// Before (deprecated)
{
  "hooks": {
    "PreApprovalHook": [...]
  }
}

// After (current)
{
  "hooks": {
    "PreToolUse": [...]
  }
}
```

**Example: Add YAML frontmatter to command**

```markdown
---
description: Brief description of what this command does
argument-hint: "[options]"
---

# Command Title

Command content here...
```

**Example: Migrate actions to hooks**

If you have `.claude/actions/` directory:

1. Review each action file
2. Convert to PreToolUse or PostToolUse hook in settings.json
3. Move action script to `.claude/hooks/`
4. Remove `.claude/actions/` directory

**Example: Fix hook permissions**

```bash
# Make hook executable
chmod +x .claude/hooks/my-hook.sh
```

## Output Format

### Text Output (default)

```
╔══════════════════════════════════════════════════════════════╗
║         CLAUDE CONFIG AUDIT REPORT                           ║
╚══════════════════════════════════════════════════════════════╝

Summary:
  Total Audited:    5
  Passed:           4
  Failed:           1
  Warnings:         3
  Deprecated:       2

━━━ Failed Configurations ━━━
  • settings.json (.claude/settings.json)
    Errors: Deprecated hook event 'PreApprovalHook' found

━━━ Warnings ━━━
  • action-capture.sh:
    - Consider adding 'set -e' for error handling

━━━ Improvement Recommendations ━━━
  • project-config.json:
    - Consider adding 'framework_repo' field for framework updates

━━━ Deprecated Features ━━━
  • .claude/actions/ (directory)
    Reason: Actions directory is deprecated
    Migration: Migrate actions to PreToolUse/PostToolUse hooks
    Severity: high

══════════════════════════════════════════════════════════════
✗ Configuration audit found 1 failed items
══════════════════════════════════════════════════════════════
```

### JSON Output

```json
{
  "summary": {
    "total_audited": 5,
    "passed": 4,
    "failed": 1,
    "warnings": 3,
    "deprecated": 2
  },
  "hooks": [
    {
      "name": "action-capture.sh",
      "path": ".claude/hooks/action-capture.sh",
      "type": "hook",
      "score": 95,
      "status": "passed",
      "errors": [],
      "warnings": ["Consider adding 'set -e' for error handling"],
      "improvements": []
    }
  ],
  "settings": [
    {
      "name": "settings.json",
      "path": ".claude/settings.json",
      "type": "settings",
      "score": 80,
      "status": "failed",
      "errors": ["Deprecated hook event 'PreApprovalHook' found"],
      "warnings": [],
      "improvements": []
    }
  ],
  "deprecated": [
    {
      "location": ".claude/actions/",
      "type": "directory",
      "reason": "Actions directory is deprecated",
      "migration": "Migrate actions to PreToolUse/PostToolUse hooks",
      "severity": "high"
    }
  ],
  "timestamp": "2026-02-21T12:00:00Z"
}
```

### Markdown Output

```markdown
# Claude Config Audit Report

**Generated:** 2026-02-21 12:00:00 UTC

## Summary

| Metric | Count |
|--------|-------|
| Total Audited | 5 |
| Passed | 4 |
| Failed | 1 |
| Warnings | 3 |
| Deprecated | 2 |

## Failed Configurations

### settings.json

**Path:** .claude/settings.json

**Errors:**
- Deprecated hook event 'PreApprovalHook' found

## Deprecated Features

### .claude/actions/

**Type:** directory
**Reason:** Actions directory is deprecated
**Migration:** Migrate actions to PreToolUse/PostToolUse hooks
**Severity:** high
```

## Integration with Framework Updates

Run this audit:

1. **Before framework updates** - Identify issues that need fixing first
2. **After framework updates** - Verify migration was successful
3. **In CI/CD** - Automated config validation
4. **Periodic audits** - Regular health checks

```bash
# In scripts/ci/validate-local.sh or similar
./scripts/config-audit.sh --format json --check-deprecated > config-audit-results.json

# Check exit code
if [ $? -ne 0 ]; then
  echo "Configuration audit failed - review config-audit-results.json"
  exit 1
fi
```

## Common Issues and Migrations

### Issue: Deprecated hook event names

**Problem:** Using old hook event names like `PreApprovalHook`

**Migration:**
```json
// Old format
{
  "hooks": {
    "PreApprovalHook": [...],
    "PostApprovalHook": [...]
  }
}

// New format
{
  "hooks": {
    "PreToolUse": [...],
    "PostToolUse": [...]
  }
}
```

### Issue: Actions directory exists

**Problem:** `.claude/actions/` directory with old action files

**Migration:**
1. Review each action file to understand its purpose
2. Create corresponding hook script in `.claude/hooks/`
3. Add hook configuration to `settings.json`
4. Test the hook works correctly
5. Remove `.claude/actions/` directory

### Issue: Hook not executable

**Problem:** Hook file exists but isn't executable

**Fix:**
```bash
chmod +x .claude/hooks/hook-name.sh
```

### Issue: API keys in config files

**Problem:** Security risk - API keys stored in project-config.json

**Fix:**
1. Remove API keys from config files
2. Add to environment variables or secrets manager
3. Update code to read from environment

```bash
# Use environment variables instead
export ANTHROPIC_API_KEY="your-key-here"
export GITHUB_TOKEN="your-token-here"
```

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/config-audit.sh` performs all validation
- Script uses bash/jq for efficient file parsing
- Validation logic runs server-side, not in Claude
- Returns structured JSON with pre-calculated scores

**Token savings:**
- Before: ~5,000 tokens (read all config files, validate in Claude, detect deprecated patterns)
- After: ~800 tokens (single structured JSON response with validation results)
- Savings: **84%**

**Key optimizations:**
- ✅ All validation logic in bash script
- ✅ JSON parsing with jq (not Claude)
- ✅ Pattern matching with grep/sed
- ✅ Score calculations done server-side
- ✅ Claude receives only structured results
- ✅ Batch processing of all config files

## Notes

- **READ-ONLY OPERATION**: This skill queries and validates only, does not modify files
- Run before and after framework updates to ensure compatibility
- Use `--check-deprecated` to identify features that will be removed in future versions
- Safe to run frequently - has no side effects
- Results can be saved to file for tracking over time
- Exit code 0 = all passed, exit code 1 = has failures

**Related:**
- Issue #990 - Claude config audit for deprecated capabilities
- `/ops:agents` - Audit skills and agents
- `/ops:skills` - Token efficiency audit
- `scripts/capability-audit.sh` - Capability validation
- `.claude/settings.json` - Hook configuration
- `.claude/project-config.json` - Project metadata

## Permissions

```yaml
permissions:
  - operation: file.read
    tier: T0
    reason: Read .claude/ config files for validation
  - operation: shell.info
    tier: T0
    reason: Check file permissions and validate hook executables
```

**Auto-approval:** This skill only reads configuration files and performs validation. All operations are T0 (read-only) and safe to auto-approve.
