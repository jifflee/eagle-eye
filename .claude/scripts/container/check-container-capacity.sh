#!/bin/bash
set -euo pipefail
# check-container-capacity.sh
# Three-step capacity check: token utilization + resource availability + Proxmox routing
# Part of feature #619: resource-based container scheduling
# Part of feature #1326: Proxmox-first container routing
#
# This script integrates:
# 1. Token utilization check (feature #367)
# 2. CPU/memory resource check (feature #619)
# 3. Proxmox routing decision (feature #1326)
#
# Usage:
#   ./scripts/check-container-capacity.sh [OPTIONS]
#
# Options:
#   --verbose     Include detailed check results in output
#   --worktree    Force worktree mode (passed through to routing)
#
# Output: JSON with combined decision
# {
#   "can_spawn": true/false,
#   "reason": "explanation",
#   "execution_target": "proxmox|local|worktree",
#   "checks": {
#     "token_utilization": { "passed": true, ... },
#     "resource_availability": { "passed": true, ... },
#     "proxmox_routing": { "passed": true, ... }
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
PROXMOX_ROUTE_SCRIPT="$SCRIPT_DIR/../route-execution-target.sh"

# Parse arguments
VERBOSE=false
FORCE_WORKTREE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose)
      VERBOSE=true
      shift
      ;;
    --worktree)
      FORCE_WORKTREE=true
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

# Run Step 3: Proxmox routing decision (feature #1326)
PROXMOX_ROUTE_OUTPUT='{}'
PROXMOX_TARGET="local"
PROXMOX_REASON="Proxmox routing check not available"
PROXMOX_ROUTE_PASSED="false"

if [ -x "$PROXMOX_ROUTE_SCRIPT" ]; then
  ROUTE_ARGS=()
  [ "$FORCE_WORKTREE" = "true" ] && ROUTE_ARGS+=("--worktree")

  PROXMOX_ROUTE_OUTPUT=$("$PROXMOX_ROUTE_SCRIPT" "${ROUTE_ARGS[@]}" 2>&1) || {
    PROXMOX_ROUTE_OUTPUT='{"target":"local","reason":"Proxmox routing check failed","decision_type":"error"}'
  }

  PROXMOX_TARGET=$(echo "$PROXMOX_ROUTE_OUTPUT" | jq -r '.target // "local"')
  PROXMOX_REASON=$(echo "$PROXMOX_ROUTE_OUTPUT" | jq -r '.reason // "unknown"')
  PROXMOX_ROUTE_PASSED="true"
else
  # Fallback: determine target from Docker availability
  if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    PROXMOX_TARGET="local"
    PROXMOX_REASON="Proxmox routing unavailable — using local Docker"
  else
    PROXMOX_TARGET="worktree"
    PROXMOX_REASON="Proxmox routing unavailable and Docker not running — using worktree"
  fi
fi

# If forced worktree, override target
[ "$FORCE_WORKTREE" = "true" ] && PROXMOX_TARGET="worktree"

# Combined Decision Logic
CAN_SPAWN="false"
REASON=""
FAILED_CHECK=""
EXECUTION_TARGET="$PROXMOX_TARGET"

if [ "$TOKEN_CAN_TRIGGER" = "false" ]; then
  REASON="Token utilization check failed: $TOKEN_REASON"
  FAILED_CHECK="token_utilization"
elif [ "$RESOURCE_HAS_CAPACITY" = "false" ]; then
  REASON="Resource capacity check failed: $RESOURCE_REASON"
  FAILED_CHECK="resource_availability"
elif [ "$PROXMOX_TARGET" = "worktree" ]; then
  # Worktree is a valid target — can_spawn=true but execution_target=worktree
  CAN_SPAWN="true"
  REASON="Routing to worktree: $PROXMOX_REASON"
else
  CAN_SPAWN="true"
  REASON="All capacity checks passed — routing to ${PROXMOX_TARGET}: ${PROXMOX_REASON}"
fi

# Build output JSON
if [ "$VERBOSE" = "true" ]; then
  # Verbose mode: include full check details
  jq -cn \
    --arg can_spawn "$CAN_SPAWN" \
    --arg reason "$REASON" \
    --arg failed_check "$FAILED_CHECK" \
    --arg execution_target "$EXECUTION_TARGET" \
    --argjson token_check "$TOKEN_CHECK_OUTPUT" \
    --argjson resource_check "$RESOURCE_CHECK_OUTPUT" \
    --argjson proxmox_route "$PROXMOX_ROUTE_OUTPUT" \
    --arg proxmox_route_passed "$PROXMOX_ROUTE_PASSED" \
    '{
      can_spawn: ($can_spawn == "true"),
      reason: $reason,
      execution_target: $execution_target,
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
        },
        proxmox_routing: {
          passed: ($proxmox_route_passed == "true"),
          target: $proxmox_route.target,
          reason: $proxmox_route.reason,
          details: $proxmox_route
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
    --arg execution_target "$EXECUTION_TARGET" \
    --arg token_passed "$TOKEN_CAN_TRIGGER" \
    --arg token_reason "$TOKEN_REASON" \
    --arg resource_passed "$RESOURCE_HAS_CAPACITY" \
    --arg resource_reason "$RESOURCE_REASON" \
    --arg proxmox_target "$PROXMOX_TARGET" \
    --arg proxmox_reason "$PROXMOX_REASON" \
    --arg proxmox_route_passed "$PROXMOX_ROUTE_PASSED" \
    '{
      can_spawn: ($can_spawn == "true"),
      reason: $reason,
      execution_target: $execution_target,
      failed_check: (if $failed_check == "" then null else $failed_check end),
      checks: {
        token_utilization: {
          passed: ($token_passed == "true"),
          reason: $token_reason
        },
        resource_availability: {
          passed: ($resource_passed == "true"),
          reason: $resource_reason
        },
        proxmox_routing: {
          passed: ($proxmox_route_passed == "true"),
          target: $proxmox_target,
          reason: $proxmox_reason
        }
      },
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }'
fi

exit 0
