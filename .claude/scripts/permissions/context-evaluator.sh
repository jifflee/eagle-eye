#!/bin/bash
# context-evaluator.sh
# Evaluate context-aware risk adjustments for permission decisions
# Part of Issue #597: Context-aware risk assessment for Permission Decision Engine
#
# Usage:
#   echo '{"tier":"T2","file_path":"scripts/permissions/test.sh","command":"..."}' | ./scripts/permissions/context-evaluator.sh
#
# Output: JSON with adjusted tier and reason

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR/../..}"
EXTRACT_SCOPE="${SCRIPT_DIR}/extract-issue-scope.sh"
HISTORY_TRACKER="${SCRIPT_DIR}/track-command-history.sh"
CACHE_DIR="${CACHE_DIR:-$HOME/.claude-tastic/permission-cache}"

mkdir -p "$CACHE_DIR"

# Read input
INPUT=$(cat)
TIER=$(echo "$INPUT" | jq -r '.tier // ""')
FILE_PATH=$(echo "$INPUT" | jq -r '.file_path // ""')
COMMAND=$(echo "$INPUT" | jq -r '.command // ""')
TOOL=$(echo "$INPUT" | jq -r '.tool // ""')
ISSUE_NUMBER=$(echo "$INPUT" | jq -r '.issue_number // ""')

# Get issue scope (with caching)
get_issue_scope() {
    local issue_num="$1"

    if [ -z "$issue_num" ]; then
        echo '{"has_scope":false}'
        return
    fi

    local cache_file="$CACHE_DIR/issue-scope-${issue_num}.json"

    # Check cache (valid for 1 hour)
    if [ -f "$cache_file" ]; then
        local file_mod_time cache_age
        # Try BSD stat, then GNU stat, then skip cache check
        if file_mod_time=$(stat -f %m "$cache_file" 2>/dev/null); then
            cache_age=$(($(date +%s) - file_mod_time))
        elif file_mod_time=$(stat -c %Y "$cache_file" 2>/dev/null); then
            cache_age=$(($(date +%s) - file_mod_time))
        else
            cache_age=9999  # Force refresh if stat fails
        fi

        if [ "$cache_age" -lt 3600 ]; then
            cat "$cache_file"
            return
        fi
    fi

    # Extract and cache
    if [ -x "$EXTRACT_SCOPE" ]; then
        local scope
        scope=$("$EXTRACT_SCOPE" --issue-number "$issue_num" 2>/dev/null || echo '{"has_scope":false}')
        echo "$scope" > "$cache_file"
        echo "$scope"
    else
        echo '{"has_scope":false}'
    fi
}

# Check if file matches issue scope
file_in_scope() {
    local file="$1"
    local scope="$2"

    if [ -z "$file" ]; then
        return 1
    fi

    # Check against file patterns
    local patterns
    patterns=$(echo "$scope" | jq -r '.file_patterns[]?' 2>/dev/null || echo "")

    while IFS= read -r pattern; do
        [ -z "$pattern" ] && continue

        # Convert glob pattern to regex
        local regex="${pattern//\*/.*}"
        if [[ "$file" =~ $regex ]]; then
            return 0
        fi
    done <<< "$patterns"

    # Check acceptance files
    local acceptance_files
    acceptance_files=$(echo "$scope" | jq -r '.acceptance_files[]?' 2>/dev/null || echo "")

    while IFS= read -r acc_file; do
        [ -z "$acc_file" ] && continue
        if [[ "$file" == *"$acc_file"* ]]; then
            return 0
        fi
    done <<< "$acceptance_files"

    return 1
}

# Check if command matches issue keywords
command_in_context() {
    local cmd="$1"
    local scope="$2"

    if [ -z "$cmd" ]; then
        return 1
    fi

    # Get keywords from scope
    local keywords
    keywords=$(echo "$scope" | jq -r '.keywords[]?' 2>/dev/null || echo "")

    while IFS= read -r keyword; do
        [ -z "$keyword" ] && continue
        if [[ "$cmd" =~ $keyword ]]; then
            return 0
        fi
    done <<< "$keywords"

    return 1
}

# Check if file is a test file
is_test_file() {
    local file="$1"
    [[ "$file" =~ (test|spec|__tests__|tests)/ ]] || [[ "$file" =~ \.(test|spec)\. ]]
}

# Check command history (success rate)
get_command_history() {
    local cmd="$1"

    if [ -x "$HISTORY_TRACKER" ]; then
        echo '{"command":"'"$cmd"'"}' | "$HISTORY_TRACKER" --check 2>/dev/null || echo '{"success_count":0}'
    else
        echo '{"success_count":0}'
    fi
}

# Calculate tier adjustment
calculate_adjustment() {
    local base_tier="$1"
    local adjustments=()
    local reasons=()

    # Get issue scope if available
    local scope='{"has_scope":false}'
    if [ -n "$ISSUE_NUMBER" ]; then
        scope=$(get_issue_scope "$ISSUE_NUMBER")
    fi

    # Rule 1: File in issue scope = -1 tier
    if [ -n "$FILE_PATH" ] && [ "$(echo "$scope" | jq -r '.has_scope')" = "true" ]; then
        if file_in_scope "$FILE_PATH" "$scope"; then
            adjustments+=(-1)
            reasons+=("file in issue scope")
        fi
    fi

    # Rule 1b: Command matches issue context = -1 tier
    if [ -n "$COMMAND" ] && [ "$(echo "$scope" | jq -r '.has_scope')" = "true" ]; then
        if command_in_context "$COMMAND" "$scope"; then
            adjustments+=(-1)
            reasons+=("command matches issue context")
        fi
    fi

    # Rule 2: Test files = -1 tier (lower risk)
    if [ -n "$FILE_PATH" ] && is_test_file "$FILE_PATH"; then
        adjustments+=(-1)
        reasons+=("test file modification")
    fi

    # Rule 3: Historical success = -1 tier
    if [ -n "$COMMAND" ]; then
        local history
        history=$(get_command_history "$COMMAND")
        local success_count
        success_count=$(echo "$history" | jq -r '.success_count // 0')

        if [ "$success_count" -ge 3 ]; then
            adjustments+=(-1)
            reasons+=("historically safe command (${success_count} successes)")
        fi
    fi

    # Rule 4: Files outside scope = +1 tier (if scope exists)
    if [ -n "$FILE_PATH" ] && [ "$(echo "$scope" | jq -r '.has_scope')" = "true" ]; then
        if ! file_in_scope "$FILE_PATH" "$scope"; then
            # Only increase tier if not already adjusted down by other rules
            if [ ${#adjustments[@]} -eq 0 ]; then
                adjustments+=(1)
                reasons+=("file outside issue scope")
            fi
        fi
    fi

    # Sum adjustments
    local total_adjustment=0
    for adj in "${adjustments[@]}"; do
        total_adjustment=$((total_adjustment + adj))
    done

    # Output results
    local reasons_json
    reasons_json=$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s .)

    jq -n \
        --arg adjustment "$total_adjustment" \
        --argjson reasons "$reasons_json" \
        '{adjustment: ($adjustment | tonumber), reasons: $reasons}'
}

# Apply tier adjustment
apply_adjustment() {
    local tier="$1"
    local adjustment="$2"

    # Map tiers to numeric levels
    local tier_level
    case "$tier" in
        T0) tier_level=0 ;;
        T1) tier_level=1 ;;
        T2) tier_level=2 ;;
        T3) tier_level=3 ;;
        *) tier_level=2 ;;  # Default unknown to T2
    esac

    # Apply adjustment (with bounds checking)
    local new_level=$((tier_level + adjustment))
    if [ "$new_level" -lt 0 ]; then
        new_level=0
    elif [ "$new_level" -gt 3 ]; then
        new_level=3
    fi

    # Map back to tier
    case "$new_level" in
        0) echo "T0" ;;
        1) echo "T1" ;;
        2) echo "T2" ;;
        3) echo "T3" ;;
        *) echo "T2" ;;
    esac
}

# Main evaluation
if [ -z "$TIER" ]; then
    echo '{"error":"missing tier","original_tier":"","adjusted_tier":"","adjustment":0,"reasons":[]}'
    exit 1
fi

# Calculate adjustment
ADJUSTMENT_RESULT=$(calculate_adjustment "$TIER")
ADJUSTMENT=$(echo "$ADJUSTMENT_RESULT" | jq -r '.adjustment')
REASONS=$(echo "$ADJUSTMENT_RESULT" | jq -r '.reasons')

# Apply adjustment if any
if [ "$ADJUSTMENT" -ne 0 ]; then
    ADJUSTED_TIER=$(apply_adjustment "$TIER" "$ADJUSTMENT")
else
    ADJUSTED_TIER="$TIER"
fi

# Output result
jq -n \
    --arg original "$TIER" \
    --arg adjusted "$ADJUSTED_TIER" \
    --arg adjustment "$ADJUSTMENT" \
    --argjson reasons "$REASONS" \
    --arg has_context "$([ "$ADJUSTMENT" -ne 0 ] && echo true || echo false)" \
    '{
        original_tier: $original,
        adjusted_tier: $adjusted,
        adjustment: ($adjustment | tonumber),
        reasons: $reasons,
        context_applied: ($has_context == "true")
    }'
