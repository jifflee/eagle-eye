---
description: Automated review-fix iteration loop until PR is approved or max iterations reached
---

# PR Iterate

Automated review-fix loop that runs `/pr-review-internal` and `/pr-fix` until the PR is approved or the maximum iteration count is reached.

## Usage

```
/pr-iterate                # Default: max 3 iterations
/pr-iterate --max 5        # Allow up to 5 iterations
/pr-iterate --auto         # Non-interactive mode (no prompts)
/pr-iterate --skip-security # Skip security review for faster iterations
```

## Container Mode Support

When running in a container (detected automatically), `/pr-iterate` operates in non-interactive mode:

**Auto-detection triggers:**
- Environment variable `CLAUDE_CONTAINER_MODE=true`
- No TTY available (`[ ! -t 0 ]`)
- Running inside Docker (presence of `/.dockerenv`)

**Container mode behavior:**
- `--auto` flag is automatically enabled
- No user prompts - continues until max iterations or approval
- Status updates written to `pr-status.json` for host monitoring
- Uses reduced iteration count (default: 2) for faster feedback
- Automatically pushes fixes after each iteration

**Example container invocation:**
```bash
# In container context (automatically detected)
claude -p "/pr-iterate"

# Explicit container-friendly invocation
claude -p "/pr-iterate --auto --max 2"
```

**Status persistence:**
Container mode reads/writes to `pr-status.json` at these locations (in order):
1. `PR_STATUS_FILE` environment variable
2. `/workspace/repo/pr-status.json`
3. `/workspace/pr-status.json`
4. `./pr-status.json`

## Prerequisites

- Must be in a worktree with an open PR
- PR must target dev branch
- `pr-status.json` will be created if it doesn't exist

## Token Optimization

This skill uses a data-gathering script to batch GitHub API calls:

**Data Script:** `./scripts/pr/pr-iterate-data.sh`

**Optimizations:**
- Single `gh pr view` call captures all PR metadata
- Reads `pr-status.json` for review state (no API needed)
- Pre-calculates iteration limits and stop conditions
- Returns structured JSON for direct consumption

**Token Usage:**
- Before: ~2,300 tokens (7 inline `gh` calls, parsing overhead)
- After: ~725 tokens (single data script, structured output)
- **Savings: 68%**

## Steps

### 1. Initialize

```bash
# Detect container mode
CONTAINER_MODE=false
if [ "$CLAUDE_CONTAINER_MODE" = "true" ] || [ -f "/.dockerenv" ] || [ ! -t 0 ]; then
    CONTAINER_MODE=true
    echo "Container mode detected - running non-interactively"
    AUTO_MODE=true  # Force auto mode in containers
fi

# Gather all data in single script call (container-aware)
DATA=$(./scripts/pr/pr-iterate-data.sh --max "${MAX:-3}" ${CONTAINER_MODE:+--container})

# Check for errors
if [ "$(echo "$DATA" | jq -r '.has_pr')" = "false" ]; then
  echo "Error: $(echo "$DATA" | jq -r '.error')"
  echo "$(echo "$DATA" | jq -r '.suggestion')"
  exit 1
fi

# Extract PR info from cached data
PR_NUMBER=$(echo "$DATA" | jq -r '.pr.number')
PR_TITLE=$(echo "$DATA" | jq -r '.pr.title')
echo "Starting review iteration for PR #${PR_NUMBER}: ${PR_TITLE}"

# Get iteration config from cached data (includes container-aware defaults)
MAX_ITERATIONS=$(echo "$DATA" | jq -r '.iteration_config.max_iterations')
CURRENT_ITERATION=$(echo "$DATA" | jq -r '.review_state.iteration')
PR_STATUS_FILE=$(echo "$DATA" | jq -r '.status_file // "pr-status.json"')

echo "Using status file: ${PR_STATUS_FILE}"

# Check if we should continue
if [ "$(echo "$DATA" | jq -r '.iteration_config.can_iterate')" = "false" ]; then
  REASON=$(echo "$DATA" | jq -r '.iteration_config.stop_reason')
  case "$REASON" in
    already_approved)
      echo "PR already approved - no iteration needed"
      ;;
    max_iterations_reached)
      echo "Max iterations ($MAX_ITERATIONS) already reached"
      ;;
    pr_already_merged)
      echo "PR already merged - nothing to iterate"
      ;;
    pr_closed)
      echo "PR is closed - cannot iterate"
      ;;
  esac
  exit 0
fi
```

### 2. Iteration Loop

```
while CURRENT_ITERATION < MAX_ITERATIONS:
    CURRENT_ITERATION++

    echo "=== Iteration ${CURRENT_ITERATION}/${MAX_ITERATIONS} ==="

    # Step 2a: Run review
    /pr-review-internal

    # Step 2b: Check status (read from local file, no API call)
    STATUS=$(jq -r '.review_state.status' pr-status.json)

    if STATUS == "approved":
        echo "PR approved after ${CURRENT_ITERATION} iteration(s)"
        break

    if STATUS == "needs_fixes":
        BLOCKING_COUNT=$(jq '[.blocking_issues[] | select(.status=="open")] | length' pr-status.json)
        echo "Found ${BLOCKING_COUNT} blocking issue(s)"

        # Step 2c: Run fixes
        /pr-fix

        # Step 2d: Push changes
        git push

        # Continue to next iteration

    if STATUS == "incomplete":
        echo "Review incomplete (agent timeout?)"
        # Prompt for manual intervention unless --auto
        if not AUTO_MODE:
            prompt "Continue iteration? [y/n]"
```

### 3. Review Phase

For each iteration, invoke `/pr-review-internal`:

```
Use the Skill tool to invoke /pr-review-internal

The skill will:
1. Run all PR review agents (code, test, docs, security)
2. Collect findings into pr-status.json
3. Generate review-findings.md
4. Set review_status to "approved" or "needs-fixes"
```

**Skip security option:**

If `--skip-security` flag is set, pass it to the review:

```
/pr-review-internal --skip-security
```

### 4. Fix Phase

When status is "needs-fixes", invoke `/pr-fix`:

```
Use the Skill tool to invoke /pr-fix

The skill will:
1. Read blocking_issues from pr-status.json
2. Group issues by owning agent
3. Invoke each agent to fix their issues
4. Create commits for fixes
5. Update pr-status.json with resolved issues
```

### 5. Push Changes

After fixes are applied:

```bash
# Push to remote
git push

# Update iteration count in pr-status.json
jq --arg iter "$CURRENT_ITERATION" \
  '.iteration = ($iter | tonumber)' \
  pr-status.json > pr-status.json.tmp && mv pr-status.json.tmp pr-status.json
```

### 6. Check Exit Conditions

After each iteration:

```
if review_status == "approved":
    # Success - PR ready to merge
    exit with success summary

if CURRENT_ITERATION >= MAX_ITERATIONS:
    # Max iterations reached
    exit with warning and manual intervention guidance

if review_status == "incomplete":
    # Agent failures or timeouts
    if AUTO_MODE:
        continue to next iteration
    else:
        prompt user for guidance
```

### 7. Final Status Report

After loop completes:

```
## PR Iteration Complete

**PR:** #{number} - {title}
**Final Status:** {approved|needs-fixes|incomplete}
**Iterations:** {current}/{max}

### Iteration History

| Iteration | Errors Found | Errors Fixed | Status |
|-----------|--------------|--------------|--------|
| 1 | 5 | 5 | needs-fixes |
| 2 | 2 | 2 | needs-fixes |
| 3 | 0 | 0 | approved |

### Summary

{if approved}
PR is approved and ready for merge.

**Next Steps:**
1. Final manual review (optional)
2. Merge: `gh pr merge --squash --delete-branch`
{/if}

{if needs-fixes after max iterations}
Max iterations ({max}) reached with {remaining} blocking issues.

**Remaining Issues:**
{list of unresolved issues}

**Recommendations:**
1. Review remaining issues manually
2. Increase max iterations: `/pr-iterate --max 5`
3. Fix complex issues manually, then re-run
{/if}

{if incomplete}
Review incomplete due to agent failures.

**Failed Agents:**
{list of failed/timed-out agents}

**Recommendations:**
1. Check agent logs for errors
2. Run individual reviews: `/pr-review-internal --agents code`
3. Fix issues manually if agents continue to fail
{/if}
```

## Output Format

### During Iteration

```
## PR Iterate: Iteration 1/3

**PR:** #156 - Add user authentication

### Running Review...

[Invoking /pr-review-internal]
- pr-code-reviewer: 2 errors, 1 warning
- pr-test: 0 errors, 3 warnings
- pr-documentation: 0 errors
- pr-security-iam: 1 error

**Status:** needs-fixes (3 blocking issues)

### Running Fixes...

[Invoking /pr-fix]
- backend-developer: Fixed 2 issues
- frontend-developer: Fixed 1 issue

**Commits:** 2 new commits

### Pushing Changes...

[git push]
Branch 'feat/issue-123' pushed to origin

---
Continuing to iteration 2/3...
```

### Final Success

```
## PR Iterate Complete

**PR:** #156 - Add user authentication
**Status:** APPROVED
**Iterations:** 2/3

### Summary

The PR passed review after 2 iterations.

| Metric | Value |
|--------|-------|
| Total issues found | 5 |
| Total issues fixed | 5 |
| Commits created | 3 |
| Agents invoked | 2 |

### Next Steps

1. Merge the PR:
   ```bash
   gh pr merge --squash --delete-branch
   ```

2. Or review manually first:
   ```bash
   gh pr view --web
   ```
```

### Max Iterations Reached

```
## PR Iterate: Max Iterations Reached

**PR:** #156 - Add user authentication
**Status:** needs-fixes
**Iterations:** 3/3 (max reached)

### Remaining Issues (2)

1. **src/auth/service.py:92** (error)
   Complex race condition in session handling
   Agent: backend-developer (attempted fix failed)

2. **src/auth/service.py:145** (error)
   Architectural issue: circular dependency
   Agent: unknown (no owning agent)

### Recommendations

These issues require manual intervention:

1. **Race condition:** Consider using mutex or transaction
2. **Circular dependency:** May need architectural refactor

After manual fixes:
```bash
git add -A && git commit -m "fix: manual fixes for review issues"
git push
/pr-iterate  # Re-run iteration
```
```

## Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--max N` | Maximum iterations before stopping | 3 (2 in container) |
| `--auto` | Non-interactive mode (no prompts) | false (true in container) |
| `--skip-security` | Skip security review for faster iterations | false |

## Error Handling

### No PR Found

```
Error: No PR found for current branch

Create a PR first:
  gh pr create --base dev --title "feat(#123): Description"
```

### Agent Timeout

```
Warning: pr-security-iam timed out during iteration 2

Options:
1. Continue without security review
2. Retry security review
3. Skip security: /pr-iterate --skip-security

Select [1/2/3]:
```

### Push Failed

```
Error: Failed to push changes

Possible causes:
1. Remote branch has new commits (pull first)
2. Branch protection rules blocking push
3. Network issues

Recommendations:
1. Pull latest: git pull --rebase
2. Resolve conflicts if any
3. Re-run: /pr-iterate
```

## Notes

- **WRITE operation** - Modifies code, creates commits, pushes to remote
- **Invokes other skills** - Uses /pr-review-internal and /pr-fix
- **Default max: 3** - Prevents infinite loops; increase with --max if needed
- **Auto mode** - Use --auto for CI/CD or unattended operation
- **Worktree aware** - Designed to run from issue worktrees
- **Container aware** - Automatically detects container context and enables auto mode
- **Idempotent** - Safe to run multiple times; continues from current state
- **Status persistence** - Writes to pr-status.json for cross-session state tracking
- **Data script** - Uses `./scripts/pr/pr-iterate-data.sh` for efficient data gathering
- **Token optimized** - See Token Optimization section for efficiency details
