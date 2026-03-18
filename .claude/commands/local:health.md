---
description: Quick health check for framework integration issues
argument-hint: "[--fix] [--verbose]"
global: true
---

# Local Health Check

Run a quick health check on your consumer repository's Claude Agent Framework integration.

## Usage

```
/local:health          # Run health check (read-only)
/local:health --fix    # Auto-fix common issues
/local:health --verbose # Show detailed diagnostics
```

## Checks Performed

### 1. Framework Files

Check for:
- `.claude/.manifest.json` exists and is valid JSON
- `.claude/commands/` directory exists
- `.claude/agents/` directory exists
- `.claude/hooks/` directory exists (if applicable)

### 2. Configuration Integrity

Verify:
- `.claude/project-config.json` is valid
- `.claude/settings.json` is valid
- `.claude/tier-registry.json` exists
- Git repository is initialized

### 3. Manifest Consistency

Check:
- All files referenced in manifest exist
- All command files are registered in manifest
- No orphaned files (exist but not in manifest)
- Hash mismatches (file changed but manifest not updated)

### 4. Broken References

Scan for:
- Dead skill references (e.g., `/old-skill-name` in command bodies)
- Missing agent references (Task tool calls to non-existent agents)
- Broken file paths in documentation

### 5. Permission Issues

Verify:
- Hooks are executable (`.claude/hooks/*.sh` have +x)
- Scripts are executable (`scripts/**/*.sh` have +x)
- No permission errors on `.claude/` directory

### 6. Skill Health

Check:
- Total number of skills deployed
- Number of skill categories
- Skill deployment status (100% if all skills synced)
- Legacy alias mappings
- Orphaned skills (not referenced anywhere)

## Auto-Fix (--fix flag)

When run with `--fix`, automatically:

1. **Create missing directories**
   - `.claude/commands/`
   - `.claude/agents/`

2. **Fix executable permissions**
   - `chmod +x .claude/hooks/*.sh`
   - `chmod +x scripts/**/*.sh`

3. **Repair manifest mismatches**
   - Update hashes for modified files
   - Remove orphaned entries

4. **Initialize missing configs**
   - Create default `project-config.json`
   - Create default `settings.json`

## Health Report Format

```
✅ Framework Files: OK
✅ Configuration: OK
⚠️  Manifest Consistency: 3 issues found
   - audit-ui.md: hash mismatch (file modified)
   - old-command.md: orphaned (not in manifest)
   - missing-skill.md: referenced but doesn't exist
✅ References: OK
✅ Permissions: OK

### Skill Health
  Total skills:       63
  Categories:         13
  Deployed:           63/63 (100%)
  Legacy aliases:     43 (mapped)
  Orphaned:           0

  Tip: Run /skill-help to browse all available skills
  Tip: Run /skill-help <category> to filter by category

Overall Health: ⚠️ WARNINGS (3 issues)

Run `/local:health --fix` to auto-repair issues.
```

## Exit Codes

- `0`: All checks passed
- `1`: Warnings found (non-critical)
- `2`: Errors found (critical issues)

## Implementation Steps

When running the health check, perform these checks in order:

### 1. Framework Files Check
- Verify `.claude/.manifest.json` exists and is valid JSON
- Verify `.claude/commands/` directory exists
- Verify `.claude/agents/` directory exists
- Verify `.claude/hooks/` directory exists (if applicable)

### 2. Configuration Integrity Check
- Verify `.claude/project-config.json` is valid JSON
- Verify `.claude/settings.json` is valid JSON
- Verify `.claude/tier-registry.json` exists
- Verify Git repository is initialized

### 3. Manifest Consistency Check
- Compare manifest entries with actual files
- Detect orphaned files (exist but not in manifest)
- Detect missing files (in manifest but don't exist)
- Check hash mismatches (file changed but manifest not updated)

### 4. Broken References Check
- Scan for dead skill references in command bodies
- Check for missing agent references in Task tool calls
- Verify file paths in documentation exist

### 5. Permission Check
- Verify hooks are executable (`.claude/hooks/*.sh` have +x)
- Verify scripts are executable (`scripts/**/*.sh` have +x)
- Check for permission errors on `.claude/` directory

### 6. Skill Health Check

Gather skill statistics and display health summary:

**Data Collection:**

Count skills by reading `core/commands/*.md` files:
```bash
# Count total skills
total_skills=$(find core/commands -name "*.md" -type f | wc -l)

# Count categories (unique prefixes before :)
categories=$(find core/commands -name "*:*.md" -type f |
  sed 's/.*\///' |
  sed 's/:.*//' |
  sort -u |
  wc -l)

# Check deployment status (compare core/commands with .claude/commands)
core_count=$(find core/commands -name "*.md" -type f | wc -l)
deployed_count=$(find .claude/commands -name "*.md" -type f | wc -l)

# Calculate deployment percentage
deployment_pct=$((deployed_count * 100 / core_count))
```

**Display Format:**

```
### Skill Health
  Total skills:       {total_skills}
  Categories:         {categories}
  Deployed:           {deployed_count}/{core_count} ({deployment_pct}%)
  Legacy aliases:     N/A (requires validate-skill-retention.sh)
  Orphaned:           {orphaned_count}

  Tip: Run /skill-help to browse all available skills
  Tip: Run /skill-help <category> to filter by category
```

**Orphaned Skills Detection:**

An orphaned skill is a file in `.claude/commands/` that doesn't exist in `core/commands/`:
```bash
# Find orphaned skills
orphaned=$(comm -13 \
  <(cd core/commands && find . -name "*.md" | sort) \
  <(cd .claude/commands && find . -name "*.md" | sort) | wc -l)
```

**Legacy Alias Count:**

If `scripts/validate/validate-skill-retention.sh` exists and supports `--json` flag:
```bash
# Get alias count from validation script
if [[ -x scripts/validate/validate-skill-retention.sh ]]; then
  alias_count=$(scripts/validate/validate-skill-retention.sh --json 2>/dev/null | jq '.aliases | length' 2>/dev/null || echo "N/A")
else
  alias_count="N/A"
fi
```

If the script doesn't exist or doesn't support `--json`, display "N/A" for legacy aliases.

**Status Indicators:**

| Status | Meaning |
|--------|---------|
| ✅ `{deployed}/{total} (100%)` | All skills deployed |
| ⚠️ `{deployed}/{total} (<100%)` | Some skills not deployed |
| ✅ `Orphaned: 0` | No orphaned skills |
| ⚠️ `Orphaned: N` | N orphaned skills found |

## Notes

- Run this after framework updates
- Safe to run anytime (read-only by default)
- Use `--fix` for automated repairs
- Review changes before committing fixes
- Skill health check added in issue #1094
- Legacy alias count requires `validate-skill-retention.sh --json` support
