---
description: Audit UI/UX design standard compliance — tokens, components, accessibility, responsive design, and style profile consistency (READ-ONLY with delegation)
argument-hint: "[--tokens] [--components] [--accessibility] [--responsive] [--profile <name>] [--all] [--fix] [--dry-run] [--format json]"
---

# Audit UI

**🔒 READ-ONLY OPERATION — This skill NEVER modifies code directly**

Scan frontend code for design standard compliance and delegate fixes to the frontend-developer agent via PM orchestrator.

**Related:** Issue #916 — UI/UX Design Standardization Research

**CRITICAL SAFEGUARD:**
- This skill ONLY observes, analyzes, and produces findings
- All fixes are delegated to the `frontend-developer` agent via PM orchestrator
- NEVER directly edit, write, or delete files as part of scanning
- `--fix` mode creates a fix plan and hands off to PM — it does NOT fix directly

## Usage

```
/audit:ui-ux                              # Interactive menu
/audit:ui-ux --tokens                     # Design token compliance audit
/audit:ui-ux --components                 # Component structure standards audit
/audit:ui-ux --accessibility              # WCAG 2.1 AA compliance check
/audit:ui-ux --responsive                 # Responsive design pattern audit
/audit:ui-ux --profile financial          # Style profile consistency (financial)
/audit:ui-ux --profile general            # Style profile consistency (general)
/audit:ui-ux --profile admin              # Style profile consistency (admin)
/audit:ui-ux --profile marketing          # Style profile consistency (marketing)
/audit:ui-ux --all                        # Full audit (all dimensions)
/audit:ui-ux --fix                        # Delegate findings to frontend-developer
/audit:ui-ux --dry-run                    # Preview fix delegation without applying
/audit:ui-ux --format json                # JSON output for CI integration
/audit:ui-ux --severity high              # High/critical findings only
/audit:ui-ux --scope changed              # Only scan files changed since last commit
```

## Steps

### 0. Parse Arguments

```bash
MODE="interactive"
DIMENSIONS=()
SCOPE="full"
SEVERITY_FILTER=""
FIX_MODE=false
DRY_RUN=false
FORMAT="text"
PROFILE=""

for arg in "$@"; do
  case "$arg" in
    --tokens)        MODE="scan"; DIMENSIONS+=(tokens) ;;
    --components)    MODE="scan"; DIMENSIONS+=(components) ;;
    --accessibility) MODE="scan"; DIMENSIONS+=(accessibility) ;;
    --responsive)    MODE="scan"; DIMENSIONS+=(responsive) ;;
    --profile)       MODE="scan"; DIMENSIONS+=(profile) ;;
    --all)           MODE="scan"; DIMENSIONS=(tokens components accessibility responsive profile) ;;
    --fix)           FIX_MODE=true ;;
    --dry-run)       DRY_RUN=true ;;
    --format)        ;; # handled by next arg
    json)            FORMAT="json" ;;
    --severity)      ;; # handled by next arg
    high|medium|low) SEVERITY_FILTER="$arg" ;;
    --scope)         ;; # handled by next arg
    changed)         SCOPE="changed" ;;
    financial|general|admin|marketing) PROFILE="$arg" ;;
  esac
done
```

### 1. Interactive Menu (no flags)

If no dimension flags are provided, show the selection menu:

```
## UI/UX Audit Scanner

Select dimension(s) to audit:

  [1] --tokens        Design token compliance (hardcoded colors, spacing violations)
  [2] --components    Component structure standards (TypeScript, hooks, SRP)
  [3] --accessibility WCAG 2.1 AA compliance (axe-core, ARIA, contrast)
  [4] --responsive    Responsive design patterns (mobile-first, breakpoints)
  [5] --profile       Style profile consistency (financial/general/admin/marketing)
  [6] --all           Full audit (all dimensions)

  Profile (required for dimension 5):
  [f] financial   [g] general   [a] admin   [m] marketing

  Scope options:
  [s] --scope changed   Only scan files changed since last commit
  [A] --scope all       Scan entire repo (default)

  Filter:
  [h] --severity high   High/critical findings only

Enter selection (e.g. "1 3" or "6"):
```

### 2. Run Scanners

```bash
mkdir -p .audit-ui

SCOPE_FLAGS=""
[[ "$SCOPE" == "changed" ]] && SCOPE_FLAGS="--changed-files-only"

for dimension in "${DIMENSIONS[@]}"; do
  case "$dimension" in
    tokens)        ./scripts/scan-ui-tokens.sh $SCOPE_FLAGS \
                     --output-file .audit-ui/findings-tokens.json ;;
    components)    ./scripts/scan-ui-components.sh $SCOPE_FLAGS \
                     --output-file .audit-ui/findings-components.json ;;
    accessibility) ./scripts/scan-ui-accessibility.sh $SCOPE_FLAGS \
                     --output-file .audit-ui/findings-accessibility.json ;;
    responsive)    ./scripts/scan-ui-responsive.sh $SCOPE_FLAGS \
                     --output-file .audit-ui/findings-responsive.json ;;
    profile)       ./scripts/scan-ui-profile.sh $SCOPE_FLAGS \
                     --profile "${PROFILE:-general}" \
                     --output-file .audit-ui/findings-profile.json ;;
  esac
done

# Merge all findings
FINDING_FILES=""
for dimension in "${DIMENSIONS[@]}"; do
  f=".audit-ui/findings-${dimension}.json"
  [[ -f "$f" ]] && FINDING_FILES="$FINDING_FILES $f"
done

jq -s 'add // []' $FINDING_FILES > .audit-ui/findings.json
```

**Scanner dispatch table:**

| Dimension | Script | Output File |
|-----------|--------|-------------|
| `tokens` | `./scripts/scan-ui-tokens.sh` | `.audit-ui/findings-tokens.json` |
| `components` | `./scripts/scan-ui-components.sh` | `.audit-ui/findings-components.json` |
| `accessibility` | `./scripts/scan-ui-accessibility.sh` | `.audit-ui/findings-accessibility.json` |
| `responsive` | `./scripts/scan-ui-responsive.sh` | `.audit-ui/findings-responsive.json` |
| `profile` | `./scripts/scan-ui-profile.sh` | `.audit-ui/findings-profile.json` |

### 3. Apply Severity Filter

```bash
case "$SEVERITY_FILTER" in
  high)
    FILTERED=$(jq '[.[] | select(.severity == "critical" or .severity == "high")]' \
      .audit-ui/findings.json)
    ;;
  medium)
    FILTERED=$(jq '[.[] | select(.severity == "critical" or .severity == "high" or .severity == "medium")]' \
      .audit-ui/findings.json)
    ;;
  low|"")
    FILTERED=$(jq '.' .audit-ui/findings.json)
    ;;
esac

echo "$FILTERED" > .audit-ui/findings-filtered.json
```

### 4. JSON Format Mode (`--format json`)

If `--format json`, output structured JSON and exit:

```bash
if [[ "$FORMAT" == "json" ]]; then
  FINDINGS=$(cat .audit-ui/findings-filtered.json)
  TOTAL=$(echo "$FINDINGS" | jq 'length')
  CRITICAL=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "critical")] | length')
  HIGH=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "high")] | length')

  echo "$FINDINGS" | jq '{
    total: '"$TOTAL"',
    critical: '"$CRITICAL"',
    high: '"$HIGH"',
    findings: .
  }'

  # Exit code: 0 = clean, 1 = findings, 2 = critical findings
  if [[ "$CRITICAL" -gt 0 ]]; then exit 2
  elif [[ "$TOTAL" -gt 0 ]]; then exit 1
  else exit 0
  fi
fi
```

### 5. Display Findings Report

Display a human-readable summary:

```
## UI/UX Audit Results

**Dimensions scanned:** {dimension_list}
**Scope:** {full | changed files only}
**Profile:** {profile name if applicable}
**Total findings:** {count}

| Severity | Count |
|----------|-------|
| Critical | {n}   |
| High     | {n}   |
| Medium   | {n}   |
| Low      | {n}   |

---

### 🎨 Design Token Findings ({n})

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-001 | high | src/components/PriceCell.tsx:14 | Hardcoded color #DC2626 → use token `color-loss` |
| UI-002 | medium | src/views/Dashboard.tsx:31 | Arbitrary spacing `p-[7px]` → use spacing scale |

---

### 🧩 Component Structure Findings ({n})

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-010 | high | src/components/LegacyTable.jsx | Class component — convert to functional |
| UI-011 | medium | src/components/UserCard.tsx:5 | Props use `any` type — add explicit interface |

---

### ♿ Accessibility Findings ({n})

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-020 | critical | src/views/RiskMatrix.tsx | Chart has no accessible alternative (WCAG 1.1.1) |
| UI-021 | high | src/components/PriceTable.tsx:44 | Missing `<th>` scope attribute on header cells |

---

### 📱 Responsive Design Findings ({n})

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-030 | high | src/layouts/MainLayout.tsx:12 | Fixed pixel width `w-[1024px]` — use `max-w-*` |

---

### 🎯 Profile Consistency Findings ({n})

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-040 | medium | src/components/Alert.tsx | Uses `text-gain` in general profile — cross-profile token |

---

**Findings saved to:** `.audit-ui/findings.json`

Run `/audit:ui-ux --fix` to delegate fixes to the frontend-developer agent.
Run `/audit:ui-ux --format json` for CI-friendly JSON output.
```

**If no findings:**

```
✅ No UI/UX compliance issues found.

Scanned {n} files across {dimension_list}. Frontend code meets standards!
```

### 6. Fix Mode (`--fix` or `--dry-run`)

```bash
if [[ ! -f ".audit-ui/findings.json" ]]; then
  echo "No findings file found. Run a scan first."
  echo "  Example: /audit:ui-ux --all"
  exit 1
fi

FINDINGS=$(cat .audit-ui/findings.json)
OPEN_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.status == "open")] | length')

if [[ "$OPEN_COUNT" -eq 0 ]]; then
  echo "No open UI/UX findings to fix. Frontend code is clean!"
  exit 0
fi
```

**Dry run mode** — display fix plan without delegating:

```
## Dry Run: UI/UX Fix Plan

**Open findings:** {open_count}
**Owning agent:** frontend-developer

### Findings to delegate:

| ID | Severity | Dimension | File | Description |
|----|----------|-----------|------|-------------|
| UI-001 | high | tokens | src/components/PriceCell.tsx | Replace hardcoded color |
| UI-020 | critical | accessibility | src/views/RiskMatrix.tsx | Add accessible chart alternative |

---
No changes made (--dry-run)
```

**Live fix mode** — delegate to PM orchestrator via Task tool:

Dispatch the `pm-orchestrator` agent with the fix plan:

```
Prompt to PM orchestrator:

"You are orchestrating UI/UX compliance fixes.

Findings: {findings_json}

Dispatch the frontend-developer agent with the following context:
- Findings: the specific UI/UX findings listed above
- Owning files: the files containing the findings
- Acceptance criteria: fix each finding per its description
- Standards reference: docs/ui-standards/component-standards.md
- Token reference: docs/design-tokens/ for the active profile
- Accessibility reference: docs/ui-standards/accessibility-checklist.md

Constraint: The audit-ui skill is READ-ONLY. Dispatch ALL fixes to frontend-developer.
NEVER fix findings yourself.

After the agent completes, verify fixes by re-running:
  /audit:ui-ux --scope changed"
```

## Output Format

### Text Mode (default)

```
## UI/UX Audit Results

**Dimensions:** tokens, accessibility
**Scope:** full repository
**Total findings:** 3 (1 critical, 1 high, 1 medium)

---

### Design Token Findings (1)

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-001 | medium | src/components/Card.tsx:8 | Hardcoded #F3F4F6 → use token `color-surface` |

---

### Accessibility Findings (2)

| ID | Severity | File | Description |
|----|----------|------|-------------|
| UI-020 | critical | src/views/Chart.tsx | No accessible alternative for chart data |
| UI-021 | high | src/components/Table.tsx:44 | Missing `scope` on column headers |

**Findings saved to:** `.audit-ui/findings.json`
```

### JSON Mode (`--format json`)

```json
{
  "total": 3,
  "critical": 1,
  "high": 1,
  "findings": [
    {
      "id": "UI-001",
      "dimension": "tokens",
      "severity": "medium",
      "owning_agent": "frontend-developer",
      "file_paths": ["src/components/Card.tsx:8"],
      "description": "Hardcoded color #F3F4F6 should use design token color-surface",
      "suggested_fix": "Replace inline style with Tailwind class bg-surface",
      "status": "open"
    },
    {
      "id": "UI-020",
      "dimension": "accessibility",
      "severity": "critical",
      "owning_agent": "frontend-developer",
      "file_paths": ["src/views/Chart.tsx"],
      "description": "Chart has no accessible alternative — violates WCAG 1.1.1 (Non-text Content)",
      "suggested_fix": "Add aria-label + companion data table, or role='img' with descriptive aria-label",
      "status": "open"
    }
  ]
}
```

Exit codes: `0` = clean, `1` = findings present, `2` = critical findings

## Findings Schema

Findings conform to the standard refactor finding schema:

```json
{
  "id": "UI-001",
  "dimension": "tokens|components|accessibility|responsive|profile",
  "severity": "critical|high|medium|low",
  "owning_agent": "frontend-developer",
  "file_paths": ["path/to/file.tsx:line"],
  "description": "Human-readable finding description",
  "suggested_fix": "Suggested remediation",
  "acceptance_criteria": ["criterion 1", "criterion 2"],
  "status": "open|in-progress|completed|deferred",
  "metadata": {
    "wcag_criterion": "1.1.1",
    "profile": "financial",
    "created_at": "ISO8601"
  }
}
```

## Scanner Scripts Reference

| Script | Checks | Implementation Notes |
|--------|--------|---------------------|
| `scripts/scan-ui-tokens.sh` | Hardcoded colors/spacing, arbitrary Tailwind values | grep/ast-grep for style patterns |
| `scripts/scan-ui-components.sh` | Class components, `any` props, hooks violations, file size | ESLint + file analysis |
| `scripts/scan-ui-accessibility.sh` | WCAG 2.1 AA via axe-core | Playwright + @axe-core/playwright |
| `scripts/scan-ui-responsive.sh` | Fixed widths, desktop-first patterns, touch targets | grep + CSS analysis |
| `scripts/scan-ui-profile.sh` | Cross-profile token usage, density settings | Token manifest + component scan |

## Integration with `/refactor`

This skill integrates with the existing `/refactor` system. The `ui` dimension can be added to `/refactor --audit`:

```bash
# Full refactor audit now includes UI checks
/refactor --audit  # runs: code, docs, deps, tests, arch, framework, ui

# UI-specific refactor
/refactor --ui     # equivalent to /audit:ui-ux --all
```

**Owning agents for UI dimension:**
- `.tsx`, `.jsx`, `.css`, `.scss` (frontend paths) → `frontend-developer`

## CI Integration

Add to local CI scripts:

```bash
# scripts/ci/validate-local.sh
# Run UI audit in CI-friendly mode
./scripts/run-audit-ui.sh --format json --severity high > .audit-ui/ci-results.json

if [ $? -eq 2 ]; then
  echo "❌ Critical UI/UX violations found — review .audit-ui/ci-results.json"
  exit 1
fi
```

## Token Optimization

**Data gathering via scanner scripts:**
- Each scanner outputs pre-structured JSON (no Claude reasoning needed)
- Severity pre-computed in scripts
- Findings merged via `jq` — no Claude parsing
- Fix plan generated automatically — no Claude planning

**Token usage:**
- Scan mode: ~500 tokens (scripts handle analysis, Claude only formats report)
- Fix mode: ~700 tokens (plan from script, Claude only dispatches PM)
- JSON mode: ~150 tokens (JSON passthrough with exit code)

**Key optimizations:**
- ✅ All scanning done in bash/Node scripts (not in Claude context)
- ✅ Findings pre-structured as JSON
- ✅ Claude receives only structured results
- ✅ Batch processing across all dimensions

## Notes

- **READ-ONLY OPERATION**: This skill observes and delegates. NEVER modifies files.
- Findings saved to `.audit-ui/findings.json` (gitignored by convention)
- `--fix` delegates to PM orchestrator → `frontend-developer` agent
- `--format json` integrates with CI pipelines (`exit 2` on critical findings)
- `--scope changed` uses `git diff` to limit scan to recently changed files

**Profile reference files:**
- `docs/design-tokens/profiles/financial.tokens.json`
- `docs/design-tokens/profiles/general.tokens.json`
- `docs/design-tokens/profiles/admin.tokens.json`
- `docs/design-tokens/profiles/marketing.tokens.json`

**Standards references:**
- `docs/ui-standards/component-standards.md`
- `docs/ui-standards/accessibility-checklist.md`
- `docs/ui-standards/financial-ui-guide.md`

**Related:**
- Issue #916 — UI/UX Design Standardization Research
- `/refactor` — General refactor skill (sibling)
- `frontend-developer` agent — Implementation agent
- `product-spec-ux` agent — UX specification agent
