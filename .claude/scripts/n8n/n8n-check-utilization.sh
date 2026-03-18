#!/bin/bash
set -euo pipefail
# n8n-check-utilization.sh
# Token-protective utilization check for n8n orchestration
# Optimized for minimal token consumption
#
# Usage:
#   ./scripts/n8n-check-utilization.sh [OPTIONS]
#
# Output: JSON with decision and metadata
# {
#   "can_trigger": true/false,
#   "reason": "explanation",
#   "utilization": { ... },
#   "metadata": { ... }
# }
#
# Exit codes:
#   0 - Success (check completed)
#   1 - Error (configuration, file access, etc.)

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="."
STATE_SCRIPT="$SCRIPT_DIR/utilization-state.sh"

# Thresholds (configurable via environment)
MAX_UTILIZATION="${N8N_MAX_UTILIZATION:-85}"  # Don't trigger if > 85% utilized
MIN_CAPACITY="${N8N_MIN_CAPACITY:-15}"        # Need at least 15% capacity remaining
STALE_ALLOWED="${N8N_STALE_ALLOWED:-true}"    # Allow stale data by default

# Check if state script exists
if [ ! -x "$STATE_SCRIPT" ]; then
  jq -cn \
    --arg reason "State management script not found or not executable: $STATE_SCRIPT" \
    '{
      can_trigger: false,
      reason: $reason,
      error: "missing_dependency"
    }'
  exit 1
fi

# Read state (free - no token cost)
STATE_JSON=$("$STATE_SCRIPT" --read 2>/dev/null || echo "")

# Check if state read failed
if [ -z "$STATE_JSON" ]; then
  # State file doesn't exist - initialize it
  "$STATE_SCRIPT" --init >/dev/null 2>&1 || true
  STATE_JSON=$("$STATE_SCRIPT" --read 2>/dev/null || echo "")

  if [ -z "$STATE_JSON" ]; then
    jq -cn \
      --arg reason "Failed to read or initialize utilization state" \
      '{
        can_trigger: false,
        reason: $reason,
        error: "state_unavailable"
      }'
    exit 1
  fi
fi

# Parse state data
USAGE_PCT=$(echo "$STATE_JSON" | jq -r '.utilization.current_usage_pct // 0')
REMAINING_PCT=$(echo "$STATE_JSON" | jq -r '.utilization.remaining_capacity_pct // 100')
IS_STALE=$(echo "$STATE_JSON" | jq -r '.staleness.is_stale // false')
DATA_AGE=$(echo "$STATE_JSON" | jq -r '.staleness.data_age_minutes // 999')
WORK_IN_PROGRESS=$(echo "$STATE_JSON" | jq -r '.session.work_in_progress // false')

# Decision logic
CAN_TRIGGER="false"
REASON=""

# Check 1: Work already in progress?
if [ "$WORK_IN_PROGRESS" = "true" ]; then
  REASON="Work already in progress - prevent double-triggering"
# Check 2: Data too stale?
elif [ "$IS_STALE" = "true" ] && [ "$STALE_ALLOWED" = "false" ]; then
  REASON="Utilization data is stale (${DATA_AGE} min old) - refresh needed"
# Check 3: Usage too high?
elif [ "$USAGE_PCT" -ge "$MAX_UTILIZATION" ]; then
  REASON="Utilization too high (${USAGE_PCT}% >= ${MAX_UTILIZATION}% threshold)"
# Check 4: Capacity too low?
elif [ "$REMAINING_PCT" -lt "$MIN_CAPACITY" ]; then
  REASON="Remaining capacity too low (${REMAINING_PCT}% < ${MIN_CAPACITY}% threshold)"
# All checks passed
else
  CAN_TRIGGER="true"
  REASON="Capacity available (${REMAINING_PCT}% remaining, ${USAGE_PCT}% utilized)"
fi

# Build output JSON
jq -cn \
  --arg can_trigger "$CAN_TRIGGER" \
  --arg reason "$REASON" \
  --argjson utilization "$(echo "$STATE_JSON" | jq -c '.utilization')" \
  --argjson session "$(echo "$STATE_JSON" | jq -c '.session')" \
  --argjson staleness "$(echo "$STATE_JSON" | jq -c '.staleness')" \
  --argjson reset_window "$(echo "$STATE_JSON" | jq -c '.reset_window')" \
  --arg max_utilization "$MAX_UTILIZATION" \
  --arg min_capacity "$MIN_CAPACITY" \
  --arg stale_allowed "$STALE_ALLOWED" \
  '{
    can_trigger: ($can_trigger == "true"),
    reason: $reason,
    utilization: $utilization,
    session: $session,
    staleness: $staleness,
    reset_window: $reset_window,
    thresholds: {
      max_utilization: ($max_utilization | tonumber),
      min_capacity: ($min_capacity | tonumber),
      stale_allowed: ($stale_allowed == "true")
    },
    timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  }'

exit 0
