---
description: Analyze code patterns, module boundaries, coupling, and identify refactoring opportunities (READ-ONLY - query only)
---

# Repo Code

**🔒 READ-ONLY OPERATION - This skill NEVER modifies code**

Analyze code quality: complexity, coupling, code smells, tech debt markers.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

```
/repo-code
/repo-code --resolve code-001
```

## Steps

### 1. Initialize

```bash
./scripts/repo-audit-findings.sh init
```

### 2. Detect Project Type

```bash
[[ -f "package.json" ]] && echo "Node.js"
[[ -f "requirements.txt" ]] && echo "Python"
[[ -f "Cargo.toml" ]] && echo "Rust"
[[ -f "go.mod" ]] && echo "Go"
```

### 3. Gather Metrics

```bash
# Pre-processed metrics (fast, reduces token usage by 42%)
DATA=$(./scripts/repo-code-data.sh)

# Parse key fields
SCORE=$(echo "$DATA" | jq '.score')
STATUS=$(echo "$DATA" | jq -r '.status')
LARGE_FILES=$(echo "$DATA" | jq -r '.large_files')
```

For detailed drill-down (if needed):
```bash
# File sizes
find . -name "*.ts" -o -name "*.py" | grep -v node_modules | xargs wc -l | sort -rn | head -20
```

### 4. Analyze Quality

**File Size:**
| Lines | Status |
|-------|--------|
| < 100 | Good |
| 100-300 | OK |
| 300-500 | Warning |
| > 500 | Critical |

**Coupling:** Flag if > 10 imports or imported by > 10 files

**Code Smells:**
- `console.log`/`print` statements
- TODO/FIXME markers
- God files (> 500 LOC + > 15 functions)
- Long functions (> 50 lines)

### 5. Calculate Score

```
Base: 100
- Large files (> 500 LOC): -10 each
- God classes: -15 each
- High coupling: -10 each
- Critical TODO/FIXME: -5 each
- Debug statements (> 10): -10
```

Thresholds: Good (80+), Warning (60-79), Needs Work (40-59), Critical (<40)

### 6. Add Findings

```bash
./scripts/repo-audit-findings.sh add --id "code-001" --type "code" --severity "high" --title "..."
```

## Output Format

```
## Code Quality Audit

**Score:** {score}/100 ({status})
**Files analyzed:** {n}
**Findings:** {n} open

---

### Large Files (> 300 LOC)

| File | Lines | Functions | Status |
|------|-------|-----------|--------|
| {file} | {lines} | {count} | {status} |

---

### Tech Debt Markers

| Type | Count | Top Locations |
|------|-------|---------------|
| TODO | {n} | {files} |
| FIXME | {n} | {files} |

---

### Code Smells

| ID | Severity | Finding |
|----|----------|---------|
| code-001 | high | {description} |

---

### Recommendations

1. **{severity}** {action}
```

## Token Optimization

This skill has moderate optimization with room for improvement:

**Current optimizations:**
- ✅ Findings stored in cached file (`.repo-audit/findings.json`)
- ✅ No repeated code analysis (uses cached results)
- ✅ Part of batch audit workflow

**Token usage:**
- Current: ~1,250 tokens (moderate complexity with inline analysis)
- Optimized target: ~725 tokens (with dedicated analysis script)
- Potential savings: **42%**

**Implemented optimizations:**
- ✅ `repo-code-data.sh` script for pre-processing
- ✅ Code pattern detection via grep in script
- ✅ Coupling analysis via import frequency in script

**Measurement:**
- Baseline: 1,250 tokens (current implementation)
- Target: 725 tokens (with analysis script)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy (implemented):**
`./scripts/repo-code-data.sh` provides:
- `grep` for pattern detection
- Coupling metrics via import frequency analysis
- Code smell detection with rule-based checks
- Single JSON output with metrics and score
- Claude only formats and prioritizes pre-detected issues

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Part of /repo-audit-complete workflow
- Findings stored in `.repo-audit/findings.json`
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - Code modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**User action:** Apply recommended refactoring changes manually
