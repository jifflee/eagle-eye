---
description: Batch merge mergeable PRs for milestone (validates before merging)
argument-hint: "[--milestone NAME] [--dry-run] [--pr NUMBER]"
---

# PR Merge

Batch merge PRs that are ready (MERGEABLE + CLEAN) for the current milestone.

## Usage

```
/pr-merge                    # Auto-merge all MERGEABLE+CLEAN PRs, sync, cleanup containers
/pr-merge --milestone X      # Specific milestone
/pr-merge --dry-run          # Preview only (no merges)
/pr-merge --pr N             # Merge specific PR
/pr-merge --no-sync          # Skip automatic git pull after merge
/pr-merge --no-cleanup       # Skip container cleanup after merge
/pr-merge --cleanup-only     # Run only the container cleanup sweep (no merging)
```

## Prerequisites

**Ensure you are in the repository root before running.**

```bash
cd "$(git rev-parse --show-toplevel)"
```

**Safeguards:**
- Validate PR is still mergeable before executing merge (state may change)
- Use squash merge to maintain clean history

**Default Behavior (Auto-Merge):**
- Automatically merges all MERGEABLE+CLEAN PRs without prompting
- After merging, syncs local branch with `git pull origin dev`
- Cleans up stopped containers for issues whose PRs were just merged
- Runs a sweep to cleanup ALL containers with merged/closed issues (not just current session)
- Use `--no-sync` to skip the automatic pull
- Use `--no-cleanup` to skip all container cleanup (both targeted and sweep)
- Use `--cleanup-only` to run just the sweep cleanup without merging any PRs

## Steps

### 1. Gather PR Data

```bash
# Get current milestone
MILESTONE=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.state=="open") | .title' | head -1)

# Get mergeable PRs
gh pr list --json number,title,mergeable,mergeStateStatus,reviewDecision,headRefName \
  --jq '.[] | select(.mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN")'
```

**For specific milestone:**
```bash
gh pr list --search "milestone:\"$MILESTONE\"" \
  --json number,title,mergeable,mergeStateStatus,reviewDecision,headRefName \
  --jq '.[] | select(.mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN")'
```

### 2. Display MERGEABLE PRs

```
### PRs Ready to Merge

| # | PR | Issue | Title | Checks | Review |
|---|-----|-------|-------|--------|--------|
| 1 | #{pr_number} | #{linked_issue} | {title} | Passing | Approved |
| 2 | #{pr_number} | #{linked_issue} | {title} | Passing | No review required |

**Total:** {count} PRs ready to merge
```

**If --dry-run:** Display table and exit without prompting.

### 3. Auto-Merge (Default Behavior)

**Auto-merge is the default.** All MERGEABLE+CLEAN PRs are merged automatically without prompting.

For each MERGEABLE PR:
1. Run PR validation gate (`./scripts/pr/pr-validation-gate.sh {pr_number}`)
2. Block merge if gate returns exit code 1 (FAIL)
3. Run pre-merge validation (GitHub state check)
4. Execute merge if gate + validation pass
5. Report results
6. Sync local branch (unless `--no-sync`)

### 3.5. PR Validation Gate (Replaces GitHub Required Status Checks)

Before merging any PR, run the validation gate to ensure all checks pass.
This gate is the authoritative merge-readiness check for this repository.

```bash
# Run full gate for a specific PR
./scripts/pr/pr-validation-gate.sh {pr_number}

# Quick mode (lint + tests only, skips security and docs)
./scripts/pr/pr-validation-gate.sh {pr_number} --quick

# JSON output for scripted integration
./scripts/pr/pr-validation-gate.sh {pr_number} --json

# Bypass cache and force re-run
./scripts/pr/pr-validation-gate.sh {pr_number} --no-cache
```

**Gate Check Categories:**
| Check | What it validates | Blocks merge? |
|-------|------------------|---------------|
| `tests` | Test suite passes, test existence | Yes (fail) |
| `security` | No critical/high CVEs or secrets | Yes (fail) |
| `quality` | Code quality, naming conventions | No (warn) |
| `docs` | Documentation freshness | No (warn) |
| `lint` | Script linting, shellcheck | Depends |

**Gate Exit Codes:**
- `0` - PASS: all checks passed, merge is cleared
- `1` - FAIL: checks failed, **merge is BLOCKED**
- `2` - WARN: passed with warnings, merge cleared with caution
- `3` - ERROR: gate could not run (script/API failure)

**If gate FAILS:**
```
✗ GATE BLOCKED - 2 check(s) failed - merge is BLOCKED

[TESTS] FAILED
  2 tests failing in tests/unit/
  Remediation:
    • Fix failing tests before merging: ./scripts/test-runner.sh

[SECURITY] FAILED
  Critical/high security findings detected
  Remediation:
    • Fix critical/high security findings before merging
    • View report: cat security-report.json
```

**Emergency bypass** (use only when gate is broken, not when checks fail):
```bash
PR_GATE_SKIP=1 gh pr merge {pr_number} --squash --delete-branch
```

**Integration:** `/pr-merge` automatically runs the gate for each PR before merging.
Cache results are stored in `.pr-gate-cache/` and valid for 30 minutes per HEAD SHA.

### 4. Pre-merge Validation (per PR)

Before executing merge, verify PR is still mergeable:

```bash
gh pr view {pr_number} --json mergeable,mergeStateStatus,reviewDecision
```

**Validation checklist:**
- `mergeable == "MERGEABLE"` - GitHub confirms merge is possible
- `mergeStateStatus == "CLEAN"` - All status checks passing
- No merge conflicts detected
- Review requirements met (if repo requires reviews)

**If gate fails (exit code 1):**
```
✗ GATE BLOCKED - PR #{pr_number} failed validation

{gate failure report with check details and remediations}

Options:
1. Skip this PR (fix and re-merge later)
2. View full gate report: cat .pr-gate-{pr_number}.json
3. Abort remaining merges
4. Force bypass (emergency only): PR_GATE_SKIP=1

Select [1/2/3/4]:
```

**If GitHub validation fails:**
```
PR #{pr_number} is no longer mergeable

Reason: {validation_failure_reason}

Options:
1. Skip this PR
2. View PR details
3. Abort remaining merges

Select [1/2/3]:
```

### 5. Execute Merge

```bash
gh pr merge {pr_number} --squash --delete-branch
```

**Merge options:**
- `--squash` - Squash commits into single commit (default)
- `--delete-branch` - Delete branch after merge (keeps repo clean)

**Note on linked issues:** If the PR body contains "Fixes #N", "Closes #N", or "Resolves #N",
GitHub will automatically close the linked issue **ONLY if merging to the default branch (main)**.
Since PRs typically merge to `dev` first, issues will NOT auto-close. They must be closed manually
or automatically when promoted to `main` using `./scripts/auto-close-issues-after-promotion.sh`.

### 6. Report Results

```
### Merge Results

| PR | Issue | Result | Notes |
|----|-------|--------|-------|
| #{pr_number} | #{linked_issue} | Merged | Issue remains open (dev branch) |
| #{pr_number} | #{linked_issue} | Failed | {error_reason} |

**Summary:** {merged_count}/{total_count} PRs merged successfully
```

**If any failures occurred:**
- Display error details
- Suggest remediation actions
- Continue with remaining PRs

### 6.5. Check for Unclosed Issues (Warning)

After merging PRs to `dev`, check if any linked issues remain open and warn the user:

```bash
# For each merged PR, extract linked issues
for PR in $MERGED_PRS; do
  LINKED_ISSUES=$(gh pr view $PR --json body -q '.body' | grep -oiE '(fixes|closes|resolves) #[0-9]+' | grep -oE '[0-9]+')

  for ISSUE in $LINKED_ISSUES; do
    ISSUE_STATE=$(gh issue view $ISSUE --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
    if [ "$ISSUE_STATE" = "OPEN" ]; then
      echo "⚠️  Issue #$ISSUE still open after PR #$PR merged (expected for dev branch)"
    fi
  done
done
```

**Display warning:**
```
⚠️  GitHub Limitation: Issues remain open after merging to 'dev'

The following issues are linked to merged PRs but remain OPEN:
  - Issue #614 (PR #615)
  - Issue #611 (PR #613)
  - Issue #610 (PR #616)

These issues will auto-close when promoted to 'main', or you can close them manually:

  # Close all issues from recently merged PRs
  ./scripts/auto-close-issues-after-promotion.sh --recent 10

  # Or close a specific issue manually
  gh issue close 614 --comment "Closed after PR #615 merged to dev"
```

### 7. Sync Local Branch (Auto)

After all merges complete, automatically sync local branch.

**Pre-sync check for uncommitted changes:**

```bash
# Check for uncommitted changes before git pull
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "⚠️  Uncommitted local changes detected:"
  git status --short
  echo ""
  echo "Options:"
  echo "1. Stash changes, sync, then restore"
  echo "2. Skip sync (manual sync later)"
  echo "3. View changes"
  read -p "Select [1/2/3]: " choice

  case $choice in
    1)
      echo "Stashing changes..."
      git stash push -m "pr-merge: auto-stash before sync"
      git pull origin dev
      echo "Restoring stashed changes..."
      git stash pop
      ;;
    2)
      echo "⏭️  Skipping sync. Run 'git pull origin dev' manually when ready."
      # Skip to cleanup step
      ;;
    3)
      git diff
      # After viewing, re-prompt for option 1 or 2
      ;;
  esac
else
  # No uncommitted changes, safe to pull
  git pull origin dev
fi
```

**Skip with:** `--no-sync` flag

**Output (normal case - no uncommitted changes):**
```
Syncing local branch...
✓ Local dev branch updated ({commits_behind} commits pulled)
```

**Output (uncommitted changes detected):**
```
⚠️  Uncommitted local changes detected:
 M scripts/container/container-launch.sh

Options:
1. Stash changes, sync, then restore
2. Skip sync (manual sync later)
3. View changes
Select [1/2/3]: 1

Stashing changes...
Saved working directory and index state On dev: pr-merge: auto-stash before sync
✓ Local dev branch updated (2 commits pulled)
Restoring stashed changes...
On branch dev
Changes not staged for commit:
  modified:   scripts/container/container-launch.sh
```

### 8. Clean Up Merged Containers (Auto)

After merging, automatically clean up containers in two phases:

#### Phase 1: Targeted Cleanup (Current Session)

Clean up stopped containers whose PRs were just merged in this session.

```bash
# Get stopped containers
STOPPED=$(./scripts/container/container-status.sh --json | jq -r '.containers[] | select(.status=="exited") | .issue')

# For each merged issue, clean up its container
for ISSUE in $MERGED_ISSUES; do
  if echo "$STOPPED" | grep -q "^$ISSUE$"; then
    ./scripts/container/container-cleanup.sh --issue "$ISSUE"
  fi
done
```

#### Phase 2: Sweep Cleanup (All Merged/Closed Issues)

Run a comprehensive sweep to catch containers from previously-merged PRs that were missed by earlier cleanup runs.

```bash
# Sweep all stopped containers and check their issue/PR status
./scripts/container/container-cleanup-sweep.sh --force
```

**Sweep Logic:**
1. List ALL stopped `claude-tastic-issue-*` containers
2. For each container, extract the issue number from the name
3. Check if the issue is CLOSED (via `gh issue view`)
4. Check if the issue has a merged PR (via `gh pr list`)
5. If either condition is true, remove the container (with log preservation for failures)

**Output:**
```
Cleaning up containers for merged PRs (targeted)...
✓ Removed container for issue #448
✓ Removed container for issue #123

**Containers cleaned (targeted):** 2

Running container cleanup sweep...
Found 3 container(s) to cleanup (out of 5 stopped):

CONTAINER                           ISSUE      REASON
─────────                           ─────      ──────
claude-tastic-issue-1020            #1020      PR merged
claude-tastic-issue-500             #500       Issue closed
claude-tastic-issue-495             #495       PR merged

Cleanup complete: removed 3 container(s)

**Total containers cleaned:** 5
```

**Skip with:** `--no-cleanup` flag (skips both phases)

**Cleanup-only mode:** Use `--cleanup-only` to run just the sweep cleanup without merging any PRs

## Handling Non-MERGEABLE PRs

For PRs that aren't immediately mergeable, offer appropriate actions:

### Unstable - CI Failing

When a PR has failing checks:

```
PR #{pr_number} has failing CI checks

**Failing Checks:**
| Check | Suggestion |
|-------|------------|
| {check_name} | {remediation_suggestion} |

**Options:**
[r] Re-run failed checks
[v] View check details in browser
[s] Skip for now

Select action:
```

### Blocked - Merge Conflicts

When merge_state is BLOCKED:

```
PR #{pr_number} is blocked

**Reason:** {merge_state_reason}

**To resolve:**
1. Fetch latest: `git fetch origin dev`
2. Rebase: `git rebase origin/dev`
3. Resolve conflicts manually
4. Force push: `git push --force-with-lease`

Skip for now? [y/n]
```

### Behind - Needs Update

When merge_state is BEHIND:

```
PR #{pr_number} needs update from base branch

**Options:**
[u] Update branch (merge base into PR)
[s] Skip for now

Select action:
```

**If 'u' (update):**
```bash
gh api repos/{owner}/{repo}/pulls/{pr_number}/update-branch -X PUT
```

## Output Format

```
## PR Merge

**Milestone:** {name}
**Mode:** {auto|dry-run}

### PRs Ready to Merge

| PR | Issue | Title | Status |
|----|-------|-------|--------|
| #123 | #100 | Add feature X | MERGEABLE ✓ |

Merging {count} PRs...

### Merge Results

| PR | Issue | Result |
|----|-------|--------|
| #123 | #100 | ✅ Merged |

**Summary:** {merged_count}/{total_count} merged

Syncing local branch...
✓ Local dev updated

Cleaning up containers for merged PRs...
✓ Removed container for issue #100

**Containers cleaned:** 1
```

## Dry Run Format

```
## PR Merge (Dry Run)

**Milestone:** {name}

### Would Merge

| PR | Issue | Title | Status |
|----|-------|-------|--------|
| #123 | #100 | Add feature X | MERGEABLE + CLEAN |

**Total:** 1 PR would be merged

(No changes made - dry run mode)
```

## Cleanup-Only Format

```
## PR Merge (Cleanup Only)

Running container cleanup sweep...
Found 5 container(s) to cleanup (out of 8 stopped):

CONTAINER                           ISSUE      REASON
─────────                           ─────      ──────
claude-tastic-issue-1020            #1020      PR merged
claude-tastic-issue-500             #500       Issue closed
claude-tastic-issue-495             #495       PR merged
claude-tastic-issue-123             #123       Issue closed
claude-tastic-issue-100             #100       PR merged

Cleanup complete: removed 5 container(s)

**Total containers cleaned:** 5
```

## Token Optimization

- **Data gathering:** Inline gh commands (no data script yet)
- **API calls:** 2 per PR (list + view for validation)
- **Optimization opportunity:** Could add `pr-merge-data.sh` for batching

## Notes

- This is a WRITE operation - it modifies the repository
- **Auto-merge is the default** - no confirmation prompt needed
- **Auto-sync is the default** - runs `git pull origin dev` after merging
- **Auto-cleanup is the default** - removes stopped containers for merged issues (two-phase cleanup)
  - **Phase 1:** Targeted cleanup of containers from PRs merged in the current session
  - **Phase 2:** Sweep cleanup of ALL containers with closed issues or merged PRs
- Uses squash merge by default for clean history
- Deletes source branch after merge
- Linked issues are auto-closed by GitHub when PR body contains "Fixes #N"
- PRs must pass validation check before merge (state may change between display and merge)
- Use `--dry-run` to preview without making changes
- Use `--no-sync` to skip automatic local branch sync
- Use `--no-cleanup` to skip all container cleanup (both phases)
- Use `--cleanup-only` to run just the sweep cleanup without merging any PRs
- For worktree-safe merging, use `./scripts/worktree/worktree-safe-merge.sh`
- Container cleanup sweep uses `./scripts/container/container-cleanup-sweep.sh` (Issue #1032)
