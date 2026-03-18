#!/bin/bash
set -euo pipefail
# watchdog-heartbeat.sh
# Helper functions for updating watchdog heartbeat from scripts
#
# Usage:
#   source scripts/lib/watchdog-heartbeat.sh
#   watchdog_heartbeat "Starting Phase 1"
#   watchdog_phase "implementation"

# Heartbeat file location
WATCHDOG_HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-/tmp/claude-heartbeat}"

# Update heartbeat with a message
watchdog_heartbeat() {
    local message="${1:-heartbeat}"
    if [ "${WATCHDOG_DISABLED:-false}" != "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" > "$WATCHDOG_HEARTBEAT_FILE"
    fi
}

# Update heartbeat with phase marker (resets phase timer)
watchdog_phase() {
    local phase_name="${1:-unknown}"
    if [ "${WATCHDOG_DISABLED:-false}" != "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - phase:$phase_name" > "$WATCHDOG_HEARTBEAT_FILE"
    fi
}

# Initialize watchdog (call at start of script)
watchdog_init() {
    local script_name="${1:-script}"
    if [ "${WATCHDOG_DISABLED:-false}" != "true" ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - init:$script_name" > "$WATCHDOG_HEARTBEAT_FILE"
    fi
}

# Cleanup watchdog (call at end of script)
watchdog_cleanup() {
    if [ "${WATCHDOG_DISABLED:-false}" != "true" ]; then
        rm -f "$WATCHDOG_HEARTBEAT_FILE" 2>/dev/null || true
    fi
}
