#!/bin/bash
# framework-update-check.sh
# Tracks sprint-work run count per repo and checks for framework updates every N runs.
# Non-blocking: check is lightweight, update is queued and triggered after current run.
#
# Usage:
#   ./framework-update-check.sh increment          # Increment counter, queue update if due
#   ./framework-update-check.sh trigger-if-queued  # Trigger queued update if pending (HOST-side)
#   ./framework-update-check.sh reset              # Reset counter (called after update completes)
#   ./framework-update-check.sh status             # Show current state
#
# Environment Variables:
#   SPRINT_UPDATE_CHECK_INTERVAL  - Runs between checks (default: 25, configurable)
#   CLAUDE_FRAMEWORK_DIR          - Path to framework source repo (default: ~/Repos/claude-agents)
#   SPRINT_UPDATE_CHECK_DISABLE   - Set to "true" to disable all checks
#
# Config storage: ~/.claude-tastic/config.json
# Tracks per-repo: sprint_run_count, last_run_at, last_update_check_at, framework_update_queued
#
# Integration:
#   Called from sprint-work-preflight.sh (increment) and sprint-orchestrator.sh (trigger-if-queued)

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────

UPDATE_CHECK_INTERVAL="${SPRINT_UPDATE_CHECK_INTERVAL:-25}"
CONFIG_DIR="${HOME}/.claude-tastic"
CONFIG_FILE="${CONFIG_DIR}/config.json"
FRAMEWORK_DIR="${CLAUDE_FRAMEWORK_DIR:-${HOME}/Repos/claude-agents}"

# Prefix for all log lines (goes to stderr so it doesn't pollute JSON output)
LOG_PREFIX="[framework-update-check]"

log_info()  { echo "${LOG_PREFIX} $*" >&2; }
log_warn()  { echo "${LOG_PREFIX} WARN: $*" >&2; }
log_error() { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# ─── Config File Helpers ───────────────────────────────────────────────────────

# Read the whole config file, returning {} if missing or invalid
read_config() {
    if [ -f "$CONFIG_FILE" ]; then
        local content
        content=$(cat "$CONFIG_FILE" 2>/dev/null || echo "{}")
        # Validate JSON
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
    # Write to temp then move for atomicity
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

# Get a stable identifier for the current repo (owner/repo or fallback)
get_repo_id() {
    # Try gh CLI first (most reliable for GitHub repos)
    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
    if [ -n "$repo" ]; then
        echo "$repo"
        return
    fi

    # Fallback: parse from git remote URL
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [ -n "$remote_url" ]; then
        echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/.]+)(\.git)?$|\1|'
        return
    fi

    # Last resort: use repo root directory basename
    basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}

# ─── Framework Version Check ───────────────────────────────────────────────────

# Compare installed framework version vs latest in framework source repo.
# Outputs one of:
#   up_to_date:<version>
#   update_available:<from_version>:<to_version>
#   no_manifest
#   no_framework_source
#   check_failed
check_framework_version() {
    # Find the installed manifest to get current commit
    local installed_commit=""
    local installed_version="unknown"
    local manifest_file=""

    for path in ".claude/.manifest.json" "${HOME}/.claude/.manifest.json"; do
        if [ -f "$path" ]; then
            manifest_file="$path"
            installed_commit=$(jq -r '.git_commit // empty' "$path" 2>/dev/null || echo "")
            installed_version=$(jq -r '.framework_version // "unknown"' "$path" 2>/dev/null || echo "unknown")
            break
        fi
    done

    if [ -z "$installed_commit" ]; then
        echo "no_manifest"
        return
    fi

    # Check framework source repo exists
    if [ ! -d "${FRAMEWORK_DIR}/.git" ]; then
        echo "no_framework_source"
        return
    fi

    # Fetch latest from framework source (non-blocking: skip if fetch fails)
    git -C "$FRAMEWORK_DIR" fetch origin --quiet 2>/dev/null || true

    # Get latest commit on the default branch
    local latest_commit
    latest_commit=$(git -C "$FRAMEWORK_DIR" rev-parse origin/HEAD 2>/dev/null || \
                    git -C "$FRAMEWORK_DIR" rev-parse origin/main 2>/dev/null || \
                    git -C "$FRAMEWORK_DIR" rev-parse HEAD 2>/dev/null || echo "")

    if [ -z "$latest_commit" ]; then
        echo "no_framework_source"
        return
    fi

    # Already up to date
    if [ "$installed_commit" = "$latest_commit" ]; then
        echo "up_to_date:${installed_version}"
        return
    fi

    # Get version tag for the latest commit
    local latest_version
    latest_version=$(git -C "$FRAMEWORK_DIR" describe --tags --abbrev=0 2>/dev/null || \
                     git -C "$FRAMEWORK_DIR" rev-parse --short "$latest_commit" 2>/dev/null || echo "unknown")

    # Verify latest is actually a descendant of installed (not just different)
    if git -C "$FRAMEWORK_DIR" merge-base --is-ancestor "$installed_commit" "$latest_commit" 2>/dev/null; then
        echo "update_available:${installed_version}:${latest_version}"
    else
        # Diverged or installed is newer — no update needed
        echo "up_to_date:${installed_version}"
    fi
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_increment() {
    # Skip if explicitly disabled
    if [ "${SPRINT_UPDATE_CHECK_DISABLE:-}" = "true" ]; then
        log_info "Update checks disabled (SPRINT_UPDATE_CHECK_DISABLE=true)"
        exit 0
    fi

    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    # Read and increment run counter
    local current_count
    current_count=$(get_repo_config "$repo_id" "sprint_run_count" "0")
    local new_count=$(( current_count + 1 ))

    # Persist updated counter and timestamp
    set_repo_config_num "$repo_id" "sprint_run_count" "$new_count"
    set_repo_config_str "$repo_id" "last_run_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    log_info "Run #${new_count} for ${repo_id} (check every ${UPDATE_CHECK_INTERVAL} runs)"

    # Only perform version check on the Nth run
    if [ $(( new_count % UPDATE_CHECK_INTERVAL )) -ne 0 ]; then
        exit 0
    fi

    log_info "Run #${new_count}: performing framework version check..."
    set_repo_config_str "$repo_id" "last_update_check_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Run version check (best-effort, non-fatal)
    local version_result
    version_result=$(check_framework_version 2>/dev/null || echo "check_failed")

    case "$version_result" in
        up_to_date:*)
            local current_ver="${version_result#up_to_date:}"
            log_info "Framework is up to date (${current_ver})"
            set_repo_config_bool "$repo_id" "framework_update_queued" "false"
            ;;

        update_available:*)
            local from_ver to_ver
            from_ver=$(echo "$version_result" | cut -d: -f2)
            to_ver=$(echo "$version_result" | cut -d: -f3)
            log_info "Framework update available (${from_ver} -> ${to_ver}), queuing update after current run"
            # Also write to stdout so caller can display it
            echo "Framework update available (${from_ver} -> ${to_ver}), will update after current run"
            set_repo_config_bool "$repo_id" "framework_update_queued" "true"
            set_repo_config_str  "$repo_id" "framework_update_from" "$from_ver"
            set_repo_config_str  "$repo_id" "framework_update_to"   "$to_ver"
            ;;

        no_manifest)
            log_info "No framework manifest found (.claude/.manifest.json) — skipping version check"
            ;;

        no_framework_source)
            log_info "Framework source not found at ${FRAMEWORK_DIR} — skipping version check"
            log_info "Set CLAUDE_FRAMEWORK_DIR or clone to ${FRAMEWORK_DIR} to enable auto-updates"
            ;;

        check_failed|*)
            log_warn "Version check failed (non-fatal) — will retry on next scheduled check"
            ;;
    esac
}

cmd_trigger_if_queued() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    local update_queued
    update_queued=$(get_repo_config "$repo_id" "framework_update_queued" "false")

    if [ "$update_queued" != "true" ]; then
        exit 0
    fi

    local from_ver to_ver
    from_ver=$(get_repo_config "$repo_id" "framework_update_from" "unknown")
    to_ver=$(get_repo_config  "$repo_id" "framework_update_to"   "unknown")

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  FRAMEWORK UPDATE QUEUED                                      ║"
    echo "╠═══════════════════════════════════════════════════════════════╣"
    echo "║  Version: ${from_ver} -> ${to_ver}"
    echo "║  Running repo:framework-update before next issue...          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # Clear queue flag before running (so a crash doesn't loop)
    set_repo_config_bool "$repo_id" "framework_update_queued" "false"

    if ! command -v claude &>/dev/null; then
        log_warn "claude CLI not available — framework update skipped (will retry next check)"
        set_repo_config_bool "$repo_id" "framework_update_queued" "true"
        exit 0
    fi

    log_info "Running /repo:framework-update ..."
    if echo "/repo:framework-update" | claude --permission-mode default 2>&1; then
        # Success: reset run counter
        set_repo_config_num  "$repo_id" "sprint_run_count" "0"
        set_repo_config_bool "$repo_id" "framework_update_queued" "false"
        log_info "Framework updated successfully. Run counter reset."
        echo ""
        echo "Framework updated to ${to_ver}. Run counter reset — next check in ${UPDATE_CHECK_INTERVAL} runs."
        echo ""
    else
        log_warn "Framework update failed — re-queuing for next run"
        set_repo_config_bool "$repo_id" "framework_update_queued" "true"
        exit 1
    fi
}

cmd_reset() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")
    set_repo_config_num  "$repo_id" "sprint_run_count" "0"
    set_repo_config_bool "$repo_id" "framework_update_queued" "false"
    log_info "Run counter reset for ${repo_id}"
}

cmd_status() {
    local repo_id
    repo_id=$(get_repo_id 2>/dev/null || echo "unknown")

    local run_count last_check update_queued from_ver to_ver
    run_count=$(get_repo_config    "$repo_id" "sprint_run_count"          "0")
    last_check=$(get_repo_config   "$repo_id" "last_update_check_at"      "never")
    update_queued=$(get_repo_config "$repo_id" "framework_update_queued"  "false")
    from_ver=$(get_repo_config     "$repo_id" "framework_update_from"     "")
    to_ver=$(get_repo_config       "$repo_id" "framework_update_to"       "")

    local next_check=$(( (run_count / UPDATE_CHECK_INTERVAL + 1) * UPDATE_CHECK_INTERVAL ))

    echo "Framework Update Check Status"
    echo "  Repo:              ${repo_id}"
    echo "  Run count:         ${run_count}"
    echo "  Check interval:    every ${UPDATE_CHECK_INTERVAL} runs"
    echo "  Next check at run: ${next_check}"
    echo "  Last check:        ${last_check}"
    echo "  Update queued:     ${update_queued}"
    if [ -n "$from_ver" ]; then
        echo "  Queued update:     ${from_ver} -> ${to_ver}"
    fi
    echo "  Config file:       ${CONFIG_FILE}"
    echo "  Framework dir:     ${FRAMEWORK_DIR}"
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
