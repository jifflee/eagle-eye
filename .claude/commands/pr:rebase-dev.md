---
description: Rebase a PR branch on dev to resolve conflicts
---

# PR Rebase

Rebase a PR branch on the latest dev branch to resolve merge conflicts.

## Usage

```
/pr-rebase <PR_NUMBER>       # Rebase specific PR on dev
/pr-rebase 569               # Example: rebase PR #569
/pr-rebase --dry-run 569     # Preview without making changes
/pr-rebase --strategy ours   # Use 'ours' for conflicts (keep PR changes)
/pr-rebase --strategy theirs # Use 'theirs' for conflicts (keep dev changes)
```

## Prerequisites

**Ensure you are in the repository root before running.**

```bash
cd "$(git rev-parse --show-toplevel)"
```

**Requirements:**
- PR number must be provided as argument
- Local working tree must be clean (no uncommitted changes)
- GitHub CLI authenticated (`gh auth status`)

## Steps

### 1. Validate Input and State

```bash
# Check PR number provided
if [ -z "$PR_NUMBER" ]; then
    echo "Error: PR number required"
    echo "Usage: /pr-rebase <PR_NUMBER>"
    exit 1
fi

# Check working tree is clean
if ! git diff --quiet || ! git diff --staged --quiet; then
    echo "Error: Working tree has uncommitted changes"
    echo "Please commit or stash changes first"
    exit 1
fi

# Save current branch to return to later
ORIGINAL_BRANCH=$(git branch --show-current)
```

### 2. Fetch PR Information

```bash
# Get PR details
PR_INFO=$(gh pr view $PR_NUMBER --json headRefName,baseRefName,mergeable,mergeStateStatus,title,url)

BRANCH=$(echo "$PR_INFO" | jq -r '.headRefName')
BASE=$(echo "$PR_INFO" | jq -r '.baseRefName')
MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable')
STATE=$(echo "$PR_INFO" | jq -r '.mergeStateStatus')
TITLE=$(echo "$PR_INFO" | jq -r '.title')
URL=$(echo "$PR_INFO" | jq -r '.url')
```

Display PR status:

```
## PR Rebase

**PR:** #$PR_NUMBER - $TITLE
**Branch:** $BRANCH → $BASE
**Current Status:** $MERGEABLE ($STATE)
**URL:** $URL
```

### 3. Check if Rebase Needed

```bash
# If already mergeable and clean, no action needed
if [ "$MERGEABLE" = "MERGEABLE" ] && [ "$STATE" = "CLEAN" ]; then
    echo "✅ PR is already mergeable - no rebase needed"
    exit 0
fi
```

**If --dry-run:** Display status and exit.

### 4. Checkout PR Branch

```bash
# Fetch latest from origin
git fetch origin

# Checkout the PR branch
git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH" "origin/$BRANCH"

# Ensure we have latest
git pull origin "$BRANCH" --rebase 2>/dev/null || true
```

### 5. Fetch Latest Base Branch

```bash
# Fetch latest dev (or whatever base branch)
git fetch origin "$BASE"

echo "Rebasing $BRANCH on origin/$BASE..."
```

### 6. Attempt Rebase

```bash
# Attempt rebase
if git rebase "origin/$BASE"; then
    echo "✅ Rebase completed successfully (no conflicts)"
else
    # Conflicts detected
    CONFLICTS=$(git diff --name-only --diff-filter=U)
    echo ""
    echo "⚠️ Conflicts detected in:"
    echo "$CONFLICTS" | while read file; do
        echo "  - $file"
    done
fi
```

### 7. Handle Conflicts

When conflicts are detected, offer resolution strategies:

```
### Conflict Resolution

**Conflicting files:**
| File | Type | Suggestion |
|------|------|------------|
| {file_path} | {file_type} | {resolution_hint} |

**Resolution Options:**

1. **Auto-resolve (recommended for generated files)**
   - Use `--theirs` for files like package-lock.json, generated docs
   - Use `--ours` for implementation files (keep PR changes)

2. **Manual resolution**
   - Review each conflict
   - Edit files to resolve
   - Stage resolved files

**Select strategy:**
[a] Auto-resolve using smart defaults
[o] Use --ours (keep PR changes for all conflicts)
[t] Use --theirs (keep dev changes for all conflicts)
[m] Manual resolution (show diffs)
[x] Abort rebase
```

**Auto-resolve logic:**

```bash
# Smart defaults based on file type
for file in $CONFLICTS; do
    case "$file" in
        *.lock|*.sum|package-lock.json|yarn.lock)
            # Generated files: use theirs (regenerate after)
            git checkout --theirs "$file"
            ;;
        docs/*)
            # Documentation: prefer ours (PR's version)
            git checkout --ours "$file"
            ;;
        *.md)
            # Markdown: prefer ours
            git checkout --ours "$file"
            ;;
        *)
            # Code files: need manual review
            echo "Manual resolution needed: $file"
            NEEDS_MANUAL=true
            ;;
    esac
    git add "$file"
done
```

### 8. Complete Rebase

After conflicts resolved:

```bash
# Continue rebase
git rebase --continue

# If still conflicts, abort
if [ $? -ne 0 ]; then
    echo "❌ Could not complete rebase automatically"
    echo "Manual intervention required"
    git rebase --abort
    exit 1
fi
```

### 9. Force Push

```bash
echo "Pushing rebased branch..."
git push origin "$BRANCH" --force-with-lease

if [ $? -eq 0 ]; then
    echo "✅ Branch pushed successfully"
else
    echo "❌ Push failed - branch may have been updated"
    exit 1
fi
```

### 10. Verify PR Status

```bash
# Wait briefly for GitHub to update
sleep 3

# Check new status
NEW_INFO=$(gh pr view $PR_NUMBER --json mergeable,mergeStateStatus)
NEW_MERGEABLE=$(echo "$NEW_INFO" | jq -r '.mergeable')
NEW_STATE=$(echo "$NEW_INFO" | jq -r '.mergeStateStatus')
```

Display results:

```
### Rebase Complete

**Before:** $MERGEABLE ($STATE)
**After:** $NEW_MERGEABLE ($NEW_STATE)

**PR URL:** $URL
```

**If now mergeable:**
```
✅ PR #$PR_NUMBER is now ready to merge!

**Next steps:**
- Run `/pr-merge --pr $PR_NUMBER` to merge
- Or merge via GitHub UI
```

**If still not mergeable:**
```
⚠️ PR still has issues after rebase

**Status:** $NEW_MERGEABLE ($NEW_STATE)

**Possible causes:**
- CI checks still running (wait and check again)
- New conflicts introduced
- Review requirements not met

**To check CI:**
gh pr checks $PR_NUMBER
```

### 11. Return to Original Branch

```bash
git checkout "$ORIGINAL_BRANCH"
echo "Returned to branch: $ORIGINAL_BRANCH"
```

## Conflict Resolution Strategies

| Strategy | Flag | Use When |
|----------|------|----------|
| Smart auto | (default) | Mixed file types, let tool decide |
| Ours | `--strategy ours` | Keep all PR changes, discard dev changes |
| Theirs | `--strategy theirs` | Keep all dev changes, discard PR changes |
| Manual | `--manual` | Complex conflicts needing human review |

## Common Conflict Patterns

| File Pattern | Recommended Strategy | Reason |
|--------------|---------------------|--------|
| `*.lock`, `*.sum` | theirs + regenerate | Lock files should be regenerated |
| `docs/*.md` | ours | Documentation usually PR-specific |
| `scripts/*.sh` | manual | Logic changes need review |
| `*.json` (config) | manual | Config changes need review |

## Error Handling

### Working Tree Not Clean

```
Error: Working tree has uncommitted changes

**To resolve:**
1. Commit your changes: `git add . && git commit -m "WIP"`
2. Or stash them: `git stash`
3. Then re-run /pr-rebase
```

### PR Not Found

```
Error: PR #$PR_NUMBER not found

**Possible causes:**
- PR number is incorrect
- PR has been closed or merged
- You don't have access to this repository
```

### Push Rejected

```
Error: Push rejected - branch has diverged

**This can happen if:**
- Someone else pushed to the PR branch
- GitHub auto-merged base branch into PR

**To resolve:**
1. Fetch latest: `git fetch origin $BRANCH`
2. Re-run /pr-rebase
```

### Rebase Aborted

If rebase cannot be completed:

```bash
git rebase --abort
git checkout "$ORIGINAL_BRANCH"
```

```
Rebase aborted - returned to $ORIGINAL_BRANCH

**Manual resolution required:**
1. `git checkout $BRANCH`
2. `git rebase origin/$BASE`
3. Resolve conflicts manually
4. `git push --force-with-lease`
```

## Output Format

### Success

```
## PR Rebase

**PR:** #569 - Add structured logging for containers
**Branch:** feat/issue-510 → dev
**Status:** CONFLICTING → MERGEABLE

### Actions Taken

1. ✅ Checked out feat/issue-510
2. ✅ Fetched latest origin/dev
3. ✅ Rebased on origin/dev
4. ⚠️ Resolved 2 conflicts (auto)
   - scripts/container/container-entrypoint.sh (ours)
   - scripts/container/container-sprint-workflow.sh (ours)
5. ✅ Force pushed to origin
6. ✅ Verified PR is mergeable

**Result:** PR #569 is ready to merge!
```

### Dry Run

```
## PR Rebase (Dry Run)

**PR:** #569 - Add structured logging for containers
**Branch:** feat/issue-510 → dev
**Current Status:** CONFLICTING

### Would Perform

1. Checkout feat/issue-510
2. Rebase on origin/dev
3. Resolve conflicts (if any)
4. Force push to origin

(No changes made - dry run mode)
```

## Notes

- This is a WRITE operation - it modifies the PR branch
- Uses `--force-with-lease` for safe force push
- Always returns to original branch after completion
- Conflicts in lock files are auto-resolved, then regenerated
- For complex merges, consider using `--manual` flag
- After rebase, CI checks will re-run on the updated branch
