---
description: Analyze folder/file organization, project structure conventions, and architectural consistency (READ-ONLY - query only)
---

# Repo Structure

**🔒 READ-ONLY OPERATION - This skill NEVER modifies files or structure**

Analyze repository structure: directory organization, naming conventions, module boundaries.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/repo-structure
/repo-structure --resolve struct-001
```

## Steps

### 1. Initialize

```bash
./scripts/repo-audit-findings.sh init
```

### 2. Gather Data

```bash
# Pre-processed metrics (fast, reduces token usage by 42%)
DATA=$(./scripts/repo-structure-data.sh)

# Parse key fields
SCORE=$(echo "$DATA" | jq '.score')
STATUS=$(echo "$DATA" | jq -r '.status')
```

For detailed drill-down (if needed):
```bash
# Directory structure
find . -type d -not -path '*/\.*' -not -path '*/node_modules/*' | head -50
```

### 3. Analyze

**Directory conformance:**
- Standard dirs (src/, lib/, tests/, docs/) → +20
- Reasonable depth (< 5 levels) → +20
- No orphaned top-level dirs → +10

**File placement:**
- Config in root or /config
- Source in source directories
- Tests near source or in /tests

**Naming conventions:**
- Consistent case (kebab-case, camelCase, snake_case)
- Consistent patterns across similar files

### 4. Calculate Score

```
Base: 100
- Non-standard top-level dirs: -10 each
- Excessive nesting (> 5): -15
- Mixed naming styles: -10
- Orphan config files: -5 each
- No README: -15
```

Thresholds: Good (80+), Warning (60-79), Needs Work (<60)

### 5. Add Findings

```bash
./scripts/repo-audit-findings.sh add --id "struct-001" --type "structure" --severity "medium" --title "..."
```

## Output Format

```
## Structure Audit

**Score:** {score}/100 ({status})
**Directories:** {n}
**Files:** {n}

---

### Directory Analysis

| Directory | Files | Depth | Status |
|-----------|-------|-------|--------|
| {dir} | {n} | {n} | {status} |

---

### Naming Conventions

| Pattern | Count | Examples |
|---------|-------|----------|
| kebab-case | {n} | {files} |
| camelCase | {n} | {files} |

**Consistency:** {pct}% ({status})

---

### Findings

| ID | Severity | Finding |
|----|----------|---------|
| struct-001 | {severity} | {description} |

---

### Recommendations

1. **{severity}** {action}
```

## Token Optimization

This skill has moderate optimization with room for improvement:

**Current optimizations:**
- ✅ Findings stored in cached file (`.repo-audit/findings.json`)
- ✅ No repeated file system scans (uses cached results)
- ✅ Part of batch audit workflow

**Token usage:**
- Current: ~1,250 tokens (moderate complexity with inline analysis)
- Optimized target: ~725 tokens (with dedicated analysis script)
- Potential savings: **42%**

**Implemented optimizations:**
- ✅ `repo-structure-data.sh` script for pre-processing
- ✅ Folder structure analysis via find/tree + rules in script
- ✅ Convention checking via pattern matching in script

**Measurement:**
- Baseline: 1,250 tokens (current implementation)
- Target: 725 tokens (with analysis script)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy (implemented):**
`./scripts/repo-structure-data.sh` provides:
- `find`/`tree` for folder structure mapping
- Convention rules via pattern matching
- Inconsistency detection with rule-based checks
- Single JSON output with metrics and score
- Claude only formats and prioritizes pre-detected issues

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Part of /repo-audit-complete workflow
- Findings stored in `.repo-audit/findings.json`
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - File modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**User action:** Apply recommended refactoring changes manually
