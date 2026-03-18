#!/bin/bash
# policy-evaluator.sh
# Evaluate permission requests against policy rules
# Part of the Permission Decision Engine (Issue #596)
#
# Usage:
#   ./scripts/permissions/policy-evaluator.sh --tier T2 --tool Bash --input '{"command":"git push"}'
#   echo '{"tier":"T2","tool":"Bash","command":"git push"}' | ./scripts/permissions/policy-evaluator.sh
#
# Output: JSON with decision (allow/deny/escalate) and reason

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_FILE="${POLICY_FILE:-$SCRIPT_DIR/../../config/container-permission-policy.yaml}"
CACHE_DIR="${CACHE_DIR:-$HOME/.claude-tastic/permission-cache}"
SESSION_ID="${SESSION_ID:-$(date +%Y%m%d)}"
CONTEXT_EVALUATOR="${SCRIPT_DIR}/context-evaluator.sh"
HISTORY_TRACKER="${SCRIPT_DIR}/track-command-history.sh"

# Context-aware evaluation enabled by default (set DISABLE_CONTEXT_EVAL=true to disable)
CONTEXT_EVAL_ENABLED="${CONTEXT_EVAL_ENABLED:-true}"
if [ "${DISABLE_CONTEXT_EVAL:-}" = "true" ]; then
    CONTEXT_EVAL_ENABLED="false"
fi

# Ensure cache directory exists
mkdir -p "$CACHE_DIR"

# Read input
if [ -t 0 ]; then
    TIER=""
    TOOL=""
    INPUT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier) TIER="$2"; shift 2 ;;
            --tool) TOOL="$2"; shift 2 ;;
            --input) INPUT="$2"; shift 2 ;;
            --session) SESSION_ID="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
else
    INPUT=$(cat)
    TIER=$(echo "$INPUT" | jq -r '.tier // ""')
    TOOL=$(echo "$INPUT" | jq -r '.tool // .tool_name // ""')
fi

COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | jq -r '.file_path // .tool_input.file_path // ""' 2>/dev/null || echo "")
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Extract issue number from branch if available
ISSUE_NUMBER=""
if [[ "$BRANCH" =~ (feat|fix|issue)[/-]([0-9]+) ]]; then
    ISSUE_NUMBER="${BASH_REMATCH[2]}"
fi

# Log decision
log_decision() {
    local decision="$1"
    local reason="$2"
    local audit_file="$CACHE_DIR/audit-$(date +%Y%m%d).jsonl"

    jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg session "$SESSION_ID" \
        --arg tier "$TIER" \
        --arg tool "$TOOL" \
        --arg command "$COMMAND" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        '{timestamp:$ts,session:$session,tier:$tier,tool:$tool,command:$command,decision:$decision,reason:$reason}' \
        >> "$audit_file"
}

# Check session cache for T2 operations
check_cache() {
    local cache_key="$1"
    local cache_file="$CACHE_DIR/session-$SESSION_ID.json"

    if [ -f "$cache_file" ]; then
        local cached=$(jq -r --arg key "$cache_key" '.[$key] // empty' "$cache_file" 2>/dev/null)
        if [ -n "$cached" ]; then
            echo "$cached"
            return 0
        fi
    fi
    return 1
}

# Update session cache
update_cache() {
    local cache_key="$1"
    local decision="$2"
    local cache_file="$CACHE_DIR/session-$SESSION_ID.json"

    if [ -f "$cache_file" ]; then
        local updated=$(jq --arg key "$cache_key" --arg val "$decision" '.[$key] = $val' "$cache_file")
        echo "$updated" > "$cache_file"
    else
        jq -n --arg key "$cache_key" --arg val "$decision" '{($key): $val}' > "$cache_file"
    fi
}

# Apply context-aware tier adjustment
apply_context_adjustment() {
    local tier="$1"

    if [ "$CONTEXT_EVAL_ENABLED" != "true" ] || [ ! -x "$CONTEXT_EVALUATOR" ]; then
        echo "$tier"
        return
    fi

    # Build context input
    local context_input
    context_input=$(jq -n \
        --arg tier "$tier" \
        --arg file "$FILE_PATH" \
        --arg command "$COMMAND" \
        --arg tool "$TOOL" \
        --arg issue "$ISSUE_NUMBER" \
        '{tier:$tier,file_path:$file,command:$command,tool:$tool,issue_number:$issue}')

    # Evaluate context
    local context_result
    context_result=$(echo "$context_input" | "$CONTEXT_EVALUATOR" 2>/dev/null || echo '{"adjusted_tier":"'"$tier"'","context_applied":false}')

    # Extract adjusted tier
    local adjusted_tier
    adjusted_tier=$(echo "$context_result" | jq -r '.adjusted_tier')

    # Log context factors if applied
    if [ "$(echo "$context_result" | jq -r '.context_applied')" = "true" ]; then
        local reasons
        reasons=$(echo "$context_result" | jq -r '.reasons | join(", ")')
        log_decision "context_adjustment" "tier adjusted from $tier to $adjusted_tier: $reasons"
    fi

    echo "$adjusted_tier"
}

# Evaluate against policy rules
evaluate_policy() {
    # Apply context-aware adjustment to tier
    local original_tier="$TIER"
    TIER=$(apply_context_adjustment "$TIER")

    # Track context metadata for audit
    local context_note=""
    if [ "$original_tier" != "$TIER" ]; then
        context_note=" (context-adjusted from $original_tier)"
    fi

    # T0: Always allow (read-only)
    if [ "$TIER" = "T0" ]; then
        log_decision "allow" "T0 auto-allow${context_note}"
        echo '{"decision":"allow","reason":"T0 auto-allow (read-only)'"${context_note}"'","original_tier":"'"$original_tier"'","adjusted_tier":"'"$TIER"'"}'
        return
    fi

    # T1: Allow with logging (safe writes)
    if [ "$TIER" = "T1" ]; then
        log_decision "allow" "T1 auto-allow${context_note}"
        echo '{"decision":"allow","reason":"T1 auto-allow (safe write)'"${context_note}"'","original_tier":"'"$original_tier"'","adjusted_tier":"'"$TIER"'"}'
        return
    fi

    # T2: Check cache first, then policy
    if [ "$TIER" = "T2" ]; then
        local cache_key="${TOOL}:${COMMAND:0:50}"
        local cached_decision
        if cached_decision=$(check_cache "$cache_key"); then
            log_decision "$cached_decision" "T2 cached decision"
            echo "{\"decision\":\"$cached_decision\",\"reason\":\"T2 cached decision\"}"
            return
        fi

        # Check against policy rules
        local policy_result
        policy_result=$(check_policy_rules)

        if [ -n "$policy_result" ]; then
            local decision=$(echo "$policy_result" | jq -r '.decision')
            update_cache "$cache_key" "$decision"
            log_decision "$decision" "$(echo "$policy_result" | jq -r '.reason')"
            echo "$policy_result"
            return
        fi

        # Default T2: allow in container (pre-approved settings cover most)
        update_cache "$cache_key" "allow"
        log_decision "allow" "T2 default allow (container mode)${context_note}"
        echo '{"decision":"allow","reason":"T2 default allow (container mode)'"${context_note}"'","original_tier":"'"$original_tier"'","adjusted_tier":"'"$TIER"'"}'

        # Record successful command execution for history tracking
        if [ -x "$HISTORY_TRACKER" ]; then
            "$HISTORY_TRACKER" --record --command "$COMMAND" --success &>/dev/null &
        fi
        return
    fi

    # T3: Deny or escalate
    if [ "$TIER" = "T3" ]; then
        local policy_result
        policy_result=$(check_policy_rules)

        if [ -n "$policy_result" ]; then
            local decision=$(echo "$policy_result" | jq -r '.decision')
            log_decision "$decision" "$(echo "$policy_result" | jq -r '.reason')"
            echo "$policy_result"
            return
        fi

        # Check if webhook escalation is configured
        if [ -n "${PERMISSION_WEBHOOK_URL:-}" ]; then
            log_decision "escalate" "T3 webhook escalation"
            echo '{"decision":"escalate","reason":"T3 requires human approval"}'
            return
        fi

        # Default T3: deny in container
        log_decision "deny" "T3 auto-deny (container mode)${context_note}"
        echo '{"decision":"deny","reason":"T3 auto-deny (destructive operation)'"${context_note}"'","original_tier":"'"$original_tier"'","adjusted_tier":"'"$TIER"'"}'
        return
    fi

    # Unknown tier: deny
    log_decision "deny" "unknown tier"
    echo '{"decision":"deny","reason":"unknown tier","original_tier":"'"$original_tier"'","adjusted_tier":"'"$TIER"'"}'
}

# Check against explicit policy rules
check_policy_rules() {
    # Explicit allow patterns for container mode
    local allow_patterns=(
        "^git (add|commit|push|pull|fetch|checkout|branch|merge|rebase|stash|tag)"
        "^npm (install|run|test|build|publish)"
        "^gh (issue|pr|api|repo|workflow)"
        "^make "
        "^python "
        "^node "
        "^\./scripts/"
    )

    # Explicit deny patterns (override everything)
    local deny_patterns=(
        "rm -rf /"
        "rm -rf \*"
        ":(){ :|:& };:"  # Fork bomb
        "DROP DATABASE"
        "DELETE FROM .* WHERE 1"
        "TRUNCATE TABLE"
        "--force.*origin/(main|master)"
        "push --force.*(main|master)"
        "curl.*\|.*bash"
        "wget.*\|.*bash"
    )

    # Check deny patterns first
    for pattern in "${deny_patterns[@]}"; do
        if [[ "$COMMAND" =~ $pattern ]]; then
            echo '{"decision":"deny","reason":"matches deny pattern: '"$pattern"'"}'
            return
        fi
    done

    # Check allow patterns for T2/T3
    for pattern in "${allow_patterns[@]}"; do
        if [[ "$COMMAND" =~ $pattern ]]; then
            echo '{"decision":"allow","reason":"matches allow pattern"}'
            return
        fi
    done

    # No matching rule
    return 1
}

# Main
evaluate_policy
