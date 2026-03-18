---
description: Automatically work through milestone issues from backlog to completion following SDLC workflow
---

# Sprint Work

Orchestrates working through backlog issues in the active milestone, running each through SDLC phases.

## Usage

```
/sprint-work                  # Auto-detect issue from worktree, or select from backlog
/sprint-work --issue N        # Work on specific issue (overrides auto-detect)
/sprint-work --epic N         # Work on children of epic #N
/sprint-work --dry-run        # Show what would be done
/sprint-work --issue N --container         # Run in Docker container (detached by default)
/sprint-work --issue N --container --sync  # Run in Docker container (synchronous/foreground)
/sprint-work --issue N --container --image IMAGE  # Use specific Docker image
```

## Worktree Auto-Detection

When running `/sprint-work` without the `--issue` flag in a worktree, the command
automatically detects the issue number from the directory name.

**Pattern:** `*-issue-{N}` (e.g., `claude-tastic-issue-192`)

**Example:**
```bash
# In directory: /path/to/claude-tastic-issue-192
/sprint-work  # Automatically works on issue #192
```

**Behavior:**
- If in a worktree matching `*-issue-{N}`, uses issue #{N} automatically
- Shows message: "Working on issue #N (from worktree context)"
- Manual `--issue N` flag always overrides auto-detection
- If not in a worktree (or no pattern match), prompts for issue selection from backlog

## Autonomous Execution Mode

Issues can be automatically routed to container or worktree execution mode without
manual `--container` flags. The system detects the appropriate mode automatically.

**Automatic Mode Detection:**

The preflight script (`sprint-work-preflight.sh`) calls `detect-execution-mode.sh` to
determine execution mode:

1. **Label-based**: Issues with `execution:container` label use container mode
2. **Label-based**: Issues with `execution:worktree` label use worktree mode
3. **Body-based**: Issue body containing `## Execution Mode: container` uses container
4. **Config-based**: Default mode from `~/.claude-tastic/config.json`
5. **Fallback**: Worktree mode (current default behavior)

**Example - Setting Container Mode via Label:**
```bash
# Add label to force container execution for an issue
gh issue edit 204 --add-label "execution:container"

# Now /sprint-work will auto-detect and launch in container
/sprint-work --issue 204  # No --container flag needed!
```

**Example - Setting via Issue Body:**
```markdown
## Execution Mode: container

## Summary
This issue requires container isolation because...
```

**Configuration File (`~/.claude-tastic/config.json`):**
```json
{
  "default_execution_mode": "container"
}
```

**Automatic Token Loading:**

Container mode automatically loads tokens from macOS Keychain:
- `GITHUB_TOKEN` from keychain entry `github-container-token`
- `CLAUDE_CODE_OAUTH_TOKEN` from keychain entry `claude-oauth-token`
- Falls back to `gh auth token` for GitHub if keychain not available

No manual `eval "$(./scripts/container/load-container-tokens.sh load)"` required!

**Container Mode Behavior (Non-Interactive):**

When running in container mode, Claude operates autonomously without user prompts:

1. **Detect container mode** by checking:
   - Environment variable `CLAUDE_CONTAINER_MODE=true`
   - No TTY available (`[ ! -t 0 ]`)
   - Running inside Docker (presence of `/.dockerenv`)

2. **Auto-approve the following without prompting:**
   - Git commits (commit after each phase)
   - Git push to feature branch
   - PR creation targeting `dev` branch
   - Issue label updates (in-progress, etc.)

3. **Still require human review:**
   - PR merge (happens outside container)
   - Issue closure (triggered by PR merge)

**Container detection in Claude:**
```bash
# Check if running in container mode
if [ "$CLAUDE_CONTAINER_MODE" = "true" ] || [ -f "/.dockerenv" ] || [ ! -t 0 ]; then
    # Auto-approve push and PR creation
    git push origin HEAD
    gh pr create --base dev --fill
fi
```

**Why auto-approve in containers?**
- Containers are ephemeral - work is lost if not pushed
- No interactive terminal for user input
- Container lifecycle is managed externally
- PR review happens after container exits

**Sprint Orchestrator (Fully Autonomous Execution):**

For continuous backlog processing without intervention:

```bash
# Process all backlog issues automatically
./scripts/sprint/sprint-orchestrator.sh

# Process max 5 issues
./scripts/sprint/sprint-orchestrator.sh --max-issues 5

# Dry run to preview
./scripts/sprint/sprint-orchestrator.sh --dry-run

# Specific milestone
./scripts/sprint/sprint-orchestrator.sh --milestone "sprint-1/13"
```

The orchestrator:
1. Selects highest priority issue from backlog
2. Detects execution mode (worktree vs container) automatically
3. Loads tokens from macOS Keychain
4. Launches execution (container or worktree)
5. Creates PR
6. Loops to next issue until backlog empty

**Container Mode (`--container`):**
When using `--container` flag:
- Launches work in an isolated Docker container instead of a local worktree
- Runs in **detached mode by default** (fire-and-forget, non-blocking)
- Use `--sync` or `--foreground` flag for synchronous execution (blocks terminal)
- No host filesystem access (security isolation)
- Tokens passed via environment variables
- Container clones repo, creates branch, does work, creates PR
- Results reported back to user after container completes

**Container Token Optimization:**
Container mode uses `container-sprint-workflow.sh` for token efficiency:
- **Before**: Claude loaded full 800-line sprint-work.md skill and reasoned through every step
- **After**: Script handles orchestration, Claude only does implementation work
- **Savings**: ~50-70% token reduction

The workflow script:
1. Reads issue context from pre-injected environment variables (no API calls)
2. Updates labels via direct `gh` commands (no Claude reasoning)
3. Invokes Claude with focused implementation prompt only
4. Handles post-work (commit, push, PR) via direct commands

**Detached Mode (Default for Container Execution):**

Container mode runs detached by default to work on multiple issues simultaneously:

```bash
# Launch multiple containers in parallel (default behavior)
/sprint-work --issue 211 --container
/sprint-work --issue 212 --container
/sprint-work --issue 213 --container

# Continue working in current terminal while containers run
```

**Synchronous mode (when you need to wait):**
```bash
# Run synchronously and wait for completion
/sprint-work --issue N --container --sync
/sprint-work --issue N --container --foreground

# Or use the direct script with --sync
./scripts/container/container-launch.sh --issue N --repo OWNER/REPO --sprint-work --sync
```

**Backward compatibility:**
```bash
# --fire-and-forget is still supported (deprecated, same as default)
/sprint-work --issue N --fire-and-forget
/sprint-work --issue N --container --detach  # Explicit detach (same as default)
```

**Monitoring Detached Containers:**

```bash
# Check container status (human-readable)
./scripts/container/container-status.sh

# Check specific issue
./scripts/container/container-status.sh 211

# JSON output (for sprint-status integration)
./scripts/container/container-status.sh --json

# View container logs
docker logs -f claude-tastic-issue-211

# Stop a container
./scripts/container/container-launch.sh --stop 211

# Cleanup all stopped containers
./scripts/container/container-launch.sh --cleanup
```

**Integration with /sprint-status:**

Container status is automatically included in `/sprint-status` output:

```
### Active Containers

| Issue | Status | Age | Last Activity |
|-------|--------|-----|---------------|
| #211 | running | 5m | Just now |
| #212 | completed | 12m | 2m ago |
| #213 | failed | 8m | 5m ago |

**Summary:** 1 running, 1 completed, 1 failed
```

**Container Lifecycle:**
- `running` - Container actively executing sprint-work
- `stopped` - Exited cleanly (exit code 0), PR likely created
- `failed` - Exited with error (exit code != 0), check logs
- `orphan` - Running > 24h with no activity (may be stuck)

**Epic Mode (`--epic N`):**
When working on an epic's children:
- Lists all issues with `parent:N` label
- Prioritizes by P0 > P1 > P2 > P3, then type, then age
- Shows epic completion status before and after each issue
- Can spawn parallel worktrees for independent children

## Steps

### 0. Container Mode Check (if --container flag)

**If `--container` flag is present, use containerized execution instead of worktree:**

```bash
# Step 0a: Check Docker availability
if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker is not installed or not in PATH"
  echo "Falling back to worktree mode..."
  # Continue to Step 0.1 (Worktree Pre-flight)
fi

if ! docker info &> /dev/null; then
  echo "ERROR: Docker daemon is not running"
  echo "Falling back to worktree mode..."
  # Continue to Step 0.1 (Worktree Pre-flight)
fi

# Step 0b: Get repository info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Step 0c: Launch container with streamlined sprint-work mode
# This auto-loads tokens from keychain and runs detached by default
./scripts/container/container-launch.sh \
  --issue "$ISSUE_NUMBER" \
  --repo "$REPO" \
  --sprint-work

# Container runs in background by default
# Use --sync flag for synchronous execution:
# ./scripts/container/container-launch.sh --issue "$ISSUE_NUMBER" --repo "$REPO" --sprint-work --sync

# For detached mode (default), container status available via:
# - ./scripts/container/container-status.sh
# - /sprint-status (shows container section)
exit 0
```

**Execution Modes:**

| Mode | Flag | Use Case | Behavior |
|------|------|----------|----------|
| Detached (default) | `--sprint-work` | Most tasks | Background execution, non-blocking |
| Synchronous | `--sprint-work --sync` | Debug/interactive | Foreground execution, blocks terminal |
| Complex | `--exec-mode complex` | Long tasks (deprecated) | Detached with polling/heartbeat |

**Detached mode (default for --sprint-work):**
- Container runs in background
- Terminal returns immediately
- Monitor via `container-status.sh` or `/sprint-status`
- No output streamed (view logs with `docker logs -f`)

**Synchronous mode (with --sync flag):**
```bash
./scripts/container/container-launch.sh \
  --issue "$ISSUE_NUMBER" \
  --repo "$REPO" \
  --sprint-work \
  --sync
```
- Blocks terminal until complete
- Output streamed to terminal
- Hard timeout enforced (default: 30 min)
- Useful for debugging or when you need immediate results

**Container mode output format:**
```
## Container Sprint Work

**Mode:** Containerized (isolated execution)
**Issue:** #{number}: "{title}"
**Image:** {image_name}

[Container launching...]
[Container output streamed here...]

**Container completed**
**PR created:** https://github.com/{owner}/{repo}/pull/{N}
```

**If Docker unavailable:** Falls back to worktree mode with a warning message.

### 0.1. Worktree Pre-flight (MANDATORY - DO NOT SKIP)

**STOP: This step MUST be executed FIRST before any other action.**

```bash
./scripts/sprint/sprint-work-preflight.sh [ISSUE_NUMBER]
```

**JSON action handling:**

The script outputs JSON to stdout. Parse the `action` field:

| Action | Meaning | Next Step |
|--------|---------|-----------|
| `continue` | Safe to proceed | Go to Step 1 |
| `switch` | Worktree exists | STOP - user must switch terminals |
| `created` | Worktree created | STOP - user must switch terminals |
| `error` | Something failed | Investigate the error message |

**If action is `switch` or `created`:**
```
DO NOT PROCEED. The script has printed handoff instructions.
The user MUST switch to the worktree terminal and run sprint-work there.
EXIT this sprint-work session NOW.
```

**If action is `continue`:**
- Sprint state cached to `.sprint-state.json` (use this instead of API calls)
- Proceed to Step 1 (Initialize Session)

**If action is `error`:**
- Check stderr for error details (exit code will be 2)

**Bypass (rare):** Only use `--force` flag for meta-fixes (e.g., fixing sprint-work itself):
```bash
./scripts/sprint/sprint-work-preflight.sh 26 --force
```

**Read-only mode:** For read-only operations (status checks, audits, queries), use `--read-only`:
```bash
./scripts/sprint/sprint-work-preflight.sh 26 --read-only
```
See `/docs/WORKTREE_OPERATIONS.md` for operation classification.

### 1. Initialize Session

**If working on specific issue (--issue N):** Read from cache (no API calls needed):
```bash
# Issue data already cached by preflight
./scripts/sprint/read-sprint-state.sh issue         # Full issue details
./scripts/sprint/read-sprint-state.sh issue.title   # Just title
./scripts/sprint/read-sprint-state.sh pr.exists     # Check if PR exists
```

**If discovering next issue:** Query milestone backlog:
```bash
MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '.[] | select(.state=="open") | .title' | head -1)
gh issue list --milestone "$MILESTONE" --label "backlog" --json number,title,labels,createdAt
```

### 2. Select Next Issue

**Standard Mode:**
Priority order: P0 > P1 > P2 > P3
Within priority: bug > feature > tech-debt > docs > oldest first

Skip: `blocked`, `in-progress`, `needs-triage`

**Four Wise Men Debate (when multiple issues at same priority):**

When multiple backlog issues share the same priority (e.g., three P2 features), use the Four Wise Men framework to determine order:

```bash
# Detect if debate is needed
SAME_PRIORITY_COUNT=$(gh issue list --milestone "$MILESTONE" --label "backlog" --label "P2" --json number | jq length)

if [ "$SAME_PRIORITY_COUNT" -gt 1 ]; then
  echo "Multiple P2 issues found. Running Four Wise Men debate..."
  # Invoke wise-men-debate for each candidate
  # See /wise-men-debate command for details
fi
```

**Debate flow:**
1. Gather candidate issues at the same priority level
2. Run `/wise-men-debate` for each (or top 3-5 if many)
3. Order by consensus score:
   - PROCEED NOW + ESSENTIAL + ALIGNED → First
   - WAIT + VALUABLE + COMPATIBLE → Middle
   - DEFER + OPTIONAL + TANGENTIAL → Last
4. Present ordered list to user for confirmation

**Skip debate when:**
- Only one issue at the top priority
- User specifies `--issue N` explicitly
- `--no-debate` flag is used

**Epic Mode (`--epic N`):**

When `--epic N` flag is provided, query children of the specified epic:

```bash
# Get epic status first
./scripts/find-parent-issues.sh --epic-status N

# List children in backlog
gh issue list --label "parent:N" --label "backlog" --json number,title,labels,createdAt
```

**Display epic status:**
```
## Working on Epic #45: Auth System Refactor

**Progress:** 2/5 children closed (40%)

Open children:
| # | Priority | Type | Title | Status |
|---|----------|------|-------|--------|
| #47 | P1 | bug | Fix session timeout | backlog |
| #48 | P2 | feature | Add 2FA | backlog |
| #49 | P2 | feature | Add OAuth | in-progress |

Select next issue or [a]ll independent in parallel:
```

**Parallel Execution (Advanced):**

When children are independent (no inter-dependencies), spawn parallel worktrees:

```bash
# Step 1: Detect parallel candidates
./scripts/issue-dependencies.sh --parallel-candidates

# Returns JSON with:
# - parallel_candidates: Issues with no interdependencies
# - foundational_first: Issues that others depend on (do these first)
# - recommendation: Suggested action
```

**Example output:**
```json
{
  "summary": {
    "total_backlog": 5,
    "parallel_ready": 3,
    "foundational": 1
  },
  "parallel_candidates": [
    {"number": 162, "title": "Add PR check validation", "priority": 2},
    {"number": 160, "title": "Add PR merge handling", "priority": 2}
  ],
  "foundational_first": [
    {"number": 156, "title": "Add PR lifecycle labels", "priority": 1}
  ],
  "recommendation": "Work on foundational issues first: #156"
}
```

**Spawning parallel worktrees:**
```bash
# Spawn worktrees for specific issues
./scripts/worktree/spawn-parallel-worktrees.sh 162 160 157

# Or auto-detect and spawn from candidates
./scripts/worktree/spawn-parallel-worktrees.sh --from-candidates --max 3

# Dry run to preview
./scripts/worktree/spawn-parallel-worktrees.sh --from-candidates --dry-run
```

**After spawning, each worktree is independent:**
```
# Terminal 1
cd ../repo-issue-162 && claude /sprint-work --issue 162

# Terminal 2
cd ../repo-issue-160 && claude /sprint-work --issue 160

# Terminal 3
cd ../repo-issue-157 && claude /sprint-work --issue 157
```

**Prompt for parallel execution:**
```
Issues #47, #48, and #50 have no interdependencies.
Run in parallel worktrees? [y/n/select]

y = Spawn all 3 worktrees
n = Continue with single issue
select = Choose which issues to parallelize
```

### 3. Pre-flight Validation

Check issue has sufficient context (min score: 40):
- Bug: reproduction_steps, expected/actual behavior
- Feature: acceptance_criteria
- Tech-debt: problem, proposed_solution

**If fails:** Skip (add `needs-triage`), provide context, or proceed anyway

### 3.5 Already-Complete Detection

Before starting work, check if implementation already exists.

**CRITICAL LIMITATION:** Artifact detection alone is NOT sufficient for closure.
Finding files/code does not prove the feature works. See [Issue #244](https://github.com/jifflee/claude-tastic/issues/244).

**Two-Phase Detection:**

**Phase 1: Artifact Detection (Quick Check)**
1. Parse acceptance criteria from issue body (lines starting with `- [ ]`)
2. For each criterion, search codebase for evidence:
   - File existence checks (glob patterns)
   - Function/class existence (grep)
   - Feature presence in configs
3. Calculate artifact score (artifacts found / total criteria)

**Phase 2: Behavioral Verification (Required for Closure)**

If artifact score >= 80%, run behavioral verification:

| Issue Type | Verification Method |
|------------|---------------------|
| CLI flag | Execute command with flag, verify behavior |
| Script | Run script with test inputs, check outputs |
| Feature | Run tests or execute feature manually |
| Bug fix | Reproduce original bug scenario, verify fixed |
| Documentation | Check docs are accurate to implementation |

**Verification Examples:**
```bash
# CLI flag verification (e.g., --container flag)
./sprint-work.sh --issue 123 --container 2>&1 | grep -q "Container mode"
# If grep fails → feature doesn't work despite artifacts

# Script verification
./scripts/some-script.sh --test-mode
# Check exit code and output

# Feature verification (run related tests)
pytest tests/test_feature.py -v
# If tests pass → feature works
```

**Detection Flow:**
```
1. Extract acceptance criteria from issue body
2. Phase 1 - Artifact Detection:
   - Search for files, functions, configs
   - Calculate artifact_score
3. If artifact_score < 80%:
   - Continue to SDLC (not complete)
4. If artifact_score >= 80%:
   - Phase 2 - Behavioral Verification:
     a. Identify verification method for each criterion
     b. Execute verification (run tests, commands, etc.)
     c. Calculate behavior_score
5. Decision based on behavior_score:
   - behavior_score >= 80%: Offer to close (verified complete)
   - behavior_score < 80%: Add "needs-verification" label, continue SDLC
   - Cannot verify: Warn user, proceed with SDLC
```

**Example - Artifact Found BUT Behavior Fails:**
```
Issue: "Add --container flag to sprint-work"
Criteria: "- [ ] Add --container flag support"

Phase 1 (Artifacts):
  → Searching: "container" in sprint-work.md
  → FOUND: Documentation mentions --container flag
  → Artifact score: 100% (1/1)

Phase 2 (Behavior):
  → Executing: ./scripts/sprint/sprint-work-preflight.sh 123 --container
  → Expected: Container mode activated
  → Actual: Created worktree (flag ignored!)
  → Behavior score: 0% (0/1)

Result: FAIL - Artifacts exist but feature doesn't work
Action: Continue SDLC to fix implementation
```

**User Prompt (Artifacts Found):**
```
Artifacts detected for {issue_count} criteria:
- [x] sprint-work.md mentions --container (artifact exists)
- [x] container-launch.sh exists (artifact exists)

Running behavioral verification...

Verification Results:
- [ ] --container flag activates container mode (FAILED - worktree created instead)

Artifact Score: 100% | Behavior Score: 0%

⚠️ WARNING: Artifacts exist but feature does NOT work as expected.

Options:
1. Continue with SDLC (fix the implementation)
2. Add "needs-verification" label and skip (for later triage)
3. Inspect findings in detail

Select [1/2/3]:
```

**Auto-Close Criteria (ALL required):**
- Artifact score >= 80%
- Behavior score >= 80%
- User confirms closure

**If behavioral verification is not possible:**
```
⚠️ Cannot verify behavior automatically.

Artifacts found but no automated verification available.
Manual testing required before closure.

Options:
1. Proceed with SDLC (safest)
2. Add "needs-verification" label
3. Close with manual verification note (requires user attestation)

Select [1/2/3]:
```

**Closing with Verified Behavior:**
```bash
gh issue close $ISSUE --comment "Verified complete - implementation exists AND works.

**Artifact Detection:**
- [criterion]: [artifact found]

**Behavioral Verification:**
- [criterion]: [verification method] → PASS

Closed by /sprint-work auto-detection with behavioral verification."
```

### 4. Start Work

```bash
gh issue edit $ISSUE --remove-label "backlog" --add-label "in-progress"
```

### 5. Execute SDLC Phases

**Feature:** spec → design → implement → test → docs
**Bug:** analysis → fix → regression test
**Tech-debt:** plan → refactor → verify tests
**Docs:** write documentation

Use appropriate agents per phase. Commit after each phase.

**Requirement Monitoring (Between Phases):**

Check for issue changes between SDLC phases to incorporate feedback:

```bash
# Initialize monitoring at start of work
./scripts/issue-monitor.sh --issue $ISSUE --init

# Check for changes between each phase
if ! ./scripts/issue-monitor.sh --issue $ISSUE --check --quiet; then
  # Changes detected - review and incorporate
  echo "Requirement changes detected! Review before continuing."
  ./scripts/issue-monitor.sh --issue $ISSUE --check  # Show details
fi
```

**What triggers re-evaluation:**
- Issue body updated (requirements/AC changes)
- New comments added (design feedback, clarifications)
- Labels changed (blocked, priority shift)
- Issue state changed (closed by someone else)

**Agent response to changes:**
```
## Requirement Update Detected

**Changed:** [body, comments, labels]

**Summary of changes:**
- Acceptance criteria updated with new requirement X
- PM added clarification comment about Y

**Options:**
1. Incorporate changes and continue
2. Review changes in detail
3. Pause and request human decision

Select [1/2/3]:
```

**For containerized execution**, the container runs monitoring in background:
```bash
# Container entrypoint starts background monitor
./scripts/issue-monitor.sh --issue $ISSUE --poll 60 &
MONITOR_PID=$!

# ... container does work ...

# Stop monitor on exit
kill $MONITOR_PID 2>/dev/null
```

### 6. Create PR (Worktree Exit Point)

```bash
# Check for existing PR (from cache first, then API as fallback)
PR_EXISTS=$(./scripts/sprint/read-sprint-state.sh pr.exists 2>/dev/null || echo "null")
if [ "$PR_EXISTS" = "true" ]; then
  git push  # Adds commits to existing PR
else
  gh pr create --base dev --title "[type]: {title}" --body "Fixes #$ISSUE"
fi
```

**WORKTREE EXIT POINT:** After PR creation, the worktree's work is **complete**.

Per the [Worktree Merge Strategy](/docs/BRANCHING_STRATEGY.md#worktree-merge-strategy):
- Worktrees do NOT merge PRs themselves
- PR review and merge happens via GitHub UI or main repo
- Worktree can be cleaned up after PR is created

**What to tell the user:**
```
PR created: https://github.com/{owner}/{repo}/pull/{N}

Worktree work is complete. Next steps:
1. Review and merge PR via GitHub UI
2. Cleanup worktree: ./scripts/worktree/worktree-cleanup.sh {issue}
   (Run from main repo, not this worktree)
```

### 6b. Auto-Completion Flow (Optional)

For automated completion (merge, issue closure, cleanup), use the `worktree-complete.sh` script:

```bash
# Auto-complete with CI wait
./scripts/worktree/worktree-complete.sh --wait

# Auto-complete specific issue
./scripts/worktree/worktree-complete.sh --issue $ISSUE --wait --auto
```

**What it does:**
1. Verifies all commits are pushed
2. Creates PR if not exists
3. Waits for CI to pass (with `--wait`)
4. Auto-merges PR when conditions met
5. Verifies issue is closed
6. Provides cleanup instructions

**Options:**
- `--wait` - Wait for CI to complete before merging
- `--auto` - Non-interactive mode (auto-confirm prompts)
- `--skip-cleanup` - Don't show cleanup instructions
- `--dry-run` - Show what would be done without executing

**When merge is blocked:**
- **CI failing**: Shows failing checks and remediation guidance
- **Needs approval**: Prompts to request review
- **Conflicts**: Provides rebase instructions

**Example output:**
```
=== Worktree Completion Flow ===
Issue: #156

Step 1: Verifying work status...
✓ Work status verified

Step 2: Checking PR status...
Found PR #184: feat: Add PR lifecycle labels (state: OPEN)

Step 3: Attempting auto-merge...
✓ PR merged successfully

Step 4: Verifying issue closure...
✓ Issue #156 is closed

Step 5: Cleaning up worktree...
To complete cleanup, run from the main repo:
  cd /path/to/main/repo
  ./scripts/worktree/worktree-cleanup.sh 156 --delete-branch

=== Worktree Completion Flow Done ===
```

### 6c. CI Status Check (Post-PR Creation)

After PR creation, automatically check CI completion status with wait and retry.

**Script:** `./scripts/pr/check-pr-ci-status.sh`

**Usage:**
```bash
# Check single PR with wait and retry
./scripts/pr/check-pr-ci-status.sh <PR_NUMBER>

# Check with custom wait/timeout
./scripts/pr/check-pr-ci-status.sh <PR_NUMBER> --wait 60 --timeout 600

# Check all open PRs (for parallel worktrees)
./scripts/pr/check-pr-ci-status.sh --all

# JSON output for programmatic use
./scripts/pr/check-pr-ci-status.sh <PR_NUMBER> --json
```

**Options:**
- `--wait <sec>` - Initial wait before first check (default: 60s)
- `--interval <sec>` - Poll interval for retries (default: 30s)
- `--timeout <sec>` - Max time to wait for CI completion (default: 600s)
- `--all` - Check all open PRs targeting dev/main
- `--json` - Output JSON format
- `--quiet` - Minimal output (exit codes only)

**Exit Codes:**
- `0` - All checks passed (mergeable)
- `1` - Some checks failed (needs review)
- `2` - Checks still pending (timed out)
- `3` - Error (invalid PR, API failure)

**Status Output:**
```
✓ PR #123: MERGEABLE (8/8 checks passed)
✗ PR #124: NEEDS REVIEW (2 failed: lint, test-unit)
⏳ PR #125: PENDING (3 in progress: test-integration, deploy-preview)
```

**Container Integration:**

In container mode, CI checking is automatic:
- `container-sprint-workflow.sh` checks CI status after PR creation
- `container-post-pr.sh` supports `--check-ci` flag for explicit checking
- CI status is included in the SPRINT_RESULT JSON output

```bash
# container-post-pr.sh with CI check
./scripts/container/container-post-pr.sh --issue 107 --pr 456 --check-ci

# Custom wait/timeout in container
./scripts/container/container-post-pr.sh --issue 107 --pr 456 --check-ci --ci-wait 30 --ci-timeout 300
```

**Multiple PR Handling (Parallel Worktrees):**

When running parallel worktrees, check all PRs at once:

```bash
# Check status of all open PRs
./scripts/pr/check-pr-ci-status.sh --all

# Output:
# ✓ PR #201: MERGEABLE (8/8 checks passed)
# ✗ PR #202: NEEDS REVIEW (lint failed)
# ⏳ PR #203: PENDING (CI still running)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Some PRs need review (see failures above)
```

### 7. PR Review (Optional in Worktree)

If continuing in the worktree, run review agents:

Run in parallel: pr-code-reviewer, pr-test, pr-documentation, guardrails-policy

**Note:** Review can also happen after worktree exits, via GitHub UI or main repo.

### 8. Merge (Worktree-Safe)

**Merge can happen anywhere** using the worktree-safe merge script.

```bash
# Worktree-safe merge (works in any context)
./scripts/worktree/worktree-safe-merge.sh <PR#> --squash --delete-branch
```

**How it works:**
- **In worktree**: Uses GitHub API directly (bypasses local git operations)
- **In main repo**: Uses standard `gh pr merge` command
- **Either way**: Same command, same result, no confusing errors

**Alternative merge methods:**
- **GitHub UI**: Click "Squash and merge" button (always safe)
- **Main repo only**: `gh pr merge <PR#> --squash --delete-branch`

**Why standard `gh pr merge` fails in worktrees:**
```
# This fails when another worktree tracks `dev`:
gh pr merge 101 --squash --delete-branch
# Error: fatal: 'dev' is already used by worktree at '/path/to/...'
```

The `--delete-branch` flag causes `gh` to update local git refs, which fails
when another worktree is tracking the target branch. The worktree-safe script
avoids this by using the GitHub API for all operations.

### 9. Handle Blocking

If blocked: mark issue `blocked`, add comment, move to next

### 10. Cycle to Next

Display progress, ask to continue or select different issue.

## Output Format

```
## Sprint Work Session

**Milestone:** {name} ({days} days remaining, {pct}% complete)
**Issue:** #{number}: "{title}"

#### Phase 1: {name} ✓
#### Phase 2: {name} ⏳
...

**Action required:** Approve merge? [y/n/skip]
```

## Dry Run Format

```
**Would process issues:**

| Priority | Issue | Type | Title |
|----------|-------|------|-------|
| 1 | #{n} | {type} | {title} |

**Agent routing:** #{n}: agent1 → agent2 → agent3
```

## Container Mode Output Format

```
## Container Sprint Work

**Mode:** Containerized (isolated execution)
**Issue:** #{number}: "{title}"
**Image:** {image_name}
**Status:** {launching|running|completed|failed}

### Container Log
[Streamed container output...]

### Result
**Exit code:** {0|1|...}
**PR created:** https://github.com/{owner}/{repo}/pull/{N}

**Container cleanup:** Automatic (--rm flag)
```

**Error Output (Docker unavailable):**
```
⚠️ Docker not available

Docker is required for --container mode but is not available:
- Docker not installed: Install Docker Desktop
- Docker not running: Start Docker daemon

Falling back to worktree mode...
```

## Permissions

Auto-approved scripts after preflight returns `continue`:

```yaml
permissions:
  max_tier: T0  # Auto-approve T0 operations in validated worktree context
  context: "worktree_validated"  # Only applies after preflight success
  scripts:
    - name: "read-sprint-state.sh"
      tier: T0
      description: "Read cached sprint state (no API calls)"
      rationale: "Read-only access to cache file created by preflight"
```

**Efficiency gain:** Reduces 2-3 permission prompts per sprint-work session (Issue #211)

## Token Optimization

This skill is partially optimized but has room for improvement:

**Current optimizations:**
- ✅ Uses `sprint-work-preflight.sh` data script for initial state gathering
- ✅ Reads cached sprint state from `.sprint-state.json` (no repeated API calls)
- ✅ Uses `jq` for JSON parsing in scripts
- ✅ Epic mode uses `find-parent-issues.sh` for hierarchy queries

**Token usage:**
- Current: ~1,400 tokens (large monolithic skill file)
- Optimized target: ~725 tokens (using dispatcher pattern)
- Potential savings: **48%**

**Remaining optimizations needed:**
- ❌ Large skill file (1016 lines) - could split into dispatcher + worker
- ❌ Multiple `gh` commands without batch processing (12 instances)
- ❌ Heavy context loaded for every dispatch

**Measurement:**
- Baseline: 1,400 tokens (current monolithic approach)
- Target: 725 tokens (dispatcher pattern like `/sprint-continue`)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Optimization strategy:**
Use `/sprint-continue` for lightweight dispatch, load full `/sprint-work` only in worker context.
This reduces dispatcher token count by 67% while maintaining full functionality in workers.

**Related skills:**
- `/sprint-continue` - Optimized dispatcher (800 tokens)
- Current monolithic pattern - Full skill loaded for dispatch (1,400 tokens)

## Notes

- WRITE operation (creates PRs, updates issues, merges)
- Requires worktree - cannot run in main repo when worktree exists (unless using --container)
- Requires user approval for merges
- PRs target `dev` branch by default, or `--base` branch if specified
- **Merging**: Use `./scripts/worktree/worktree-safe-merge.sh` for worktree-safe PR merging
- See BRANCHING_STRATEGY.md for worktree workflow
- See WORKTREE_OPERATIONS.md for read-only vs write classification
- Auto-detects already-complete issues before starting work (step 3.5)
  - **Limitation:** Requires behavioral verification, not just artifact detection
  - See [Issue #244](https://github.com/jifflee/claude-tastic/issues/244) for context
- Uses `.sprint-state.json` cache to reduce GitHub API calls (generated by preflight)
- **Epic mode:** Use `--epic N` to work through children of an epic
- **Hierarchy queries:** Uses `find-parent-issues.sh` for epic status
- **Parallel worktrees:** Can spawn parallel worktrees for independent children
  - Use `issue-dependencies.sh --parallel-candidates` to detect independent issues
  - Use `spawn-parallel-worktrees.sh` to create multiple worktrees
  - Each worktree runs independently with its own Claude instance
- **Container merge:** Use `merge-in-container.sh` to avoid branch conflicts during merge
- **Container mode:** Use `--container` flag for isolated Docker execution
  - Requires Docker installed and running
  - Requires `GITHUB_TOKEN` environment variable
  - Falls back to worktree mode if Docker unavailable
  - Uses `container-launch.sh` for lifecycle management
  - Container has no host filesystem access (security isolation)
  - Good for CI/CD pipelines or untrusted environments
- **Container mode:** Runs detached by default (fire-and-forget behavior)
  - Launches container in background, returns immediately
  - Run multiple containers in parallel
  - Monitor via `./scripts/container/container-status.sh` or `/sprint-status`
  - Integrated into `/sprint-status` container section
  - Use `--sync` or `--foreground` flag for synchronous execution
- **CI Status Check:** Automatically checks CI completion after PR creation
  - Uses `check-pr-ci-status.sh` with wait and retry logic
  - Initial wait (default 60s) before first check
  - Retries until CI completes or timeout (default 600s)
  - Reports: mergeable, needs_review, or pending
  - Supports `--all` flag to check multiple PRs (parallel worktrees)
  - Integrated into both container and worktree workflows

## Limitations

### Already-Complete Detection (Step 3.5)

**Problem:** The auto-detection feature can produce false positives when artifacts exist
but the feature doesn't actually work. This was discovered in [Issue #238](https://github.com/jifflee/claude-tastic/issues/238)
where `--container` flag documentation and scripts existed, but the flag was ignored at runtime.

**Root Cause:** Original implementation checked only for artifact existence:
- File exists? ✓
- Documentation mentions feature? ✓
- Scripts present? ✓

But did NOT verify:
- Does the feature actually work? ❌
- Does running the command produce expected behavior? ❌

**Solution (Implemented):** Two-phase detection:
1. **Phase 1 - Artifact Detection:** Quick check for files/code (same as before)
2. **Phase 2 - Behavioral Verification:** Execute feature and verify it works

**Important Constraints:**
- **Never auto-close based on artifacts alone** - Always require behavioral verification
- **Default to SDLC** - When in doubt, proceed with implementation
- **Use "needs-verification" label** - For cases that need human verification
- **Require user confirmation** - Even with behavioral pass, user must confirm closure

**When Behavioral Verification is Not Possible:**
Some criteria cannot be automatically verified (e.g., "code is readable", "follows best practices").
In these cases:
1. Warn the user that automated verification is not possible
2. Default to proceeding with SDLC (safest option)
3. Offer "needs-verification" label for later human review
4. Allow user attestation for closure only with explicit confirmation
