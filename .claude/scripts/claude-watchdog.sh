#!/bin/bash
# claude-watchdog.sh
# Watchdog process to monitor Claude invocations and prevent indefinite hangs
#
# This watchdog monitors Claude invocation time, CPU usage, and heartbeat signals
# to detect and handle stuck or hung invocations within containers.
#
# Environment Variables:
#   PHASE_TIMEOUT       - Max seconds per Claude invocation phase (default: 600 = 10 min)
#   TOTAL_TIMEOUT       - Max seconds total for all phases (default: 3600 = 60 min)
#   HEARTBEAT_MAX_AGE   - Max seconds without heartbeat update (default: 120 = 2 min)
#   WATCHDOG_CHECK_INTERVAL - Seconds between checks (default: 10)
#   WATCHDOG_HEARTBEAT_FILE - Path to heartbeat file (default: /tmp/claude-heartbeat)
#   WATCHDOG_DISABLED   - Set to 'true' to disable watchdog (default: false)
#
# Usage:
#   # Start watchdog in background before invoking Claude
#   ./scripts/claude-watchdog.sh &
#   WATCHDOG_PID=$!
#
#   # Invoke Claude with heartbeat updates
#   echo "$PROMPT" | claude -p --permission-mode acceptEdits
#
#   # Kill watchdog after Claude completes
#   kill $WATCHDOG_PID 2>/dev/null || true
#
# Exit Codes:
#   0   - Watchdog stopped normally (parent killed it)
#   124 - Phase timeout exceeded
#   125 - Total timeout exceeded
#   126 - Heartbeat timeout (stale heartbeat file)

set -euo pipefail

# Configuration with defaults
PHASE_TIMEOUT="${PHASE_TIMEOUT:-600}"           # 10 minutes per phase
TOTAL_TIMEOUT="${TOTAL_TIMEOUT:-3600}"          # 60 minutes total
HEARTBEAT_MAX_AGE="${HEARTBEAT_MAX_AGE:-120}"   # 2 minutes stale heartbeat
WATCHDOG_CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-10}"  # Check every 10 seconds
WATCHDOG_HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/tmp/claude-heartbeat}"
WATCHDOG_DISABLED="${WATCHDOG_DISABLED:-false}"

# Warning thresholds (80% of timeout)
PHASE_WARNING_THRESHOLD=$((PHASE_TIMEOUT * 80 / 100))
TOTAL_WARNING_THRESHOLD=$((TOTAL_TIMEOUT * 80 / 100))

# Logging
log_watchdog() {
    echo "[WATCHDOG $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_warn() {
    echo "[WATCHDOG WARNING $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_error() {
    echo "[WATCHDOG ERROR $(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Find Claude process
find_claude_process() {
    # Find Claude process (claude CLI or node process running claude)
    pgrep -f "claude" | grep -v "watchdog" | head -1 || echo ""
}

# Get process stats
get_process_stats() {
    local pid=$1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        # Get CPU and memory usage on Linux
        ps -p "$pid" -o pid,ppid,pcpu,pmem,vsz,rss,etime,stat,comm --no-headers 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get heartbeat file age in seconds
get_heartbeat_age() {
    if [ -f "$WATCHDOG_HEARTBEAT_FILE" ]; then
        local current_time file_time
        current_time=$(date +%s)
        file_time=$(stat -c %Y "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || stat -f %m "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || echo "$current_time")
        echo $((current_time - file_time))
    else
        # No heartbeat file yet
        echo 0
    fi
}

# Log diagnostic information before killing
log_diagnostics() {
    local reason=$1
    local phase_elapsed=$2
    local total_elapsed=$3
    local claude_pid=$4

    log_error "Timeout detected: $reason"
    log_error "Phase elapsed: ${phase_elapsed}s / ${PHASE_TIMEOUT}s"
    log_error "Total elapsed: ${total_elapsed}s / ${TOTAL_TIMEOUT}s"

    if [ -n "$claude_pid" ]; then
        log_error "Claude process (PID $claude_pid) stats:"
        get_process_stats "$claude_pid" | while read -r line; do
            log_error "  $line"
        done
    else
        log_error "Claude process not found"
    fi

    # Log top processes
    log_error "Top CPU processes:"
    ps aux --sort=-%cpu | head -6 | while read -r line; do
        log_error "  $line"
    done

    # Log memory usage
    log_error "Memory usage:"
    free -h 2>/dev/null | while read -r line; do
        log_error "  $line"
    done || log_error "  (free command not available)"

    # Heartbeat status
    if [ -f "$WATCHDOG_HEARTBEAT_FILE" ]; then
        local heartbeat_age
        heartbeat_age=$(get_heartbeat_age)
        log_error "Heartbeat file age: ${heartbeat_age}s"
        log_error "Last heartbeat: $(cat "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || echo 'N/A')"
    else
        log_error "Heartbeat file not found: $WATCHDOG_HEARTBEAT_FILE"
    fi
}

# Kill Claude process gracefully, then forcefully if needed
kill_claude_process() {
    local claude_pid=$1

    if [ -z "$claude_pid" ] || ! kill -0 "$claude_pid" 2>/dev/null; then
        log_watchdog "Claude process already stopped"
        return 0
    fi

    log_error "Sending SIGTERM to Claude process (PID $claude_pid)..."
    kill -TERM "$claude_pid" 2>/dev/null || true

    # Wait up to 30 seconds for graceful shutdown
    local wait_count=0
    while [ $wait_count -lt 30 ]; do
        if ! kill -0 "$claude_pid" 2>/dev/null; then
            log_watchdog "Claude process terminated gracefully"
            return 0
        fi
        sleep 1
        wait_count=$((wait_count + 1))
    done

    # Force kill if still running
    if kill -0 "$claude_pid" 2>/dev/null; then
        log_error "Sending SIGKILL to Claude process (PID $claude_pid)..."
        kill -KILL "$claude_pid" 2>/dev/null || true
        sleep 1
    fi

    if kill -0 "$claude_pid" 2>/dev/null; then
        log_error "Failed to kill Claude process"
        return 1
    else
        log_watchdog "Claude process force killed"
        return 0
    fi
}

# Main watchdog loop
main() {
    if [ "$WATCHDOG_DISABLED" = "true" ]; then
        log_watchdog "Watchdog disabled via WATCHDOG_DISABLED=true"
        exit 0
    fi

    log_watchdog "Starting Claude invocation watchdog"
    log_watchdog "Phase timeout: ${PHASE_TIMEOUT}s (warning at ${PHASE_WARNING_THRESHOLD}s)"
    log_watchdog "Total timeout: ${TOTAL_TIMEOUT}s (warning at ${TOTAL_WARNING_THRESHOLD}s)"
    log_watchdog "Heartbeat max age: ${HEARTBEAT_MAX_AGE}s"
    log_watchdog "Check interval: ${WATCHDOG_CHECK_INTERVAL}s"
    log_watchdog "Heartbeat file: $WATCHDOG_HEARTBEAT_FILE"

    local start_time phase_start_time current_time
    local total_elapsed phase_elapsed heartbeat_age
    local phase_warned=false
    local total_warned=false
    local claude_pid
    local last_heartbeat_content=""

    start_time=$(date +%s)
    phase_start_time=$start_time

    # Initialize heartbeat file
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Watchdog started" > "$WATCHDOG_HEARTBEAT_FILE"

    while true; do
        sleep "$WATCHDOG_CHECK_INTERVAL"
        current_time=$(date +%s)
        total_elapsed=$((current_time - start_time))
        phase_elapsed=$((current_time - phase_start_time))

        # Find Claude process
        claude_pid=$(find_claude_process)

        # Check if heartbeat file updated (phase change detection)
        if [ -f "$WATCHDOG_HEARTBEAT_FILE" ]; then
            local current_heartbeat
            current_heartbeat=$(cat "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || echo "")
            if [ "$current_heartbeat" != "$last_heartbeat_content" ] && [ -n "$current_heartbeat" ]; then
                # Heartbeat changed - reset phase timer
                if echo "$current_heartbeat" | grep -q "phase:"; then
                    log_watchdog "Phase change detected: $current_heartbeat"
                    phase_start_time=$current_time
                    phase_elapsed=0
                    phase_warned=false
                fi
                last_heartbeat_content="$current_heartbeat"
            fi
        fi

        # Get heartbeat age
        heartbeat_age=$(get_heartbeat_age)

        # Check 1: Heartbeat staleness (no updates for HEARTBEAT_MAX_AGE)
        if [ "$heartbeat_age" -ge "$HEARTBEAT_MAX_AGE" ]; then
            log_diagnostics "Heartbeat stale for ${heartbeat_age}s (max: ${HEARTBEAT_MAX_AGE}s)" \
                "$phase_elapsed" "$total_elapsed" "$claude_pid"

            kill_claude_process "$claude_pid"

            # Exit container with timeout code
            log_error "Exiting container with code 126 (heartbeat timeout)"
            exit 126
        fi

        # Check 2: Phase timeout
        if [ "$phase_elapsed" -ge "$PHASE_TIMEOUT" ]; then
            log_diagnostics "Phase timeout exceeded (${phase_elapsed}s >= ${PHASE_TIMEOUT}s)" \
                "$phase_elapsed" "$total_elapsed" "$claude_pid"

            kill_claude_process "$claude_pid"

            # Exit container with timeout code
            log_error "Exiting container with code 124 (phase timeout)"
            exit 124
        fi

        # Check 3: Total timeout
        if [ "$total_elapsed" -ge "$TOTAL_TIMEOUT" ]; then
            log_diagnostics "Total timeout exceeded (${total_elapsed}s >= ${TOTAL_TIMEOUT}s)" \
                "$phase_elapsed" "$total_elapsed" "$claude_pid"

            kill_claude_process "$claude_pid"

            # Exit container with timeout code
            log_error "Exiting container with code 125 (total timeout)"
            exit 125
        fi

        # Warning 1: Phase approaching timeout (80%)
        if [ "$phase_elapsed" -ge "$PHASE_WARNING_THRESHOLD" ] && [ "$phase_warned" = false ]; then
            log_warn "Phase approaching timeout: ${phase_elapsed}s / ${PHASE_TIMEOUT}s (80% threshold reached)"
            if [ -n "$claude_pid" ]; then
                log_warn "Claude process stats: $(get_process_stats "$claude_pid")"
            fi
            phase_warned=true
        fi

        # Warning 2: Total approaching timeout (80%)
        if [ "$total_elapsed" -ge "$TOTAL_WARNING_THRESHOLD" ] && [ "$total_warned" = false ]; then
            log_warn "Total execution approaching timeout: ${total_elapsed}s / ${TOTAL_TIMEOUT}s (80% threshold reached)"
            if [ -n "$claude_pid" ]; then
                log_warn "Claude process stats: $(get_process_stats "$claude_pid")"
            fi
            total_warned=true
        fi

        # Debug logging
        if [ -n "$claude_pid" ]; then
            log_watchdog "Status: phase=${phase_elapsed}s, total=${total_elapsed}s, heartbeat_age=${heartbeat_age}s, pid=$claude_pid"
        else
            # Claude not running yet or already finished - this is OK
            log_watchdog "Status: phase=${phase_elapsed}s, total=${total_elapsed}s, heartbeat_age=${heartbeat_age}s, pid=none"
        fi
    done
}

# Handle signals
cleanup() {
    log_watchdog "Watchdog received signal, shutting down normally"
    exit 0
}

trap cleanup SIGTERM SIGINT

# Run main loop
main
