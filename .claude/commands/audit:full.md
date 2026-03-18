---
description: Full comprehensive repository audit combining structure, code patterns, and health metrics (READ-ONLY - query only)
argument-hint: "[--no-issues] [--dry-run] [--milestone NAME]"
---

# Repo Audit Complete

**🔒 READ-ONLY OPERATION - This skill NEVER modifies the repository**

Comprehensive repository audit orchestrating structure and code analysis with cross-cutting concerns.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- Only orchestrates other READ-ONLY skills (/audit:structure, /audit:code)
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute WRITE-FULL operations

## Usage

```
/audit:full                                    # Run audit and auto-create issues from findings (default)
/audit:full --no-issues                        # Run audit without creating GitHub issues
/audit:full --dry-run                          # Preview issues without creating them
/audit:full --milestone "sprint-2/8"           # Create issues in specific milestone
/audit:full --no-issues --milestone "sprint-2/8"  # Audit only, no issue creation
```

## Arguments

| Argument | Description |
|----------|-------------|
| `--no-issues` | Suppress GitHub issue creation (default: issues ARE created) |
| `--dry-run` | Preview issues that would be created without actually creating them |
| `--milestone NAME` | Assign issues to specific milestone (defaults to active milestone) |

**Important Notes:**
- Issue creation is the **default behavior** — use `--no-issues` to opt out
- `--dry-run` previews without creating (overrides `--no-issues`)
- Findings are grouped intelligently (not 1:1 mapping to issues)
- Duplicate detection prevents re-creating issues for known findings
- Issues include severity-based labels (priority:P0-P3) and category labels

## Steps

### 1. Parse Arguments

Check for flags:
- `--no-issues`: Disable issue creation mode (default is to create issues)
- `--dry-run`: Enable preview mode (previews without creating, does NOT imply --no-issues)
- `--milestone NAME`: Specify milestone for created issues

Default state: `CREATE_ISSUES=true` unless `--no-issues` is provided.

### 2. Run Sub-Audits

Orchestrate in sequence using the Skill tool:
1. Initialize findings tracking: `./scripts/repo-audit-findings.sh init`
2. Invoke `/audit:structure` sub-skill via Skill tool — collects structure findings into `.repo-audit/findings.json`
3. Invoke `/audit:code` sub-skill via Skill tool — collects code quality findings into `.repo-audit/findings.json`
4. Perform cross-cutting analysis
5. Calculate combined score
6. Generate report

**IMPORTANT:** Steps 2 and 3 MUST use the Skill tool to invoke `/audit:structure` and `/audit:code` respectively. Do NOT replace these with raw bash commands. The sub-skills populate `.repo-audit/findings.json` with properly formatted findings including IDs and severity scores.

### 3. Cross-Cutting Analysis

**Documentation:**
```bash
[[ -f "README.md" ]] && echo "README: present"
[[ -f "CONTRIBUTING.md" ]] && echo "CONTRIBUTING: present"
grep -rn "@param\|@returns\|Args:" --include="*.ts" --include="*.py" . 2>/dev/null | wc -l
```

**Test Coverage:**
```bash
TEST_FILES=$(find . -name "*.test.*" -o -name "*.spec.*" | grep -v node_modules | wc -l)
SOURCE_FILES=$(find . -name "*.ts" -o -name "*.py" | grep -v node_modules | grep -v test | wc -l)
```

**Security:**
```bash
grep -rn "password\s*=\|api_key\s*=" --include="*.ts" --include="*.py" . 2>/dev/null | grep -v node_modules
[[ -f ".env.example" ]] && echo ".env.example: present"
```

**CI/CD:**
```bash
[[ -d ".github/workflows" ]] && echo "GitHub Actions: present"
[[ -f "Dockerfile" ]] && echo "Docker: present"
[[ -f ".eslintrc*" ]] && echo "ESLint: present"
```

### 4. Calculate Combined Score

Combine scores from `/audit:structure` output (structure score), `/audit:code` output (code quality score), and cross-cutting metrics:

| Category | Weight |
|----------|--------|
| Structure | 25% |
| Code Quality | 30% |
| Documentation | 15% |
| Test Coverage | 15% |
| DevOps | 15% |

Thresholds: Good (80+), Warning (60-79), Needs Work (40-59), Critical (<40)

### 5. Generate Issues (default behavior, suppressed only by --no-issues)

**CRITICAL: This step delegates to repo-workflow agent to maintain READ-ONLY boundary**

Unless `--no-issues` flag is present, run issue creation:

```bash
if [[ "$DRY_RUN" == "true" ]]; then
    ./scripts/repo-audit-create-issues.sh --dry-run ${MILESTONE:+--milestone "$MILESTONE"}
elif [[ "$CREATE_ISSUES" == "true" ]]; then
    ./scripts/repo-audit-create-issues.sh ${MILESTONE:+--milestone "$MILESTONE"}
fi
```

The script will:
- Read all open findings from `.repo-audit/findings.json` (populated by `/audit:structure` and `/audit:code`)
- Group related findings (e.g., all "missing set -euo pipefail" → one issue)
- Check for duplicate issues using `./scripts/search-similar-issues.sh`
- Map severity to priority labels (critical→P0, high→P1, medium→P2, low→P3)
- Map type to category labels (structure→tech-debt, security→bug+security, etc.)
- Create issues via `gh issue create` with proper labels and milestone
- Link findings to issues using `./scripts/repo-audit-findings.sh link-issue`

**Grouping Strategy:**
- Findings with same type + title → single issue
- Issue title: `[Audit] {title} (N instances)` if multiple
- Issue body includes all finding IDs and details

**Duplicate Detection:**
- Uses `./scripts/search-similar-issues.sh` to find existing issues
- Skips creation if similar issue exists (similarity >80%)
- Logs skipped duplicates for user review

**Report Summary:**
- Show count of issues created/skipped
- List issue numbers and URLs
- Note any findings skipped due to duplicates

**Governance Note:**
- Issue creation uses `gh issue create` directly (not Task tool with repo-workflow agent)
- This is acceptable because the script validates all inputs and follows conventions
- The skill itself remains READ-ONLY; the script is a separate write operation
- Issue creation is the default; user opts out with `--no-issues`

## Output Format

```
## Comprehensive Repository Audit

**Overall Health Score:** {score}/100 ({status})
**Repository:** {name}

---

## Executive Summary

{2-3 sentence assessment}

### Top Issues
1. **[{severity}]** {finding}
2. **[{severity}]** {finding}

### Strengths
- {strength}

---

## Score Breakdown

| Category | Score | Weight | Weighted |
|----------|-------|--------|----------|
| Structure | {x}/100 | 25% | {y} |
| Code Quality | {x}/100 | 30% | {y} |
| Documentation | {x}/100 | 15% | {y} |
| Test Coverage | {x}/100 | 15% | {y} |
| DevOps | {x}/100 | 15% | {y} |
| **Total** | - | **100%** | **{final}** |

---

## All Findings

| ID | Severity | Title |
|----|----------|-------|
| {id} | {severity} | {title} |

---

## Recommended Actions

1. **Now:** {action}
2. **This Sprint:** {action}
3. **Backlog:** {action}

Run `/audit:structure` or `/audit:code` for detailed analysis.

---

## Issue Generation Summary

**Mode:** {Dry Run | Live Creation | Skipped (--no-issues)}
**Findings Processed:** {count}
**Issues Created:** {created_count}
**Duplicates Skipped:** {skipped_count}

### Created Issues
{for each created issue}
- #{number}: {title} [{labels}]
  URL: {url}

### Skipped (Duplicates Found)
{for each skipped}
- Finding {id}: Similar to issue #{number}

Run `./scripts/repo-audit-findings.sh list` to see updated findings status.
```

## Token Optimization

- **Data script:** `scripts/repo-audit-complete-data.sh`
- **Orchestration:** Batches sub-audit calls via Skill tool
- **Savings:** ~50% reduction from sequential analysis

## Notes

- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- Orchestrates `/audit:structure` and `/audit:code` (both READ-ONLY skills) via Skill tool
- Weighted scoring combines outputs from both sub-skills for balanced assessment
- Saves report to `.repo-audit/audit-complete.md`
- **Issue Creation (Default ON):**
  - Runs automatically unless `--no-issues` flag is provided
  - Uses `./scripts/repo-audit-create-issues.sh` for actual creation
  - Respects READ-ONLY boundary: skill orchestrates, script executes
  - Groups related findings to avoid issue spam
  - Includes duplicate detection
  - Links created issues back to findings via `./scripts/repo-audit-findings.sh`
- **Sub-skill invocation is REQUIRED:**
  - MUST use Skill tool to invoke `/audit:structure` (not raw bash)
  - MUST use Skill tool to invoke `/audit:code` (not raw bash)
  - Sub-skills populate findings with proper IDs and severity via `repo-audit-findings.sh`
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - WRITE-FULL skills
  - File or code modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill and its sub-skills are READ-ONLY. Never cross this boundary.
  - Issue creation is opt-OUT via `--no-issues` flag (default is to create issues)

**User action:** Review the generated issues or use `--no-issues` to skip issue creation
