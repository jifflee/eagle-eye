---
description: Automatically work through milestone issues from backlog to completion following SDLC workflow
permissions:
  max_tier: T0
  scripts:
    - name: detect-infrastructure.sh
      tier: T0
    - name: sprint-work-preflight.sh
      tier: T0
    - name: read-sprint-state.sh
      tier: T0
    - name: find-parent-issues.sh
      tier: T0
    - name: issue-dependencies.sh
      tier: T0
    - name: container-status.sh
      tier: T0
    - name: analyze-epic-work-mode.sh
      tier: T0
    - name: auto-select-issue.sh
      tier: T0
---

# Sprint Work

Orchestrates working through backlog issues in the active milestone, running each through SDLC phases.

## Usage

```
/sprint-work                  # Auto-start highest priority issue (feature #1253), or detect from worktree
/sprint-work --issue N        # Work on specific issue (container mode by default)
/sprint-work --issue N --worktree      # Opt into worktree mode instead of container
/sprint-work --epic N         # Work on children of epic #N
/sprint-work --dry-run        # Show what would be done
/sprint-work --issue N --sync          # Run container synchronous (foreground)
/sprint-work --issue N --image IMAGE   # Use specific Docker image

# Review flags (Phase 7)
/sprint-work --skip-review           # Skip internal review phase
/sprint-work --review-only           # Run review but don't auto-fix
/sprint-work --max-review-iterations N  # Max review-fix cycles (default: 3)

# Deprecated flags (still work but show warnings)
/sprint-work --issue N --container     # DEPRECATED: Container is now default
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

## n8n Container Dependency

Sprint-work automatically checks for and starts the n8n-github container if needed.
This container is required for:
- PR merge automation pipeline (#715)
- Container monitoring
- GitHub webhook handling

**Auto-Start Behavior:**
- Before starting work, sprint-work checks if n8n is healthy
- If n8n is not running, it automatically starts the container
- If n8n fails to start, shows a warning but continues (graceful fallback)
- Manual start: `./scripts/n8n/n8n-start.sh`
- Health check: `./scripts/n8n/n8n-health.sh`

**Container Name:** `n8n-local` (from `deploy/n8n/docker-compose.n8n.yml`)

## Autonomous Execution Mode

**Container mode is now the default** (changed in #531). Issues run in Docker containers
unless you explicitly opt into worktree mode with `--worktree`.

**Execution Mode Detection:**

The preflight script (`sprint-work-preflight.sh`) calls `detect-execution-mode.sh` to
determine execution mode:

1. **Explicit flag**: `--worktree` flag forces worktree mode
2. **Label-based**: Issues with `execution:worktree` label use worktree mode
3. **Label-based**: Issues with `execution:container` label use container mode
4. **Body-based**: Issue body containing `## Execution Mode: worktree` uses worktree
5. **Config-based**: Default mode from `~/.claude-tastic/config.json`
6. **Fallback**: Container mode (default since #531)

**Example - Opting into Worktree Mode:**
```bash
# Use --worktree flag to run locally instead of in container
/sprint-work --issue 204 --worktree

# Or add label for persistent worktree preference
gh issue edit 204 --add-label "execution:worktree"
```

**Example - Setting via Issue Body:**
```markdown
## Execution Mode: worktree

## Summary
This issue requires local filesystem access because...
```

**Configuration File (`~/.claude-tastic/config.json`):**
```json
{
  "default_execution_mode": "worktree"
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

## Infrastructure Detection (Consumer Repos)

**IMPORTANT**: Consumer repos deployed via `/repo:init-framework` may not have the full container/worktree infrastructure scripts. This command gracefully adapts based on what's available.

### Infrastructure Check

Before starting work, check if required infrastructure scripts exist:

```bash
# Check for container infrastructure
# Scripts may be at .claude/scripts/ (consumer repos) or ./scripts/ (framework repo)
# Use detect-infrastructure.sh for proper path resolution instead of hardcoding
CONTAINER_SCRIPT=""
WORKTREE_SCRIPT=""
if [ -f ".claude/scripts/container/container-launch.sh" ]; then
  CONTAINER_SCRIPT=".claude/scripts/container/container-launch.sh"
elif [ -f "./scripts/container/container-launch.sh" ]; then
  CONTAINER_SCRIPT="./scripts/container/container-launch.sh"
fi
if [ -f ".claude/scripts/sprint/sprint-work-preflight.sh" ]; then
  WORKTREE_SCRIPT=".claude/scripts/sprint/sprint-work-preflight.sh"
elif [ -f "./scripts/sprint/sprint-work-preflight.sh" ]; then
  WORKTREE_SCRIPT="./scripts/sprint/sprint-work-preflight.sh"
fi

if [ -z "$CONTAINER_SCRIPT" ] && [ -z "$WORKTREE_SCRIPT" ]; then
  echo "⚠️  Container/worktree infrastructure not available in this repository"
  echo "📋 This appears to be a consumer repo without full framework scripts"
  echo "✅ Proceeding with direct in-session execution..."

  # Set flags to force direct execution
  FORCE_DIRECT_MODE="true"
fi
```

### Execution Mode Priority (Consumer Repos)

When infrastructure scripts are missing, the execution mode priority is:

1. **Direct in-session mode** (REQUIRED when scripts missing)
   - Execute SDLC phases directly in current Claude session
   - No container or worktree isolation
   - Works in consumer repos without infrastructure

2. **Container mode** (if Docker + scripts available)
   - Requires `container-launch.sh` and Docker daemon
   - Isolated execution environment
   - Full feature set

3. **Worktree mode** (if worktree scripts available)
   - Requires `sprint-work-preflight.sh`
   - Local worktree isolation
   - Filesystem-based separation

### Direct In-Session Mode (Fallback)

When operating in direct mode (no infrastructure), the command:

1. ✅ Works directly on the current branch (no worktree/container)
2. ✅ Executes all SDLC phases inline (spec → design → implement → test → docs)
3. ✅ Creates commits and PRs normally
4. ✅ Uses Task tool to invoke specialized agents per phase
5. ⚠️  **Caveat**: No parallel execution or isolation (sequential only)

**User Notification:**
```
## Direct Execution Mode

**Why**: Container/worktree infrastructure not available
**Mode**: In-session execution (no isolation)
**Issue**: #{number} - {title}

Proceeding with sequential SDLC workflow...
```

## Steps

### CRITICAL: Execution Flow

**Container mode is the default** (when infrastructure is available). The flow depends on infrastructure availability and whether `--issue N` is provided:

**Infrastructure Available (framework source repo):**

**With `--issue N`:** Go directly to Step 0 (launch container immediately).

**Without `--issue N` (auto-select, feature #1253):**
1. Go to Step 2 to **auto-select** the highest priority non-conflicting backlog issue
2. **Show selected issue(s) to the user and allow override before launching**
3. **RETURN TO STEP 0** to launch the container for the selected issue(s)
4. Do NOT proceed to Step 4 inline — the selected issue MUST be launched via container
5. If multiple non-conflicting issues share the highest priority, launch up to max concurrent limit in parallel
6. If no suitable issues found (all blocked/conflicting/resource-constrained), fall back to interactive selection

**The ONLY cases where inline (direct) execution is allowed with infrastructure:**
- `--worktree` flag is explicitly specified
- `execution:worktree` label is on the issue
- Docker is unavailable (fallback)
- `--force` flag for meta-fixes (fixing sprint-work itself)

**Infrastructure NOT Available (consumer repos via /repo:init-framework):**
- **Always use direct in-session execution** (Step 0 detects and skips to Step 1)
- No container or worktree isolation available
- Execute SDLC phases sequentially in current session
- All other features work normally (PR creation, commits, etc.)

### 0. Container Mode (Default)

**Container execution is the default mode** (since #531). Use `--worktree` to opt out.

**Resource-Aware Scaling (Feature #775):**

Before launching containers, the system enforces resource-aware scaling limits:

- **Environment Detection:** Auto-detects local (macOS) vs Proxmox
- **Local Limit:** Maximum **2 concurrent containers** when CPU/RAM resources are available
- **Proxmox Limit:** Maximum **3 concurrent containers** when disk resources are available
- **Capacity Checks:** Runs `check-resource-capacity.sh` before each launch
- **Automatic Limits:** Container launches are blocked when:
  - Max container limit reached for environment
  - CPU usage > 80%
  - Memory usage > 85%
  - Projected resource usage would exceed thresholds

**Container Launch Policy:**
- Container launches require **explicit `/sprint-work` invocation**
- **Never launched automatically** by other skills (e.g., `/pr-merge`)
- Each launch checks current capacity before proceeding
- See `/docs/RESOURCE_AWARE_SCALING.md` for details

```bash
# Step 0a: Detect infrastructure availability (CRITICAL for consumer repos)
# detect-infrastructure.sh resolves script paths for both consumer repos
# (.claude/scripts/) and the framework source repo (./scripts/)
INFRA_JSON=$(./scripts/detect-infrastructure.sh)
INFRA_TYPE=$(echo "$INFRA_JSON" | jq -r '.infrastructure_type')
RECOMMENDED_MODE=$(echo "$INFRA_JSON" | jq -r '.recommended_mode')
# Use the resolved path returned by detect-infrastructure (works in both
# consumer repos and the framework repo — no hardcoded ./scripts/ prefix)
CONTAINER_SCRIPT=$(echo "$INFRA_JSON" | jq -r '.container_script')
WORKTREE_SCRIPT=$(echo "$INFRA_JSON" | jq -r '.worktree_script')

# Step 0b: Handle consumer repos (no infrastructure)
if [ "$INFRA_TYPE" = "none" ]; then
  echo "## Direct Execution Mode"
  echo ""
  echo "**Why**: Container/worktree infrastructure scripts not found"
  echo "**Mode**: In-session execution (no isolation)"
  echo "**Issue**: #$ISSUE_NUMBER"
  echo ""
  echo "⚠️  This appears to be a consumer repo without full framework scripts"
  echo "✅ Proceeding with direct SDLC workflow..."
  echo ""
  # Skip to Step 4 (Initialize Session for direct execution)
  # Do NOT attempt to launch container or worktree
fi

# Step 0c: Handle --worktree flag override
if [ "${WORKTREE_FLAG:-false}" = "true" ]; then
  if [ "$INFRA_TYPE" = "none" ]; then
    echo "⚠️  Cannot use --worktree flag: worktree infrastructure not available"
    echo "Falling back to direct execution mode..."
  else
    RECOMMENDED_MODE="worktree"
  fi
fi

# Step 0d: Execute based on recommended mode
if [ "$RECOMMENDED_MODE" = "container" ]; then
  # Get repository info
  REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

  # Launch container with streamlined sprint-work mode
  # This auto-loads tokens from keychain and runs detached by default
  # $CONTAINER_SCRIPT is resolved by detect-infrastructure.sh to the correct
  # location: .claude/scripts/ (consumer repos) or ./scripts/ (framework repo)
  "$CONTAINER_SCRIPT" \
    --issue "$ISSUE_NUMBER" \
    --repo "$REPO" \
    --sprint-work

  # Container runs in background by default
  # Use --sync flag for synchronous execution:
  # "$CONTAINER_SCRIPT" --issue "$ISSUE_NUMBER" --repo "$REPO" --sprint-work --sync

  # For detached mode (default), container status available via:
  # - ./scripts/container/container-status.sh or .claude/scripts/container/container-status.sh
  # - /sprint-status (shows container section)
  exit 0

elif [ "$RECOMMENDED_MODE" = "worktree" ]; then
  # Continue to Step 0.1 (Worktree Pre-flight)
  echo "Using worktree mode..."

elif [ "$RECOMMENDED_MODE" = "direct" ]; then
  # Continue to Step 1 (Initialize Session for direct execution)
  echo "Using direct in-session execution..."
fi
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
# $CONTAINER_SCRIPT resolved by detect-infrastructure.sh (Step 0a)
"$CONTAINER_SCRIPT" \
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

### 0.1. Worktree Pre-flight (When Using Worktree Mode)

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
MILESTONE=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.state=="open") | .title' | head -1)
gh issue list --milestone "$MILESTONE" --label "backlog" --json number,title,labels,createdAt
```

### 2. Select Next Issue

**IMPORTANT:** After issue selection in this step, **GO TO STEP 0** to launch the container.
Do NOT proceed to Step 4 inline unless worktree mode is active.

**Standard Mode:**
Priority order: P0 > P1 > P2 > P3
Within priority: bug > feature > tech-debt > docs > oldest first

Skip: `blocked`, `in-progress`, `needs-triage`

#### Auto-Select Mode (No `--issue` Flag) — Feature #1253

When invoked without `--issue N`, auto-select the highest priority non-conflicting issue:

**Step 2a: Check Resource Availability**
```bash
CAPACITY_JSON=$(./scripts/check-resource-capacity.sh)
HAS_CAPACITY=$(echo "$CAPACITY_JSON" | jq -r '.has_capacity')
MAX_CONTAINERS=$(echo "$CAPACITY_JSON" | jq -r '.max_containers')
RUNNING_CONTAINERS=$(echo "$CAPACITY_JSON" | jq -r '.running_containers')
AVAILABLE_SLOTS=$((MAX_CONTAINERS - RUNNING_CONTAINERS))

if [ "$HAS_CAPACITY" = "false" ]; then
  echo "⚠️  No container slots available (${RUNNING_CONTAINERS}/${MAX_CONTAINERS} running)"
  echo "Resource reason: $(echo "$CAPACITY_JSON" | jq -r '.reason')"
  echo "Falling back to interactive selection..."
  # Prompt user for manual issue selection
fi
```

**Step 2b: Query Backlog (Filtered)**
```bash
MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '.[] | select(.state=="open") | .title' | head -1)

# Fetch backlog issues, excluding skip labels
BACKLOG=$(gh issue list \
  --milestone "$MILESTONE" \
  --label "backlog" \
  --json number,title,labels,createdAt \
  --jq '[.[] | select(
    ([.labels[].name] | any(. == "blocked" or . == "in-progress" or . == "needs-triage")) | not
  )]')
```

**Step 2c: Detect Running Container File Overlap**
```bash
CONTAINER_STATUS=$(./scripts/container/container-status.sh --json 2>/dev/null || echo '{"containers":[]}')
RUNNING_ISSUE_NUMS=$(echo "$CONTAINER_STATUS" | jq -r '.containers[] | select(.status=="running") | .issue')

# For each running container, get its branch/files touched
declare -A CONFLICTING_ISSUES
for running_issue in $RUNNING_ISSUE_NUMS; do
  BRANCH="feat/issue-${running_issue}"
  # Get files changed in that branch vs main
  CHANGED_FILES=$(git diff --name-only "origin/main...origin/${BRANCH}" 2>/dev/null || true)
  if [ -n "$CHANGED_FILES" ]; then
    CONFLICTING_ISSUES["$running_issue"]="$CHANGED_FILES"
  fi
done

# For each backlog candidate, check if its anticipated files overlap with running containers
# A candidate conflicts if it touches the same files as a running container
check_file_overlap() {
  local candidate_issue="$1"
  # Simple heuristic: check if a branch for this issue already exists with overlap
  local branch="feat/issue-${candidate_issue}"
  local candidate_files
  candidate_files=$(git diff --name-only "origin/main...origin/${branch}" 2>/dev/null || true)

  if [ -z "$candidate_files" ]; then
    return 1  # No branch yet, no known overlap — safe to run
  fi

  for running_issue in $RUNNING_ISSUE_NUMS; do
    local running_files="${CONFLICTING_ISSUES[$running_issue]:-}"
    if [ -n "$running_files" ]; then
      local overlap
      overlap=$(comm -12 \
        <(echo "$candidate_files" | sort) \
        <(echo "$running_files" | sort))
      if [ -n "$overlap" ]; then
        return 0  # Overlap detected
      fi
    fi
  done
  return 1  # No overlap
}
```

**Step 2d: Auto-Select by Priority**
```bash
# Priority label weights: P0=0, P1=1, P2=2, P3=3, unset=4
get_priority() {
  local labels="$1"
  echo "$labels" | jq -r '
    if any(.[]; . == "P0") then "0"
    elif any(.[]; . == "P1") then "1"
    elif any(.[]; . == "P2") then "2"
    elif any(.[]; . == "P3") then "3"
    else "4" end'
}

# Iterate over backlog sorted by priority, select non-conflicting issues
SELECTED_ISSUES=()
HIGHEST_PRIORITY=""

while IFS= read -r issue_json; do
  num=$(echo "$issue_json" | jq -r '.number')
  title=$(echo "$issue_json" | jq -r '.title')
  labels=$(echo "$issue_json" | jq '[.labels[].name]')
  priority=$(get_priority "$labels")

  # Stop if we've moved past the highest selected priority
  if [ -n "$HIGHEST_PRIORITY" ] && [ "$priority" -gt "$HIGHEST_PRIORITY" ]; then
    break
  fi

  # Check resource slots
  if [ "${#SELECTED_ISSUES[@]}" -ge "$AVAILABLE_SLOTS" ]; then
    break
  fi

  # Skip if file overlap with running containers
  if check_file_overlap "$num"; then
    echo "  ⏭️  Skipping #${num} (file overlap with running container)"
    continue
  fi

  SELECTED_ISSUES+=("$num")
  HIGHEST_PRIORITY="$priority"
done < <(echo "$BACKLOG" | jq -c 'sort_by(.labels[].name // "P4") | .[]')
```

**Step 2e: Show Selection and Allow Override**
```
## Auto-Selected Issues

The following issue(s) were automatically selected for launch:

| # | Priority | Type | Title |
|---|----------|------|-------|
| #42 | P1 | feature | Add rate limiting to API endpoints |
| #38 | P1 | bug | Fix session timeout race condition |

**Available slots:** 2/2 (local limit)
**Reason:** Highest priority (P1), no conflicts detected

Options:
  [y] Launch selected issue(s) — default (Enter)
  [n] Interactive selection instead
  [s] Launch only #42 (single issue)
  [o] Override: specify different issue number(s)

Select [y/n/s/o]:
```

If the user accepts or no TTY (container mode), proceed to launch. Otherwise, fall back to interactive selection.

**Step 2f: Parallel Launch When Multiple Issues Selected**
```bash
if [ "${#SELECTED_ISSUES[@]}" -gt 1 ]; then
  echo "Launching ${#SELECTED_ISSUES[@]} containers in parallel..."
  # $CONTAINER_SCRIPT resolved by detect-infrastructure.sh (Step 0a)
  for issue_num in "${SELECTED_ISSUES[@]}"; do
    REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
    "$CONTAINER_SCRIPT" \
      --issue "$issue_num" \
      --repo "$REPO" \
      --sprint-work
    echo "  ✅ Launched container for issue #${issue_num}"
  done
  echo "Monitor with: $CONTAINER_SCRIPT --list (or container-status.sh)"
  exit 0
elif [ "${#SELECTED_ISSUES[@]}" -eq 1 ]; then
  ISSUE_NUMBER="${SELECTED_ISSUES[0]}"
  # Proceed to Step 0 (launch single container)
else
  echo "⚠️  No suitable issues found in backlog."
  echo "All issues are either blocked, in-progress, conflict with running containers,"
  echo "or resource capacity is exhausted."
  echo ""
  echo "Falling back to interactive selection..."
  # Show full backlog for manual selection
fi
```

**Step 2g: Fallback to Interactive Selection**

If auto-selection finds no suitable issues, show the full backlog for manual selection:
```
## Backlog (Interactive Selection)

No issues were auto-selected (all blocked, conflicting, or resources exhausted).

| # | Priority | Type | Title | Skip Reason |
|---|----------|------|-------|-------------|
| #55 | P0 | bug | Auth service crash | in-progress |
| #42 | P1 | feature | Rate limiting | running conflict |
| #38 | P1 | bug | Session timeout | running conflict |
| #61 | P2 | feature | Export to CSV | available |

Enter issue number to work on (or 'q' to quit):
```

**Four Wise Men Debate (when multiple issues at same priority):**

When multiple backlog issues share the same priority (e.g., three P2 features), use the Four Wise Men framework to determine order:

```bash
# Detect if debate is needed
SAME_PRIORITY_COUNT=$(gh issue list --milestone "$MILESTONE" --label "backlog" --label "P2" --json number | jq length)

if [ "$SAME_PRIORITY_COUNT" -gt 1 ]; then
  echo "Multiple P2 issues found. Running Four Wise Men debate..."
  # Invoke wise-men-debate for each candidate
  # See /issue-prioritize command for details
fi
```

**Debate flow:**
1. Gather candidate issues at the same priority level
2. Run `/issue-prioritize` for each (or top 3-5 if many)
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

# Analyze work mode (parallel vs sequential)
./scripts/analyze-epic-work-mode.sh N
```

**Parallel vs Sequential Recommendation:**

The system automatically analyzes child issues to recommend execution mode:

```bash
# Analysis considers:
# 1. Dependency graph - are children interdependent?
# 2. File overlap - do they modify the same files?
# 3. Data dependencies - API changes, schema migrations, etc.

ANALYSIS=$(./scripts/analyze-epic-work-mode.sh $EPIC_NUMBER --json)
RECOMMENDATION=$(echo "$ANALYSIS" | jq -r '.recommendation')
```

**Recommendation output:**
```
╔══════════════════════════════════════════════════════════════════╗
║  EPIC WORK MODE ANALYSIS: #143
╠══════════════════════════════════════════════════════════════════╣
║
║  RECOMMENDATION: sequential (confidence: high)
║
║  ANALYSIS SUMMARY:
║    - Children count: 3
║    - Dependency edges: 2
║    - Related pairs: 1
║    - File overlap score: 4
║
║  REASONING:
║    • Dependency relationships exist between children (2 edges)
║    • High file overlap detected (score: 4)
║
║  FILE OVERLAP DETAILS:
║    • API/endpoint changes in #194 and #195 may conflict
║
║  RECOMMENDED MERGE ORDER:
║    1. #192: Base infrastructure changes
║    2. #194: API endpoint updates
║    3. #195: Feature implementation
║
╚══════════════════════════════════════════════════════════════════╝
```

**Display epic status with recommendation:**
```
## Working on Epic #45: Auth System Refactor

**Progress:** 2/5 children closed (40%)

**Work Mode:** Sequential (dependencies detected)

Open children:
| # | Priority | Type | Title | Status | Order |
|---|----------|------|-------|--------|-------|
| #47 | P1 | bug | Fix session timeout | backlog | 1st |
| #48 | P2 | feature | Add 2FA | backlog | 2nd |
| #49 | P2 | feature | Add OAuth | backlog | 3rd |

Recommendation: Work sequentially due to API contract dependencies
User can override: [p]arallel / [s]equential / [c]ontinue with recommendation
```

**Parallel Execution (When Recommended):**

When children are independent (no inter-dependencies), spawn parallel containers or worktrees:

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

**Spawning parallel containers (default):**
```bash
# When recommendation is parallel, offer to spawn multiple containers
for child in $CHILD_NUMBERS; do
  /sprint-work --issue $child  # Launches in detached container by default
done

# Monitor parallel execution
./scripts/container/container-status.sh --json
```

**Spawning parallel worktrees (with --worktree):**
```bash
# Spawn worktrees for specific issues
./scripts/worktree/spawn-parallel-worktrees.sh 162 160 157

# Or auto-detect and spawn from candidates
./scripts/worktree/spawn-parallel-worktrees.sh --from-candidates --max 3

# Dry run to preview
./scripts/worktree/spawn-parallel-worktrees.sh --from-candidates --dry-run
```

**After spawning, each worktree/container is independent:**
```
# Container mode (default):
/sprint-work --issue 162  # Container 1 (detached)
/sprint-work --issue 160  # Container 2 (detached)
/sprint-work --issue 157  # Container 3 (detached)

# Worktree mode:
# Terminal 1
cd ../repo-issue-162 && claude /sprint-work --issue 162

# Terminal 2
cd ../repo-issue-160 && claude /sprint-work --issue 160

# Terminal 3
cd ../repo-issue-157 && claude /sprint-work --issue 157
```

**Prompt for parallel execution:**
```
RECOMMENDATION: Parallel execution (confidence: high)

Issues #47, #48, and #50 have no interdependencies.
No file overlap detected. Safe to work in parallel.

Options:
  [p] Spawn all 3 in parallel (containers)
  [w] Spawn all 3 in parallel (worktrees)
  [s] Work sequentially (override recommendation)
  [1] Work on single issue only

Select [p/w/s/1]:
```

**Prompt for sequential execution:**
```
RECOMMENDATION: Sequential execution (confidence: high)

Dependencies detected:
  - Issue #192 blocks #194, #195
  - File overlap in API endpoints (issues #194, #195)

Recommended merge order:
  1. #192 (no dependencies)
  2. #194 (depends on #192)
  3. #195 (depends on #192)

Options:
  [s] Work sequentially in recommended order
  [p] Override and work in parallel (risk of conflicts)
  [1] Work on single issue only

Select [s/p/1]:
```

**User Override:**

User can always override the recommendation:
- Parallel → Sequential: Useful when user knows of undocumented dependencies
- Sequential → Parallel: When user is confident in manual conflict resolution

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

# Initialize pr-status.json for agent tracking
./scripts/pr/update-pr-status.sh --issue $ISSUE --init
```

**Agent Tracking Initialization:**

The `pr-status.json` file tracks which agents write which files during implementation.
This enables the PR review feedback mechanism to route review issues back to the
responsible agents. See [PR_STATUS_SCHEMA.md](/docs/PR_STATUS_SCHEMA.md) for details.

### 5. Execute SDLC Phases

**Feature:** spec → design → implement → test → docs
**Bug:** analysis → fix → regression test
**Tech-debt:** plan → refactor → verify tests
**Docs:** write documentation

Use appropriate agents per phase. Commit after each phase.

**Implementation Agent Tracking:**

After each agent writes or modifies files, register them in pr-status.json:

```bash
# After backend-developer writes a file
./scripts/pr/update-pr-status.sh --issue $ISSUE --register-file scripts/new-feature.sh --agent backend-developer

# After documentation agent writes docs
./scripts/pr/update-pr-status.sh --issue $ISSUE --register-file docs/NEW_FEATURE.md --agent documentation

# After test-qa writes tests
./scripts/pr/update-pr-status.sh --issue $ISSUE --register-file tests/test_feature.py --agent test-qa
```

**Why track implementation agents?**
- Enables `/pr-fix` to route review issues to the agent that wrote the code
- Provides accountability for code ownership
- Supports same-agent fix workflow (agents fix their own review issues)
- See epic #381 for the full PR review feedback mechanism

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

**Auto PR Creation (Recommended):**

Use the git push wrapper for automatic draft PR creation via n8n:

```bash
# Push with automatic PR creation (if n8n is running)
./scripts/pr/git-push-with-pr.sh -u origin feat/issue-$ISSUE

# Or use manual method (below)
```

When using `git-push-with-pr.sh`:
- Sends webhook to n8n after push
- n8n creates draft PR automatically
- Adds comment to linked issue
- See [AUTO_PR_CREATION.md](/docs/AUTO_PR_CREATION.md) for details

**Manual PR Creation:**

```bash
# Check for existing PR (from cache first, then API as fallback)
PR_EXISTS=$(./scripts/sprint/read-sprint-state.sh pr.exists 2>/dev/null || echo "null")
if [ "$PR_EXISTS" = "true" ]; then
  git push  # Adds commits to existing PR
else
  PR_URL=$(gh pr create --base dev --title "[type]: {title}" --body "Fixes #$ISSUE")
  PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$')

  # Update pr-status.json with PR number
  ./scripts/pr/update-pr-status.sh --issue $ISSUE --set-pr $PR_NUM
fi
```

**PR Creation with Auto-Cleanup (New in #104):**

To enable automatic worktree cleanup after PR merge:

```bash
# Create PR with auto-cleanup enabled
./scripts/pr/pr-create-with-cleanup.sh --cleanup-after-merge --base dev --fill

# Or use gh pr create wrapper
./scripts/pr/pr-create-with-cleanup.sh --cleanup-after-merge --base dev --title "feat: {title}" --body "Fixes #$ISSUE"
```

**How it works:**
1. PR is created normally via `gh pr create`
2. Issue/PR is registered in `~/.claude-tastic/pending-cleanup.json`
3. After PR is merged, the post-merge git hook automatically:
   - Detects the merge
   - Checks for cleanup intent
   - Removes worktree and deletes branch
4. No manual cleanup needed!

**Manual trigger:**
```bash
# Trigger cleanup for all merged PRs
./scripts/auto-cleanup-merged.sh --all

# Trigger cleanup for specific issue
./scripts/auto-cleanup-merged.sh --issue $ISSUE
```

**Benefits:**
- No manual cleanup step required
- Worktrees are removed immediately after merge
- Works for both worktree and container modes
- Survives restarts (tracked in persistent JSON file)

See [AUTO_CLEANUP_AFTER_MERGE.md](/docs/AUTO_CLEANUP_AFTER_MERGE.md) for detailed documentation.

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

### 7. Internal PR Review (Post-PR Creation)

After PR creation, run internal review to catch issues before external review.

**Skip with:** `--skip-review` flag

**Automatic Workflow:**

```
if not --skip-review:
    # Run review
    /pr-review-internal

    # Check status
    if status == "needs-fixes" and not --review-only:
        # Auto-fix loop
        /pr-iterate --max ${MAX_REVIEW_ITERATIONS:-3}

    # Push any fixes
    git push
```

**Review Flow:**

1. **Run `/pr-review-internal`**
   - Invokes 4 PR review agents in parallel:
     - pr-code-reviewer (haiku) - Code quality, patterns
     - pr-test (haiku) - Test coverage, quality
     - pr-documentation (haiku) - Documentation completeness
     - pr-security-iam (sonnet) - Security vulnerabilities
   - Writes findings to `pr-status.json`
   - Generates `review-findings.md`

2. **If needs-fixes (and not --review-only):**
   - Run `/pr-iterate` for automated review-fix loop
   - Routes issues to owning implementation agents
   - Commits fixes with proper attribution
   - Re-runs review until approved or max iterations

3. **Push fixes:**
   - Push any fix commits to remote
   - Update PR with latest changes

**Review Flags:**

| Flag | Description |
|------|-------------|
| `--skip-review` | Skip internal review entirely |
| `--review-only` | Run review but don't auto-fix |
| `--max-review-iterations N` | Max review-fix cycles (default: 3) |

**Status Check:**

After review completes:

```
if review_status == "approved":
    echo "Internal review passed"
    # Continue to merge phase
elif review_status == "needs-fixes" and iterations >= max:
    echo "Max iterations reached with ${remaining} issues"
    echo "Manual intervention required"
    # Still creates PR, but with review notes
```

**Container Mode:**

In container mode, review runs automatically:
- Uses `--max-review-iterations 2` by default (faster)
- Skips security review for speed (`--skip-security`)
- Auto-pushes all fixes
- Reports final status in SPRINT_RESULT

**Manual Review Alternative:**

Review can also happen after worktree exits:
- Via `/pr-review-internal` from main repo
- Via GitHub UI review
- Via external CI/CD review workflows

**Related Skills:**
- `/pr-review-internal` - Run review agents manually
- `/pr-fix` - Fix blocking issues manually
- `/pr-iterate` - Run review-fix loop manually
- `/pr-status` - Check current review status

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
- **Consumer repo support (Issue #1133):** Gracefully falls back to direct in-session execution when container/worktree infrastructure scripts are not available
  - Detects missing `container-launch.sh` and `sprint-work-preflight.sh`
  - Automatically switches to direct execution mode (no isolation)
  - All SDLC features work normally (sequential execution only)
  - No error for consumer repos deployed via `/repo:init-framework`
- **Container mode is the default** (since #531, when infrastructure available). Use `--worktree` to opt into worktree mode.
- **n8n dependency:** Auto-checks and starts n8n-local container if not running (required for PR automation pipeline #715)
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
- **Parallel worktrees (when using --worktree):** Can spawn parallel worktrees for independent children
  - Use `issue-dependencies.sh --parallel-candidates` to detect independent issues
  - Use `spawn-parallel-worktrees.sh` to create multiple worktrees
  - Each worktree runs independently with its own Claude instance
- **Container merge:** Use `merge-in-container.sh` to avoid branch conflicts during merge
- **Container mode (default):** Runs in Docker containers
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
- **Worktree mode (opt-in via --worktree):** Use for local development
  - Required when Docker is unavailable
  - Use for issues requiring host filesystem access
- **CI Status Check:** Automatically checks CI completion after PR creation
  - Uses `check-pr-ci-status.sh` with wait and retry logic
  - Initial wait (default 60s) before first check
  - Retries until CI completes or timeout (default 600s)
  - Reports: mergeable, needs_review, or pending
  - Supports `--all` flag to check multiple PRs (parallel worktrees)
  - Integrated into both container and worktree workflows
- **Auto PR Creation:** Use `git-push-with-pr.sh` for automatic draft PR creation via n8n
  - Sends webhook to n8n after successful push
  - Creates draft PR targeting `dev` branch
  - Comments on linked issue with PR link
  - Requires n8n to be running with `auto-pr-create.json` workflow
  - See [AUTO_PR_CREATION.md](/docs/AUTO_PR_CREATION.md) for setup

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
