#!/bin/bash
# triage-bulk-check.sh
# Tracks sprint-work run count per repo and auto-triggers triage-bulk --apply every N runs.
# Also performs retroactive context review of last 5 completed issues.
# Non-blocking: check is lightweight, triage is queued and triggered after current run.
#
# Usage:
#   ./triage-bulk-check.sh increment          # Increment counter, queue triage if due
#   ./triage-bulk-check.sh trigger-if-queued  # Trigger queued triage if pending (HOST-side)
#   ./triage-bulk-check.sh reset              # Reset counter (called after triage completes)
#   ./triage-bulk-check.sh status             # Show current state
#
# Environment Variables:
#   SPRINT_TRIAGE_INTERVAL        - Runs between auto-triage (default: 5, configurable)
#   SPRINT_TRIAGE_CHECK_DISABLE   - Set to "true" to disable all checks
#   SPRINT_TRIAGE_RETROACTIVE_N   - Number of completed issues to review (default: 5)
#
# Config storage: ~/.claude-tastic/config.json
# Tracks per-repo: triage_run_count, last_triage_at, triage_queued
#
# Integration:
#   Called from sprint-work-preflight.sh (increment) and sprint-orchestrator.sh (trigger-if-queued)

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────

TRIAGE_INTERVAL="${SPRINT_TRIAGE_INTERVAL:-5}"
RETROACTIVE_N="${SPRINT_TRIAGE_RETROACTIVE_N:-5}"
CONFIG_DIR="${HOME}/.claude-tastic"
CONFIG_FILE="${CONFIG_DIR}/config.json"

# Prefix for all log lines (goes to stderr so it doesn't pollute JSON output)
LOG_PREFIX="[triage-bulk-check]"

log_info()  { echo "${LOG_PREFIX} $*" >&2; }
log_warn()  { echo "${LOG_PREFIX} WARN: $*" >&2; }
log_error() { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# ─── Config File Helpers ───────────────────────────────────────────────────────

# Read the whole config file, returning {} if missing or invalid
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        local content
        content=$(cat "$CONFIG_FILE" 2>/dev/null || echo "{}")
        if echo "$content" | jq empty 2>/dev/null; then
            echo "$content"
        else
            echo "{}"
        fi
    else
        echo "{}"
    fi
}

# Write config atomically (creates directory if needed)
write_config() {
    local config="$1"
    mkdir -p "$CONFIG_DIR"
    local tmp_file
    tmp_file=$(mktemp "${CONFIG_DIR}/config.json.XXXXXX")
    echo "$config" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
}

# Get a value from per-repo config namespace
get_repo_config() {
    local repo_id="$1"
    local field="$2"
    local default="${3:-}"
    read_config | jq -r \
        --arg repo "$repo_id" \
        --arg field "$field" \
        --arg default "$default" \
        '.repos[$repo][$field] // $default' 2>/dev/null || echo "$default"
}

# Set a scalar string value in per-repo config namespace
set_repo_config_str() {
    local repo_id="$1"
    local field="$2"
    local value="$3"

    local current
    current=$(read_config)
    local updated
    updated=$(echo "$current" | jq \
        --arg repo "$repo_id" \
        --arg field "$field" \
        --arg val "$value" \
        '.repos[$repo][$field] = $val' 2>/dev/null || echo "$current")
    write_config "$updated"
}

# Set a boolean value in per-repo config namespace
set_repo_config_bool() {
    local repo_id="$1"
    local field="$2"
    local value="$3"   # "true" or "false"

    local current
    current=$(read_config)
    local updated
    if [ "$value" = "true" ]; then
        updated=$(echo "$current" | jq \
            --arg repo "$repo_id" \
            --arg field "$field" \
            '.repos[$repo][$field] = true' 2>/dev/null || echo "$current")
    else
        updated=$(echo "$current" | jq \
            --arg repo "$repo_id" \
            --arg field "$field" \
            '.repos[$repo][$field] = false' 2>/dev/null || echo "$current")
    fi
    write_config "$updated"
}

# Set a numeric value in per-repo config namespace
set_repo_config_num() {
    local repo_id="$1"
    local field="$2"
    local value="$3"

    local current
    current=$(read_config)
    local updated
    updated=$(echo "$current" | jq \
        --arg repo "$repo_id" \
        --arg field "$field" \
        --argjson val "$value" \
        '.repos[$repo][$field] = $val' 2>/dev/null || echo "$current")
    write_config "$updated"
}

# ─── Repo Identity ─────────────────────────────────────────────────────────────

get_repo_id() {
    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    if [ -n "$repo" ]; then
        echo "$repo"
        return
    fi

    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$remote_url" ]; then
        echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/.]+)(\.git)?$|\1|'
        return
    fi

    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_increment() {
    # Skip if explicitly disabled
    if [ "${SPRINT_TRIAGE_CHECK_DISABLE:-}" = "true" ]; then
        log_info "Triage checks disabled (SPRINT_TRIAGE_CHECK_DISABLE=true)"
        exit 0
    fi

    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    # Read and increment triage run counter (separate from framework update counter)
    local current_count
    current_count=$(get_repo_config "$repo_id" "triage_run_count" "0")
    local new_count=$(( current_count + 1 ))

    # Persist updated counter and timestamp
    set_repo_config_num "$repo_id" "triage_run_count" "$new_count"
    set_repo_config_str "$repo_id" "triage_last_run_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Triage run #${new_count} for ${repo_id} (auto-triage every ${TRIAGE_INTERVAL} runs)"

    # Only queue triage on the Nth run
    if [ $(( new_count % TRIAGE_INTERVAL )) -ne 0 ]; then
        exit 0
    fi

    log_info "Run #${new_count}: queuing auto-triage (every ${TRIAGE_INTERVAL} runs)"
    set_repo_config_bool "$repo_id" "triage_queued" "true"
    set_repo_config_str  "$repo_id" "triage_queued_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    set_repo_config_num  "$repo_id" "triage_trigger_run" "$new_count"

    # Echo to stdout so caller can display it
    echo "Auto-triage triggered (run ${new_count}/${TRIAGE_INTERVAL}). Will run triage-bulk --apply after current issue."
}

cmd_trigger_if_queued() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    local triage_queued
    triage_queued=$(get_repo_config "$repo_id" "triage_queued" "false")

    if [ "$triage_queued" != "true" ]; then
        exit 0
    fi

    local trigger_run
    trigger_run=$(get_repo_config "$repo_id" "triage_trigger_run" "?")

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  AUTO-TRIAGE TRIGGERED                                        ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  Auto-triage triggered (run ${trigger_run}/${TRIAGE_INTERVAL}). Reviewing ${RETROACTIVE_N} completed  ║"
    echo "║  issues for context updates.                                  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Clear queue flag before running (so a crash doesn't loop)
    set_repo_config_bool "$repo_id" "triage_queued" "false"
    set_repo_config_str  "$repo_id" "last_triage_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Step 1: Run retroactive context review (analyzes last N completed issues)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -x "${script_dir}/retroactive-context-review.sh" ]; then
        log_info "Running retroactive context review (last ${RETROACTIVE_N} completed issues)..."
        "${script_dir}/retroactive-context-review.sh" \
            --limit "${RETROACTIVE_N}" 2>&1 || {
            log_warn "Retroactive context review failed (non-fatal) — continuing with triage"
        }
    else
        log_warn "retroactive-context-review.sh not found — skipping context review"
    fi

    # Step 2: Run triage-bulk --apply via claude CLI
    if ! command -v claude &>/dev/null; then
        log_warn "claude CLI not available — triage-bulk skipped (will retry next trigger)"
        set_repo_config_bool "$repo_id" "triage_queued" "true"
        exit 0
    fi

    log_info "Running /issue:triage-bulk --apply ..."
    if echo "/issue:triage-bulk --apply" | claude --permission-mode default 2>&1; then
        # Success: reset triage run counter
        set_repo_config_num  "$repo_id" "triage_run_count" "0"
        set_repo_config_bool "$repo_id" "triage_queued" "false"
        log_info "Triage-bulk completed successfully. Triage counter reset."
        echo ""
        echo "Auto-triage complete. Counter reset — next auto-triage in ${TRIAGE_INTERVAL} runs."
        echo ""
    else
        log_warn "triage-bulk failed — re-queuing for next run"
        set_repo_config_bool "$repo_id" "triage_queued" "true"
        exit 1
    fi
}

cmd_reset() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")
    set_repo_config_num  "$repo_id" "triage_run_count" "0"
    set_repo_config_bool "$repo_id" "triage_queued" "false"
    log_info "Triage run counter reset for ${repo_id}"
}

cmd_status() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    local run_count last_triage triage_queued trigger_run
    run_count=$(get_repo_config    "$repo_id" "triage_run_count"    "0")
    last_triage=$(get_repo_config  "$repo_id" "last_triage_at"      "never")
    triage_queued=$(get_repo_config "$repo_id" "triage_queued"       "false")
    trigger_run=$(get_repo_config  "$repo_id" "triage_trigger_run"  "")

    local next_trigger=$(( (run_count / TRIAGE_INTERVAL + 1) * TRIAGE_INTERVAL ))

    echo "Auto Triage-Bulk Check Status"
    echo "  Repo:                 ${repo_id}"
    echo "  Triage run count:     ${run_count}"
    echo "  Triage interval:      every ${TRIAGE_INTERVAL} runs"
    echo "  Next trigger at run:  ${next_trigger}"
    echo "  Last triage:          ${last_triage}"
    echo "  Triage queued:        ${triage_queued}"
    if [ -n "$trigger_run" ]; then
        echo "  Queued at run:        ${trigger_run}"
    fi
    echo "  Retroactive review:   last ${RETROACTIVE_N} completed issues"
    echo "  Config file:          ${CONFIG_FILE}"
}

# ─── Dispatch ──────────────────────────────────────────────────────────────────

COMMAND="${1:-increment}"

case "$COMMAND" in
    increment)          cmd_increment ;;
    trigger-if-queued)  cmd_trigger_if_queued ;;
    reset)              cmd_reset ;;
    status)             cmd_status ;;
    *)
        echo "Usage: $0 {increment|trigger-if-queued|reset|status}" >&2
        exit 1
        ;;
esac
