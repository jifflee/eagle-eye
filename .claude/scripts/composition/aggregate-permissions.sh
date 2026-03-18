#!/usr/bin/env bash
# aggregate-permissions.sh - Compute effective permission tier for composed skills
# Part of the skill composition framework (#224)
#
# Integrates with tier-lookup.sh (#225) to provide:
# - Effective tier calculation (max of all dependency tiers)
# - Session-scoped approval tracking
# - Permission boundary enforcement
#
# Usage:
#   ./scripts/composition/aggregate-permissions.sh <skill-name>
#   ./scripts/composition/aggregate-permissions.sh --file <contract>
#   ./scripts/composition/aggregate-permissions.sh --check-approval <tier>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PARSE_SCRIPT="$SCRIPT_DIR/parse-dependencies.sh"
TIER_LOOKUP="$REPO_ROOT/scripts/tier-lookup.sh"

# Session approvals file (created per-session)
SESSION_ID="${COMPOSITION_SESSION_ID:-$$}"
SESSION_FILE="${TMPDIR:-/tmp}/composition-session-${SESSION_ID}.json"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <skill-name>

Aggregate permission tiers for composed skills.

Options:
  --file <path>       Use specific contract file
  --check-approval    Check if tier is approved for current session
  --grant <tier>      Grant session approval for tier (T2)
  --revoke <tier>     Revoke session approval for tier
  --session-info      Show current session state
  --reset             Reset session approvals
  -h, --help          Show this help message

Examples:
  $(basename "$0") sprint-work-composed
  $(basename "$0") --check-approval T2
  $(basename "$0") --grant T2
  $(basename "$0") --session-info
EOF
}

# Initialize session file if it doesn't exist
init_session() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        cat > "$SESSION_FILE" <<EOF
{
  "session_id": "$SESSION_ID",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "approvals": {
    "T0": true,
    "T1": true,
    "T2": false,
    "T3_items": {}
  }
}
EOF
    fi
}

# Check if tier is approved for this session
check_approval() {
    local tier="$1"
    local item="${2:-}"

    init_session

    case "$tier" in
        T0|T1)
            # Always approved
            echo "true"
            return 0
            ;;
        T2)
            jq -r '.approvals.T2 // false' "$SESSION_FILE"
            ;;
        T3)
            if [[ -n "$item" ]]; then
                jq -r --arg item "$item" '.approvals.T3_items[$item] // false' "$SESSION_FILE"
            else
                echo "false"
            fi
            ;;
        *)
            echo "false"
            ;;
    esac
}

# Grant approval for tier
grant_approval() {
    local tier="$1"
    local item="${2:-}"

    init_session

    case "$tier" in
        T2)
            local tmp="${SESSION_FILE}.tmp"
            jq '.approvals.T2 = true' "$SESSION_FILE" > "$tmp"
            mv "$tmp" "$SESSION_FILE"
            echo "Granted T2 approval for session $SESSION_ID"
            ;;
        T3)
            if [[ -z "$item" ]]; then
                echo "Error: T3 requires specific item to approve" >&2
                return 1
            fi
            local tmp="${SESSION_FILE}.tmp"
            jq --arg item "$item" '.approvals.T3_items[$item] = true' "$SESSION_FILE" > "$tmp"
            mv "$tmp" "$SESSION_FILE"
            echo "Granted T3 approval for item: $item"
            ;;
        *)
            echo "Cannot grant approval for tier: $tier" >&2
            return 1
            ;;
    esac
}

# Revoke approval for tier
revoke_approval() {
    local tier="$1"
    local item="${2:-}"

    init_session

    case "$tier" in
        T2)
            local tmp="${SESSION_FILE}.tmp"
            jq '.approvals.T2 = false' "$SESSION_FILE" > "$tmp"
            mv "$tmp" "$SESSION_FILE"
            echo "Revoked T2 approval for session $SESSION_ID"
            ;;
        T3)
            if [[ -z "$item" ]]; then
                # Revoke all T3
                local tmp="${SESSION_FILE}.tmp"
                jq '.approvals.T3_items = {}' "$SESSION_FILE" > "$tmp"
                mv "$tmp" "$SESSION_FILE"
                echo "Revoked all T3 approvals"
            else
                local tmp="${SESSION_FILE}.tmp"
                jq --arg item "$item" 'del(.approvals.T3_items[$item])' "$SESSION_FILE" > "$tmp"
                mv "$tmp" "$SESSION_FILE"
                echo "Revoked T3 approval for item: $item"
            fi
            ;;
        *)
            echo "Cannot revoke approval for tier: $tier" >&2
            return 1
            ;;
    esac
}

# Show session info
session_info() {
    init_session

    echo "Session: $SESSION_ID"
    echo "File: $SESSION_FILE"
    echo ""

    jq -r '
        "Created: " + .created_at,
        "",
        "Tier Approvals:",
        "  T0: always (read-only)",
        "  T1: always (safe write)",
        "  T2: " + (if .approvals.T2 then "APPROVED" else "not approved" end),
        "  T3 items: " + (.approvals.T3_items | keys | if length == 0 then "(none)" else join(", ") end)
    ' "$SESSION_FILE"
}

# Reset session
reset_session() {
    rm -f "$SESSION_FILE"
    echo "Session reset"
}

# Calculate aggregate permission info for a skill
aggregate_skill() {
    local skill_name="$1"
    local contract_file="${2:-}"

    # Find contract file if not provided
    if [[ -z "$contract_file" ]]; then
        contract_file="$REPO_ROOT/contracts/skills/${skill_name}.contract.yaml"
    fi

    if [[ ! -f "$contract_file" ]]; then
        echo '{"error": "Contract file not found", "file": "'"$contract_file"'"}'
        return 1
    fi

    # Parse dependencies
    local parsed
    parsed=$("$PARSE_SCRIPT" --file "$contract_file")

    if echo "$parsed" | jq -e '.error' >/dev/null 2>&1; then
        echo "$parsed"
        return 1
    fi

    init_session

    local session_state
    session_state=$(cat "$SESSION_FILE")

    # Build permission report
    echo "$parsed" | jq --argjson session "$session_state" '
        # Check what needs approval
        {
            skill: .skill,
            effective_tier: .effective_tier,
            dependency_count: .dependency_count,

            tier_breakdown: (
                .dependencies | group_by(.tier) | map({
                    tier: .[0].tier,
                    count: length,
                    items: map(.name)
                })
            ),

            auto_approve: (
                [.dependencies[] | select(.tier == "T0" or .tier == "T1")] | map(.name)
            ),

            needs_session_approval: (
                if $session.approvals.T2 then
                    []
                else
                    [.dependencies[] | select(.tier == "T2")] | map(.name)
                end
            ),

            needs_individual_approval: (
                [.dependencies[] | select(.tier == "T3") |
                    .name as $n |
                    if $session.approvals.T3_items[$n] then empty else $n end
                ]
            ),

            session_id: $session.session_id,
            session_t2_approved: $session.approvals.T2,
            session_t3_approved: ($session.approvals.T3_items | keys)
        }
    '
}

# Main
main() {
    local skill_name=""
    local contract_file=""
    local mode="aggregate"
    local tier=""
    local item=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                contract_file="$2"
                shift 2
                ;;
            --check-approval)
                mode="check"
                tier="$2"
                shift 2
                ;;
            --grant)
                mode="grant"
                tier="$2"
                shift 2
                ;;
            --revoke)
                mode="revoke"
                tier="$2"
                shift 2
                ;;
            --item)
                item="$2"
                shift 2
                ;;
            --session-info)
                mode="info"
                shift
                ;;
            --reset)
                mode="reset"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
            *)
                skill_name="$1"
                shift
                ;;
        esac
    done

    case "$mode" in
        aggregate)
            if [[ -z "$skill_name" && -z "$contract_file" ]]; then
                echo "Error: Must specify skill name or --file" >&2
                usage >&2
                exit 1
            fi
            aggregate_skill "$skill_name" "$contract_file"
            ;;
        check)
            if [[ -z "$tier" ]]; then
                echo "Error: --check-approval requires tier" >&2
                exit 1
            fi
            check_approval "$tier" "$item"
            ;;
        grant)
            if [[ -z "$tier" ]]; then
                echo "Error: --grant requires tier" >&2
                exit 1
            fi
            grant_approval "$tier" "$item"
            ;;
        revoke)
            if [[ -z "$tier" ]]; then
                echo "Error: --revoke requires tier" >&2
                exit 1
            fi
            revoke_approval "$tier" "$item"
            ;;
        info)
            session_info
            ;;
        reset)
            reset_session
            ;;
    esac
}

main "$@"
