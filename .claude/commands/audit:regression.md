---
description: Run regression audit for skills, hooks, and actions (runtime behavioral verification)
argument-hint: "[--skills] [--hooks] [--actions] [--verbose]"
---

# Regression Audit

**Runtime behavioral verification for framework artifacts**

Comprehensive regression testing that validates all skills, hooks, and actions are functioning correctly. Goes beyond static validation (#1021) to include behavioral verification — actually checking that scripts exist, are executable, and can run without errors.

**Feature:** #1024 - Add regression audit for skills, hooks, and actions
**Complements:** `/validate:framework` (static validation)

## Usage

```
/audit:regression                  # Full regression audit
/audit:regression --skills         # Skills only
/audit:regression --hooks          # Hooks only
/audit:regression --actions        # Actions only
/audit:regression --verbose        # Detailed output
```

## What This Audits

### Skills (`.claude/commands/*.md` and `core/commands/*.md`)

Runtime checks for each skill:
- ✓ Valid YAML frontmatter with required fields
- ✓ Referenced backing scripts exist
- ✓ Backing scripts are executable
- ✓ Scripts support `--help` or fail gracefully
- ✓ Primary data scripts can be invoked
- ⚠ Token Optimization section present (best practice)

### Hooks (`.claude/hooks/*` and `settings.json`)

Runtime checks for hooks:
- ✓ `settings.json` is valid, parseable JSON
- ✓ All registered hooks exist as files
- ✓ Hook files are executable
- ✓ Hooks have proper shebang lines
- ✓ Bash/Python syntax validation (no execution)
- ✓ Expected output format verification
- ⚠ Detection of orphaned hooks (files not registered)

### Actions (backing scripts in `scripts/`)

Runtime checks for actions:
- ✓ Action scripts exist and are executable
- ✓ `tier-registry.json` valid (if present)
- ✓ Tier assignments are correct (T0-T3)
- ✓ Critical framework scripts validated
- ✓ Bash syntax validation for all scripts

## Steps

### 1. Run Regression Audit

```bash
./scripts/audit:regression.sh [options]
```

**Options:**
- `--skills` - Test skills only
- `--hooks` - Test hooks only
- `--actions` - Test actions only
- `--json` - Output as JSON for CI integration
- `--verbose` - Show detailed test output

### 2. Review Results

The audit performs behavioral tests on each artifact:

**For Skills:**
- Validates frontmatter structure
- Checks all `./scripts/xxx.sh` references point to existing files
- Verifies scripts are executable (`chmod +x` check)
- Tests if primary backing script responds to `--help` flag
- Reports missing Token Optimization sections

**For Hooks:**
- Parses `settings.json` to extract all registered hooks
- Verifies each hook file exists and is executable
- Validates shebang lines (`#!/bin/bash`, `#!/usr/bin/env python3`)
- Runs syntax validation (bash -n, python -m py_compile)
- Detects orphaned hook files

**For Actions:**
- Counts and validates backing scripts in `scripts/`
- Checks `tier-registry.json` structure and tier values
- Spot-checks critical framework scripts
- Validates bash syntax for key scripts

### 3. Interpret Results

**Output Format (Text):**

```
╔══════════════════════════════════════════════════════════════╗
║         REGRESSION AUDIT - Runtime Verification              ║
╚══════════════════════════════════════════════════════════════╝

Testing Skills...
✓ Skill audit-capabilities: All regression tests passed
✓ Skill issue-triage: All regression tests passed
✗ Skill broken-skill: Referenced scripts not found: ./scripts/missing.sh

Testing Hooks...
✓ settings.json: Valid JSON structure
✓ Hook dynamic-loader.sh (UserPromptSubmit): All regression tests passed
⚠ Orphaned hook file (not registered): old-hook.sh

Testing Actions...
✓ Found 268 executable action scripts
✓ tier-registry.json: Valid structure and tier assignments
✓ Critical script capability-audit.sh: OK

══════════════════════════════════════════════════════════════
Regression Audit Summary
══════════════════════════════════════════════════════════════
Total Tests:    45
Passed:         42
Failed:         1
Warnings:       2
══════════════════════════════════════════════════════════════
✗ Regression audit failed with 1 errors
══════════════════════════════════════════════════════════════
```

**Status Codes:**
- ✓ `passed` - All behavioral tests passed
- ✗ `failed` - Critical issue detected (missing script, syntax error, not executable)
- ⚠ `warning` - Best practice violation (orphaned hook, missing section)

### 4. Fix Issues

Based on audit results, apply fixes:

```bash
# Fix missing backing script
touch scripts/skill-name-data.sh
chmod +x scripts/skill-name-data.sh

# Fix non-executable hook
chmod +x .claude/hooks/my-hook.sh

# Fix orphaned hook - register in settings.json
# Edit .claude/settings.json to add hook to appropriate type

# Fix syntax error in bash script
bash -n scripts/problematic-script.sh  # Debug syntax
```

### 5. Re-run Audit

After fixes, verify all issues resolved:

```bash
./scripts/audit:regression.sh --verbose
```

## Output Format

### JSON Output (`--json`)

For CI integration:

```json
{
  "summary": {
    "total_tests": 45,
    "passed": 42,
    "failed": 1,
    "warnings": 2,
    "status": "failed",
    "timestamp": "2026-02-22T12:00:00Z"
  },
  "results": [
    {
      "type": "skill",
      "name": "audit-capabilities",
      "status": "passed",
      "message": "All tests passed"
    },
    {
      "type": "skill",
      "name": "broken-skill",
      "status": "failed",
      "message": "Referenced scripts not found: ./scripts/missing.sh"
    },
    {
      "type": "hook",
      "name": "dynamic-loader.sh",
      "status": "passed",
      "message": "All tests passed"
    },
    {
      "type": "actions",
      "name": "tier-registry",
      "status": "passed",
      "message": "Valid structure"
    }
  ]
}
```

## Comparison: Static vs Runtime Validation

| Aspect | `/validate:framework` (#1021) | `/audit:regression` (#1024) |
|--------|-------------------------------|----------------------------|
| **Type** | Static validation | Runtime behavioral testing |
| **Focus** | Format compliance | Functional verification |
| **Checks** | YAML, naming, structure | Executability, invocation, syntax |
| **Skills** | Frontmatter format | Scripts exist & executable |
| **Hooks** | Registered in settings.json | Can be invoked without error |
| **Actions** | Naming conventions | Scripts run successfully |
| **When** | Pre-commit, on file changes | After changes, pre-release |
| **Speed** | Very fast (static parsing) | Slower (runtime checks) |

**Use both:**
- Run `/validate:framework` during development (pre-commit)
- Run `/audit:regression` before releases and after major changes

## Integration with CI

Add to local CI validation pipeline:

```bash
# In scripts/ci/validators/regression-audit.sh
./scripts/audit:regression.sh --json > regression-results.json

if [ $? -ne 0 ]; then
  echo "Regression audit failed - review regression-results.json"
  cat regression-results.json | jq '.results[] | select(.status == "failed")'
  exit 1
fi
```

## Use Cases

### Scenario 1: After Framework Update

After updating framework to latest version:

```bash
/audit:regression --verbose
```

Ensures all skills still reference valid backing scripts after framework changes.

### Scenario 2: Before Release

Before promoting to production:

```bash
/audit:regression --json > audit-$(date +%Y%m%d).json
```

Creates audit trail showing all artifacts passed behavioral tests.

### Scenario 3: Debugging Silent Failures

When a skill mysteriously stops working:

```bash
/audit:regression --skills --verbose
```

Identifies if backing script went missing or became non-executable.

### Scenario 4: New Skill Development

After creating a new skill:

```bash
/audit:regression --skills
```

Verifies all script references are correct and executable.

## Token Optimization

This skill is optimized for minimal token usage:

**Data gathering via script:**
- Single call to `./scripts/audit:regression.sh` performs all runtime tests
- Script uses bash for file operations and executability checks
- Syntax validation runs server-side (bash -n, python -m py_compile)
- No actual hook/script execution (safe testing)
- Returns structured JSON with pre-calculated results

**Token savings:**
- Before: ~5,000 tokens (read all files, test manually, check each script)
- After: ~800 tokens (single structured JSON response with test results)
- Savings: **84%**

**Measurement:**
- Baseline: 5,000 tokens (manual file reads + executability checks + script invocations)
- Current: 800 tokens (pre-tested JSON results)
- See `/docs/METRICS_OBSERVABILITY.md` for methodology

**Key optimizations:**
- ✅ All runtime testing done in bash script
- ✅ Syntax validation with bash -n / python -m py_compile (no execution)
- ✅ Executability checks with file operations (not test runs)
- ✅ Claude receives only structured results
- ✅ Batch processing of all artifacts

## Safety & Security

**Safe testing approach:**
- Hooks are NOT executed during audit (only syntax validation)
- Scripts checked for existence and executability, not run
- `--help` flag tested on backing scripts (read-only operation)
- No side effects from regression testing

**Why this is safe:**
- Uses `bash -n` for syntax checking (parse only, no execution)
- Uses `python -m py_compile` for Python validation (compile only)
- File operations only: existence checks, permission checks
- No environment modifications

## Common Issues & Fixes

### Skills

**Issue:** Referenced script not found
```bash
# Fix: Create the missing script
touch scripts/missing-script.sh
chmod +x scripts/missing-script.sh
```

**Issue:** Script not executable
```bash
# Fix: Add execute permission
chmod +x scripts/your-script.sh
```

### Hooks

**Issue:** Hook file not found
```bash
# Fix: Either create the hook or remove from settings.json
# Create:
touch .claude/hooks/missing-hook.sh
chmod +x .claude/hooks/missing-hook.sh

# Or remove from settings.json
```

**Issue:** Syntax error in hook
```bash
# Debug bash hooks
bash -n .claude/hooks/your-hook.sh

# Debug Python hooks
python3 -m py_compile .claude/hooks/your-hook.py
```

**Issue:** Orphaned hook (not registered)
```bash
# Option 1: Register in settings.json
# Edit .claude/settings.json and add hook to appropriate type

# Option 2: Remove if obsolete
rm .claude/hooks/orphaned-hook.sh
```

### Actions

**Issue:** Critical script missing
```bash
# Check if script should exist
ls -la scripts/ | grep <script-name>

# Restore from git if accidentally deleted
git checkout -- scripts/<script-name>.sh
```

**Issue:** Invalid tier in tier-registry.json
```bash
# Fix: Change tier to valid value (T0, T1, T2, T3)
# Edit .claude/tier-registry.json
```

## Notes

- **READ-ONLY OPERATION**: This skill performs runtime verification but doesn't execute hooks/scripts
- **Complements static validation**: Use with `/validate:framework` for comprehensive coverage
- **Safe for CI**: No side effects, predictable exit codes
- **Verbose mode recommended**: Use `--verbose` for debugging specific failures
- **Run regularly**: Before releases, after framework updates, during troubleshooting

## Related

- Issue #1024 - Add regression audit for skills, hooks, and actions (this feature)
- Issue #1021 - Static enforcement guardrails (`/validate:framework`)
- Issue #1020 - Container mode investigation (trigger for this feature)
- Issue #1017 - Skill naming conventions
- `/validate:framework` - Static validation (format, naming, structure)
- `/audit-capabilities` - Format compliance audit
- `/audit-skills` - Token efficiency audit
- `scripts/validate:framework-artifacts.sh` - Static validation script
