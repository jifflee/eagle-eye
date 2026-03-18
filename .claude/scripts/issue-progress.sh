#!/bin/bash
set -euo pipefail
# issue-progress.sh
# Posts real-time agent progress comments to GitHub issues during work (Issue #1269)
# size-ok: multi-mode progress reporting with phase updates, heartbeat, blocker detection, and completion
#
# Agents post structured progress comments to their assigned GitHub issue at each
# SDLC phase transition, on heartbeat intervals, blocker detection, and completion.
#
# Comment Format:
#   <!-- agent-progress:{phase}:{status} -->
#   (machine-parseable marker used by issue-monitor.sh)
#
# Usage:
#   ./scripts/issue-progress.sh --issue N --phase implement --status "Writing auth service"
#   ./scripts/issue-progress.sh --issue N --heartbeat
#   ./scripts/issue-progress.sh --issue N --blocker 456 --reason "Waiting for auth module"
#   ./scripts/issue-progress.sh --issue N --complete --pr-url https://... --pr-number 789
#   ./scripts/issue-progress.sh --issue N --fail --phase implement --error "Claude timed out"
#   ./scripts/issue-progress.sh --issue N --read-wip   # Read progress from other agents
#
# Environment Variables:
#   ISSUE              - Issue number (can also be passed via --issue)
#   CONTAINER_NAME     - Container identifier (default: auto-detected)
#   AGENT_TYPE         - Agent type: container|worktree (default: container)
#   REPO_FULL_NAME     - owner/repo format (auto-detected from git if not set)
#   PROGRESS_COMMENT_MARKER - HTML comment marker prefix (default: agent-progress)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities if available
for path in "${SCRIPT_DIR}/lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        break
    fi
done

# Fallback logging if common.sh not loaded
if ! command -v log_info >/dev/null 2>&1; then
    log_info()  { echo "[INFO] $*" >&2; }
    log_warn()  { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ─── Configuration ────────────────────────────────────────────────────────────

MARKER_PREFIX="${PROGRESS_COMMENT_MARKER:-agent-progress}"
AGENT_TYPE="${AGENT_TYPE:-container}"

# Auto-detect container/worktree name
if [ -z "${CONTAINER_NAME:-}" ]; then
    CONTAINER_NAME="${HOSTNAME:-$(hostname 2>/dev/null || echo "unknown")}"
fi

# Auto-detect repo
if [ -z "${REPO_FULL_NAME:-}" ]; then
    REPO_FULL_NAME=$(git remote get-url origin 2>/dev/null \
        | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|' \
        || echo "")
fi

# SDLC phase ordering (for display as N/M)
PHASES=("spec" "design" "implement" "test" "docs" "pr")
PHASE_COUNT=${#PHASES[@]}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Return 1-based index of a phase name, or 0 if unknown
phase_index() {
    local target="$1"
    local i
    for i in "${!PHASES[@]}"; do
        if [ "${PHASES[$i]}" = "$target" ]; then
            echo $((i + 1))
            return
        fi
    done
    echo "0"
}

# Format elapsed seconds as "Xm Ys"
format_duration() {
    local secs="${1:-0}"
    local mins=$((secs / 60))
    local rem=$((secs % 60))
    if [ "$mins" -gt 0 ]; then
        echo "${mins}m ${rem}s"
    else
        echo "${rem}s"
    fi
}

# Count modified files in git working tree
count_modified_files() {
    git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' '
}

# Get current UTC timestamp
utc_timestamp() {
    date -u "+%Y-%m-%d %H:%M:%S UTC"
}

# Build the structured comment body for a phase update
build_phase_comment() {
    local issue="$1"
    local phase="$2"
    local status_msg="$3"
    local container="$4"
    local blocker="${5:-None}"
    local start_epoch="${6:-0}"

    local phase_num
    phase_num=$(phase_index "$phase")

    local phase_display="${phase_num}/${PHASE_COUNT}"
    if [ "$phase_num" -eq 0 ]; then
        phase_display="?/${PHASE_COUNT}"
    fi

    local duration_str="0s"
    if [ "$start_epoch" -gt 0 ]; then
        local now_epoch
        now_epoch=$(date +%s)
        duration_str=$(format_duration $((now_epoch - start_epoch)))
    fi

    local files_modified
    files_modified=$(count_modified_files)

    local ts
    ts=$(utc_timestamp)

    cat <<EOF
<!-- ${MARKER_PREFIX}:${phase}:in-progress -->
<details open>
<summary>🤖 <strong>Agent Progress Update</strong> (${AGENT_TYPE}: ${container})</summary>

| Field | Value |
|-------|-------|
| **Phase** | ${phase} (${phase_display}) |
| **Status** | ${status_msg} |
| **Files modified** | ${files_modified} |
| **Duration** | ${duration_str} |
| **Blocking** | ${blocker} |

_Last updated: ${ts}_

</details>
EOF
}

# Build heartbeat comment body
build_heartbeat_comment() {
    local issue="$1"
    local phase="$2"
    local status_msg="$3"
    local container="$4"
    local start_epoch="${5:-0}"

    local phase_num
    phase_num=$(phase_index "$phase")
    local phase_display="${phase_num}/${PHASE_COUNT}"
    [ "$phase_num" -eq 0 ] && phase_display="?/${PHASE_COUNT}"

    local duration_str="0s"
    if [ "$start_epoch" -gt 0 ]; then
        local now_epoch
        now_epoch=$(date +%s)
        duration_str=$(format_duration $((now_epoch - start_epoch)))
    fi

    local files_modified
    files_modified=$(count_modified_files)

    local ts
    ts=$(utc_timestamp)

    cat <<EOF
<!-- ${MARKER_PREFIX}:${phase}:heartbeat -->
<details>
<summary>🤖 <strong>Agent Heartbeat</strong> (${AGENT_TYPE}: ${container})</summary>

| Field | Value |
|-------|-------|
| **Phase** | ${phase} (${phase_display}) |
| **Status** | ${status_msg} |
| **Files modified** | ${files_modified} |
| **Duration** | ${duration_str} |

_Heartbeat: ${ts}_

</details>
EOF
}

# Build blocker comment body (posted to both issues)
build_blocker_comment() {
    local this_issue="$1"
    local blocking_issue="$2"
    local reason="$3"
    local container="$4"
    local phase="${5:-implement}"

    local ts
    ts=$(utc_timestamp)

    cat <<EOF
<!-- ${MARKER_PREFIX}:${phase}:blocked -->
## ⚠️ Agent Blocker Detected

**Container/Worktree:** ${container}
**Working on:** #${this_issue}
**Blocked by:** #${blocking_issue}

**Reason:** ${reason}

Work on issue #${this_issue} is paused until #${blocking_issue} is resolved.

_Detected: ${ts}_
EOF
}

# Build completion comment body
build_complete_comment() {
    local issue="$1"
    local pr_url="$2"
    local pr_number="$3"
    local container="$4"
    local start_epoch="${5:-0}"

    local duration_str="0s"
    if [ "$start_epoch" -gt 0 ]; then
        local now_epoch
        now_epoch=$(date +%s)
        duration_str=$(format_duration $((now_epoch - start_epoch)))
    fi

    local files_modified
    files_modified=$(count_modified_files)

    # Count commits made on feature branch vs base
    local commit_count=0
    commit_count=$(git log --oneline "origin/${BRANCH:-main}..HEAD" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    local ts
    ts=$(utc_timestamp)

    cat <<EOF
<!-- ${MARKER_PREFIX}:complete:success -->
## ✅ Agent Work Complete

**Container/Worktree:** ${container}
**PR:** [#${pr_number}](${pr_url})

<details>
<summary>Work Summary</summary>

| Field | Value |
|-------|-------|
| **Files modified** | ${files_modified} |
| **Commits** | ${commit_count} |
| **Total duration** | ${duration_str} |

</details>

_Completed: ${ts}_
EOF
}

# Build failure comment body
build_failure_comment() {
    local issue="$1"
    local phase="$2"
    local error_msg="$3"
    local container="$4"
    local start_epoch="${5:-0}"

    local duration_str="0s"
    if [ "$start_epoch" -gt 0 ]; then
        local now_epoch
        now_epoch=$(date +%s)
        duration_str=$(format_duration $((now_epoch - start_epoch)))
    fi

    local ts
    ts=$(utc_timestamp)

    cat <<EOF
<!-- ${MARKER_PREFIX}:${phase}:failed -->
## ❌ Agent Work Failed

**Container/Worktree:** ${container}
**Phase:** ${phase}
**Duration before failure:** ${duration_str}

<details>
<summary>Error Details</summary>

\`\`\`
${error_msg}
\`\`\`

</details>

**Remediation:** Re-launch container with \`./scripts/container/container-launch.sh ${issue}\`

_Failed: ${ts}_
EOF
}

# Post or update a GitHub issue comment.
# Looks for an existing agent-progress comment and edits it (to avoid spam),
# or creates a new one if none exists.
post_or_update_comment() {
    local issue="$1"
    local body="$2"
    local mode="${3:-update}"  # update|new

    if [ -z "${REPO_FULL_NAME:-}" ]; then
        log_warn "REPO_FULL_NAME not set - cannot post GitHub comment"
        return 0
    fi

    if [ "$mode" = "new" ]; then
        # Always create a new comment (used for blockers/completion/failure)
        gh issue comment "$issue" --body "$body" 2>/dev/null || \
            log_warn "Failed to post new comment to issue #$issue"
        return
    fi

    # For phase updates and heartbeats: find and edit existing agent-progress comment,
    # or create one if no prior comment exists.
    local existing_comment_id
    existing_comment_id=$(gh api \
        "repos/${REPO_FULL_NAME}/issues/${issue}/comments" \
        --jq "[.[] | select(.body | startswith(\"<!-- ${MARKER_PREFIX}:\"))] | last | .id // empty" \
        2>/dev/null || echo "")

    if [ -n "$existing_comment_id" ] && [ "$existing_comment_id" != "null" ]; then
        # Edit existing comment in-place
        gh api \
            --method PATCH \
            "repos/${REPO_FULL_NAME}/issues/comments/${existing_comment_id}" \
            --field body="$body" \
            >/dev/null 2>&1 || \
            log_warn "Failed to update comment ${existing_comment_id} on issue #$issue"
        log_info "Updated progress comment on issue #$issue (comment #$existing_comment_id)"
    else
        # No existing comment - create one
        gh issue comment "$issue" --body "$body" 2>/dev/null || \
            log_warn "Failed to post progress comment to issue #$issue"
        log_info "Posted new progress comment to issue #$issue"
    fi
}

# Read WIP progress from issue comments posted by other agents
read_wip_progress() {
    local issue="$1"

    if [ -z "${REPO_FULL_NAME:-}" ]; then
        log_warn "REPO_FULL_NAME not set - cannot read comments"
        echo '{"error": "REPO_FULL_NAME not set"}'
        return 1
    fi

    local comments
    comments=$(gh api \
        "repos/${REPO_FULL_NAME}/issues/${issue}/comments" \
        --jq "[.[] | select(.body | startswith(\"<!-- ${MARKER_PREFIX}:\"))]" \
        2>/dev/null || echo "[]")

    if [ "$comments" = "[]" ] || [ -z "$comments" ]; then
        echo '{"wip": false, "issue": '"$issue"', "progress_comments": []}'
        return 0
    fi

    # Parse the latest progress comment
    local latest_comment
    latest_comment=$(echo "$comments" | jq 'last')

    local latest_body
    latest_body=$(echo "$latest_comment" | jq -r '.body // ""')
    local latest_updated
    latest_updated=$(echo "$latest_comment" | jq -r '.updated_at // ""')

    # Extract phase and status from marker line
    # Format: <!-- agent-progress:{phase}:{status} -->
    local marker_line
    marker_line=$(echo "$latest_body" | grep -oE "<!-- ${MARKER_PREFIX}:[^>]+ -->" | head -1 || echo "")

    local phase="unknown"
    local wip_status="unknown"
    if [ -n "$marker_line" ]; then
        phase=$(echo "$marker_line" | sed -E "s|<!-- ${MARKER_PREFIX}:([^:]+):([^:]+) -->|\1|")
        wip_status=$(echo "$marker_line" | sed -E "s|<!-- ${MARKER_PREFIX}:([^:]+):([^:]+) -->|\2|")
    fi

    # Determine if actively in-progress (not complete/failed)
    local is_active=false
    if [ "$wip_status" != "success" ] && [ "$wip_status" != "failed" ]; then
        is_active=true
    fi

    # Check comment age to detect stale agents (>30 min = possibly stale)
    local is_stale=false
    local age_seconds=0
    if [ -n "$latest_updated" ]; then
        local now_epoch
        now_epoch=$(date +%s)
        local updated_epoch
        updated_epoch=$(date -d "$latest_updated" +%s 2>/dev/null || \
            date -j -f "%Y-%m-%dT%H:%M:%SZ" "$latest_updated" +%s 2>/dev/null || \
            echo "$now_epoch")
        age_seconds=$((now_epoch - updated_epoch))
        if [ "$age_seconds" -gt 1800 ]; then  # 30 minutes
            is_stale=true
        fi
    fi

    jq -n \
        --argjson wip "$is_active" \
        --arg issue "$issue" \
        --arg phase "$phase" \
        --arg status "$wip_status" \
        --argjson stale "$is_stale" \
        --argjson age "$age_seconds" \
        --arg updated "$latest_updated" \
        --argjson count "$(echo "$comments" | jq 'length')" \
        '{
            wip: $wip,
            issue: ($issue | tonumber),
            phase: $phase,
            status: $status,
            stale: $stale,
            age_seconds: $age,
            last_updated: $updated,
            progress_comment_count: $count
        }'
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

ISSUE_NUM="${ISSUE:-}"
PHASE=""
STATUS_MSG=""
MODE=""         # phase|heartbeat|blocker|complete|fail|read-wip
BLOCKER_ISSUE=""
BLOCKER_REASON=""
PR_URL=""
PR_NUMBER=""
ERROR_MSG=""
START_EPOCH=0
ALWAYS_NEW=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue|-i)
            ISSUE_NUM="$2"; shift 2 ;;
        --phase|-p)
            PHASE="$2"; MODE="phase"; shift 2 ;;
        --status|-s)
            STATUS_MSG="$2"; shift 2 ;;
        --heartbeat)
            MODE="heartbeat"; shift ;;
        --blocker|-b)
            MODE="blocker"; BLOCKER_ISSUE="$2"; shift 2 ;;
        --reason|-r)
            BLOCKER_REASON="$2"; shift 2 ;;
        --complete)
            MODE="complete"; shift ;;
        --fail|--failure)
            MODE="fail"; shift ;;
        --pr-url)
            PR_URL="$2"; shift 2 ;;
        --pr-number)
            PR_NUMBER="$2"; shift 2 ;;
        --error|-e)
            ERROR_MSG="$2"; shift 2 ;;
        --start-epoch)
            START_EPOCH="$2"; shift 2 ;;
        --new)
            ALWAYS_NEW=true; shift ;;
        --container)
            CONTAINER_NAME="$2"; shift 2 ;;
        --read-wip)
            MODE="read-wip"; shift ;;
        --help|-h)
            cat <<'USAGE'
issue-progress.sh - Real-time agent progress updates for GitHub issues

USAGE:
    issue-progress.sh --issue N --phase PHASE --status "Status message"
    issue-progress.sh --issue N --heartbeat [--phase PHASE] [--status MSG]
    issue-progress.sh --issue N --blocker BLOCKING_ISSUE --reason "Reason"
    issue-progress.sh --issue N --complete --pr-url URL --pr-number N
    issue-progress.sh --issue N --fail --phase PHASE --error "Error message"
    issue-progress.sh --issue N --read-wip

MODES:
    --phase PHASE       Post/update phase progress comment
    --heartbeat         Post heartbeat update (edits existing comment)
    --blocker N         Post blocker notification to both issues
    --complete          Post completion summary with PR link
    --fail              Post failure notification
    --read-wip          Read WIP progress from other agents (outputs JSON)

OPTIONS:
    --issue N           Issue number (required, or set ISSUE env var)
    --status MSG        Status message for phase/heartbeat updates
    --phase PHASE       Phase name: spec|design|implement|test|docs|pr
    --reason TEXT       Reason for blocker
    --pr-url URL        PR URL for completion
    --pr-number N       PR number for completion
    --error TEXT        Error message for failure
    --start-epoch N     Unix epoch when work started (for duration calculation)
    --container NAME    Override container/worktree name
    --new               Always create new comment (don't edit existing)

PHASES: spec design implement test docs pr

EXAMPLES:
    # Post phase update
    issue-progress.sh --issue 123 --phase implement --status "Writing auth service"

    # Post heartbeat during long phase
    issue-progress.sh --issue 123 --heartbeat --phase implement

    # Report blocker
    issue-progress.sh --issue 123 --blocker 456 --reason "auth module not complete"

    # Report completion
    issue-progress.sh --issue 123 --complete --pr-url https://... --pr-number 789

    # Report failure
    issue-progress.sh --issue 123 --fail --phase implement --error "Timeout after 30m"

    # Check if another agent is working on this issue
    issue-progress.sh --issue 123 --read-wip

USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [ -z "$ISSUE_NUM" ]; then
    log_error "Issue number required: --issue N or set ISSUE env var"
    exit 1
fi

if [ -z "$MODE" ]; then
    log_error "Mode required: --phase, --heartbeat, --blocker, --complete, --fail, or --read-wip"
    exit 1
fi

# ─── Main Dispatch ────────────────────────────────────────────────────────────

case "$MODE" in
    phase)
        if [ -z "$PHASE" ]; then
            log_error "--phase PHASE required in phase mode"
            exit 1
        fi
        STATUS_MSG="${STATUS_MSG:-Working...}"
        body=$(build_phase_comment "$ISSUE_NUM" "$PHASE" "$STATUS_MSG" "$CONTAINER_NAME" "None" "$START_EPOCH")
        if [ "$ALWAYS_NEW" = "true" ]; then
            post_or_update_comment "$ISSUE_NUM" "$body" "new"
        else
            post_or_update_comment "$ISSUE_NUM" "$body" "update"
        fi
        ;;

    heartbeat)
        PHASE="${PHASE:-implement}"
        STATUS_MSG="${STATUS_MSG:-Active}"
        body=$(build_heartbeat_comment "$ISSUE_NUM" "$PHASE" "$STATUS_MSG" "$CONTAINER_NAME" "$START_EPOCH")
        post_or_update_comment "$ISSUE_NUM" "$body" "update"
        ;;

    blocker)
        if [ -z "$BLOCKER_ISSUE" ]; then
            log_error "--blocker BLOCKING_ISSUE required"
            exit 1
        fi
        BLOCKER_REASON="${BLOCKER_REASON:-Dependency not resolved}"
        PHASE="${PHASE:-implement}"

        # Post to the blocked issue (this issue)
        body=$(build_blocker_comment "$ISSUE_NUM" "$BLOCKER_ISSUE" "$BLOCKER_REASON" "$CONTAINER_NAME" "$PHASE")
        post_or_update_comment "$ISSUE_NUM" "$body" "new"

        # Post to the blocking issue (cross-reference)
        blocking_body=$(cat <<EOF
<!-- ${MARKER_PREFIX}:blocking:info -->
## ℹ️ This Issue Is Blocking Another Agent

**Container/Worktree:** ${CONTAINER_NAME}
**Blocked issue:** #${ISSUE_NUM}
**Reason:** ${BLOCKER_REASON}

Issue #${ISSUE_NUM} is waiting on this issue to be resolved.

_Detected: $(utc_timestamp)_
EOF
)
        post_or_update_comment "$BLOCKER_ISSUE" "$blocking_body" "new"
        log_info "Blocker posted to both issues #$ISSUE_NUM and #$BLOCKER_ISSUE"
        ;;

    complete)
        PR_URL="${PR_URL:-}"
        PR_NUMBER="${PR_NUMBER:-0}"
        body=$(build_complete_comment "$ISSUE_NUM" "$PR_URL" "$PR_NUMBER" "$CONTAINER_NAME" "$START_EPOCH")
        # Always post completion as new comment (preserve history)
        post_or_update_comment "$ISSUE_NUM" "$body" "new"
        log_info "Completion posted to issue #$ISSUE_NUM"
        ;;

    fail)
        PHASE="${PHASE:-unknown}"
        ERROR_MSG="${ERROR_MSG:-Unknown error}"
        body=$(build_failure_comment "$ISSUE_NUM" "$PHASE" "$ERROR_MSG" "$CONTAINER_NAME" "$START_EPOCH")
        # Always post failure as new comment
        post_or_update_comment "$ISSUE_NUM" "$body" "new"
        log_info "Failure notification posted to issue #$ISSUE_NUM"
        ;;

    read-wip)
        read_wip_progress "$ISSUE_NUM"
        ;;

    *)
        log_error "Unknown mode: $MODE"
        exit 1
        ;;
esac

exit 0
