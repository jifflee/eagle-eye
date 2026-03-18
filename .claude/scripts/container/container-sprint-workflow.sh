#!/bin/bash
# container-sprint-workflow.sh
# Optimized container workflow that minimizes Claude token usage
# size-ok: multi-phase container orchestration with pre/post-work scripts and focused Claude invocation
#
# This script orchestrates sprint-work inside a container by:
# 1. Reading issue context from environment (no Claude reasoning needed)
# 2. Running pre-work scripts (label updates)
# 3. Invoking Claude ONLY for implementation (focused prompt)
# 4. Running post-work scripts (commit, push, PR)
#
# Token Optimization:
# - Before: Claude loads 800-line sprint-work.md and reasons through every step
# - After: Claude receives focused implementation prompt only
# - Estimated savings: 50-70% token reduction
#
# Environment Variables (set by container-launch.sh):
#   ISSUE              - Issue number (required)
#   SPRINT_STATE_B64   - Base64-encoded sprint state JSON (optional)
#   REPO_FULL_NAME     - owner/repo format (required)
#   BRANCH             - Base branch (auto-detected from repo's default branch if not set)
#
# Usage:
#   ./scripts/container-sprint-workflow.sh
#
# This script should be invoked by the container entrypoint instead of
# piping /sprint-work to claude directly.

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cleanup Handler ──────────────────────────────────────────────────────────

# Track workflow start time for duration reporting
WORKFLOW_START_EPOCH=$(date +%s)

# Background heartbeat PID for progress updates during long phases
PROGRESS_HEARTBEAT_PID=""

cleanup() {
  local exit_code=$?
  # Stop background progress heartbeat if running
  if [ -n "$PROGRESS_HEARTBEAT_PID" ]; then
    kill "$PROGRESS_HEARTBEAT_PID" 2>/dev/null || true
    wait "$PROGRESS_HEARTBEAT_PID" 2>/dev/null || true
  fi
  # Clean up any temporary files or resources
  if [[ -n "${TEMP_FILES:-}" ]]; then
    rm -f $TEMP_FILES 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT INT TERM

# Source shared logging utilities - try multiple paths for container context
for path in "${SCRIPT_DIR}/../lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        break
    fi
done

# Source watchdog heartbeat utilities
for path in "${SCRIPT_DIR}/../lib/watchdog-heartbeat.sh" "/workspace/repo/scripts/lib/watchdog-heartbeat.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        break
    fi
done

# Source structured logging library if available
STRUCTURED_LOGGING_ENABLED=false
for path in "${SCRIPT_DIR}/../lib/structured-logging.sh" "/workspace/repo/scripts/lib/structured-logging.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        STRUCTURED_LOGGING_ENABLED=true
        init_structured_logging
        break
    fi
done

# Custom phase logging
log_phase() {
    echo -e "${BLUE:-}=== $1 ===${NC:-}"
    # Also log to structured log if enabled
    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
        local phase_name
        phase_name=$(echo "$1" | sed 's/Phase [0-9]*: //' | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        phase_start "$phase_name"
    fi
}

# ─── Issue Progress Reporting ─────────────────────────────────────────────────
# Posts real-time progress updates to GitHub issues for agent visibility.
# Non-fatal: failures are logged but do not abort the workflow.

PROGRESS_SCRIPT=""
for path in "${SCRIPT_DIR}/issue-progress.sh" "/workspace/repo/scripts/issue-progress.sh"; do
    if [ -f "$path" ] && [ -x "$path" ]; then
        PROGRESS_SCRIPT="$path"
        break
    fi
done

# Post a phase progress comment to the GitHub issue
post_issue_progress() {
    local phase="$1"
    local status_msg="${2:-Working...}"
    if [ -n "$PROGRESS_SCRIPT" ] && [ -n "${ISSUE:-}" ]; then
        "$PROGRESS_SCRIPT" \
            --issue "$ISSUE" \
            --phase "$phase" \
            --status "$status_msg" \
            --container "${CONTAINER_NAME:-$HOSTNAME}" \
            --start-epoch "$WORKFLOW_START_EPOCH" \
            2>/dev/null || log_warn "issue-progress: failed to post phase update (non-fatal)"
    fi
}

# Post a failure notification to the GitHub issue
post_issue_failure() {
    local phase="$1"
    local error_msg="${2:-Unknown error}"
    if [ -n "$PROGRESS_SCRIPT" ] && [ -n "${ISSUE:-}" ]; then
        "$PROGRESS_SCRIPT" \
            --issue "$ISSUE" \
            --fail \
            --phase "$phase" \
            --error "$error_msg" \
            --container "${CONTAINER_NAME:-$HOSTNAME}" \
            --start-epoch "$WORKFLOW_START_EPOCH" \
            2>/dev/null || log_warn "issue-progress: failed to post failure notification (non-fatal)"
    fi
}

# Post a completion summary to the GitHub issue
post_issue_complete() {
    local pr_url="${1:-}"
    local pr_number="${2:-0}"
    if [ -n "$PROGRESS_SCRIPT" ] && [ -n "${ISSUE:-}" ]; then
        "$PROGRESS_SCRIPT" \
            --issue "$ISSUE" \
            --complete \
            --pr-url "$pr_url" \
            --pr-number "$pr_number" \
            --container "${CONTAINER_NAME:-$HOSTNAME}" \
            --start-epoch "$WORKFLOW_START_EPOCH" \
            2>/dev/null || log_warn "issue-progress: failed to post completion (non-fatal)"
    fi
}

# Post a blocker notification to both the blocked and blocking issue
post_issue_blocker() {
    local blocking_issue="$1"
    local reason="${2:-Dependency not resolved}"
    local phase="${3:-implement}"
    if [ -n "$PROGRESS_SCRIPT" ] && [ -n "${ISSUE:-}" ]; then
        "$PROGRESS_SCRIPT" \
            --issue "$ISSUE" \
            --blocker "$blocking_issue" \
            --reason "$reason" \
            --phase "$phase" \
            --container "${CONTAINER_NAME:-$HOSTNAME}" \
            2>/dev/null || log_warn "issue-progress: failed to post blocker notification (non-fatal)"
    fi
}

# Start background heartbeat that posts to GitHub issue every 5 minutes.
# Stores the PID in PROGRESS_HEARTBEAT_PID for cleanup.
start_issue_heartbeat() {
    local phase="${1:-implement}"
    if [ -z "$PROGRESS_SCRIPT" ] || [ -z "${ISSUE:-}" ]; then
        return
    fi
    # Stop any previous heartbeat
    stop_issue_heartbeat

    local prog="$PROGRESS_SCRIPT"
    local iss="$ISSUE"
    local container="${CONTAINER_NAME:-$HOSTNAME}"
    local start="$WORKFLOW_START_EPOCH"

    (
        while true; do
            sleep 300  # 5 minutes
            "$prog" \
                --issue "$iss" \
                --heartbeat \
                --phase "$phase" \
                --status "Active (heartbeat)" \
                --container "$container" \
                --start-epoch "$start" \
                2>/dev/null || true
        done
    ) &
    PROGRESS_HEARTBEAT_PID=$!
    log_info "Started issue heartbeat (PID: $PROGRESS_HEARTBEAT_PID, interval: 5m)"
}

# Stop background heartbeat
stop_issue_heartbeat() {
    if [ -n "${PROGRESS_HEARTBEAT_PID:-}" ]; then
        kill "$PROGRESS_HEARTBEAT_PID" 2>/dev/null || true
        wait "$PROGRESS_HEARTBEAT_PID" 2>/dev/null || true
        PROGRESS_HEARTBEAT_PID=""
    fi
}

# Validate required environment
if [ -z "${ISSUE:-}" ]; then
    log_error "ISSUE environment variable not set"
    exit 1
fi

if [ -z "${REPO_FULL_NAME:-}" ]; then
    # Try to detect from git remote
    REPO_FULL_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|' || echo "")
    if [ -z "${REPO_FULL_NAME:-}" ]; then
        log_error "REPO_FULL_NAME not set and could not be detected"
        exit 1
    fi
fi

if [ -z "${BRANCH:-}" ]; then
    # Detect default branch dynamically from remote (repo already cloned by entrypoint)
    BRANCH=$(git remote show origin 2>/dev/null | sed -n '/HEAD branch/s/.*: //p' | tr -d '[:space:]')
    if [ -z "$BRANCH" ]; then
        # Fallback: query GitHub API
        BRANCH=$(gh repo view "$REPO_FULL_NAME" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")
    fi
    log_info "Detected default branch: $BRANCH"
fi
BATCH_BRANCH="${BATCH_BRANCH:-}"  # Optional batch branch for parallel execution
FEATURE_BRANCH="feat/issue-$ISSUE"

# Determine target branch for PR (batch branch takes precedence)
TARGET_BRANCH="${BATCH_BRANCH:-$BRANCH}"

log_info "Container Sprint Workflow - Issue #$ISSUE"
log_info "Repository: $REPO_FULL_NAME"
log_info "Feature branch: $FEATURE_BRANCH"
if [ -n "$BATCH_BRANCH" ]; then
    log_info "Batch branch: $BATCH_BRANCH (PR target)"
fi

# Initialize watchdog heartbeat
watchdog_init "container-sprint-workflow"

# ============================================================================
# Phase 1: Decode Sprint State (if available)
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_start "load_context"
fi
log_phase "Phase 1: Loading Issue Context"
watchdog_phase "load-context"

ISSUE_TITLE=""
ISSUE_BODY=""
ISSUE_TYPE=""
ISSUE_LABELS=""

if [ -n "${SPRINT_STATE_B64:-}" ]; then
    log_info "Decoding sprint state from environment..."
    SPRINT_STATE=$(echo "$SPRINT_STATE_B64" | base64 -d 2>/dev/null || echo "{}")

    ISSUE_TITLE=$(echo "$SPRINT_STATE" | jq -r '.issue.title // empty')
    ISSUE_BODY=$(echo "$SPRINT_STATE" | jq -r '.issue.body // empty')
    ISSUE_TYPE=$(echo "$SPRINT_STATE" | jq -r '.issue.type // "feature"')
    # Labels can be strings or objects with .name field
    ISSUE_LABELS=$(echo "$SPRINT_STATE" | jq -r '.issue.labels // [] | if type == "array" then (if (.[0] | type) == "object" then [.[].name] else . end) | join(", ") else "" end')

    if [ -n "$ISSUE_TITLE" ]; then
        log_info "Issue: #$ISSUE - $ISSUE_TITLE"
        log_info "Type: $ISSUE_TYPE"
    fi
else
    log_info "No sprint state provided, fetching from GitHub..."
    ISSUE_JSON=$(gh issue view "$ISSUE" --json title,body,labels 2>/dev/null || echo "{}")
    ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // empty')
    ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // empty')
    ISSUE_LABELS=$(echo "$ISSUE_JSON" | jq -r '.labels[].name // empty' | tr '\n' ', ' | sed 's/,$//')

    # Detect issue type from labels
    if echo "$ISSUE_LABELS" | grep -q "bug"; then
        ISSUE_TYPE="bug"
    elif echo "$ISSUE_LABELS" | grep -q "feature"; then
        ISSUE_TYPE="feature"
    elif echo "$ISSUE_LABELS" | grep -q "tech-debt"; then
        ISSUE_TYPE="tech-debt"
    else
        ISSUE_TYPE="feature"
    fi
fi

if [ -z "$ISSUE_TITLE" ]; then
    log_error "Could not get issue title"
    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
        phase_error "load_context" "Failed to get issue title"
    fi
    exit 1
fi

if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_complete "load_context" "complete"
fi

# ============================================================================
# Phase 2: Pre-Work (Script-Handled)
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_start "pre_work"
fi
log_phase "Phase 2: Pre-Work Setup"
watchdog_phase "pre-work"

# Update issue label to in-progress
log_info "Updating issue labels..."
gh issue edit "$ISSUE" --remove-label "backlog" --add-label "in-progress" 2>/dev/null || true

# Post initial progress comment so other agents can see this issue is being worked
post_issue_progress "spec" "Loading issue context and setting up workspace"

# Ensure we're on the feature branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$FEATURE_BRANCH" ]; then
    log_info "Switching to feature branch: $FEATURE_BRANCH"
    git checkout "$FEATURE_BRANCH" 2>/dev/null || git checkout -b "$FEATURE_BRANCH"
fi

if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_complete "pre_work" "complete"
fi

# ============================================================================
# Phase 3: Implementation (Claude-Handled)
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_start "implement"
fi
log_phase "Phase 3: Implementation (Claude)"
watchdog_phase "implementation"

# Determine PR/commit prefix from issue type (used in prompts and PR creation)
case "$ISSUE_TYPE" in
    bug) PR_PREFIX="fix" ;;
    tech-debt) PR_PREFIX="refactor" ;;
    *) PR_PREFIX="feat" ;;
esac

# Build a focused implementation prompt based on issue type
# This is much more focused than the full /sprint-work skill

# Global constraint for all container work
CONTAINER_CONSTRAINTS="IMPORTANT CONSTRAINTS:
- NEVER create or modify files in .github/workflows/ - the OAuth token lacks workflow scope and the push will be rejected.
- If CI/CD changes are needed, create local scripts in scripts/ci/ or scripts/ instead.
- Document any required workflow changes in the PR description for manual application.
- NEVER delete the feature branch $FEATURE_BRANCH - this is the branch you are working on. Deleting it will lose all your work.
- If you detect the feature is already complete, add tests or documentation on the feature branch and push those changes."

case "$ISSUE_TYPE" in
    bug)
        IMPLEMENTATION_PROMPT="TASK: Fix bug #$ISSUE

INSTRUCTIONS: Investigate the bug, fix it using Write/Edit tools, then commit.

$CONTAINER_CONSTRAINTS

---
Bug: $ISSUE_TITLE

$ISSUE_BODY
---

Steps:
1. Use Grep/Read tools to find the relevant code and understand the bug
2. Use Edit tool to fix the bug in the relevant files
3. Use Write tool to add a regression test if applicable
4. Use Bash tool: git add -A && git commit -m 'fix: $ISSUE_TITLE'

Start by reading the relevant files to understand the bug."
        ;;
    tech-debt)
        IMPLEMENTATION_PROMPT="TASK: Refactor for #$ISSUE

INSTRUCTIONS: Explore the code, then refactor using Edit tools, and commit.

$CONTAINER_CONSTRAINTS

---
Refactor: $ISSUE_TITLE

$ISSUE_BODY
---

Steps:
1. Use Grep/Read tools to understand the current code structure
2. Use Edit tool to implement the refactoring
3. Use Bash tool: git add -A && git commit -m 'refactor: $ISSUE_TITLE'

Start by reading the relevant files to understand what needs to change."
        ;;
    *)
        IMPLEMENTATION_PROMPT="TASK: Implement feature #$ISSUE

INSTRUCTIONS: Explore the codebase, implement the feature using Write/Edit tools, then commit.

$CONTAINER_CONSTRAINTS

---
Feature: $ISSUE_TITLE

$ISSUE_BODY
---

Steps:
1. Use Glob/Read tools to explore relevant existing files and understand the codebase
2. Use Write tool to create new files
3. Use Edit tool to modify existing files if needed
4. Use Bash tool: git add -A && git commit -m 'feat: $ISSUE_TITLE'

Start by exploring the codebase with Glob and Read tools to understand what exists."
        ;;
esac

log_info "Invoking Claude for implementation..."

# Post implementation phase progress comment and start 5-min heartbeat
post_issue_progress "implement" "Running Claude implementation agent"
start_issue_heartbeat "implement"

# Export SDLC_PHASE so metrics-capture.sh hook records meaningful phase labels
# instead of the generic "agent-invocation" default (Issue #833)
# Maps issue type to SDLC phase: tech-debt=implement, bug=implement, feature=implement
export SDLC_PHASE="implement"

# Record HEAD before Claude runs (to detect if Claude commits)
HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

# Start watchdog in background to monitor Claude invocation
WATCHDOG_PID=""
for watchdog_path in "${SCRIPT_DIR}/claude-watchdog.sh" "/workspace/repo/scripts/claude-watchdog.sh"; do
    if [ -f "$watchdog_path" ] && [ -x "$watchdog_path" ]; then
        "$watchdog_path" &
        WATCHDOG_PID=$!
        log_info "Started watchdog (PID: $WATCHDOG_PID)"
        break
    fi
done

# Claude invocation mode depends on INTERACTIVE_MODE environment variable
# - Interactive: Uses TTY with --permission-mode default (prompts for decisions)
# - Non-interactive (default): Uses -p with --permission-mode bypassPermissions (autonomous)
#   IMPORTANT: acceptEdits only auto-approves Write/Edit tools, NOT Bash.
#   In non-interactive -p mode, Bash permission prompts can't be answered,
#   causing Claude to describe instead of executing tool calls.
#   bypassPermissions is safe here because the container is already isolated:
#   - No volume mounts (no host filesystem access)
#   - All capabilities dropped (--cap-drop ALL)
#   - Read-only rootfs (--read-only)
#   - No privilege escalation (--security-opt no-new-privileges)
CLAUDE_SETTINGS="/home/claude/.claude/settings.json"

# System prompt that prioritizes tool usage while allowing brief reasoning
TOOL_SYSTEM_PROMPT="You are a coding assistant. Your primary job is to write and modify files using tools.

RULES:
1. ALWAYS use Read/Grep/Glob tools first to understand existing code before making changes.
2. ALWAYS use Write tool to create new files and Edit tool to modify existing files.
3. ALWAYS use Bash tool to run git commands when instructed.
4. Keep explanations minimal - focus on executing tool calls.
5. If the task is unclear, read relevant files to gather context, then proceed with implementation.
6. Do NOT just describe what you would do - actually do it with tool calls."

# Timeout for a single Claude invocation (default 30 minutes)
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1800}"

# Total retry window for transient API errors (default 10 minutes = 600 seconds)
API_RETRY_TIMEOUT="${API_RETRY_TIMEOUT:-600}"

# Exit code indicating API failure exhausted all retries
readonly EXIT_CODE_API_FAILURE=3

# Transient API error exit codes from Claude CLI (maps to HTTP 429/500/502/503)
# Claude CLI exits with non-zero codes for API errors; we detect via output patterns
is_transient_api_error() {
    local exit_code="$1"
    local output="$2"

    # Exit code 1 with API error patterns in output indicates transient failure
    if [ "$exit_code" -ne 0 ]; then
        if echo "$output" | grep -qiE '(500 Internal Server Error|502 Bad Gateway|503 Service Unavailable|429 Too Many Requests|rate.?limit|overloaded|temporarily unavailable|API error|api_error)'; then
            return 0
        fi
    fi
    return 1
}

# Log diagnostic information before Claude invocation
log_claude_diagnostics() {
    log_info "Claude Invocation Diagnostics:"
    log_info "  HOME: ${HOME:-unset}"
    log_info "  PWD: ${PWD:-unset}"
    log_info "  TTY available: $([ -t 0 ] && echo yes || echo no)"
    log_info "  CLAUDE_CODE_OAUTH_TOKEN: $([ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo set || echo unset)"
    log_info "  Claude version: $(claude --version 2>/dev/null || echo unknown)"
    log_info "  CLAUDE_TIMEOUT: ${CLAUDE_TIMEOUT}s"
    log_info "  API_RETRY_TIMEOUT: ${API_RETRY_TIMEOUT}s"
}

# Report API failure to GitHub issue and label it
report_api_failure_to_github() {
    local issue_num="$1"
    local retry_duration="$2"
    local last_exit_code="$3"

    log_warn "Reporting API failure to GitHub issue #$issue_num..."

    local comment_body
    comment_body="## ⚠️ Container Failed: Transient API Error

The container sprint workflow for this issue failed due to repeated transient API errors after **${retry_duration} seconds** of retries.

**Details:**
- Error type: Transient API failure (HTTP 500/502/503/429)
- Retry duration: ${retry_duration}s (limit: ${API_RETRY_TIMEOUT}s)
- Last exit code: ${last_exit_code}

**Action required:** This issue can be re-launched when the API recovers. It has been labeled \`api-failure\` for easy filtering.

To re-launch: \`./scripts/container-launch.sh $issue_num\`"

    # Post comment to issue
    gh issue comment "$issue_num" --body "$comment_body" 2>/dev/null || \
        log_warn "Failed to post failure comment to issue #$issue_num"

    # Add api-failure label (create if it doesn't exist)
    gh label create "api-failure" --description "Failed due to transient API errors, safe to re-launch" --color "e11d48" 2>/dev/null || true
    gh issue edit "$issue_num" --add-label "api-failure" 2>/dev/null || \
        log_warn "Failed to add api-failure label to issue #$issue_num"

    log_info "GitHub issue #$issue_num updated with API failure information"
}

# Invoke Claude with exponential backoff retry for transient API errors.
# On exhausted retries (10-minute window), reports failure to GitHub and exits 3.
# Uses a temp file for the prompt to avoid stdin/pipe issues (Issue #476).
#
# Arguments:
#   $1 - prompt text
#   $2 - optional: interactive mode flag ("interactive" or empty)
invoke_claude_with_retry() {
    local prompt="$1"
    local interactive_mode="${2:-}"

    # Write prompt to temp file (avoids stdin pipe issues, see Issue #476)
    local PROMPT_FILE
    PROMPT_FILE=$(mktemp)
    echo "$prompt" > "$PROMPT_FILE"
    # Ensure cleanup on function exit
    trap 'rm -f "$PROMPT_FILE"' RETURN

    local retry_start
    retry_start=$(date +%s)
    local attempt=0
    local backoff=5  # initial backoff seconds
    local last_exit=0
    local last_output=""

    while true; do
        attempt=$((attempt + 1))
        local now
        now=$(date +%s)
        local elapsed=$((now - retry_start))

        if [ "$attempt" -gt 1 ]; then
            log_info "API retry attempt $attempt (elapsed: ${elapsed}s / ${API_RETRY_TIMEOUT}s)..."
        fi

        if [ "$interactive_mode" = "interactive" ]; then
            # Interactive mode: human-supervised, can prompt for permissions
            claude --permission-mode default < "$PROMPT_FILE"
            last_exit=$?
            last_output=""
        else
            # Non-interactive mode: capture output for error detection
            if [ -f "$CLAUDE_SETTINGS" ]; then
                last_output=$(timeout "$CLAUDE_TIMEOUT" claude -p \
                    --permission-mode bypassPermissions \
                    --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
                    --system-prompt "$TOOL_SYSTEM_PROMPT" \
                    --settings "$CLAUDE_SETTINGS" \
                    < "$PROMPT_FILE" 2>&1)
                last_exit=$?
            else
                log_warn "Settings file not found, using basic permissions"
                last_output=$(timeout "$CLAUDE_TIMEOUT" claude -p \
                    --permission-mode bypassPermissions \
                    --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
                    --system-prompt "$TOOL_SYSTEM_PROMPT" \
                    < "$PROMPT_FILE" 2>&1)
                last_exit=$?
            fi
            # Print captured output so it appears in container logs
            echo "$last_output"
        fi

        # Handle timeout exit code (124 = timeout(1) killed the process)
        if [ "$last_exit" -eq 124 ]; then
            log_error "Claude invocation timed out after ${CLAUDE_TIMEOUT}s"
            echo "SPRINT_RESULT={\"status\":\"timeout\",\"issue\":$ISSUE,\"phase\":\"implementation\",\"exit_code\":124,\"message\":\"Claude invocation timed out after ${CLAUDE_TIMEOUT}s\"}"
            rm -f "$PROMPT_FILE"
            return 124
        fi

        # Success - return immediately
        if [ "$last_exit" -eq 0 ]; then
            rm -f "$PROMPT_FILE"
            return 0
        fi

        # Check if this is a transient API error worth retrying
        if is_transient_api_error "$last_exit" "$last_output"; then
            now=$(date +%s)
            elapsed=$((now - retry_start))

            if [ "$elapsed" -ge "$API_RETRY_TIMEOUT" ]; then
                log_error "Transient API errors persisted for ${elapsed}s (limit: ${API_RETRY_TIMEOUT}s) - giving up"
                report_api_failure_to_github "$ISSUE" "$elapsed" "$last_exit"
                echo "SPRINT_RESULT={\"status\":\"api_failure\",\"issue\":$ISSUE,\"phase\":\"implementation\",\"exit_code\":$EXIT_CODE_API_FAILURE,\"retry_duration\":$elapsed,\"message\":\"Transient API errors exhausted ${API_RETRY_TIMEOUT}s retry window\"}"
                rm -f "$PROMPT_FILE"
                exit "$EXIT_CODE_API_FAILURE"
            fi

            log_warn "Transient API error detected (exit $last_exit) - retrying in ${backoff}s (elapsed: ${elapsed}s / ${API_RETRY_TIMEOUT}s)"
            sleep "$backoff"

            # Exponential backoff: 5 → 10 → 20 → 40 → 60 (cap at 60s)
            backoff=$((backoff * 2))
            if [ "$backoff" -gt 60 ]; then
                backoff=60
            fi
            continue
        fi

        # Non-transient error - return the exit code without retrying
        rm -f "$PROMPT_FILE"
        return "$last_exit"
    done
}

log_claude_diagnostics

if [ "${INTERACTIVE_MODE:-false}" = "true" ]; then
    # Interactive mode: human-supervised, can prompt for permissions
    log_info "Running in INTERACTIVE mode (permission prompts enabled)"
    invoke_claude_with_retry "$IMPLEMENTATION_PROMPT" "interactive"
else
    # Non-interactive mode: autonomous execution with all tools pre-approved
    invoke_claude_with_retry "$IMPLEMENTATION_PROMPT"
fi

CLAUDE_EXIT=$?

# Stop background issue heartbeat now that Claude has finished
stop_issue_heartbeat

# Stop watchdog
if [ -n "$WATCHDOG_PID" ]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    log_info "Stopped watchdog"
fi

if [ $CLAUDE_EXIT -ne 0 ]; then
    log_error "Claude exited with code $CLAUDE_EXIT"
    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
        phase_error "implement" "Claude exited with code $CLAUDE_EXIT"
    fi
    # Write error result for host capture
    echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"implementation\",\"exit_code\":$CLAUDE_EXIT,\"message\":\"Claude exited with code $CLAUDE_EXIT\"}"
    # Post failure notification to GitHub issue
    post_issue_failure "implement" "Claude exited with code $CLAUDE_EXIT"
    # Don't exit - still try to push what we have
else
    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
        phase_complete "implement" "complete"
    fi
    post_issue_progress "test" "Implementation complete, validating and preparing PR"
fi

# ============================================================================
# Phase 3.5: Validate Implementation (Check files were written)
# ============================================================================
log_info "Validating implementation..."

# Check if HEAD changed (Claude may have already committed)
HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
if [ -n "$HEAD_BEFORE" ] && [ -n "$HEAD_AFTER" ] && [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
    log_info "Implementation validated - Claude committed changes (HEAD: $HEAD_BEFORE → $HEAD_AFTER)"
    IMPLEMENTATION_VALIDATED=true
# Check if there are any changes (staged or unstaged)
elif ! git diff --quiet || ! git diff --staged --quiet; then
    log_info "Implementation validated - files were modified"
    IMPLEMENTATION_VALIDATED=true
else
    # Check if any new untracked files were created
    UNTRACKED=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
    if [ "$UNTRACKED" -gt 0 ]; then
        log_info "Found $UNTRACKED new untracked files"
        IMPLEMENTATION_VALIDATED=true
    else
        # Retry with a more explicit prompt before giving up
        if [ "${RETRY_ATTEMPTED:-false}" = "false" ]; then
            log_warn "No files written on first attempt - retrying with explicit prompt..."
            RETRY_ATTEMPTED=true

            # Build a retry prompt that is more explicit about what to do
            RETRY_PROMPT="IMPORTANT: Your previous attempt did not create or modify any files. You MUST use tools to write code.

$IMPLEMENTATION_PROMPT

CRITICAL INSTRUCTIONS FOR THIS RETRY:
- You MUST call the Write tool or Edit tool at least once.
- If the task seems too large, implement just the first acceptance criterion.
- If you need to understand existing code first, use Read tool, then immediately Write/Edit.
- Do NOT describe what you would do. Actually call the tools.
- If the issue references dependencies that don't exist yet, create stub implementations.
- After writing files, run: git add -A && git commit -m '$PR_PREFIX: $ISSUE_TITLE'

Begin by using the Read tool on a relevant file, then use Write or Edit to make changes."

            log_info "Retrying Claude invocation..."
            HEAD_BEFORE=$(git rev-parse HEAD 2>/dev/null || echo "")

            if [ "${INTERACTIVE_MODE:-false}" = "true" ]; then
                invoke_claude_with_retry "$RETRY_PROMPT" "interactive"
            else
                invoke_claude_with_retry "$RETRY_PROMPT"
            fi

            # Re-validate after retry
            HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null || echo "")
            if [ -n "$HEAD_BEFORE" ] && [ -n "$HEAD_AFTER" ] && [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]; then
                log_info "Retry successful - Claude committed changes"
                IMPLEMENTATION_VALIDATED=true
            elif ! git diff --quiet || ! git diff --staged --quiet; then
                log_info "Retry successful - files were modified"
                IMPLEMENTATION_VALIDATED=true
            else
                UNTRACKED_RETRY=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
                if [ "$UNTRACKED_RETRY" -gt 0 ]; then
                    log_info "Retry successful - found $UNTRACKED_RETRY new files"
                    IMPLEMENTATION_VALIDATED=true
                else
                    log_error "IMPLEMENTATION VALIDATION FAILED after retry: No files were created or modified"
                    log_error "Claude described the implementation but did not use Write/Edit tools"
                    log_error "See issue #705 for investigation"

                    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
                        phase_error "implement" "No files written after retry - Claude described but did not implement"
                    fi

                    echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"validation\",\"error\":\"NO_FILES_WRITTEN\",\"message\":\"Claude described implementation but did not use Write/Edit tools to create files (after retry)\"}"
                    exit 1
                fi
            fi
        else
            log_error "IMPLEMENTATION VALIDATION FAILED: No files were created or modified"
            log_error "Claude described the implementation but did not use Write/Edit tools"
            log_error "See issue #705 for investigation"

            if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
                phase_error "implement" "No files written - Claude described but did not implement"
            fi

            echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"validation\",\"error\":\"NO_FILES_WRITTEN\",\"message\":\"Claude described implementation but did not use Write/Edit tools to create files\"}"
            exit 1
        fi
    fi
fi

# ============================================================================
# Phase 4: Post-Work (Script-Handled)
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_start "post_work"
fi
log_phase "Phase 4: Post-Work"
watchdog_phase "post-work"
post_issue_progress "pr" "Pushing changes and creating pull request"

# Check if there are any changes to commit
if git diff --quiet && git diff --staged --quiet; then
    log_warn "No changes to commit"
else
    # Ensure all changes are staged and committed
    log_info "Staging any remaining changes..."
    git add -A

    if ! git diff --staged --quiet; then
        log_info "Committing remaining changes..."
        git commit -m "chore: finalize implementation for issue #$ISSUE

Co-Authored-By: Claude <noreply@anthropic.com>" || true

        # Log commit to structured log
        if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
            COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
            log_git_commit "$COMMIT_SHA" "finalize implementation for issue #$ISSUE"
        fi
    fi
fi

# Configure git credentials for push (use GITHUB_TOKEN)
if [ -n "$GITHUB_TOKEN" ]; then
    log_info "Configuring git credentials..."
    git config credential.helper "!f() { echo username=x-access-token; echo password=\$GITHUB_TOKEN; }; f"
fi

# Auto-rebase on latest base branch before push to prevent conflicts
log_info "Rebasing on latest $BRANCH to prevent conflicts..."
git fetch origin "$BRANCH"

if ! git rebase "origin/$BRANCH"; then
    log_warn "Rebase conflicts detected"
    git rebase --abort
    log_error "AUTO_REBASE_FAILED: Conflicts detected when rebasing on origin/$BRANCH"
    log_error "Manual intervention required - issue will remain in-progress"

    # Write error result for host capture
    echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"rebase\",\"error\":\"AUTO_REBASE_FAILED\",\"message\":\"Rebase conflicts detected, manual intervention required\"}"
    post_issue_failure "pr" "Rebase conflicts detected when rebasing on origin/$BRANCH - manual intervention required"
    exit 1
fi

log_info "Rebase successful"

# Validate feature branch still exists before attempting push
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$FEATURE_BRANCH" ]; then
    log_error "BRANCH VALIDATION FAILED: Not on feature branch $FEATURE_BRANCH (currently on: $CURRENT_BRANCH)"
    log_error "The feature branch may have been deleted during execution"
    log_error "This is a critical error - all work may be lost"

    # Check if feature branch exists at all
    if ! git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1; then
        log_error "Feature branch $FEATURE_BRANCH does not exist!"
        log_error "Claude may have deleted it during 'already-complete detection'"
        echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"post_work\",\"error\":\"BRANCH_DELETED\",\"message\":\"Feature branch was deleted during execution - all work lost\"}"
        exit 1
    else
        # Branch exists but we're not on it - try to switch back
        log_warn "Feature branch exists but not checked out - attempting to switch back"
        git checkout "$FEATURE_BRANCH" || {
            log_error "Failed to checkout feature branch"
            exit 1
        }
    fi
fi

# Double-check branch exists as a remote-tracking branch candidate
if ! git rev-parse --verify "$FEATURE_BRANCH" >/dev/null 2>&1; then
    log_error "CRITICAL: Feature branch $FEATURE_BRANCH does not exist"
    log_error "Cannot push a non-existent branch"
    echo "SPRINT_RESULT={\"status\":\"error\",\"issue\":$ISSUE,\"phase\":\"post_work\",\"error\":\"BRANCH_MISSING\",\"message\":\"Feature branch $FEATURE_BRANCH does not exist, cannot push\"}"
    exit 1
fi

# Push to remote
log_info "Pushing to origin..."
git push -u origin "$FEATURE_BRANCH" --force-with-lease || {
    log_error "Push failed"
    exit 1
}

# Check if PR already exists
log_info "Checking for existing PR..."
EXISTING_PR=$(gh pr list --head "$FEATURE_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

if [ -n "$EXISTING_PR" ]; then
    log_info "PR #$EXISTING_PR already exists, updating..."
    PR_URL="https://github.com/$REPO_FULL_NAME/pull/$EXISTING_PR"
else
    log_info "Creating PR..."

    # Build PR body
    batch_note=""
    if [ -n "$BATCH_BRANCH" ]; then
        batch_note="
> **Note**: This PR targets batch branch \`$BATCH_BRANCH\` for parallel execution.
> A separate PR will merge the batch branch to \`$BRANCH\`.
"
    fi

    PR_BODY="## Summary
Implements issue #$ISSUE: $ISSUE_TITLE
$batch_note
Fixes #$ISSUE

## Changes
$(git log origin/$TARGET_BRANCH..HEAD --oneline | head -10)

## Test Plan
- [ ] Automated tests pass
- [ ] Manual verification complete

---
**Note:** GitHub only auto-closes issues when PRs merge to the default branch (\`main\`).
This PR targets \`$BRANCH\`, so the linked issue will need to be closed manually or
when this is promoted to \`main\`.

Generated by container-sprint-workflow.sh"

    # PR_PREFIX already set earlier in the script

    PR_URL=$(gh pr create \
        --base "$TARGET_BRANCH" \
        --head "$FEATURE_BRANCH" \
        --title "$PR_PREFIX: $ISSUE_TITLE" \
        --body "$PR_BODY" 2>&1) || {
        log_error "PR creation failed: $PR_URL"
        exit 1
    }

    if [ -n "$BATCH_BRANCH" ]; then
        log_info "PR created targeting batch branch: $PR_URL"
    else
        log_info "PR created: $PR_URL"
    fi

    # Log PR creation to structured log
    if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
        PR_NUM=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "0")
        log_pr_created "$PR_NUM" "$PR_URL"
    fi
fi

if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_complete "post_work" "complete"
fi

# ============================================================================
# Phase 4.5: PR Cross-Reference Check (Issue #1271)
# Scan open issues for overlap with this PR and post context comments.
# Non-fatal: failures are logged but do not abort the workflow.
# Controlled by NO_CROSS_REF=true or --no-cross-ref flag.
# ============================================================================
if [ "${NO_CROSS_REF:-false}" != "true" ] && [ -n "${PR_NUMBER:-}" ] && [ -n "$ISSUE" ]; then
    log_phase "Phase 4.5: PR Cross-Reference Check"
    watchdog_phase "cross-ref"
    post_issue_progress "pr" "Running cross-reference check on open issues"

    XREF_SCRIPT=""
    for xref_path in "${SCRIPT_DIR}/pr-cross-reference.sh" "/workspace/repo/scripts/pr-cross-reference.sh"; do
        if [ -f "$xref_path" ] && [ -x "$xref_path" ]; then
            XREF_SCRIPT="$xref_path"
            break
        fi
    done

    if [ -n "$XREF_SCRIPT" ]; then
        set +e
        "$XREF_SCRIPT" \
            --pr "$PR_NUMBER" \
            --issue "$ISSUE" \
            --repo "$REPO_FULL_NAME" \
            --max-updates 10 \
            2>/dev/null
        XREF_EXIT=$?
        set -e

        if [ $XREF_EXIT -ne 0 ]; then
            log_warn "Cross-reference check exited with code $XREF_EXIT (non-fatal)"
        else
            log_info "Cross-reference check complete"
        fi
    else
        log_warn "pr-cross-reference.sh not found, skipping cross-reference check"
    fi
else
    log_info "Skipping cross-reference check (NO_CROSS_REF=true or missing PR/issue number)"
fi

# ============================================================================
# Phase 5: CI Status Check (Post-PR) - Enhanced with Resilience Features
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_start "ci_check"
fi
log_phase "Phase 5: CI Status Check"
watchdog_phase "ci-check"

# Extract PR number from URL
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "")

# Check if PR was already merged externally (issue #626)
if [ -n "$PR_NUMBER" ]; then
    log_info "Checking if PR was merged externally..."
    PR_STATE=$(gh pr view "$PR_NUMBER" --json state -q .state 2>/dev/null || echo "")
    if [ "$PR_STATE" = "MERGED" ]; then
        log_info "PR #$PR_NUMBER already merged externally. Exiting gracefully."
        echo "SPRINT_RESULT={\"status\":\"success\",\"issue\":$ISSUE,\"title\":\"$ISSUE_TITLE\",\"branch\":\"$FEATURE_BRANCH\",\"pr_url\":\"$PR_URL\",\"pr_number\":$PR_NUMBER,\"ci_status\":\"merged_externally\",\"message\":\"PR was merged externally\"}"
        exit 0
    fi
fi

# Check if issue was already closed externally (issue #626)
log_info "Checking if issue was closed externally..."
ISSUE_STATE=$(gh issue view "$ISSUE" --json state -q .state 2>/dev/null || echo "")
if [ "$ISSUE_STATE" = "CLOSED" ]; then
    log_info "Issue #$ISSUE already closed externally. Exiting gracefully."
    echo "SPRINT_RESULT={\"status\":\"success\",\"issue\":$ISSUE,\"title\":\"$ISSUE_TITLE\",\"branch\":\"$FEATURE_BRANCH\",\"pr_url\":\"$PR_URL\",\"pr_number\":$PR_NUMBER,\"ci_status\":\"issue_closed_externally\",\"message\":\"Issue was closed externally\"}"
    exit 0
fi

# Check CI status with wait and retry
CI_STATUS="unknown"
CI_SUMMARY=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$PR_NUMBER" ] && [ -x "$SCRIPT_DIR/check-pr-ci-status.sh" ]; then
    log_info "Checking CI status with resilience features enabled..."

    # Use shorter wait/timeout in container to avoid long hangs
    CI_WAIT="${CI_WAIT:-60}"
    CI_TIMEOUT="${CI_TIMEOUT:-300}"

    # State file for container restart recovery (Issue #547)
    CI_STATE_FILE="/tmp/ci-wait-state-${PR_NUMBER}.json"

    # Enable resume mode if state file exists from previous run
    RESUME_FLAG=""
    if [ -f "$CI_STATE_FILE" ]; then
        log_info "Found previous CI wait state, resuming..."
        RESUME_FLAG="--resume"
    fi

    # Enable debug logging if DEBUG env var is set
    export DEBUG="${DEBUG:-false}"

    set +e
    CI_RESULT=$("$SCRIPT_DIR/check-pr-ci-status.sh" "$PR_NUMBER" \
        --wait "$CI_WAIT" \
        --timeout "$CI_TIMEOUT" \
        --state-file "$CI_STATE_FILE" \
        $RESUME_FLAG \
        --json)
    CI_EXIT=$?
    set -e

    # Validate CI_RESULT is valid JSON before parsing
    if echo "$CI_RESULT" | jq empty 2>/dev/null; then
        CI_STATUS=$(echo "$CI_RESULT" | jq -r '.status // "unknown"')
        CI_SUMMARY=$(echo "$CI_RESULT" | jq -r '.summary // "No summary"')
    else
        log_warn "CI status check returned non-JSON output (exit $CI_EXIT): ${CI_RESULT:0:200}"
        CI_STATUS="error"
        CI_SUMMARY="CI status check failed with non-JSON output"
    fi

    case $CI_EXIT in
        0)
            log_info "CI Status: MERGEABLE - $CI_SUMMARY"
            ;;
        1)
            log_warn "CI Status: NEEDS REVIEW - $CI_SUMMARY"
            FAILED=$(echo "$CI_RESULT" | jq -r '.checks.failed_checks // ""')
            if [ -n "$FAILED" ]; then
                log_warn "Failed checks: $FAILED"
            fi
            ;;
        2)
            log_warn "CI Status: PENDING - $CI_SUMMARY"
            log_info "CI wait state saved to: $CI_STATE_FILE"
            log_info "Container can be restarted and will resume from current position"
            ;;
        *)
            log_warn "CI Status: Could not determine - $CI_SUMMARY"
            ;;
    esac
else
    log_info "Skipping CI check (PR number not available or script missing)"
fi

if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    phase_complete "ci_check" "complete"
fi

# ============================================================================
# Phase 6: Completion & Result Output
# ============================================================================
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ]; then
    # Finalize metrics before completion message
    finalize_metrics
fi
log_phase "Workflow Complete"
watchdog_heartbeat "Workflow complete"

# Post completion summary to GitHub issue
post_issue_complete "${PR_URL:-}" "${PR_NUMBER:-0}"

# Cleanup watchdog heartbeat file
watchdog_cleanup

# Persist metrics to host-accessible location (Issue #592)
# Note: Actual persistence happens via container-cleanup.sh or manual extraction
# Here we ensure metrics.json is finalized and accessible
if [ "${STRUCTURED_LOGGING_ENABLED:-}" = "true" ] && [ -f "$METRICS_FILE" ]; then
    log_info "Metrics finalized at: $METRICS_FILE"
    log_info "To persist: ./scripts/container-metrics-persist.sh $ISSUE"
fi

# Write structured JSON result to predictable location
# Host can capture via: docker logs <name> | grep SPRINT_RESULT | cut -d'=' -f2-
RESULT_JSON=$(cat <<EOF
{"status":"success","issue":$ISSUE,"title":"$ISSUE_TITLE","branch":"$FEATURE_BRANCH","pr_url":"$PR_URL","pr_number":$PR_NUMBER,"ci_status":"$CI_STATUS"}
EOF
)

# Write to file (for docker cp if needed)
echo "$RESULT_JSON" > /tmp/sprint-result.json

# Output as tagged line in logs (for docker logs parsing)
echo "SPRINT_RESULT=$RESULT_JSON"

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  CONTAINER SPRINT WORKFLOW COMPLETE                          ║"
echo "╠═══════════════════════════════════════════════════════════════╣"
echo "║  Issue: #$ISSUE - $ISSUE_TITLE"
echo "║  Branch: $FEATURE_BRANCH"
echo "║  PR: $PR_URL"
echo "║  CI Status: $CI_STATUS"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo ""

# Show CI status guidance
case "$CI_STATUS" in
    mergeable)
        echo "✅ PR is ready to merge - all CI checks passed"
        ;;
    needs_review)
        echo "❌ PR needs review - some CI checks failed"
        echo "   View checks: gh pr checks $PR_NUMBER"
        ;;
    pending)
        echo "⏳ CI checks still running"
        echo "   Monitor: gh pr checks $PR_NUMBER --watch"
        ;;
    *)
        echo "ℹ️  CI status unknown - check manually"
        ;;
esac
echo ""

# ============================================================================
# Notify n8n-github for automated PR merge pipeline
# ============================================================================
log_info "Notifying n8n-github for automated merge pipeline..."

# Check if notifier script exists
if [[ -x "$SCRIPT_DIR/container-complete-notifier.sh" ]]; then
    # Send notification to n8n-github webhook
    # This triggers the pr-merge-pipeline workflow which will:
    # 1. Check if PR is mergeable
    # 2. If CONFLICTING, rebase and retry
    # 3. If mergeable, auto-merge
    # 4. On successful merge, cleanup this container

    if "$SCRIPT_DIR/container-complete-notifier.sh" "$ISSUE" "$PR_NUMBER" "$PR_URL" "$CI_STATUS"; then
        log_info "✓ n8n-github notified - PR merge pipeline initiated"
    else
        log_warn "! Failed to notify n8n-github (non-fatal)"
    fi
else
    log_warn "! container-complete-notifier.sh not found, skipping n8n notification"
fi

echo ""

exit 0
