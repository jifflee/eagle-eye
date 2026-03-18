---
description: Analyze dependency PRs for breaking changes and produce merge verdicts
argument-hint: "[--pr N] [--all]"
---

# PR Dependency Review

Automated breaking change analysis for Dependabot and dependency PRs. Classifies version bumps, scans imports, and produces SAFE/REVIEW/BREAKING verdicts.

## Usage

```bash
/pr:dep-review-auto              # Analyze all open dependency PRs
/pr:dep-review-auto --pr 1010    # Analyze specific PR
/pr:dep-review-auto --all        # Explicit: all dependency PRs
```

## Steps

### 1. Gather Data

Run the backing script to collect dependency PR analysis:

```bash
DATA=$(./scripts/pr/dep-review-data.sh $ARGUMENTS)
```

If the script exits non-zero with exit code 2, report the error and stop.

### 2. Parse Results

From the JSON output, extract:
- `prs[]` — array of analyzed PRs with verdicts
- `summary` — counts by verdict (safe, review, breaking)

### 3. Display Report

Output a structured report:

```
## Dependency PR Review

**Total:** {total} dependency PRs analyzed

### Verdicts

| PR | Package | Bump | Verdict | Imports | Notes |
|----|---------|------|---------|---------|-------|
| #{number} | {package} | {from} → {to} ({bump_type}) | {verdict} | {import_count} | {migration_notes} |

### Summary

- **SAFE** ({count}): Auto-mergeable — patch/minor with no breaking risk
- **REVIEW** ({count}): Major bumps needing manual review
- **BREAKING** ({count}): Known breaking changes detected
```

### 4. Actionable Recommendations

For each verdict type, provide actions:

**SAFE PRs:**
```
These PRs can be merged with /pr-merge:
  gh pr merge {number} --squash --delete-branch
```

**REVIEW PRs:**
For each REVIEW PR, show:
- Changelog URL for manual review
- List of files importing the package
- Specific migration concerns (major version jump size)

**BREAKING PRs:**
- Show specific breaking changes detected
- Link to migration guides
- Recommend testing steps before merge

### 5. Merge-Safe Subset

If any PRs are SAFE, offer to merge them:

```
{count} PR(s) are safe to merge. Run:
  /pr-merge --pr {numbers}
```

## Notes

- READ-ONLY operation — analyzes PRs but does not merge
- Uses `dependency-manager` agent capabilities
- Builds on `scripts/ci/validators/dep-audit.sh` (vulnerability scanning)
- Complements `/pr-merge` by providing pre-merge analysis
- Skill file: `pr-dep-review.md` (renamed to `pr:dep-review` when #1017 lands)
