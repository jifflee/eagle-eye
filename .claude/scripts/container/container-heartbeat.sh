#!/bin/bash
set -euo pipefail
# container-heartbeat.sh
# Background heartbeat daemon for container liveness reporting (Issue #508)
#
# This script writes a heartbeat file every N seconds to enable external
# monitoring to detect stuck containers. The heartbeat includes:
#   - Timestamp
#   - Current phase (if known)
#   - Last action
#   - Process information
#
# Usage:
#   ./scripts/container-heartbeat.sh start         # Start daemon in background
#   ./scripts/container-heartbeat.sh stop          # Stop daemon
#   ./scripts/container-heartbeat.sh status        # Check if running
#   ./scripts/container-heartbeat.sh write [phase] [action]  # Manual write
#
# Environment Variables:
#   HEARTBEAT_INTERVAL    Seconds between heartbeats (default: 30)
#   HEARTBEAT_FILE        Path to heartbeat file (default: /tmp/heartbeat)
#   PROGRESS_LOG          Path to progress log (default: /tmp/progress.jsonl)

set -e

# Configuration
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/heartbeat}"
PROGRESS_LOG="${PROGRESS_LOG:-/tmp/progress.jsonl}"
PID_FILE="/tmp/heartbeat.pid"

# Current state (can be updated by other processes)
STATE_FILE="/tmp/heartbeat-state"

# Initialize state file if not exists
init_state() {
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" << EOF
phase=starting
action=initializing
EOF
    fi
}

# Read current state
read_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        phase="unknown"
        action="unknown"
    fi
}

# Update state (called by other scripts)
update_state() {
    local new_phase="${1:-}"
    local new_action="${2:-}"

    read_state

    [ -n "$new_phase" ] && phase="$new_phase"
    [ -n "$new_action" ] && action="$new_action"

    cat > "$STATE_FILE" << EOF
phase=$phase
action=$action
EOF
}

# Write heartbeat
write_heartbeat() {
    local phase="${1:-}"
    local action="${2:-}"

    # Read state if not provided
    if [ -z "$phase" ] || [ -z "$action" ]; then
        read_state
        [ -z "$phase" ] && phase="${phase:-unknown}"
        [ -z "$action" ] && action="${action:-unknown}"
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local pid=$$
    local parent_pid=$PPID

    # Get Claude process info if running
    local claude_pid=""
    local claude_cpu=""
    local claude_mem=""

    claude_pid=$(pgrep -f "claude" 2>/dev/null | head -1 || echo "")
    if [ -n "$claude_pid" ]; then
        # Get CPU and memory usage
        local ps_output
        ps_output=$(ps -p "$claude_pid" -o %cpu,%mem 2>/dev/null | tail -1 || echo "0 0")
        claude_cpu=$(echo "$ps_output" | awk '{print $1}')
        claude_mem=$(echo "$ps_output" | awk '{print $2}')
    fi

    # Build heartbeat JSON
    cat > "$HEARTBEAT_FILE" << EOF
{
  "timestamp": "$timestamp",
  "phase": "$phase",
  "action": "$action",
  "pid": $pid,
  "parent_pid": $parent_pid,
  "claude_pid": ${claude_pid:-null},
  "claude_cpu": ${claude_cpu:-0},
  "claude_mem": ${claude_mem:-0},
  "uptime_seconds": $SECONDS
}
EOF

    # Also log to progress log (append only)
    echo "{\"ts\":\"$timestamp\",\"event\":\"heartbeat\",\"phase\":\"$phase\",\"action\":\"$action\"}" >> "$PROGRESS_LOG"
}

# Run heartbeat daemon
run_daemon() {
    init_state

    echo $$ > "$PID_FILE"

    # Initialize progress log
    if [ ! -f "$PROGRESS_LOG" ]; then
        echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"event\":\"daemon_start\",\"interval\":$HEARTBEAT_INTERVAL}" > "$PROGRESS_LOG"
    fi

    # Cleanup on exit
    trap 'rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT

    while true; do
        write_heartbeat
        sleep "$HEARTBEAT_INTERVAL"
    done
}

# Start daemon in background
start_daemon() {
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "Heartbeat daemon already running (PID: $old_pid)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi

    # Start in background
    nohup "$0" daemon > /dev/null 2>&1 &
    local new_pid=$!

    # Wait a moment and verify
    sleep 1
    if kill -0 "$new_pid" 2>/dev/null; then
        echo "Heartbeat daemon started (PID: $new_pid)"
        echo "  Interval: ${HEARTBEAT_INTERVAL}s"
        echo "  File: $HEARTBEAT_FILE"
        echo "  Log: $PROGRESS_LOG"
    else
        echo "ERROR: Failed to start heartbeat daemon"
        return 1
    fi
}

# Stop daemon
stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$PID_FILE"
            echo "Heartbeat daemon stopped (PID: $pid)"

            # Log stop event
            echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"event\":\"daemon_stop\"}" >> "$PROGRESS_LOG"
        else
            rm -f "$PID_FILE"
            echo "Heartbeat daemon not running (stale PID file removed)"
        fi
    else
        echo "Heartbeat daemon not running"
    fi
}

# Check status
check_status() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Heartbeat daemon running (PID: $pid)"

            # Show last heartbeat
            if [ -f "$HEARTBEAT_FILE" ]; then
                echo ""
                echo "Last heartbeat:"
                cat "$HEARTBEAT_FILE" | jq '.' 2>/dev/null || cat "$HEARTBEAT_FILE"

                # Calculate age
                local hb_time
                hb_time=$(cat "$HEARTBEAT_FILE" | jq -r '.timestamp' 2>/dev/null)
                if [ -n "$hb_time" ]; then
                    local hb_epoch
                    local now_epoch
                    hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb_time" +%s 2>/dev/null || date -d "$hb_time" +%s 2>/dev/null || echo "0")
                    now_epoch=$(date +%s)
                    local age=$((now_epoch - hb_epoch))
                    echo ""
                    echo "Heartbeat age: ${age}s"
                fi
            fi
            return 0
        fi
    fi

    echo "Heartbeat daemon not running"
    return 1
}

# Get heartbeat info as JSON (for integration with other scripts)
get_heartbeat_json() {
    if [ -f "$HEARTBEAT_FILE" ]; then
        local now_epoch
        now_epoch=$(date +%s)

        local hb_time
        hb_time=$(jq -r '.timestamp' "$HEARTBEAT_FILE" 2>/dev/null || echo "")

        local age=0
        if [ -n "$hb_time" ]; then
            local hb_epoch
            hb_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$hb_time" +%s 2>/dev/null || date -d "$hb_time" +%s 2>/dev/null || echo "$now_epoch")
            age=$((now_epoch - hb_epoch))
        fi

        # Read and augment heartbeat
        jq --arg age "$age" '. + {age_seconds: ($age | tonumber)}' "$HEARTBEAT_FILE" 2>/dev/null || echo '{"error":"invalid heartbeat file"}'
    else
        echo '{"error":"no heartbeat file"}'
    fi
}

# Usage
usage() {
    cat << EOF
container-heartbeat.sh - Container liveness heartbeat daemon

USAGE:
    $0 <command> [args]

COMMANDS:
    start               Start heartbeat daemon in background
    stop                Stop heartbeat daemon
    status              Check daemon status and show last heartbeat
    daemon              Run daemon in foreground (internal use)
    write [phase] [action]  Manually write heartbeat
    update <phase> <action> Update current state for next heartbeat
    get                 Get current heartbeat as JSON

ENVIRONMENT:
    HEARTBEAT_INTERVAL  Seconds between heartbeats (default: 30)
    HEARTBEAT_FILE      Path to heartbeat file (default: /tmp/heartbeat)
    PROGRESS_LOG        Path to progress log (default: /tmp/progress.jsonl)

EXAMPLES:
    # Start daemon
    $0 start

    # Update state from workflow script
    $0 update implement "writing file src/main.py"

    # Check status
    $0 status

    # Get heartbeat for external monitoring
    $0 get | jq '.age_seconds'

EOF
}

# Main
case "${1:-}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    status)
        check_status
        ;;
    daemon)
        run_daemon
        ;;
    write)
        write_heartbeat "${2:-}" "${3:-}"
        ;;
    update)
        update_state "${2:-}" "${3:-}"
        write_heartbeat "${2:-}" "${3:-}"
        ;;
    get)
        get_heartbeat_json
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
