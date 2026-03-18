---
description: Detect unpushed work in worktrees with risk assessment and remediation options
---

# Worktree Audit

Detect worktrees with uncommitted or unpushed work, assess risk levels, and provide remediation options.

## Usage

```
/worktree-audit              # Show all worktrees with unpushed work
/worktree-audit --high-risk  # Only HIGH risk items
/worktree-audit --all        # Include all worktrees (even clean ones)
```

## Steps

### 1. Gather Worktree Data

```bash
# Get unpushed work review from sprint-status-worktrees.sh
./scripts/sprint/sprint-status-worktrees.sh --json
```

Returns JSON with `unpushed_work_review` containing:
- `total_with_unpushed` - Count of worktrees with unpushed work
- `risk_counts` - Breakdown by HIGH/MED/LOW
- `worktrees[]` - Details per worktree

### 2. Display Risk Summary

```
### Unpushed Work Review

**Risk Summary:**
| Risk Level | Count | Action |
|------------|-------|--------|
| HIGH | {risk_counts.HIGH} | Archive (work may be lost) |
| MED | {risk_counts.MED} | Review/commit changes |
| LOW | {risk_counts.LOW} | Safe to discard |
```

### 3. Detailed View

```
| # | Issue | State | Risk | Commits | Recommended Action |
|---|-------|-------|------|---------|-------------------|
| 1 | #{number} | {state} | {risk_level} | {unpushed_commits} | {recommendation} |
```

**Risk Level Definitions:**
- **HIGH**: Issue CLOSED + NO PR merged + unpushed commits exist (work may be permanently lost)
- **MED**: Uncommitted changes OR open issue with unpushed work (needs attention)
- **LOW**: PR merged, commits are stale duplicates (safe to discard)

### 4. Interactive Remediation

If HIGH or LOW risk items exist, prompt user:

```
Unpushed Work Detected ({total_with_unpushed} worktrees)

Risk Summary: {HIGH} HIGH, {MED} MED, {LOW} LOW

Actions:
[a] Archive all HIGH risk (push to archive/* branches)
[d] Discard all LOW risk (remove worktrees, PR already merged)
[r] Review specific issue (enter number)
[s] Skip for now

Select action:
```

### 5a. Archive HIGH Risk

For each HIGH risk worktree:

```bash
./scripts/worktree/worktree-archive.sh {issue_number} --cleanup
```

**What it does:**
1. Creates `archive/{branch}` branch from worktree HEAD
2. Pushes archive branch to remote
3. Optionally cleans up worktree after archiving

**Report:**
```
Archived {N} commits to archive/{branch}, worktree cleaned up
```

### 5b. Discard LOW Risk

For each LOW risk worktree (where PR was merged):

```bash
./scripts/worktree/worktree-discard.sh {issue_number}
```

**What it does:**
1. Verifies PR for this issue was merged (double-check)
2. Removes worktree directory
3. Prunes git worktree references

**Report:**
```
Discarded worktree for #{issue} (PR #{pr_number} already merged)
```

### 5c. Review Specific Issue

When user selects 'r' (review):
- Present numbered list
- Let user enter issue number
- Show details:

```bash
git -C ../repo-issue-{N} log --oneline @{upstream}..HEAD
```

Then offer:
```
Issue #{N} has {count} unpushed commits:

{commit_log}

Options:
[a] Archive to archive/{branch}
[d] Discard (delete worktree)
[p] Push to remote
[s] Skip

Select action:
```

### 6. HIGH Risk Confirmation

Before archiving HIGH risk items, require explicit confirmation:

```
Worktree for #{N} has HIGH risk:
  - {unpushed_commits} unpushed commits
  - Issue is CLOSED
  - NO PR was merged

This work may be permanently lost. Archive it?
[y] Yes, archive to archive/{branch}
[n] No, skip for now
[v] View commits first

Select [y/n/v]:
```

### 7. Audit Trail

All archive/discard operations are logged to:
- `~/.claude-tastic/logs/archive.log` (archives)
- `~/.claude-tastic/logs/worktree-cleanup.log` (discards)

Format: `timestamp|action|issue|branch|details`

## Output Format

```
## Worktree Audit

**Total Worktrees:** {total}
**With Unpushed Work:** {total_with_unpushed}

### Risk Summary

| Risk Level | Count | Action |
|------------|-------|--------|
| HIGH | {count} | Archive (work may be lost) |
| MED | {count} | Review/commit changes |
| LOW | {count} | Safe to discard |

### Detailed View

| # | Issue | State | Risk | Commits | Recommended Action |
|---|-------|-------|------|---------|-------------------|
| 1 | #42 | CLOSED | HIGH | 5 | Archive to archive/feat-42 |
| 2 | #50 | OPEN | MED | 2 | Push or commit |
| 3 | #35 | CLOSED | LOW | 3 | Discard (PR #89 merged) |

Actions:
[a] Archive all HIGH risk
[d] Discard all LOW risk
[r] Review specific issue
[s] Skip for now

Select action:
```

## High-Risk Only Format (--high-risk)

```
## Worktree Audit (HIGH Risk Only)

**HIGH Risk Worktrees:** {count}

| # | Issue | State | Commits | Last Modified |
|---|-------|-------|---------|---------------|
| 1 | #42 | CLOSED | 5 | 3 days ago |

**Warning:** These worktrees have unpushed work for CLOSED issues with NO merged PR.
This work will be LOST if worktrees are deleted without archiving.

Archive all HIGH risk? [y/n/select]
```

## Manual Commands

For users who prefer CLI:

```bash
# View commits in worktree
git -C ../repo-issue-{N} log --oneline @{upstream}..HEAD

# Push work
git -C ../repo-issue-{N} push

# Archive work
./scripts/worktree/worktree-archive.sh {issue}

# Discard worktree
./scripts/worktree/worktree-discard.sh {issue}
```

## Token Optimization

- **Data script:** `scripts/sprint/sprint-status-worktrees.sh`
- **API calls:** Batched worktree + git status queries
- **Savings:** ~60% reduction from inline git commands

## Notes

- This is a READ-ONLY operation by default (only shows status)
- Write operations (archive/discard) require explicit user confirmation
- Always confirms before archiving or discarding work
- Audit trail logs all archive/discard operations
- HIGH risk items should be reviewed before milestone completion
- LOW risk items can be safely batch-discarded
- Use `--high-risk` flag to focus on critical items only
