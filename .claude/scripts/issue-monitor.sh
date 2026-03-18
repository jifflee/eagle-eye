#!/bin/bash
set -euo pipefail
# issue-monitor.sh
# Dynamic requirement monitoring for worktree/container processes
# Part of Issue #166
# size-ok: stateful monitoring with init/check/poll modes and change detection logic
#
# Monitors GitHub issues for changes during execution and notifies
# the agent when requirements, comments, or labels change.
#
# Usage:
#   ./scripts/issue-monitor.sh --issue N --init          # Initialize monitoring
#   ./scripts/issue-monitor.sh --issue N --check         # Check for changes
#   ./scripts/issue-monitor.sh --issue N --poll [SEC]    # Poll continuously
#
# Returns:
#   0 = No changes detected
#   1 = Changes detected (details in output)
#   2 = Error

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Script metadata
SCRIPT_NAME="issue-monitor.sh"
VERSION="1.0.0"

# Default settings
POLL_INTERVAL=60  # seconds
STATE_DIR="${HOME}/.claude-tastic/issue-state"
JSON_OUTPUT=false

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Dynamic requirement monitoring for GitHub issues

USAGE:
    $SCRIPT_NAME --issue <N> --init          Initialize monitoring for issue
    $SCRIPT_NAME --issue <N> --check         Check for changes since last check
    $SCRIPT_NAME --issue <N> --poll [SEC]    Poll continuously (default: 60s)
    $SCRIPT_NAME --issue <N> --show          Show current issue state
    $SCRIPT_NAME --issue <N> --clear         Clear cached state
    $SCRIPT_NAME --issue <N> --wip           Check if another agent is working (via progress comments)

OPTIONS:
    --issue <N>     Issue number to monitor (required)
    --init          Initialize state cache for issue
    --check         Check for changes (exit 1 if changes)
    --poll <SEC>    Poll continuously with interval
    --show          Display current cached state
    --clear         Clear cached state for issue
    --wip           Check for active agent progress comments (exit 1 if WIP)
    --json          Output changes as JSON
    --quiet         Suppress informational output

EXAMPLES:
    # Initialize monitoring before starting work
    $SCRIPT_NAME --issue 143 --init

    # Check for changes between SDLC phases
    $SCRIPT_NAME --issue 143 --check

    # Run continuous monitoring in background
    $SCRIPT_NAME --issue 143 --poll 30 &

    # Check if another agent is actively working (reads progress comments)
    $SCRIPT_NAME --issue 143 --wip

EXIT CODES:
    0 = No changes detected (or init/clear/wip-idle succeeded)
    1 = Changes detected (or WIP: another agent is actively working)
    2 = Error occurred

EOF
    exit 0
}

# Ensure state directory exists
ensure_state_dir() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR"
    fi
}

# Get current issue state from GitHub
get_issue_state() {
    local issue="$1"

    gh issue view "$issue" --json body,title,labels,comments,updatedAt,state 2>/dev/null
}

# Compute hash of issue state for quick comparison
compute_state_hash() {
    local state="$1"
    echo "$state" | shasum -a 256 | cut -d' ' -f1
}

# Extract key fields for change detection
extract_key_fields() {
    local state="$1"

    echo "$state" | jq -r '{
        title: .title,
        body: .body,
        labels: [.labels[].name] | sort,
        state: .state,
        comment_count: (.comments | length),
        last_comment: (.comments | last | .body // null),
        updated_at: .updatedAt
    }'
}

# Initialize monitoring state
init_state() {
    local issue="$1"
    local state_file="${STATE_DIR}/issue-${issue}.json"

    log_info "Initializing monitoring for issue #${issue}..."

    local state
    state=$(get_issue_state "$issue")

    if [ -z "$state" ]; then
        log_error "Failed to fetch issue #${issue}"
        return 2
    fi

    local hash
    hash=$(compute_state_hash "$state")

    # Store state with metadata
    jq -n \
        --arg hash "$hash" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson state "$state" \
        '{
            issue: '"$issue"',
            hash: $hash,
            initialized_at: $timestamp,
            last_check: $timestamp,
            state: $state
        }' > "$state_file"

    log_info "State cached at: $state_file"
    log_info "Initial hash: ${hash:0:12}..."

    return 0
}

# Check for changes since last check
check_changes() {
    local issue="$1"
    local state_file="${STATE_DIR}/issue-${issue}.json"

    if [ ! -f "$state_file" ]; then
        log_warn "No cached state for issue #${issue}. Run --init first."
        return 2
    fi

    # Get current state
    local current_state
    current_state=$(get_issue_state "$issue")

    if [ -z "$current_state" ]; then
        log_error "Failed to fetch issue #${issue}"
        return 2
    fi

    # Compare hashes
    local cached_hash current_hash
    cached_hash=$(jq -r '.hash' "$state_file")
    current_hash=$(compute_state_hash "$current_state")

    if [ "$cached_hash" = "$current_hash" ]; then
        if [ "$JSON_OUTPUT" = true ]; then
            echo '{"changes": false, "issue": '"$issue"'}'
        else
            [ "$QUIET" != true ] && log_info "No changes detected for issue #${issue}"
        fi
        return 0
    fi

    # Changes detected - analyze what changed
    local cached_state current_fields cached_fields
    cached_state=$(jq -r '.state' "$state_file")
    cached_fields=$(extract_key_fields "$cached_state")
    current_fields=$(extract_key_fields "$current_state")

    # Detect specific changes
    local changes=()

    # Title change
    local old_title new_title
    old_title=$(echo "$cached_fields" | jq -r '.title')
    new_title=$(echo "$current_fields" | jq -r '.title')
    if [ "$old_title" != "$new_title" ]; then
        changes+=("title")
    fi

    # Body change (requirements/AC)
    local old_body new_body
    old_body=$(echo "$cached_fields" | jq -r '.body')
    new_body=$(echo "$current_fields" | jq -r '.body')
    if [ "$old_body" != "$new_body" ]; then
        changes+=("body")
    fi

    # Label changes
    local old_labels new_labels
    old_labels=$(echo "$cached_fields" | jq -c '.labels')
    new_labels=$(echo "$current_fields" | jq -c '.labels')
    if [ "$old_labels" != "$new_labels" ]; then
        changes+=("labels")
    fi

    # New comments
    local old_count new_count
    old_count=$(echo "$cached_fields" | jq -r '.comment_count')
    new_count=$(echo "$current_fields" | jq -r '.comment_count')
    if [ "$new_count" -gt "$old_count" ]; then
        changes+=("comments")
    fi

    # Issue state (open/closed)
    local old_state new_state
    old_state=$(echo "$cached_fields" | jq -r '.state')
    new_state=$(echo "$current_fields" | jq -r '.state')
    if [ "$old_state" != "$new_state" ]; then
        changes+=("state")
    fi

    # Update cached state
    jq \
        --arg hash "$current_hash" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson state "$current_state" \
        '.hash = $hash | .last_check = $timestamp | .previous_state = .state | .state = $state' \
        "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"

    # Output changes
    if [ "$JSON_OUTPUT" = true ]; then
        local changes_json
        changes_json=$(printf '%s\n' "${changes[@]}" | jq -R . | jq -s .)

        jq -n \
            --argjson changes "$changes_json" \
            --arg new_title "$new_title" \
            --argjson new_labels "$new_labels" \
            --arg new_comment "$(echo "$current_fields" | jq -r '.last_comment // empty')" \
            --arg new_state "$new_state" \
            '{
                changes: true,
                issue: '"$issue"',
                changed_fields: $changes,
                current: {
                    title: $new_title,
                    labels: $new_labels,
                    state: $new_state,
                    latest_comment: $new_comment
                }
            }'
    else
        log_warn "Changes detected for issue #${issue}!"
        echo ""
        echo "Changed fields: ${changes[*]}"
        echo ""

        if [[ " ${changes[*]} " =~ " body " ]]; then
            echo "## Requirement Changes"
            echo "The issue body (requirements/AC) has been updated."
            echo "Review changes before continuing implementation."
            echo ""
        fi

        if [[ " ${changes[*]} " =~ " comments " ]]; then
            echo "## New Comments"
            echo "Latest comment:"
            echo "$current_fields" | jq -r '.last_comment // "No comment content"' | head -10
            echo ""
        fi

        if [[ " ${changes[*]} " =~ " labels " ]]; then
            echo "## Label Changes"
            echo "Previous: $old_labels"
            echo "Current:  $new_labels"

            # Check for blocker labels
            if echo "$new_labels" | jq -e 'index("blocked")' > /dev/null 2>&1; then
                echo ""
                log_warn "Issue has been marked as BLOCKED!"
            fi
            echo ""
        fi

        if [[ " ${changes[*]} " =~ " state " ]]; then
            echo "## State Change"
            echo "Issue state changed from '$old_state' to '$new_state'"
            if [ "$new_state" = "CLOSED" ]; then
                log_warn "Issue has been CLOSED!"
            fi
            echo ""
        fi
    fi

    return 1
}

# Poll for changes continuously
poll_changes() {
    local issue="$1"
    local interval="${2:-$POLL_INTERVAL}"

    log_info "Starting continuous monitoring for issue #${issue} (interval: ${interval}s)"
    log_info "Press Ctrl+C to stop"
    echo ""

    while true; do
        if check_changes "$issue"; then
            [ "$QUIET" != true ] && echo "[$(date '+%H:%M:%S')] No changes"
        else
            log_warn "Changes detected! Review above."
            # Return 1 to signal changes if running in foreground
            if [ -t 0 ]; then
                read -p "Continue monitoring? [y/n] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    exit 1
                fi
            fi
        fi
        sleep "$interval"
    done
}

# Show current cached state
show_state() {
    local issue="$1"
    local state_file="${STATE_DIR}/issue-${issue}.json"

    if [ ! -f "$state_file" ]; then
        log_warn "No cached state for issue #${issue}"
        return 2
    fi

    if [ "$JSON_OUTPUT" = true ]; then
        cat "$state_file"
    else
        echo "## Cached State for Issue #${issue}"
        echo ""
        echo "Initialized: $(jq -r '.initialized_at' "$state_file")"
        echo "Last check:  $(jq -r '.last_check' "$state_file")"
        echo "Hash:        $(jq -r '.hash' "$state_file" | cut -c1-12)..."
        echo ""
        echo "### Issue State"
        jq -r '.state | {title, state, labels: [.labels[].name], comments: (.comments | length)}' "$state_file"
    fi
}

# Clear cached state
clear_state() {
    local issue="$1"
    local state_file="${STATE_DIR}/issue-${issue}.json"

    if [ -f "$state_file" ]; then
        rm "$state_file"
        log_info "Cleared cached state for issue #${issue}"
    else
        log_info "No cached state to clear for issue #${issue}"
    fi

    return 0
}

# Check if another agent is actively working on this issue by reading
# structured progress comments posted by issue-progress.sh.
# Returns 0 if idle, 1 if another agent is WIP.
check_wip_progress() {
    local issue="$1"

    # Use issue-progress.sh --read-wip if available
    local progress_script=""
    for path in "${SCRIPT_DIR}/issue-progress.sh" "/workspace/repo/scripts/issue-progress.sh"; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            progress_script="$path"
            break
        fi
    done

    if [ -z "$progress_script" ]; then
        log_warn "issue-progress.sh not found - cannot check WIP progress comments"
        return 2
    fi

    local wip_data
    wip_data=$("$progress_script" --issue "$issue" --read-wip 2>/dev/null || echo '{"error":"failed"}')

    if echo "$wip_data" | jq -e '.error' >/dev/null 2>&1; then
        log_warn "Failed to read WIP progress for issue #${issue}"
        return 2
    fi

    local is_wip
    is_wip=$(echo "$wip_data" | jq -r '.wip // false')
    local is_stale
    is_stale=$(echo "$wip_data" | jq -r '.stale // false')
    local phase
    phase=$(echo "$wip_data" | jq -r '.phase // "unknown"')
    local wip_status
    wip_status=$(echo "$wip_data" | jq -r '.status // "unknown"')
    local age_seconds
    age_seconds=$(echo "$wip_data" | jq -r '.age_seconds // 0')
    local last_updated
    last_updated=$(echo "$wip_data" | jq -r '.last_updated // ""')

    if [ "$is_wip" != "true" ]; then
        if [ "$JSON_OUTPUT" = true ]; then
            echo "$wip_data"
        else
            [ "$QUIET" != true ] && log_info "No active agent WIP for issue #${issue}"
        fi
        return 0
    fi

    # Active WIP detected
    if [ "$JSON_OUTPUT" = true ]; then
        echo "$wip_data"
    else
        if [ "$is_stale" = "true" ]; then
            log_warn "STALE WIP detected for issue #${issue} (last updated ${age_seconds}s ago - may be stuck)"
            echo ""
            echo "Phase: $phase | Status: $wip_status"
            echo "Last updated: $last_updated"
            echo "Age: ${age_seconds}s (>30 min - possibly stale)"
            echo ""
            echo "The agent may be stuck. Consider re-launching after verification."
        else
            log_warn "Active agent WIP detected for issue #${issue}"
            echo ""
            echo "Phase: $phase | Status: $wip_status"
            echo "Last updated: $last_updated"
            echo "Age: ${age_seconds}s"
            echo ""
            echo "Another agent is actively working on this issue."
            echo "To avoid collisions, wait until the agent completes or the WIP becomes stale (>30 min)."
        fi
    fi

    return 1
}

# Parse arguments
ISSUE=""
ACTION=""
POLL_SEC=""
QUIET=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --issue|-i)
            ISSUE="$2"
            shift 2
            ;;
        --init)
            ACTION="init"
            shift
            ;;
        --check)
            ACTION="check"
            shift
            ;;
        --poll)
            ACTION="poll"
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                POLL_SEC="$2"
                shift
            fi
            shift
            ;;
        --show)
            ACTION="show"
            shift
            ;;
        --clear)
            ACTION="clear"
            shift
            ;;
        --wip)
            ACTION="wip"
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [ -z "$ISSUE" ]; then
    log_error "Issue number required (--issue N)"
    exit 2
fi

if [ -z "$ACTION" ]; then
    log_error "Action required (--init, --check, --poll, --show, --clear, or --wip)"
    exit 2
fi

# Ensure state directory exists
ensure_state_dir

# Execute action
case $ACTION in
    init)
        init_state "$ISSUE"
        ;;
    check)
        check_changes "$ISSUE"
        ;;
    poll)
        poll_changes "$ISSUE" "$POLL_SEC"
        ;;
    show)
        show_state "$ISSUE"
        ;;
    clear)
        clear_state "$ISSUE"
        ;;
    wip)
        check_wip_progress "$ISSUE"
        ;;
esac
