---
description: Clean up worktrees for closed issues with conflict detection
---

# Worktree Cleanup

Clean up worktrees for issues that have been closed, with conflict detection and batch cleanup support.

## Usage

```
/worktree-cleanup            # Interactive cleanup (shows all, prompts)
/worktree-cleanup --safe     # Only conflict-free worktrees (no prompts)
/worktree-cleanup --force    # Include conflicted (with confirmation)
/worktree-cleanup --issue N  # Clean up specific issue worktree
```

## Prerequisites

**Must run from main repository, not from within a worktree.**

```bash
# Check if in main repo
if [ ! -d ".git" ]; then
  echo "Error: Must run from main repository, not a worktree"
  exit 1
fi
```

## Steps

### 1. Gather Worktree Data

```bash
# Get worktree cleanup data
./scripts/sprint/sprint-status-worktrees.sh --json
```

Returns JSON with `cleanup` section containing:
- `cleanup_count` - Worktrees ready for cleanup
- `total` - Total issue worktrees
- `cleanup_allowed` - Boolean (true only from main repo)
- `worktrees[]` - Details per worktree

### 2. Check Cleanup Allowed

**If running from worktree (cleanup_allowed: false):**
```
Worktree cleanup must be run from the main repository.
To clean up, switch to the main repo and run /worktree-cleanup again.

Main repo location: {main_repo_path}
```

### 3. Display Worktrees Pending Cleanup

```
### Worktrees Pending Cleanup

| # | Worktree | Issue | Closed | Conflicts | Branch |
|---|----------|-------|--------|-----------|--------|
| 1 | {path} | #{number}: {title} | {time_ago} | None | {branch} |
| 2 | {path} | #{number}: {title} | {time_ago} | 3 uncommitted | {branch} |
| 3 | {path} | #{number}: {title} | {time_ago} | 2 unpushed | {branch} |

**Total:** {cleanup_count} worktrees ready for cleanup (of {total} issue worktrees)
```

**Conflicts Legend:**
- `None` - Safe to remove
- `Uncommitted changes` - Has modified files (review before cleanup)
- `N unpushed commits` - Has commits not pushed to remote

### 4. Cleanup Prompt

**If --safe flag:** Skip prompt, clean only conflict-free worktrees.

**Otherwise:**
```
Clean up stale worktrees? [y/n/select]
```

### 5a. Clean All Safe (y)

1. Collect all issue numbers with `conflicts: None` into comma-separated list
2. Run batch cleanup:

```bash
./scripts/worktree/worktree-cleanup-batch.sh {issue1},{issue2},{issue3}
```

**Response format:**
```json
{
  "success": true,
  "cleaned": [15, 21, 29, 30],
  "skipped": [{"issue": 32, "reason": "uncommitted changes"}],
  "errors": [],
  "summary": "Cleaned 4 worktrees, skipped 1"
}
```

Report: `{summary} - see audit log for details`

### 5b. Skip (n)

Exit without cleanup.

### 5c. Select Specific (select)

- Present numbered list of worktrees
- Let user choose which to clean up (comma-separated numbers)
- Use batch cleanup with selected issues:

```bash
./scripts/worktree/worktree-cleanup-batch.sh {selected_issues}
```

### 6. Conflict Handling

If some worktrees have conflicts:

```
Some worktrees have conflicts:
  #32: 3 uncommitted files
  #45: 2 unpushed commits

Options:
1. Skip conflicted (clean only safe ones)
2. Force all (discard changes)
3. Review individually

Select [1/2/3]:
```

**Option 1 (skip conflicted):**
```bash
./scripts/worktree/worktree-cleanup-batch.sh {safe_issues_only}
```

**Option 2 (force all):**
```bash
./scripts/worktree/worktree-cleanup-batch.sh {all_issues} --force
```

**Option 3 (review individually):**
For each conflicted worktree:
```
Worktree for #{N} has conflicts:
  - {conflict_details}

Options:
[f] Force cleanup (discard changes)
[s] Skip this worktree
[v] View changes

Select [f/s/v]:
```

### 7. Force Cleanup (--force)

When `--force` flag is provided:
```bash
./scripts/worktree/worktree-cleanup-batch.sh {all_issues} --force
```

Only use `--force` when user explicitly confirms they want to discard uncommitted/unpushed work.

### 8. Single Issue Cleanup (--issue N)

When specific issue is provided:
```bash
./scripts/worktree/worktree-cleanup.sh {issue_number}

# With branch deletion
./scripts/worktree/worktree-cleanup.sh {issue_number} --delete-branch
```

### 9. Audit Trail

All cleanup operations are logged to:
`~/.claude-tastic/logs/worktree-cleanup.log`

Format: `timestamp|user|repo|action|details|outcome`

## Output Format

```
## Worktree Cleanup

**Status:** Running from main repository
**Total Worktrees:** {total}
**Ready for Cleanup:** {cleanup_count}

### Worktrees Pending Cleanup

| # | Issue | Closed | Conflicts | Branch |
|---|-------|--------|-----------|--------|
| 1 | #42: Feature X | 2 days ago | None | feat/issue-42 |
| 2 | #50: Bug fix | 5 days ago | None | fix/issue-50 |

**Total:** 2 worktrees ready for cleanup

Clean up stale worktrees? [y/n/select]
```

## Safe Mode Format (--safe)

```
## Worktree Cleanup (Safe Mode)

**Cleaning conflict-free worktrees only...**

Cleaned 5 worktrees:
- #42: Feature X
- #50: Bug fix
- #55: Docs update
- #60: Test fixes
- #62: Refactor

Skipped 2 with conflicts:
- #45: 3 uncommitted files
- #48: 2 unpushed commits

**Summary:** 5 cleaned, 2 skipped
```

## Cleanup Commands

For users who prefer CLI:

```bash
# Batch cleanup (preferred)
./scripts/worktree/worktree-cleanup-batch.sh {issue1},{issue2},{issue3}

# Single cleanup
./scripts/worktree/worktree-cleanup.sh {issue_number}

# With branch deletion
./scripts/worktree/worktree-cleanup.sh {issue_number} --delete-branch

# Force cleanup (discard uncommitted)
./scripts/worktree/worktree-cleanup-batch.sh {issues} --force
```

## Token Optimization

- **Data script:** `scripts/sprint/sprint-status-worktrees.sh`, `scripts/worktree/worktree-cleanup-batch.sh`
- **API calls:** Batched worktree queries
- **Savings:** ~55% reduction from sequential worktree operations

## Notes

- This is a WRITE operation - it removes worktree directories
- **Must run from main repository**, not from within a worktree
- Conflict-free worktrees are safe to remove (no data loss)
- Conflicted worktrees require confirmation before cleanup
- Use `--force` only when you're sure you want to discard changes
- Use `--safe` for unattended/scripted cleanup of only conflict-free worktrees
- Audit trail logs all cleanup operations
- Branch deletion is optional (use `--delete-branch` when cleaning single worktrees)
- See `/worktree-audit` for unpushed work assessment before cleanup
