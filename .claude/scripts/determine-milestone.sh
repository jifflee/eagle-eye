#!/usr/bin/env bash
#
# determine-milestone.sh
# Determine the appropriate milestone for a new issue
#
# Usage:
#   ./determine-milestone.sh                    # Get active milestone
#   ./determine-milestone.sh --parent 70        # Inherit from parent issue
#
# Options:
#   --parent N    Inherit milestone from parent issue N
#
# Output:
#   Milestone title (e.g., "sprint-1/13")
#   Empty string if no milestone found
#
# Exit codes:
#   0 - Success (milestone found or empty)
#   1 - Invalid arguments
#   2 - gh CLI error

set -euo pipefail

# Colors for stderr messages
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}WARN:${NC} $1" >&2
}

# Parse arguments
PARENT_ISSUE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --parent)
            if [[ -z "${2:-}" ]]; then
                error "Missing value for --parent"
                exit 1
            fi
            PARENT_ISSUE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--parent N]"
            echo ""
            echo "Determine the appropriate milestone for a new issue."
            echo ""
            echo "Options:"
            echo "  --parent N    Inherit milestone from parent issue N"
            echo ""
            echo "Logic:"
            echo "  1. If --parent specified, inherit parent's milestone"
            echo "  2. If parent has no milestone, fall back to active milestone"
            echo "  3. Active milestone = first open milestone sorted by due date"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
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

# Function to get active milestone (first open milestone by due date)
get_active_milestone() {
    # Get all open milestones, sort by due_on, return first
    local milestones
    milestones=$(gh api repos/:owner/:repo/milestone-list \
        --jq '[.[] | select(.state=="open")] | sort_by(.due_on // "9999-12-31") | .[0].title // ""' \
        2>/dev/null) || {
        warn "Failed to fetch milestones"
        echo ""
        return
    }
    echo "$milestones"
}

# Case 1: Parent specified - try to inherit
if [[ -n "$PARENT_ISSUE" ]]; then
    # Validate parent issue number
    if ! [[ "$PARENT_ISSUE" =~ ^[0-9]+$ ]]; then
        error "Parent issue must be a number: $PARENT_ISSUE"
        exit 1
    fi

    # Get parent's milestone
    PARENT_MILESTONE=$(gh issue view "$PARENT_ISSUE" \
        --json milestone \
        --jq '.milestone.title // ""' \
        2>/dev/null) || {
        warn "Failed to fetch parent issue #$PARENT_ISSUE"
        PARENT_MILESTONE=""
    }

    if [[ -n "$PARENT_MILESTONE" ]]; then
        echo "$PARENT_MILESTONE"
        exit 0
    fi

    # Parent has no milestone, fall back to active milestone
    warn "Parent #$PARENT_ISSUE has no milestone, using active milestone"
fi

# Case 2: Get active milestone (fallback or no parent)
ACTIVE_MILESTONE=$(get_active_milestone)

if [[ -n "$ACTIVE_MILESTONE" ]]; then
    echo "$ACTIVE_MILESTONE"
else
    warn "No active milestone found"
    echo ""
fi
