#!/usr/bin/env bash
set -euo pipefail
#
# get-agents-for-issue.sh
# Retrieves the list of agents for a given issue based on its labels and body content.
#
# Usage:
#   ./scripts/get-agents-for-issue.sh --issue 267
#   ./scripts/get-agents-for-issue.sh --labels "bug,security"
#   ./scripts/get-agents-for-issue.sh --issue 267 --include-body-signals
#
# Output: Comma-separated list of agent names (deduplicated)

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/config/agent-bundles.json"

# Default values
ISSUE_NUMBER=""
LABELS=""
INCLUDE_BODY_SIGNALS=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Retrieve the list of agents for a given issue based on labels and body signals.

OPTIONS:
    --issue NUM           Issue number to look up (fetches labels from GitHub)
    --labels LIST         Comma-separated list of labels (bypasses GitHub lookup)
    --include-body-signals  Also scan issue body for keyword signals
    -h, --help            Show this help message

EXAMPLES:
    $(basename "$0") --issue 267
    $(basename "$0") --labels "bug,security"
    $(basename "$0") --issue 267 --include-body-signals

OUTPUT:
    Comma-separated list of agent names (deduplicated)
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --labels)
            LABELS="$2"
            shift 2
            ;;
        --include-body-signals)
            INCLUDE_BODY_SIGNALS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Validate inputs
if [[ -z "$ISSUE_NUMBER" && -z "$LABELS" ]]; then
    echo "ERROR: Must provide either --issue or --labels" >&2
    exit 1
fi

# Check config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# Join array elements with comma (macOS-compatible)
join_with_comma() {
    local result=""
    local first=true
    while IFS= read -r item; do
        if [[ -n "$item" ]]; then
            if $first; then
                result="$item"
                first=false
            else
                result="$result,$item"
            fi
        fi
    done
    echo "$result"
}

# Collect agents from labels
get_agents_from_labels() {
    local labels="$1"

    # Convert comma-separated labels to array
    IFS=',' read -ra label_array <<< "$labels"

    for label in "${label_array[@]}"; do
        # Trim whitespace
        label=$(echo "$label" | xargs)

        # Look up bundle in config
        jq -r --arg label "$label" \
            '.bundles[$label].agents // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true
    done
}

# Collect agents from body signals
get_agents_from_body() {
    local body="$1"

    # Iterate over body_signals patterns
    local patterns
    patterns=$(jq -r '.body_signals | keys[]' "$CONFIG_FILE" 2>/dev/null) || return

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        # Check if pattern matches body (case-insensitive)
        if echo "$body" | grep -qiE "$pattern" 2>/dev/null; then
            jq -r --arg pattern "$pattern" \
                '.body_signals[$pattern] // [] | .[]' "$CONFIG_FILE" 2>/dev/null || true
        fi
    done <<< "$patterns"
}

# Main logic
main() {
    local issue_body=""
    local all_agents=""

    # If issue number provided, fetch labels from GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        # Fetch issue details
        issue_data=$(gh issue view "$ISSUE_NUMBER" --json labels,body 2>/dev/null || echo "{}")

        # Extract labels
        fetched_labels=$(echo "$issue_data" | jq -r '.labels[].name // empty' 2>/dev/null | join_with_comma)

        if [[ -n "$fetched_labels" ]]; then
            if [[ -n "$LABELS" ]]; then
                LABELS="$LABELS,$fetched_labels"
            else
                LABELS="$fetched_labels"
            fi
        fi

        # Extract body for signal matching
        issue_body=$(echo "$issue_data" | jq -r '.body // ""' 2>/dev/null)
    fi

    # Get agents from labels
    if [[ -n "$LABELS" ]]; then
        all_agents=$(get_agents_from_labels "$LABELS")
    fi

    # Get agents from body signals (if enabled)
    if [[ "$INCLUDE_BODY_SIGNALS" == "true" && -n "$issue_body" ]]; then
        body_agents=$(get_agents_from_body "$issue_body")
        if [[ -n "$body_agents" ]]; then
            if [[ -n "$all_agents" ]]; then
                all_agents="$all_agents"$'\n'"$body_agents"
            else
                all_agents="$body_agents"
            fi
        fi
    fi

    # Deduplicate and output
    if [[ -n "$all_agents" ]]; then
        echo "$all_agents" | sort -u | join_with_comma
    fi
}

main
