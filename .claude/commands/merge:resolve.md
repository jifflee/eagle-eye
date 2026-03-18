---
description: Interactive workflow for resolving PR conflicts and managing PRs needing attention
---

# Merge Resolve

Interactive workflow for resolving PR conflicts and managing PRs needing attention.

This skill provides a comprehensive workflow for identifying and resolving PRs with conflicts, stale PRs, and other issues requiring attention. It integrates with pr-health-check.sh for analysis and resolve-pr-conflicts.sh for automatic resolution.

## Usage

```
/merge:resolve              # Show PRs needing attention
/merge:resolve 185          # Resolve specific PR
/merge:resolve --all        # Resolve all conflicting PRs
```

## Steps

### 1. List PRs Needing Attention

If no PR number is specified, list all open PRs and their health status:

```bash
# Get all open PRs
OPEN_PRS=$(gh pr list --json number,title,headRefName --limit 100 2>/dev/null)

# Check if any PRs exist
if [ "$(echo "$OPEN_PRS" | jq 'length')" -eq 0 ]; then
  echo "No open PRs found."
  exit 0
fi

# For each PR, run health check
NEEDS_ATTENTION=()

while IFS= read -r pr_num; do
  # Run health check
  HEALTH=$(./scripts/pr/pr-health-check.sh "$pr_num" 2>/dev/null)

  # Parse status
  STATUS=$(echo "$HEALTH" | jq -r '.status')

  # Filter PRs needing attention
  if [[ "$STATUS" =~ ^(CONFLICTING|NEEDS_REBASE|STALE|BLOCKED)$ ]]; then
    NEEDS_ATTENTION+=("$pr_num")
  fi
done < <(echo "$OPEN_PRS" | jq -r '.[].number')
```

**Display PRs needing attention:**

```
## PRs Needing Attention

| PR | Title | Status | Action | Reason |
|----|-------|--------|--------|--------|
| #185 | Feature X | CONFLICTING | rebase | Has merge conflicts |
| #142 | Fix Y | STALE | close | All commits already in base |
| #98 | Update Z | NEEDS_REBASE | rebase | Behind base by 15 commits |

### Next Steps

1. Resolve specific PR: `/merge:resolve <PR#>`
2. Resolve all conflicts: `/merge:resolve --all`
3. Review individually on GitHub
```

### 2. Analyze Specific PR

If PR number is provided, perform detailed health check:

```bash
PR_NUMBER="$1"

# Run health check
HEALTH_RESULT=$(./scripts/pr/pr-health-check.sh "$PR_NUMBER" 2>/dev/null)

# Check for errors
if echo "$HEALTH_RESULT" | jq -e '.error' > /dev/null 2>&1; then
  echo "Error: $(echo "$HEALTH_RESULT" | jq -r '.error')"
  exit 1
fi

# Extract health data
STATUS=$(echo "$HEALTH_RESULT" | jq -r '.status')
RECOMMENDED_ACTION=$(echo "$HEALTH_RESULT" | jq -r '.recommended_action')
REASON=$(echo "$HEALTH_RESULT" | jq -r '.reason')
HAS_CONFLICTS=$(echo "$HEALTH_RESULT" | jq -r '.has_conflicts')
COMMITS_UPSTREAM=$(echo "$HEALTH_RESULT" | jq -r '.commits_upstream')
COMMITS_TOTAL=$(echo "$HEALTH_RESULT" | jq -r '.commits_total')
COMMITS_BEHIND=$(echo "$HEALTH_RESULT" | jq -r '.commits_behind_base')
```

**Display Health Status:**

```
## PR #185 Health Status

**Status:** CONFLICTING
**Recommended Action:** rebase
**Reason:** Has merge conflicts that need resolution

### Details
- Total commits: 8
- Commits already upstream: 0
- Commits behind base: 15
- Has conflicts: Yes
```

### 3. Present Resolution Options

Use AskUserQuestion to offer interactive options based on PR status:

**For CONFLICTING or NEEDS_REBASE status:**

```
Use AskUserQuestion tool:

questions:
  - question: "How would you like to resolve PR #185?"
    header: "Resolution"
    multiSelect: false
    options:
      - label: "Auto-resolve conflicts (rebase + auto-fix)"
        description: "Run resolve-pr-conflicts.sh with automatic conflict resolution strategy"
      - label: "Manual conflict resolution"
        description: "Check out the branch for manual conflict resolution"
      - label: "Skip for now"
        description: "Leave this PR unresolved and continue"
```

**For STALE status:**

```
Use AskUserQuestion tool:

questions:
  - question: "PR #142 has all commits already in base. What would you like to do?"
    header: "Stale PR"
    multiSelect: false
    options:
      - label: "Close PR with explanation"
        description: "Automatically close the PR with a comment explaining it's already merged"
      - label: "Keep open"
        description: "Leave the PR open (may need manual review)"
      - label: "Skip"
        description: "Don't take action on this PR"
```

**For BLOCKED status:**

```
Use AskUserQuestion tool:

questions:
  - question: "PR #98 has failing checks. What would you like to do?"
    header: "Blocked PR"
    multiSelect: false
    options:
      - label: "View failing checks"
        description: "Show details of failing CI checks"
      - label: "Skip for now"
        description: "Leave this PR for manual investigation"
```

**For READY status:**

```
## PR #156 Health Status

**Status:** READY
**Recommended Action:** merge
**Reason:** PR is ready to merge

This PR is healthy and ready to merge. No action needed from /merge:resolve.

Consider using `/pr-merge` to merge this PR.
```

### 4. Execute Resolution

Based on user selection, execute the appropriate action:

#### Option: Auto-resolve conflicts

```bash
# Run resolve-pr-conflicts.sh with auto strategy
RESOLUTION_RESULT=$(./scripts/pr/resolve-pr-conflicts.sh "$PR_NUMBER" --auto --strategy ours 2>&1)

# Parse result
SUCCESS=$(echo "$RESOLUTION_RESULT" | jq -r '.success')
ACTION=$(echo "$RESOLUTION_RESULT" | jq -r '.action')
MESSAGE=$(echo "$RESOLUTION_RESULT" | jq -r '.message')

if [ "$SUCCESS" = "true" ]; then
  echo "✓ Successfully resolved PR #$PR_NUMBER"
  echo "  Action: $ACTION"
  echo "  Result: $MESSAGE"

  # Update labels
  gh pr edit "$PR_NUMBER" --remove-label "conflicts" --add-label "ready-for-review" 2>/dev/null || true
else
  echo "✗ Failed to resolve PR #$PR_NUMBER"
  echo "  Reason: $MESSAGE"

  # Suggest manual resolution
  echo ""
  echo "Manual resolution required. Checkout the branch with:"
  echo "  git fetch origin"
  echo "  git checkout <branch-name>"
  echo "  git rebase origin/main"
fi
```

#### Option: Manual conflict resolution

```bash
# Get PR branch name
PR_BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName -q '.headRefName')

echo "To manually resolve conflicts:"
echo ""
echo "1. Fetch and checkout the branch:"
echo "   git fetch origin"
echo "   git checkout $PR_BRANCH"
echo ""
echo "2. Rebase onto base branch:"
echo "   git rebase origin/main"
echo ""
echo "3. Resolve conflicts in your editor"
echo ""
echo "4. Continue rebase:"
echo "   git add ."
echo "   git rebase --continue"
echo ""
echo "5. Force push:"
echo "   git push origin $PR_BRANCH --force-with-lease"
```

#### Option: Close stale PR

```bash
# Close PR with explanation
CLOSE_COMMENT="This PR has been automatically closed because all commits are already present in the base branch.

This typically happens when:
- The same changes were merged via another PR
- A manual merge was performed
- The branch was rebased after the target branch incorporated the changes

No action is required. The changes are already in the target branch.

Closed by /merge:resolve skill."

gh pr close "$PR_NUMBER" --comment "$CLOSE_COMMENT" 2>/dev/null

if [ $? -eq 0 ]; then
  echo "✓ Successfully closed stale PR #$PR_NUMBER"

  # Update issue labels if linked
  LINKED_ISSUE=$(gh pr view "$PR_NUMBER" --json body -q '.body' | grep -oP '#\K\d+' | head -1)
  if [ -n "$LINKED_ISSUE" ]; then
    gh issue edit "$LINKED_ISSUE" --remove-label "in-progress" 2>/dev/null || true
  fi
else
  echo "✗ Failed to close PR #$PR_NUMBER"
fi
```

#### Option: View failing checks

```bash
# Get check details
gh pr checks "$PR_NUMBER" --json name,state,conclusion,detailsUrl

# Display formatted
echo ""
echo "## Failing Checks"
echo ""
gh pr checks "$PR_NUMBER" | grep -E "(FAILURE|ERROR)" || echo "No failing checks found"
echo ""
echo "View details on GitHub:"
gh pr view "$PR_NUMBER" --web
```

### 5. Handle --all Flag

When `--all` flag is provided, process all PRs needing attention:

```bash
# Get all PRs needing attention (from Step 1)
for pr_num in "${NEEDS_ATTENTION[@]}"; do
  echo ""
  echo "## Processing PR #$pr_num"
  echo ""

  # Run health check
  HEALTH=$(./scripts/pr/pr-health-check.sh "$pr_num" 2>/dev/null)
  STATUS=$(echo "$HEALTH" | jq -r '.status')

  # Auto-resolve based on status
  case "$STATUS" in
    CONFLICTING|NEEDS_REBASE)
      echo "Attempting auto-resolution..."
      ./scripts/pr/resolve-pr-conflicts.sh "$pr_num" --auto --strategy ours 2>&1
      ;;
    STALE)
      echo "Closing stale PR..."
      ./scripts/pr/resolve-pr-conflicts.sh "$pr_num" --close-if-empty 2>&1
      ;;
    BLOCKED)
      echo "Skipping blocked PR (requires manual investigation)"
      ;;
  esac
done
```

**Summary Report:**

```
## Resolution Summary

| PR | Status | Result |
|----|--------|--------|
| #185 | CONFLICTING | ✓ Resolved and rebased |
| #142 | STALE | ✓ Closed with explanation |
| #98 | BLOCKED | ⊘ Skipped (failing checks) |

### Results
- Resolved: 1
- Closed: 1
- Skipped: 1
- Failed: 0

### Next Steps

Review resolved PRs and proceed with merge workflow:
- `/pr-review-internal` - Run full PR review
- `/pr-merge` - Merge approved PRs
```

### 6. Update Issue Labels

After successful resolution, update related issue and PR labels:

```bash
# Update PR labels
gh pr edit "$PR_NUMBER" --remove-label "conflicts,needs-rebase" --add-label "ready-for-review" 2>/dev/null || true

# Find linked issue
LINKED_ISSUE=$(gh pr view "$PR_NUMBER" --json body -q '.body' | grep -oP 'Closes #\K\d+|Fixes #\K\d+|Resolves #\K\d+' | head -1)

if [ -n "$LINKED_ISSUE" ]; then
  # Update issue status if applicable
  gh issue edit "$LINKED_ISSUE" --add-label "ready-for-review" 2>/dev/null || true
fi
```

## Output Format

### Standard Output (List Mode)

```
## PRs Needing Attention (3 found)

### CONFLICTING (1)
- **PR #185**: Feature X
  - Reason: Has merge conflicts that need resolution
  - Behind base by: 15 commits
  - Action: `/merge:resolve 185`

### STALE (1)
- **PR #142**: Fix Y
  - Reason: All commits already in base branch
  - Total commits: 5 (all upstream)
  - Action: `/merge:resolve 142`

### NEEDS_REBASE (1)
- **PR #98**: Update Z
  - Reason: Branch is behind base by 20 commit(s)
  - Total commits: 3
  - Action: `/merge:resolve 98`

### Next Steps
1. Resolve specific PR: `/merge:resolve <PR#>`
2. Resolve all: `/merge:resolve --all`
```

### Standard Output (Single PR Resolution)

```
## Resolving PR #185

**Status:** CONFLICTING
**Reason:** Has merge conflicts that need resolution
**Total commits:** 8
**Commits behind base:** 15

### Resolution Options

[Interactive question presented to user via AskUserQuestion]

---

[After user selection]

### Resolution Result

✓ Successfully resolved PR #185
- Strategy: Auto-resolve (ours)
- Action: rebased
- New HEAD: abc1234
- Commits rebased: 8

### Labels Updated
- Removed: conflicts
- Added: ready-for-review

### Next Steps
- Review changes: `gh pr view 185 --web`
- Run review: `/pr-review-internal --pr 185`
- Merge when ready: `/pr-merge 185`
```

### Output (--all Mode)

```
## Resolving All PRs Needing Attention

Processing 3 PRs with issues...

---

### PR #185 (CONFLICTING)
✓ Successfully resolved
- Strategy: Auto-resolve (ours)
- Commits rebased: 8

### PR #142 (STALE)
✓ Successfully closed
- Reason: All commits already upstream
- Comment added explaining closure

### PR #98 (BLOCKED)
⊘ Skipped
- Reason: Failing CI checks require investigation
- Manual review needed

---

## Summary

| Status | Count | Result |
|--------|-------|--------|
| Resolved | 1 | ✓ |
| Closed | 1 | ✓ |
| Skipped | 1 | ⊘ |
| Failed | 0 | - |

**Total PRs processed:** 3
**Success rate:** 67% (2/3)

### Next Steps
1. Review resolved PRs: `/pr-review-internal`
2. Investigate blocked PR #98
3. Merge approved PRs: `/pr-merge`
```

## Error Handling

### PR Not Found

```
Error: PR #999 not found

Please check the PR number and try again.

List open PRs with: `gh pr list`
```

### PR Already Closed

```
Error: PR #185 is already closed

This PR cannot be resolved as it's no longer open.

To view closed PR: `gh pr view 185`
```

### Resolution Failed

```
✗ Failed to resolve PR #185

**Error:** Conflicts require manual resolution

The automatic resolution strategy could not resolve all conflicts.

### Manual Resolution Required

1. Checkout the branch:
   git checkout feature-branch

2. Rebase onto base:
   git rebase origin/main

3. Resolve conflicts in your editor

4. Continue:
   git add .
   git rebase --continue

5. Push:
   git push origin feature-branch --force-with-lease

6. Re-run health check:
   /merge:resolve 185
```

### Script Not Found

```
Error: pr-health-check.sh not found

Required scripts are missing. Please ensure:
- scripts/pr/pr-health-check.sh exists
- scripts/pr/resolve-pr-conflicts.sh exists

These scripts are required for /merge:resolve to function.
```

## Integration Points

### With Other Skills

- **`/pr-status`** - View detailed PR status before resolving
- **`/pr-review-internal`** - Review PR after conflict resolution
- **`/pr-merge`** - Merge PRs after resolution
- **`/issue:checkout`** - Checkout related issue worktree if needed

### With Scripts

- **`scripts/pr/pr-health-check.sh`** - Analyzes PR health without modifications
- **`scripts/pr/resolve-pr-conflicts.sh`** - Automates conflict resolution workflow
- **GitHub CLI (`gh`)** - For PR operations and updates

### With Labels

This skill manages these labels:

**Removed after resolution:**
- `conflicts`
- `needs-rebase`

**Added after resolution:**
- `ready-for-review`

**Added if resolution fails:**
- `manual-resolution-required`

## Options and Flags

### Positional Arguments

- `<PR#>` - Specific PR number to resolve (optional)

### Flags

- `--all` - Process all PRs needing attention automatically
- `--dry-run` - Preview actions without executing them
- `--strategy <ours|theirs>` - Force conflict resolution strategy (skip interactive prompt)
- `--close-stale` - Automatically close stale PRs without prompting

### Examples

```bash
# Interactive resolution for specific PR
/merge:resolve 185

# Auto-resolve all with 'ours' strategy
/merge:resolve --all --strategy ours

# Preview actions without executing
/merge:resolve --all --dry-run

# Close stale PRs automatically
/merge:resolve --all --close-stale
```

## Workflow Recommendations

### Daily PR Maintenance

```bash
# 1. Check for PRs needing attention
/merge:resolve

# 2. Resolve conflicts as they appear
/merge:resolve <PR#>

# 3. After resolution, run reviews
/pr-review-internal --pr <PR#>

# 4. Merge when ready
/pr-merge <PR#>
```

### Bulk Cleanup

```bash
# 1. Preview what would be done
/merge:resolve --all --dry-run

# 2. Execute bulk resolution
/merge:resolve --all --close-stale

# 3. Review results and handle failures manually
```

### Pre-Release Preparation

```bash
# 1. Resolve all outstanding conflicts
/merge:resolve --all

# 2. Review all resolved PRs
for pr in $(gh pr list --json number -q '.[].number'); do
  /pr-review-internal --pr $pr
done

# 3. Merge approved PRs
/pr-merge --ready
```

## Notes

- **READ + WRITE operation** - Reads PR status, writes resolutions and updates labels
- **Requires GitHub CLI** - Must have `gh` installed and authenticated
- **Requires scripts** - Depends on pr-health-check.sh and resolve-pr-conflicts.sh
- **Interactive by default** - Uses AskUserQuestion for user confirmation
- **Respects git state** - Stashes changes and returns to original branch
- **Safe operations** - Uses `--force-with-lease` for pushes to prevent data loss
- **Label aware** - Updates PR and issue labels after resolution
- **Batch capable** - Can process multiple PRs with `--all` flag
- **Idempotent** - Safe to run multiple times on same PR

## Safety Features

### Automatic Safeguards

1. **Stash Management** - Automatically stashes and restores uncommitted changes
2. **Branch Preservation** - Returns to original branch after operations
3. **Force-with-lease** - Prevents overwriting remote changes
4. **Dry-run Mode** - Preview actions before execution
5. **Error Recovery** - Aborts operations cleanly on failure

### User Confirmations

- Interactive prompts for destructive actions (close PR, force push)
- Summary of changes before execution in batch mode
- Option to skip individual PRs in --all mode

## Performance

### Single PR Resolution

- Health check: ~1-2 seconds
- Conflict resolution: ~5-30 seconds (depends on rebase complexity)
- Total time: ~10-35 seconds

### Batch Resolution (--all)

- Per PR overhead: ~10-35 seconds
- Parallel execution: Not currently supported (sequential processing)
- Estimated time for 10 PRs: ~2-6 minutes

## Future Enhancements

Potential improvements tracked in related issues:

- Parallel PR resolution for `--all` mode
- Smart conflict resolution using AI
- Integration with CI/CD to wait for checks
- Automatic merge after successful resolution
- Slack/email notifications for resolution results
- Dashboard view of PR health across repository
