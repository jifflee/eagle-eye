#!/bin/bash
set -euo pipefail
# check-container-capacity.sh
# Two-step capacity check: token utilization + resource availability
# Part of feature #619: resource-based container scheduling
#
# This script integrates:
# 1. Token utilization check (feature #367)
# 2. CPU/memory resource check (feature #619)
#
# Usage:
#   ./scripts/check-container-capacity.sh [OPTIONS]
#
# Options:
#   --verbose     Include detailed check results in output
#
# Output: JSON with combined decision
# {
#   "can_spawn": true/false,
#   "reason": "explanation",
#   "checks": {
#     "token_utilization": { "passed": true, ... },
#     "resource_availability": { "passed": true, ... }
#   }
# }
#
# Exit codes:
#   0 - Success (both checks completed)
#   1 - Error (script unavailable, check failed)

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="."

TOKEN_CHECK_SCRIPT="$SCRIPT_DIR/../n8n/n8n-check-utilization.sh"
RESOURCE_CHECK_SCRIPT="$SCRIPT_DIR/../check-resource-capacity.sh"

# Parse arguments
VERBOSE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Check if required scripts exist
if [ ! -x "$TOKEN_CHECK_SCRIPT" ]; then
  jq -cn \
    --arg reason "Token utilization check script not found: $TOKEN_CHECK_SCRIPT" \
    '{
      can_spawn: false,
      reason: $reason,
      error: "missing_dependency"
    }'
  exit 1
fi

if [ ! -x "$RESOURCE_CHECK_SCRIPT" ]; then
  jq -cn \
    --arg reason "Resource capacity check script not found: $RESOURCE_CHECK_SCRIPT" \
    '{
      can_spawn: false,
      reason: $reason,
      error: "missing_dependency"
    }'
  exit 1
fi

# Run Step 1: Token Utilization Check
TOKEN_CHECK_OUTPUT=$("$TOKEN_CHECK_SCRIPT" 2>&1) || {
  jq -cn \
    --arg reason "Token utilization check failed" \
    --arg error "$TOKEN_CHECK_OUTPUT" \
    '{
      can_spawn: false,
      reason: $reason,
      error: "token_check_failed",
      details: $error
    }'
  exit 1
}

TOKEN_CAN_TRIGGER=$(echo "$TOKEN_CHECK_OUTPUT" | jq -r '.can_trigger // false')
TOKEN_REASON=$(echo "$TOKEN_CHECK_OUTPUT" | jq -r '.reason // "unknown"')

# Run Step 2: Resource Availability Check
RESOURCE_CHECK_OUTPUT=$("$RESOURCE_CHECK_SCRIPT" 2>&1) || {
  jq -cn \
    --arg reason "Resource capacity check failed" \
    --arg error "$RESOURCE_CHECK_OUTPUT" \
    '{
      can_spawn: false,
      reason: $reason,
      error: "resource_check_failed",
      details: $error
    }'
  exit 1
}

RESOURCE_HAS_CAPACITY=$(echo "$RESOURCE_CHECK_OUTPUT" | jq -r '.has_capacity // false')
RESOURCE_REASON=$(echo "$RESOURCE_CHECK_OUTPUT" | jq -r '.reason // "unknown"')

# Combined Decision Logic
CAN_SPAWN="false"
REASON=""
FAILED_CHECK=""

if [ "$TOKEN_CAN_TRIGGER" = "false" ]; then
  REASON="Token utilization check failed: $TOKEN_REASON"
  FAILED_CHECK="token_utilization"
elif [ "$RESOURCE_HAS_CAPACITY" = "false" ]; then
  REASON="Resource capacity check failed: $RESOURCE_REASON"
  FAILED_CHECK="resource_availability"
else
  CAN_SPAWN="true"
  REASON="Both capacity checks passed - ready to spawn container"
fi

# Build output JSON
if [ "$VERBOSE" = "true" ]; then
  # Verbose mode: include full check details
  jq -cn \
    --arg can_spawn "$CAN_SPAWN" \
    --arg reason "$REASON" \
    --arg failed_check "$FAILED_CHECK" \
    --argjson token_check "$TOKEN_CHECK_OUTPUT" \
    --argjson resource_check "$RESOURCE_CHECK_OUTPUT" \
    '{
      can_spawn: ($can_spawn == "true"),
      reason: $reason,
      failed_check: (if $failed_check == "" then null else $failed_check end),
      checks: {
        token_utilization: {
          passed: $token_check.can_trigger,
          reason: $token_check.reason,
          details: $token_check
        },
        resource_availability: {
          passed: $resource_check.has_capacity,
          reason: $resource_check.reason,
          details: $resource_check
        }
      },
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }'
else
  # Compact mode: just decisions
  jq -cn \
    --arg can_spawn "$CAN_SPAWN" \
    --arg reason "$REASON" \
    --arg failed_check "$FAILED_CHECK" \
    --arg token_passed "$TOKEN_CAN_TRIGGER" \
    --arg token_reason "$TOKEN_REASON" \
    --arg resource_passed "$RESOURCE_HAS_CAPACITY" \
    --arg resource_reason "$RESOURCE_REASON" \
    '{
      can_spawn: ($can_spawn == "true"),
      reason: $reason,
      failed_check: (if $failed_check == "" then null else $failed_check end),
      checks: {
        token_utilization: {
          passed: ($token_passed == "true"),
          reason: $token_reason
        },
        resource_availability: {
          passed: ($resource_passed == "true"),
          reason: $resource_reason
        }
      },
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }'
fi

exit 0
