# PR Lifecycle Management Scripts

Automated tools to streamline PR merge orchestration and reduce manual interventions.

## Problem Statement

Manual PR merging involves multiple error-prone steps:
- Branch tracking issues requiring `git push origin HEAD:branch`
- "Base branch modified" errors when merging multiple PRs
- Manual worktree cleanup after merge
- Issues not auto-closing despite PR merge
- Stale `wip:checked-out` labels
- Manual conflict resolution

## Solution

A suite of scripts that automate the entire PR lifecycle from validation to cleanup.

## Scripts

### 1. `validate-merge.sh` - Pre-merge Validation

Validates a PR is ready to merge before attempting the merge.

```bash
./scripts/pr-lifecycle/validate-merge.sh <pr_number>

# With auto-rebase if behind
AUTO_REBASE=true ./scripts/pr-lifecycle/validate-merge.sh <pr_number>
```

**Checks:**
- ✅ PR is open and mergeable
- ✅ Linked issue exists (via "Fixes #N" in PR body)
- ✅ No conflicts
- ✅ Branch up-to-date with base (or auto-rebase if possible)
- ✅ CI checks passing

**Exit codes:**
- `0` - PR is ready to merge
- `1` - Validation failed

---

### 2. `merge-and-cleanup.sh` - Safe Merge with Cleanup

Merges PR and performs complete cleanup in one command.

```bash
./scripts/pr-lifecycle/merge-and-cleanup.sh <pr_number>
```

**Steps:**
1. **Validate** - Runs pre-merge validation
2. **Remove worktree** - Safely removes worktree before merge
3. **Merge PR** - Squash merge with retry logic for "base modified" errors
4. **Close issue** - Auto-closes linked issue with comment
5. **Cleanup branch** - Deletes local and remote branches
6. **Remove labels** - Removes stale `wip:checked-out` labels

**Features:**
- 🔄 Auto-retry up to 3 times on "base branch modified" error
- 🛡️ Prevents merge if worktree has uncommitted changes
- 🏷️ Auto-closes linked issues
- 🧹 Complete branch cleanup

---

### 3. `batch-merge.sh` - Merge Multiple PRs

Merge multiple PRs sequentially with intelligent ordering.

```bash
# Comma-separated
./scripts/pr-lifecycle/batch-merge.sh 123,124,125

# Space-separated
./scripts/pr-lifecycle/batch-merge.sh 123 124 125
```

**Process:**
1. **Validate all** - Pre-validates all PRs before starting
2. **Sort by dependencies** - Orders by creation date (oldest first)
3. **Sequential merge** - Merges one at a time with delays
4. **Error handling** - Option to continue or abort on failure

**Features:**
- 📊 Summary report of merged/failed PRs
- ⏱️ 3-second delay between merges to stabilize base
- ❓ Interactive confirmation before proceeding

---

### 4. `cleanup-stale-labels.sh` - Label Hygiene

Detects and removes stale `wip:checked-out` labels.

```bash
# Dry-run (preview only)
./scripts/pr-lifecycle/cleanup-stale-labels.sh --dry-run

# Apply cleanup
./scripts/pr-lifecycle/cleanup-stale-labels.sh
```

**Detects stale labels when:**
- ✅ PR is merged/closed
- ✅ No worktree exists for branch
- ✅ No associated PR found

**Output:**
- Summary of active vs stale labeled issues
- Automatic label removal

---

### 5. `resolve-conflicts.sh` - Conflict Resolution Helper

Interactive helper for resolving PR conflicts.

```bash
./scripts/pr-lifecycle/resolve-conflicts.sh <pr_number>
```

**Features:**
- 🔍 Detects if PR has conflicts
- 🌳 Creates worktree if needed
- 🔄 Attempts automatic rebase
- 📝 Provides step-by-step manual resolution guide
- 💻 Option to open VS Code for resolution

**Workflow:**
1. Fetch latest base branch
2. Attempt rebase
3. If conflicts: provide manual resolution steps
4. Guide through `git add` and `git rebase --continue`

---

## Usage Examples

### Single PR Merge
```bash
# Validate first
./scripts/pr-lifecycle/validate-merge.sh 123

# Merge with cleanup
./scripts/pr-lifecycle/merge-and-cleanup.sh 123
```

### Batch Merge Multiple PRs
```bash
# Merge sprint PRs
./scripts/pr-lifecycle/batch-merge.sh 120,121,122,123
```

### Conflict Resolution
```bash
# When PR has conflicts
./scripts/pr-lifecycle/resolve-conflicts.sh 123

# After resolving manually:
# cd <worktree>
# git add <files>
# git rebase --continue
# git push --force-with-lease
```

### Label Cleanup
```bash
# Weekly label hygiene (dry-run first)
./scripts/pr-lifecycle/cleanup-stale-labels.sh --dry-run
./scripts/pr-lifecycle/cleanup-stale-labels.sh
```

---

## Requirements

- **Git** - Worktree support
- **GitHub CLI (gh)** - For PR/issue operations
- **jq** - JSON parsing

Install dependencies:
```bash
# macOS
brew install gh jq

# Linux
apt-get install gh jq
```

---

## Configuration

### PR Body Format

For automatic issue closing, include in PR description:
```markdown
Fixes #123
Closes #124
Resolves #125
```

### Branch Protection

Recommended GitHub settings:
- ✅ Require pull request reviews
- ✅ Require status checks to pass
- ✅ Require branches to be up to date
- ✅ Require linear history (works with squash merge)

---

## Troubleshooting

### "Base branch was modified" Error
**Solution:** Use `merge-and-cleanup.sh` which has built-in retry logic.

### Worktree Blocking Branch Delete
**Solution:** Scripts remove worktree before merge to prevent this issue.

### Issue Not Auto-Closing
**Cause:** Missing "Fixes #N" in PR body
**Solution:** `validate-merge.sh` warns about missing linked issues.

### Stale Labels
**Solution:** Run `cleanup-stale-labels.sh` periodically (weekly recommended).

---

## Integration with Epic #196

This feature is part of **Epic #196: PR Lifecycle Automation**

**Related issues:**
- #197 - Conflict resolution script ✅ Implemented as `resolve-conflicts.sh`
- #198 - PR health check script ✅ Implemented as `validate-merge.sh`
- #382 - This feature

**Future enhancements:**
- Slack notifications on merge
- Auto-update CHANGELOG
- Release note generation
- Dependency graph visualization

---

## Exit Codes

All scripts follow consistent exit codes:

- `0` - Success
- `1` - Validation or operation failed

This enables scripting and CI integration:
```bash
if ./scripts/pr-lifecycle/validate-merge.sh 123; then
    ./scripts/pr-lifecycle/merge-and-cleanup.sh 123
fi
```

---

## Script Architecture

```
scripts/pr-lifecycle/
├── validate-merge.sh         # Pre-merge validation
├── merge-and-cleanup.sh      # Safe merge + cleanup
├── batch-merge.sh            # Multi-PR orchestration
├── cleanup-stale-labels.sh   # Label hygiene
├── resolve-conflicts.sh      # Conflict resolution
└── README.md                 # This file
```

Each script is:
- ✅ Standalone executable
- ✅ Well-documented with help text
- ✅ Error-handled with clear messages
- ✅ Exit code compliant
