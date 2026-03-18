#!/bin/bash
set -euo pipefail
# refresh-sprint-state.sh
# Refreshes stale sprint state cache inside containers
#
# Usage: ./scripts/refresh-sprint-state.sh [ISSUE_NUMBER]
#
# This script is designed to run inside containers when:
# 1. The cached sprint state is stale (>1 hour old)
# 2. The cached state needs to be updated after PR creation
# 3. The initial state injection failed
#
# It fetches fresh state from GitHub API and updates the local cache.
# Should be called sparingly to minimize API usage.

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ISSUE_NUMBER="${1:-$ISSUE}"

# Get issue number from environment or argument
if [ -z "$ISSUE_NUMBER" ]; then
    # Try to extract from current state file
    if [ -n "$SPRINT_STATE_FILE" ] && [ -f "$SPRINT_STATE_FILE" ]; then
        ISSUE_NUMBER=$(jq -r '.issue.number // empty' "$SPRINT_STATE_FILE" 2>/dev/null)
    fi
fi

if [ -z "$ISSUE_NUMBER" ]; then
    log_error "Issue number required. Provide as argument or set ISSUE env var."
    exit 1
fi

log_info "Refreshing sprint state for issue #$ISSUE_NUMBER..."

# Determine target file location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

if [ -n "$SPRINT_STATE_FILE" ]; then
    TARGET_FILE="$SPRINT_STATE_FILE"
elif [ -n "$TOPLEVEL" ]; then
    TARGET_FILE="$TOPLEVEL/.state/.sprint-state.json"
else
    TARGET_FILE="/tmp/.sprint-state.json"
fi

# Get base branch from current state or default
BASE_BRANCH="dev"
if [ -f "$TARGET_FILE" ]; then
    BASE_BRANCH=$(jq -r '.base_branch // "dev"' "$TARGET_FILE" 2>/dev/null)
fi

# Check if generate-sprint-state.sh exists
GENERATE_SCRIPT="$SCRIPT_DIR/generate-sprint-state.sh"
if [ ! -x "$GENERATE_SCRIPT" ]; then
    log_error "generate-sprint-state.sh not found at $GENERATE_SCRIPT"
    exit 1
fi

# Generate fresh state
log_info "Fetching fresh state from GitHub..."
NEW_STATE=$("$GENERATE_SCRIPT" "$ISSUE_NUMBER" --base-branch "$BASE_BRANCH" 2>/dev/null) || {
    log_error "Failed to generate sprint state"
    exit 1
}

# Validate JSON
if ! echo "$NEW_STATE" | jq empty 2>/dev/null; then
    log_error "Generated state is not valid JSON"
    exit 1
fi

# Add refresh metadata
NEW_STATE=$(echo "$NEW_STATE" | jq --arg refreshed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {refreshed_at: $refreshed_at, was_refreshed: true}')

# Write to file
echo "$NEW_STATE" > "$TARGET_FILE"
log_info "Sprint state refreshed and written to $TARGET_FILE"

# Update environment variable if set
if [ -n "$SPRINT_STATE_FILE" ]; then
    export SPRINT_STATE_FILE="$TARGET_FILE"
fi

# Output summary
ISSUE_TITLE=$(echo "$NEW_STATE" | jq -r '.issue.title // "unknown"')
PR_EXISTS=$(echo "$NEW_STATE" | jq -r '.pr.exists // false')
log_info "Issue: #$ISSUE_NUMBER - $ISSUE_TITLE"
log_info "PR exists: $PR_EXISTS"
