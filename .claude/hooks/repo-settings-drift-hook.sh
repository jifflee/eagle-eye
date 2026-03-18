#!/bin/bash
set -euo pipefail
# repo-settings-drift-hook.sh
# PostToolUse hook for repo settings drift detection during PR operations
# Renamed from validate-repo-settings.sh to distinguish from scripts/ci/validators/validate-repo-settings.sh
#
# This hook monitors PR-related operations and validates that repository
# settings match the desired configuration defined in config/repo-settings.yaml
#
# Triggers on:
#   - PR creation (gh pr create)
#   - PR merge operations
#
# Input: JSON via stdin with tool execution details
# Output: JSON to stdout with validation results
# Exit: 0 = allow operation, non-zero = block operation (strict mode only)

set -eo pipefail

# Get project root
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
VALIDATOR_SCRIPT="$PROJECT_ROOT/scripts/ci/validate-repo-settings.sh"

# Read JSON from stdin
json_input=$(cat)

# Extract relevant fields
tool_name=$(echo "$json_input" | jq -r '.tool_name // ""')
tool_input=$(echo "$json_input" | jq -r '.tool_input // {}')
tool_response=$(echo "$json_input" | jq -r '.tool_response // {}')
hook_event=$(echo "$json_input" | jq -r '.hook_event_name // ""')

# Only process PostToolUse events
if [[ "$hook_event" != "PostToolUse" ]]; then
  exit 0
fi

# Only process Bash tool calls
if [[ "$tool_name" != "Bash" ]]; then
  exit 0
fi

# Extract command from tool input
command=$(echo "$tool_input" | jq -r '.command // ""')

# Check if this is a PR-related command
is_pr_operation=false

if echo "$command" | grep -qE '^gh pr create'; then
  is_pr_operation=true
  operation_type="pr_create"
elif echo "$command" | grep -qE '^gh pr merge'; then
  is_pr_operation=true
  operation_type="pr_merge"
elif echo "$command" | grep -qE 'pr-to-(qa|main)'; then
  is_pr_operation=true
  operation_type="pr_promote"
fi

# Exit if not a PR operation
if [[ "$is_pr_operation" != "true" ]]; then
  exit 0
fi

# Check if the PR operation was successful
exit_code=$(echo "$tool_response" | jq -r '.exit_code // 1')
if [[ "$exit_code" != "0" ]]; then
  # PR operation failed, don't validate
  exit 0
fi

# ─── Run Validation ───────────────────────────────────────────────────────────

# Check if validator script exists
if [[ ! -f "$VALIDATOR_SCRIPT" ]]; then
  # Validator not available, skip silently
  exit 0
fi

# Check if config exists
if [[ ! -f "$PROJECT_ROOT/config/repo-settings.yaml" ]]; then
  # Config not available, skip silently
  exit 0
fi

# Check if drift detection is enabled
drift_enabled=$(yq eval '.drift_detection.enabled' "$PROJECT_ROOT/config/repo-settings.yaml" 2>/dev/null || echo "false")
if [[ "$drift_enabled" != "true" ]]; then
  exit 0
fi

# Run validation
validation_result=0
validation_output=""

if validation_output=$("$VALIDATOR_SCRIPT" 2>&1); then
  validation_result=0
else
  validation_result=$?
fi

# ─── Process Results ──────────────────────────────────────────────────────────

if [[ $validation_result -eq 0 ]]; then
  # No drift detected
  cat <<EOF
{
  "result": "✅ Repository settings validation passed - no drift detected",
  "metadata": {
    "hook": "validate-repo-settings",
    "operation": "$operation_type",
    "drift_detected": false,
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
  exit 0
else
  # Drift detected
  drift_count=$(echo "$validation_output" | grep -oP 'Settings with drift: \K\d+' || echo "unknown")

  # Get enforcement mode
  enforcement_mode=$(yq eval '.drift_detection.mode' "$PROJECT_ROOT/config/repo-settings.yaml" 2>/dev/null || echo "advisory")

  if [[ "$enforcement_mode" == "strict" ]]; then
    # Strict mode: block the operation
    cat <<EOF
{
  "result": "❌ Repository settings drift detected - BLOCKING in strict mode",
  "metadata": {
    "hook": "validate-repo-settings",
    "operation": "$operation_type",
    "drift_detected": true,
    "drift_count": "$drift_count",
    "enforcement_mode": "strict",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "error": "Drift detected: $drift_count setting(s) don't match config/repo-settings.yaml. Fix settings or update config before proceeding."
}
EOF
    # Note: Hooks currently can't block operations, so we just report
    # The validation script exit code will be used by CI
    exit 0
  else
    # Advisory mode: warn but allow
    cat <<EOF
{
  "result": "⚠️  Repository settings drift detected - WARNING in advisory mode",
  "metadata": {
    "hook": "validate-repo-settings",
    "operation": "$operation_type",
    "drift_detected": true,
    "drift_count": "$drift_count",
    "enforcement_mode": "advisory",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  },
  "warning": "Drift detected: $drift_count setting(s) don't match config/repo-settings.yaml. Consider reviewing repository settings."
}
EOF
    exit 0
  fi
fi
