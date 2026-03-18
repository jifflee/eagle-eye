---
description: Scan codebase for refactoring opportunities and delegate fixes to owning agents via PM (READ-ONLY observer with delegation)
argument-hint: "[--audit] [--code [PATH]] [--docs] [--deps] [--tests] [--arch] [--framework] [--lint] [--fix] [--dry-run] [--scope changed] [--severity high|medium|low]"
---

# Refactor

**🔒 READ-ONLY OPERATION - This skill NEVER modifies code, docs, or config directly**

Scan codebase for refactoring opportunities and delegate findings to owning agents via PM orchestrator.

**CRITICAL SAFEGUARD:**
- This skill ONLY observes, analyzes, and produces findings
- All fixes are delegated to owning agents via PM orchestrator
- NEVER directly edit, write, or delete files as part of scanning
- DO NOT use the Skill tool to execute write operations during scan phases
- `--fix` mode creates a fix plan and hands off to PM — it does NOT fix directly

## Usage

```
/refactor                    # Interactive menu (pick dimension + scope)
/refactor --audit            # Full read-only report (all dimensions)
/refactor --code [PATH]      # Code quality scan
/refactor --docs             # Documentation scan
/refactor --deps             # Dependency scan
/refactor --tests            # Test scan
/refactor --arch             # Architecture scan
/refactor --framework        # Framework-specific scan
/refactor --lint             # CI-friendly output (exit code 0/1, JSON)
/refactor --fix              # Delegate findings to owning agents (via PM)
/refactor --dry-run          # Preview what --fix would delegate
/refactor --scope changed    # Only scan files changed since last commit/PR
/refactor --severity high    # Filter findings by minimum severity
```

## Steps

### 0. Parse Arguments

Parse the command arguments to determine mode and options:

```bash
# Determine invocation mode
MODE="interactive"           # Default: show menu
DIMENSIONS=()
SCOPE="full"                 # or "changed"
SEVERITY_FILTER=""           # "" = all severities
FIX_MODE=false
DRY_RUN=false
LINT_MODE=false
CODE_PATH=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --audit)     MODE="audit"; DIMENSIONS=(code docs deps tests arch framework) ;;
    --code*)     MODE="scan"; DIMENSIONS+=(code); CODE_PATH="${arg#--code}" ;;
    --docs)      MODE="scan"; DIMENSIONS+=(docs) ;;
    --deps)      MODE="scan"; DIMENSIONS+=(deps) ;;
    --tests)     MODE="scan"; DIMENSIONS+=(tests) ;;
    --arch)      MODE="scan"; DIMENSIONS+=(arch) ;;
    --framework) MODE="scan"; DIMENSIONS+=(framework) ;;
    --lint)      MODE="lint"; LINT_MODE=true; DIMENSIONS=(code docs deps tests arch framework) ;;
    --fix)       FIX_MODE=true ;;
    --dry-run)   DRY_RUN=true ;;
    --scope)     ;; # handled by next arg
    changed)     SCOPE="changed" ;;
    --severity)  ;; # handled by next arg
    high|medium|low) SEVERITY_FILTER="$arg" ;;
  esac
done
```

### 1. Interactive Menu (no flags)

If no scan dimension flags are provided, show an interactive selection menu:

```
## Refactor Scanner

Select dimension(s) to scan:

  [1] --code      Code quality (modularize, dedup, dead-code, naming)
  [2] --docs      Documentation (coverage, accuracy, freshness)
  [3] --deps      Dependencies (outdated, unused, security)
  [4] --tests     Test coverage (missing tests, flaky patterns)
  [5] --arch      Architecture (coupling, layering, contracts)
  [6] --framework Framework-specific patterns
  [7] --audit     All dimensions (full report)

  Scope options:
  [s] --scope changed    Only scan files changed since last commit
  [a] --scope all        Scan entire repo (default)

  Filter options:
  [h] --severity high    High/critical findings only
  [m] --severity medium  Medium+ findings (medium, high, critical)
  [l] --severity low     All findings (low, medium, high, critical)

Enter selection (e.g. "1 3" or "7"):
```

After selection, proceed to Step 2 with the chosen dimensions and scope.

### 2. Run Scanner(s)

Run the appropriate scanner script(s) for each selected dimension.

**Scope detection:**

```bash
# Determine scope flags for scanners
SCOPE_FLAGS=""
if [[ "$SCOPE" == "changed" ]]; then
  SCOPE_FLAGS="--changed-files-only"
fi

# Determine path flags
PATH_FLAGS=""
if [[ -n "$CODE_PATH" ]]; then
  PATH_FLAGS="--paths $CODE_PATH"
fi
```

**Scanner dispatch:**

| Dimension | Script | Output File |
|-----------|--------|-------------|
| `code` | `./scripts/scan-code-quality.sh` | `.refactor/findings-code.json` |
| `docs` | `./scripts/scan-docs.sh` | `.refactor/findings-docs.json` |
| `deps` | `./scripts/dep-scan.sh` | `.refactor/findings-deps.json` |
| `tests` | `./scripts/test-scan.sh` | `.refactor/findings-tests.json` |
| `arch` | `./scripts/arch-scan.sh` | `.refactor/findings-arch.json` |
| `framework` | `./scripts/framework-scan.sh` | `.refactor/findings-framework.json` |

**Run each selected scanner:**

```bash
mkdir -p .refactor

for dimension in "${DIMENSIONS[@]}"; do
  case "$dimension" in
    code)      ./scripts/scan-code-quality.sh $SCOPE_FLAGS $PATH_FLAGS \
                 --output-file .refactor/findings-code.json ;;
    docs)      ./scripts/scan-docs.sh $SCOPE_FLAGS \
                 --output-file .refactor/findings-docs.json ;;
    deps)      ./scripts/dep-scan.sh \
                 --output-file .refactor/findings-deps.json ;;
    tests)     ./scripts/test-scan.sh $SCOPE_FLAGS \
                 --output-file .refactor/findings-tests.json ;;
    arch)      ./scripts/arch-scan.sh $SCOPE_FLAGS \
                 --output-file .refactor/findings-arch.json ;;
    framework) ./scripts/framework-scan.sh $SCOPE_FLAGS \
                 --output-file .refactor/findings-framework.json ;;
  esac
done
```

**Merge findings:**

```bash
# Merge all dimension findings into a single findings file
FINDING_FILES=""
for dimension in "${DIMENSIONS[@]}"; do
  f=".refactor/findings-${dimension}.json"
  [[ -f "$f" ]] && FINDING_FILES="$FINDING_FILES $f"
done

# Merge with jq (combine all arrays)
jq -s 'add // []' $FINDING_FILES > .refactor/findings.json
```

### 3. Apply Severity Filter

If `--severity` is set, filter findings before reporting:

```bash
case "$SEVERITY_FILTER" in
  high)
    FILTERED=$(jq '[.[] | select(.severity == "critical" or .severity == "high")]' \
      .refactor/findings.json)
    ;;
  medium)
    FILTERED=$(jq '[.[] | select(.severity == "critical" or .severity == "high" or .severity == "medium")]' \
      .refactor/findings.json)
    ;;
  low|"")
    FILTERED=$(jq '.' .refactor/findings.json)
    ;;
esac

echo "$FILTERED" > .refactor/findings-filtered.json
```

### 4. Lint Mode (`--lint`)

If `--lint` flag is set, output JSON and exit with CI-friendly exit code.

This is the only step that runs in lint mode — skip Steps 5-6.

```bash
if [[ "$LINT_MODE" == "true" ]]; then
  FINDINGS=$(cat .refactor/findings-filtered.json)
  TOTAL=$(echo "$FINDINGS" | jq 'length')
  CRITICAL=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "critical")] | length')
  HIGH=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "high")] | length')

  # Output JSON to stdout
  echo "$FINDINGS" | jq '{
    total: '"$TOTAL"',
    critical: '"$CRITICAL"',
    high: '"$HIGH"',
    findings: .
  }'

  # Exit code: 0 = clean, 1 = findings, 2 = critical findings
  if [[ "$CRITICAL" -gt 0 ]]; then
    exit 2
  elif [[ "$TOTAL" -gt 0 ]]; then
    exit 1
  else
    exit 0
  fi
fi
```

### 5. Display Findings Report

Display a human-readable markdown summary of all findings.

**Summary header:**

```
## Refactor Scan Results

**Dimensions scanned:** {dimension_list}
**Scope:** {full | changed files only}
**Total findings:** {count}

| Severity | Count |
|----------|-------|
| Critical | {n} |
| High     | {n} |
| Medium   | {n} |
| Low      | {n} |
```

**Findings by dimension:**

```
---

### Code Quality Findings ({n})

| ID | Severity | Category | Description | File |
|----|----------|----------|-------------|------|
| RF-001 | medium | modularize | File exceeds 300 lines | scripts/foo.sh |
| RF-002 | low | naming | Mixed naming conventions | src/bar.py |

---

### Architecture Findings ({n})

| ID | Severity | Category | Description | File |
|----|----------|----------|-------------|------|
| RF-010 | high | coupling | High coupling detected | src/api.ts |
```

**If no findings:**

```
✅ No refactoring opportunities found.

Scanned {n} files across {dimension_list}. Codebase looks clean!
```

**Save findings to file:**

```bash
# Findings always saved to .refactor/findings.json (already done in Step 2)
echo "Findings saved to .refactor/findings.json"
```

### 6. Fix Mode (`--fix` or `--dry-run`)

**Load findings:**

```bash
if [[ ! -f ".refactor/findings.json" ]]; then
  echo "No findings file found. Run a scan first."
  echo "  Example: /refactor --audit"
  exit 1
fi

FINDINGS=$(cat .refactor/findings.json)
OPEN_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.status == "open")] | length')

if [[ "$OPEN_COUNT" -eq 0 ]]; then
  echo "No open findings to fix. Codebase is clean!"
  exit 0
fi
```

**Run iteration protocol (dry-run or live):**

```bash
if [[ "$DRY_RUN" == "true" ]]; then
  ./scripts/refactor-iterate.sh \
    --findings-file .refactor/findings.json \
    --dry-run
else
  ./scripts/refactor-iterate.sh \
    --findings-file .refactor/findings.json \
    --max-iterations 3
fi
```

**Delegate to PM orchestrator:**

After `refactor-iterate.sh` outputs the fix plan (`.refactor/fix-plan.json`), read it and delegate to PM:

```bash
FIX_PLAN=$(cat .refactor/fix-plan.json)
AGENT_GROUPS=$(echo "$FIX_PLAN" | jq '.groups')
GROUP_COUNT=$(echo "$AGENT_GROUPS" | jq 'length')
```

If `--dry-run`, display the plan without delegating:

```
## Dry Run: Fix Plan

**Open findings:** {open_count}
**Agent groups:** {group_count}
**Execution order:** {batch_count} batch(es)

### Batch 1 (parallel-safe)

**refactoring-specialist** — {n} findings
Files: {file_list}

Findings:
- RF-001 (medium): modularize — scripts/foo.sh
- RF-003 (low): naming — src/bar.py

### Batch 2 (sequential)

**backend-developer** — {n} findings
Files: {file_list}

Findings:
- RF-010 (high): coupling — src/api.ts

---
No changes made (--dry-run)
```

If `--fix` (live mode), delegate to PM orchestrator via Task tool:

Use the `pm-orchestrator` agent with the fix plan:

```
Prompt to PM orchestrator:

"You are orchestrating refactoring fixes.

Fix Plan:
{fix_plan_json}

For each agent group in the execution_order, dispatch the appropriate agent
with the following context:

- Findings: the specific findings assigned to that agent
- Owning files: the files containing the findings
- Acceptance criteria: from each finding's acceptance_criteria field
- Constraint: The refactor-skill is READ-ONLY. You (PM) must dispatch the
  work to the listed owning agents. Do NOT modify files yourself.

After each agent completes, verify fixes against acceptance criteria.
Re-scan changed files using: ./scripts/refactor-iterate.sh --verify-only

Maximum iterations: 3 (enforced by refactor-iterate.sh)"
```

**Post-fix verification:**

```bash
# After PM completes delegation, re-scan changed files
./scripts/refactor-iterate.sh \
  --findings-file .refactor/findings.json \
  --iteration 2  # Continue from where iteration left off
```

**Fix summary:**

```
## Fix Session Complete

**Findings fixed:** {fixed_count}/{total_count}
**Iterations:** {n}/3
**Agents invoked:** {agent_list}

### Outcomes

| Agent | Fixed | Deferred | Rejected |
|-------|-------|----------|---------|
| refactoring-specialist | 2 | 0 | 0 |
| backend-developer | 1 | 1 | 0 |

### Remaining Findings

{if remaining > 0}
{n} finding(s) not resolved after {max_iter} iterations.
These have been converted to GitHub issues for backlog tracking.
{/if}

### Next Steps

1. Review fixes: `git log --oneline -n {commit_count}`
2. Re-scan to verify: `/refactor --audit`
3. Check open issues: `gh issue list --label "refactor"`
```

## Output Format

### Scan Mode (default)

```
## Refactor Scan Results

**Dimensions:** code, arch
**Scope:** full repository
**Total findings:** 5 (0 critical, 1 high, 3 medium, 1 low)

---

### Code Quality (3 findings)

| ID | Severity | Category | File | Description |
|----|----------|----------|------|-------------|
| RF-001 | medium | modularize | scripts/large.sh | File exceeds 300 lines (420 total) |
| RF-002 | medium | dedup | src/util.py, src/helpers.py | 85% code similarity detected |
| RF-003 | low | naming | src/api.py | Mixed naming conventions |

---

### Architecture (2 findings)

| ID | Severity | Category | File | Description |
|----|----------|----------|------|-------------|
| RF-010 | high | coupling | src/core.ts | High coupling: 18 imports |
| RF-011 | medium | layering | src/ui/data.ts | Presentation layer accessing database directly |

---

**Findings saved to:** `.refactor/findings.json`

Run `/refactor --fix` to delegate fixes to owning agents.
Run `/refactor --lint` for CI-friendly JSON output.
```

### Audit Mode (`--audit`)

Same as scan mode but always runs all 6 dimensions.

### Lint Mode (`--lint`)

```json
{
  "total": 5,
  "critical": 0,
  "high": 1,
  "findings": [
    {
      "id": "RF-001",
      "dimension": "code",
      "category": "modularize",
      "severity": "medium",
      "owning_agent": "backend-developer",
      "file_paths": ["scripts/large.sh"],
      "description": "File exceeds 300 lines (420 total).",
      "status": "open"
    }
  ]
}
```

Exit codes: `0` = clean, `1` = findings present, `2` = critical findings

### Dry Run Mode (`--dry-run`)

Shows what `--fix` would delegate without making changes.

## Findings Schema

Findings conform to `refactor-finding.schema.json` (issue #800):

```json
{
  "id": "RF-001",
  "dimension": "code",
  "category": "modularize",
  "severity": "critical|high|medium|low",
  "owning_agent": "backend-developer",
  "fallback_agent": "refactoring-specialist",
  "file_paths": ["path/to/file.sh:10-50"],
  "description": "Human-readable finding description",
  "suggested_fix": "Suggested remediation",
  "acceptance_criteria": ["criterion 1", "criterion 2"],
  "status": "open|in-progress|completed|deferred|rejected",
  "metadata": {
    "created_at": "ISO8601",
    "scanner_version": "1.0.0"
  }
}
```

## Scanner Scripts Reference

| Script | Dimensions Covered | Doc |
|--------|--------------------|-----|
| `scripts/scan-code-quality.sh` | code: modularize, dedup, dead-code, naming | Issue #802 |
| `scripts/arch-scan.sh` | arch: coupling, layering, contracts | Issue #803 |
| `scripts/scan-docs.sh` | docs: coverage, accuracy, freshness | Issue #804 |
| `scripts/dep-scan.sh` | deps: outdated, unused, security | Issue #805 |
| `scripts/test-scan.sh` | tests: coverage, flaky, missing | Issue #805 |
| `scripts/framework-scan.sh` | framework: patterns, conventions | Issue #806 |

All scanners are READ-ONLY. They produce JSON findings conforming to the findings schema.

## Iteration Protocol

`--fix` mode uses `./scripts/refactor-iterate.sh` (issue #801):

1. **SCAN** — Read findings from `.refactor/findings.json`
2. **PLAN** — Group by owning agent, detect file overlaps, sequence execution
3. **FIX** — Dispatch agents via PM orchestrator (parallel-safe groups first)
4. **VERIFY** — Re-scan changed files only (scope: changed)
5. **REPORT** — Summary of fixed, deferred, rejected findings
6. Repeat up to **3 iterations** max
7. Remaining findings → converted to GitHub issues

## Token Optimization

This skill uses data scripts for efficient token usage:

**Data gathering via scanner scripts:**
- Each scanner outputs pre-structured JSON (no Claude reasoning needed)
- Severity and ownership pre-computed in scripts
- Findings merged via `jq` — no Claude parsing
- Fix plan generated by `refactor-iterate.sh` — no Claude planning

**Token usage:**
- Scan mode: ~600 tokens (scripts handle analysis, Claude only formats report)
- Fix mode: ~800 tokens (plan from script, Claude only dispatches PM)
- Lint mode: ~200 tokens (JSON passthrough with exit code)

**Key optimizations:**
- ✅ All scanning done in bash/Python scripts (not in Claude context)
- ✅ Findings pre-structured as JSON
- ✅ Fix plan pre-computed by `refactor-iterate.sh`
- ✅ Claude only reads pre-processed results and delegates

## Notes

- **READ-ONLY OPERATION**: This skill observes and delegates. NEVER modifies files.
- Findings saved to `.refactor/findings.json` (gitignored by convention)
- `--fix` delegates to PM orchestrator, which dispatches to owning agents
- Maximum 3 fix iterations per session (configurable via `refactor-iterate.sh`)
- Remaining findings after max iterations → GitHub issues in backlog
- `--lint` is designed for `scripts/ci/refactor-lint.sh` integration
- `--scope changed` uses `git diff` to limit scan to recently changed files
- **NEVER automatically invoke**:
  - File edit/write operations from within this skill
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**Owning agents by file type:**
- `.py`, `.sh` → `backend-developer`
- `.ts`, `.tsx`, `.js` (frontend paths) → `frontend-developer`
- `.ts`, `.tsx`, `.js` (backend paths) → `backend-developer`
- `.md`, docs → `documentation`
- Architecture concerns → `architect`
- Fallback → `refactoring-specialist`
