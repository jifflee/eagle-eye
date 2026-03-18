#!/bin/bash
# permission-decision.sh
# Hook entry point for Permission Decision Engine
# Part of Issue #596: Permission Decision Engine for container automation
#
# This hook intercepts PreToolUse and PermissionRequest events and makes
# automated permission decisions based on:
#   1. Tier classification (T0-T3)
#   2. Policy rules
#   3. Session caching (T2)
#   4. Webhook escalation (T3)
#
# Exit codes:
#   0 - Allow (or output JSON decision)
#   2 - Deny (blocks execution, shows stderr)
#   Other - Non-blocking error

set -euo pipefail

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
TIER_CLASSIFIER="${REPO_ROOT}/scripts/permissions/tier-classifier.sh"
POLICY_EVALUATOR="${REPO_ROOT}/scripts/permissions/policy-evaluator.sh"
AUDIT_DIR="${HOME}/.claude-tastic/permission-audit"

# Ensure audit directory exists
mkdir -p "$AUDIT_DIR"

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Parse hook event
HOOK_EVENT=$(echo "$HOOK_INPUT" | jq -r '.hook_event_name // "PreToolUse"')
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""')
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -r '.tool_input // {}')
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // "unknown"')
PERMISSION_MODE=$(echo "$HOOK_INPUT" | jq -r '.permission_mode // "default"')

# Extract command/file from tool input
COMMAND=$(echo "$TOOL_INPUT" | jq -r '.command // ""')
FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // ""')

# Log function
log_hook() {
    local level="$1"
    local message="$2"
    local log_file="$AUDIT_DIR/hook-$(date +%Y%m%d).log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $message" >> "$log_file"
}

log_hook "INFO" "Hook triggered: event=$HOOK_EVENT tool=$TOOL_NAME"

# Only process in dontAsk mode (container mode)
# In other modes, let native permission system handle it
if [ "$PERMISSION_MODE" != "dontAsk" ] && [ "$HOOK_EVENT" = "PermissionRequest" ]; then
    log_hook "DEBUG" "Skipping - not in dontAsk mode"
    exit 0  # Let native system handle
fi

# Step 1: Classify the operation into a tier
if [ -x "$TIER_CLASSIFIER" ]; then
    TIER_RESULT=$(echo "$HOOK_INPUT" | "$TIER_CLASSIFIER" 2>/dev/null || echo '{"tier":"T2","reason":"classifier error"}')
else
    # Fallback classification
    case "$TOOL_NAME" in
        Read|Glob|Grep) TIER_RESULT='{"tier":"T0","reason":"read tool"}' ;;
        Edit|Write) TIER_RESULT='{"tier":"T1","reason":"write tool"}' ;;
        Bash) TIER_RESULT='{"tier":"T2","reason":"bash command"}' ;;
        *) TIER_RESULT='{"tier":"T2","reason":"unknown tool"}' ;;
    esac
fi

TIER=$(echo "$TIER_RESULT" | jq -r '.tier')
TIER_REASON=$(echo "$TIER_RESULT" | jq -r '.reason')

log_hook "INFO" "Classified: tier=$TIER reason=$TIER_REASON"

# Step 2: Evaluate against policy
EVAL_INPUT=$(jq -n \
    --arg tier "$TIER" \
    --arg tool "$TOOL_NAME" \
    --arg command "$COMMAND" \
    --arg file_path "$FILE_PATH" \
    --arg session "$SESSION_ID" \
    '{tier:$tier,tool:$tool,command:$command,file_path:$file_path,session:$session}')

if [ -x "$POLICY_EVALUATOR" ]; then
    POLICY_RESULT=$(echo "$EVAL_INPUT" | SESSION_ID="$SESSION_ID" "$POLICY_EVALUATOR" 2>/dev/null || echo '{"decision":"deny","reason":"evaluator error"}')
else
    # Fallback policy: allow T0/T1, deny T3, allow T2 in container
    case "$TIER" in
        T0|T1) POLICY_RESULT='{"decision":"allow","reason":"auto-allow (fallback)"}' ;;
        T2) POLICY_RESULT='{"decision":"allow","reason":"T2 allow (fallback)"}' ;;
        T3) POLICY_RESULT='{"decision":"deny","reason":"T3 deny (fallback)"}' ;;
        *) POLICY_RESULT='{"decision":"deny","reason":"unknown tier"}' ;;
    esac
fi

DECISION=$(echo "$POLICY_RESULT" | jq -r '.decision')
DECISION_REASON=$(echo "$POLICY_RESULT" | jq -r '.reason')

log_hook "INFO" "Decision: $DECISION reason=$DECISION_REASON"

# Step 3: Handle escalation (T3 webhook)
if [ "$DECISION" = "escalate" ] && [ -n "${PERMISSION_WEBHOOK_URL:-}" ]; then
    log_hook "INFO" "Escalating to webhook: $PERMISSION_WEBHOOK_URL"

    WEBHOOK_PAYLOAD=$(jq -n \
        --arg session "$SESSION_ID" \
        --arg tool "$TOOL_NAME" \
        --arg command "$COMMAND" \
        --arg tier "$TIER" \
        --arg reason "$TIER_REASON" \
        '{session:$session,tool:$tool,command:$command,tier:$tier,reason:$reason,timestamp:now|todate}')

    WEBHOOK_RESPONSE=$(curl -s -X POST "$PERMISSION_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${PERMISSION_WEBHOOK_TOKEN:-}" \
        -d "$WEBHOOK_PAYLOAD" \
        --max-time 10 2>/dev/null || echo '{"allowed":false,"reason":"webhook timeout"}')

    WEBHOOK_ALLOWED=$(echo "$WEBHOOK_RESPONSE" | jq -r '.allowed // false')
    WEBHOOK_REASON=$(echo "$WEBHOOK_RESPONSE" | jq -r '.reason // "no reason"')

    if [ "$WEBHOOK_ALLOWED" = "true" ]; then
        log_hook "INFO" "Webhook approved: $WEBHOOK_REASON"
        DECISION="allow"
        DECISION_REASON="webhook approved: $WEBHOOK_REASON"
    else
        log_hook "WARN" "Webhook denied: $WEBHOOK_REASON"
        DECISION="deny"
        DECISION_REASON="webhook denied: $WEBHOOK_REASON"
    fi
fi

# Step 4: Write audit record
AUDIT_RECORD=$(jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg session "$SESSION_ID" \
    --arg event "$HOOK_EVENT" \
    --arg tool "$TOOL_NAME" \
    --arg command "$COMMAND" \
    --arg file "$FILE_PATH" \
    --arg tier "$TIER" \
    --arg decision "$DECISION" \
    --arg reason "$DECISION_REASON" \
    '{timestamp:$ts,session:$session,event:$event,tool:$tool,command:$command,file:$file,tier:$tier,decision:$decision,reason:$reason}')

echo "$AUDIT_RECORD" >> "$AUDIT_DIR/decisions-$(date +%Y%m%d).jsonl"

# Step 5: Return decision
case "$DECISION" in
    allow)
        # Exit 0 with no output = implicit allow
        exit 0
        ;;
    deny)
        # Exit 2 = blocking error, stderr shown to user
        echo "Permission denied: $DECISION_REASON (tier: $TIER, tool: $TOOL_NAME)" >&2
        exit 2
        ;;
    *)
        # Unknown decision - deny for safety
        echo "Permission denied: unknown decision '$DECISION'" >&2
        exit 2
        ;;
esac
