#!/usr/bin/env bash
#
# find-parent-issues.sh
# Find potential parent (epic) issues for a given context/keywords
#
# Usage:
#   ./scripts/find-parent-issues.sh "search context"
#   ./scripts/find-parent-issues.sh "auth timeout" --limit 3
#   ./scripts/find-parent-issues.sh --children 45        # List children of epic #45
#   ./scripts/find-parent-issues.sh --epic-status 45     # Show epic completion status
#
# Arguments:
#   $1 - Search context (keywords) OR flag
#   --limit N - Max results (default: 5)
#   --children N - List all children of epic #N
#   --epic-status N - Show completion status of epic #N
#
# Output:
#   JSON array of matching epic issues with relevance scoring
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - gh CLI error
#   3 - No epic issues found

set -euo pipefail

# Colors for stderr messages
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}WARN:${NC} $1" >&2
}

info() {
    echo -e "${GREEN}INFO:${NC} $1" >&2
}

# Parse arguments
CONTEXT=""
LIMIT=5
MODE="search"  # search, children, epic-status
EPIC_NUMBER=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --limit)
            LIMIT="${2:-5}"
            shift 2
            ;;
        --children)
            MODE="children"
            EPIC_NUMBER="${2:-}"
            shift 2
            ;;
        --epic-status)
            MODE="epic-status"
            EPIC_NUMBER="${2:-}"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 \"search context\" [--limit N]"
            echo "       $0 --children N"
            echo "       $0 --epic-status N"
            exit 0
            ;;
        *)
            if [[ -z "$CONTEXT" ]]; then
                CONTEXT="$1"
            fi
            shift
            ;;
    esac
done

# Check gh CLI
if ! command -v gh &> /dev/null; then
    error "gh CLI not found"
    exit 2
fi

if ! gh auth status &> /dev/null; then
    error "gh CLI not authenticated"
    exit 2
fi

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    error "Not in a GitHub repository"
    exit 2
}

# Mode: List children of an epic
if [[ "$MODE" == "children" ]]; then
    if [[ -z "$EPIC_NUMBER" ]]; then
        error "Epic number required for --children"
        exit 1
    fi

    # Search for issues with parent:N label
    CHILDREN=$(gh issue list \
        --label "parent:${EPIC_NUMBER}" \
        --state all \
        --json number,title,state,labels \
        --limit 100 2>/dev/null) || {
        echo "[]"
        exit 0
    }

    echo "$CHILDREN" | jq '[.[] | {
        number: .number,
        title: .title,
        state: .state,
        labels: [.labels[].name]
    }]'
    exit 0
fi

# Mode: Epic status (completion percentage)
if [[ "$MODE" == "epic-status" ]]; then
    if [[ -z "$EPIC_NUMBER" ]]; then
        error "Epic number required for --epic-status"
        exit 1
    fi

    # Get epic details
    EPIC=$(gh issue view "$EPIC_NUMBER" --json number,title,state,labels 2>/dev/null) || {
        error "Epic #${EPIC_NUMBER} not found"
        exit 2
    }

    # Check if it's actually an epic
    IS_EPIC=$(echo "$EPIC" | jq -r '[.labels[].name] | any(. == "epic")')
    if [[ "$IS_EPIC" != "true" ]]; then
        warn "Issue #${EPIC_NUMBER} is not labeled as an epic"
    fi

    # Get children
    CHILDREN=$(gh issue list \
        --label "parent:${EPIC_NUMBER}" \
        --state all \
        --json number,title,state \
        --limit 100 2>/dev/null) || {
        CHILDREN="[]"
    }

    # Calculate stats
    TOTAL=$(echo "$CHILDREN" | jq 'length')
    CLOSED=$(echo "$CHILDREN" | jq '[.[] | select(.state == "CLOSED")] | length')
    OPEN=$(echo "$CHILDREN" | jq '[.[] | select(.state == "OPEN")] | length')

    if [[ "$TOTAL" -gt 0 ]]; then
        PERCENT=$((CLOSED * 100 / TOTAL))
    else
        PERCENT=0
    fi

    # Output status
    jq -n \
        --argjson epic "$EPIC" \
        --argjson children "$CHILDREN" \
        --argjson total "$TOTAL" \
        --argjson closed "$CLOSED" \
        --argjson open "$OPEN" \
        --argjson percent "$PERCENT" \
        '{
            epic: {
                number: $epic.number,
                title: $epic.title,
                state: $epic.state
            },
            children: {
                total: $total,
                closed: $closed,
                open: $open,
                percent_complete: $percent,
                items: $children
            },
            can_close: ($open == 0 and $total > 0)
        }'
    exit 0
fi

# Mode: Search for related epics
if [[ -z "$CONTEXT" ]]; then
    error "Search context required"
    echo "Usage: $0 \"search context\" [--limit N]"
    exit 1
fi

# First, get all open epic issues
EPICS=$(gh issue list \
    --label "epic" \
    --state open \
    --json number,title,body,labels,updatedAt \
    --limit 50 2>/dev/null) || {
    echo "[]"
    exit 0
}

# Check if any epics exist
if [[ "$EPICS" == "[]" || -z "$EPICS" ]]; then
    echo "[]"
    exit 0
fi

# Extract keywords from context (simple tokenization)
# Remove common words and get significant terms
KEYWORDS=$(echo "$CONTEXT" | tr '[:upper:]' '[:lower:]' | \
    tr -cs '[:alnum:]' '\n' | \
    grep -v -E '^(the|a|an|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|could|should|may|might|must|shall|can|need|to|of|in|for|on|with|at|by|from|as|into|through|during|before|after|above|below|between|under|again|further|then|once|here|there|when|where|why|how|all|each|few|more|most|other|some|such|no|nor|not|only|own|same|so|than|too|very|just|also|now|and|but|if|or|because|until|while|this|that|these|those|i|me|my|we|our|you|your|he|him|his|she|her|it|its|they|them|their|what|which|who|whom)$' | \
    sort -u | head -10)

# Score each epic based on keyword matches
SCORED_EPICS=$(echo "$EPICS" | jq --arg keywords "$KEYWORDS" '
    def score_match:
        . as $text |
        ($keywords | split("\n") | map(select(length > 0))) as $kw_list |
        ($kw_list | map(select($text | ascii_downcase | contains(.))) | length) as $matches |
        ($kw_list | length) as $total |
        if $total > 0 then ($matches * 100 / $total) else 0 end;

    [.[] |
        ((.title + " " + (.body // "")) | score_match) as $score |
        select($score > 0) |
        {
            number: .number,
            title: .title,
            labels: [.labels[].name],
            updated_at: .updatedAt,
            relevance_score: $score,
            preview: ((.body // "") | split("\n") | map(select(length > 0)) | .[0:2] | join(" ") | .[0:150])
        }
    ] | sort_by(-.relevance_score) | .[0:'"$LIMIT"']
')

echo "$SCORED_EPICS"
