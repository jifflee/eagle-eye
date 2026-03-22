#!/bin/bash
set -euo pipefail
# container-blocker-report.sh
# Reports container stuck/blocked state to GitHub issue for triage (Issue #1330)
# size-ok: self-reporting blocker detection with GitHub issue update and label management
#
# When a container detects it is stuck, hung, or blocked during sprint-work,
# this script posts a structured comment to the GitHub issue with blocker
# details, adds the 'blocked' label, and removes 'in-progress'. An agent team
# or human can then triage the issue and decide whether to add context, rework,
# or close it.
#
# Usage:
#   ./scripts/container-blocker-report.sh \
#     --issue N \
#     --phase PHASE \
#     --reason REASON \
#     [--detail "Additional context"] \
#     [--log-file /path/to/log] \
#     [--log-lines N]
#
# Arguments:
#   --issue N         GitHub issue number (or ISSUE env var)
#   --phase PHASE     Phase where stuck: load-context|pre-work|implementation|post-work|ci-check
#   --reason REASON   Reason code: heartbeat_timeout|phase_timeout|total_timeout|
#                     claude_timeout|no_output|exit_failure|watchdog_kill
#   --detail TEXT     Optional human-readable detail / last known activity
#   --log-file PATH   Path to log file for tail (default: /tmp/container.log)
#   --log-lines N     Number of log lines to include (default: 50)
#   --container NAME  Override container name (default: $CONTAINER_NAME or $HOSTNAME)
#
# Environment Variables:
#   ISSUE              - GitHub issue number (overridden by --issue)
#   REPO_FULL_NAME     - owner/repo format (auto-detected from git if absent)
#   GITHUB_TOKEN       - used by gh CLI (should already be configured)
#   ISSUE_TITLE        - Issue title (optional, improves comment quality)
#   CONTAINER_NAME     - Container name/ID (auto-detected from HOSTNAME)
#   STUCK_TIMEOUT      - Stuck detection threshold in seconds (default: 600)
#   HARD_TIMEOUT       - Hard timeout in seconds (default: 1800)
#
# Exit Codes:
#   0 - Report posted (or skipped because gh not available / issue unset)
#   1 - Fatal argument error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Source shared logging ─────────────────────────────────────────────────────
for _path in \
    "${SCRIPT_DIR}/lib/common.sh" \
    "/workspace/repo/scripts/lib/common.sh" \
    "/workspace/repo/.claude/scripts/lib/common.sh"; do
    if [ -f "$_path" ]; then
        # shellcheck source=/dev/null
        source "$_path"
        break
    fi
done
unset _path

# Fallback minimal logging if common.sh not found
if ! command -v log_info >/dev/null 2>&1; then
    log_info()  { echo "[BLOCKER] $*"; }
    log_warn()  { echo "[BLOCKER WARN] $*" >&2; }
    log_error() { echo "[BLOCKER ERROR] $*" >&2; }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────

ISSUE_NUM="${ISSUE:-}"
PHASE=""
REASON=""
DETAIL=""
LOG_FILE="${STRUCTURED_LOG_FILE:-/tmp/container.log}"
LOG_LINES=50
REPO="${REPO_FULL_NAME:-}"
ISSUE_TITLE_TEXT="${ISSUE_TITLE:-}"
CONTAINER="${CONTAINER_NAME:-${HOSTNAME:-unknown}}"
STUCK_TIMEOUT="${STUCK_TIMEOUT:-600}"
HARD_TIMEOUT="${HARD_TIMEOUT:-1800}"

# ─── Argument Parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue|-i)    ISSUE_NUM="$2";    shift 2 ;;
        --phase|-p)    PHASE="$2";        shift 2 ;;
        --reason|-r)   REASON="$2";       shift 2 ;;
        --detail|-d)   DETAIL="$2";       shift 2 ;;
        --log-file)    LOG_FILE="$2";     shift 2 ;;
        --log-lines)   LOG_LINES="$2";    shift 2 ;;
        --container)   CONTAINER="$2";    shift 2 ;;
        --help|-h)
            grep '^#' "$0" | head -50 | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Pre-flight ────────────────────────────────────────────────────────────────

if [ -z "$ISSUE_NUM" ]; then
    log_warn "No issue number provided (ISSUE env var or --issue N) - skipping blocker report"
    exit 0
fi

if [ -z "$REPO" ]; then
    REPO=$(git remote get-url origin 2>/dev/null \
        | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|' \
        || echo "")
fi

if [ -z "$REPO" ]; then
    log_warn "REPO_FULL_NAME not set and could not be auto-detected - skipping GitHub report"
    exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
    log_warn "gh CLI not available - cannot post blocker report"
    exit 0
fi

if ! gh auth status &>/dev/null; then
    log_warn "gh CLI not authenticated - cannot post blocker report"
    exit 0
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Map reason code to human-readable description
reason_to_description() {
    case "${1:-}" in
        heartbeat_timeout|heartbeat_stale)
            echo "No progress detected for ${STUCK_TIMEOUT}s (watchdog heartbeat stale — container may be hung)" ;;
        phase_timeout)
            echo "Exceeded maximum time per phase (${STUCK_TIMEOUT}s) with no heartbeat update" ;;
        total_timeout)
            echo "Exceeded hard container timeout (${HARD_TIMEOUT}s total runtime)" ;;
        claude_timeout)
            echo "Claude invocation did not respond within the allowed window (${STUCK_TIMEOUT}s)" ;;
        no_output)
            echo "Claude completed but produced no file changes after multiple attempts" ;;
        exit_failure)
            echo "Claude exited with a non-zero code during the implementation phase" ;;
        watchdog_kill)
            echo "Container watchdog detected a hang and forcefully terminated the Claude process" ;;
        *)
            echo "Container blocked: ${1:-unknown reason}" ;;
    esac
}

# Return last N lines from the best available log file
collect_log_tail() {
    local lines="${1:-50}"
    local content=""
    for _log in "$LOG_FILE" "/tmp/container.log" "/tmp/progress.jsonl"; do
        if [ -f "$_log" ] && [ -s "$_log" ]; then
            content=$(tail -"$lines" "$_log" 2>/dev/null || echo "")
            if [ -n "$content" ]; then
                echo "$content"
                return 0
            fi
        fi
    done
    echo "(No log data available — check docker logs for container output)"
}

utc_now() { date -u '+%Y-%m-%d %H:%M:%S UTC'; }

# ─── Build comment ────────────────────────────────────────────────────────────

REASON_DESC=$(reason_to_description "$REASON")
LOG_TAIL=$(collect_log_tail "$LOG_LINES")
TIMESTAMP=$(utc_now)
PHASE_DISPLAY="${PHASE:-unknown}"

# Optional rows for the table
DETAIL_ROW=""
if [ -n "$DETAIL" ]; then
    DETAIL_ROW="| **Last activity** | ${DETAIL} |"
fi

TITLE_ROW=""
if [ -n "$ISSUE_TITLE_TEXT" ]; then
    TITLE_ROW="| **Issue** | ${ISSUE_TITLE_TEXT} |"
fi

COMMENT_BODY="<!-- agent-progress:${PHASE_DISPLAY}:stuck -->
## Container Stuck — Needs Triage

The container working on this issue has self-reported a blocker and requires evaluation before work can continue.

### Blocker Details

| Field | Value |
|-------|-------|
| **Container** | \`${CONTAINER}\` |
| **Phase** | \`${PHASE_DISPLAY}\` |
| **Reason** | ${REASON_DESC} |
| **Detected** | ${TIMESTAMP} |
${TITLE_ROW}
${DETAIL_ROW}

### What Happened

The container was executing **Phase 3: Implementation (Claude)** when the blocker was detected. Claude either stopped producing output, timed out, or exited without completing the task.

### Triage Options

An agent team or human should evaluate this issue and choose one of:

1. **Add context** — Update the issue body or acceptance criteria with missing information, then re-launch:
   \`\`\`bash
   ./scripts/container/container-launch.sh ${ISSUE_NUM}
   \`\`\`

2. **Request human input** — Add a comment asking the issue author for clarification

3. **Rework the issue** — Rewrite the issue description with better requirements and clearer acceptance criteria

4. **Close/delete** — Close the issue if it is not actionable or out of scope

> Use \`/issue:triage-bulk\` or \`/issue:triage-single\` for automated triage assistance.

### Container Log (Last ${LOG_LINES} Lines)

<details>
<summary>Expand container log</summary>

\`\`\`
${LOG_TAIL}
\`\`\`

</details>

---
*Auto-reported by container-blocker-report.sh | Thresholds: stuck=${STUCK_TIMEOUT}s, hard=${HARD_TIMEOUT}s*"

# ─── Post to GitHub ────────────────────────────────────────────────────────────

log_info "Reporting stuck container to GitHub issue #${ISSUE_NUM} (repo: ${REPO})..."

# Post the blocker comment
if gh issue comment "$ISSUE_NUM" \
    --body "$COMMENT_BODY" \
    --repo "$REPO" 2>/dev/null; then
    log_info "Blocker comment posted to issue #${ISSUE_NUM}"
else
    log_warn "Failed to post blocker comment to issue #${ISSUE_NUM} (non-fatal)"
fi

# Ensure 'blocked' label exists in the repo
gh label create "blocked" \
    --description "Container detected a blocker; needs triage before re-launch" \
    --color "d93f0b" \
    --repo "$REPO" 2>/dev/null || true

# Add 'blocked' label; remove 'in-progress'
if gh issue edit "$ISSUE_NUM" \
    --add-label "blocked" \
    --remove-label "in-progress" \
    --repo "$REPO" 2>/dev/null; then
    log_info "Issue #${ISSUE_NUM}: labeled 'blocked', removed 'in-progress'"
else
    # Fallback: just add 'blocked' (in-progress label may already be absent)
    gh issue edit "$ISSUE_NUM" \
        --add-label "blocked" \
        --repo "$REPO" 2>/dev/null || \
        log_warn "Failed to update labels on issue #${ISSUE_NUM} (non-fatal)"
fi

log_info "Blocker report complete for issue #${ISSUE_NUM}"
exit 0
