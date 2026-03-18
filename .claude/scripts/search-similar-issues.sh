#!/usr/bin/env bash
#
# search-similar-issues.sh
# Search for similar existing issues using GitHub's search API
#
# Usage:
#   ./search-similar-issues.sh "search query"
#   ./search-similar-issues.sh "auth tokens expire" 5
#
# Arguments:
#   $1 - Search query (required)
#   $2 - Limit results (optional, default: 5)
#
# Output:
#   JSON array of matching issues with number, title, state, labels, preview
#
# Exit codes:
#   0 - Success (results found or empty array)
#   1 - No query provided
#   2 - gh CLI error

set -euo pipefail

QUERY="${1:-}"
LIMIT="${2:-5}"

# Colors for stderr messages
RED='\033[0;31m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

# Validate input
if [[ -z "$QUERY" ]]; then
    error "Search query required"
    echo "Usage: $0 \"search query\" [limit]"
    exit 1
fi

# Check gh CLI
if ! command -v gh &> /dev/null; then
    error "gh CLI not found"
    exit 2
fi

if ! gh auth status &> /dev/null; then
    error "gh CLI not authenticated"
    exit 2
fi

# Get repo name
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || {
    error "Not in a GitHub repository"
    exit 2
}

# Search open issues first
# GitHub search is smart about relevance ranking
RESULTS=$(gh search issues "$QUERY" \
    --repo "$REPO" \
    --state open \
    --limit "$LIMIT" \
    --json number,title,state,labels,body 2>/dev/null) || {
    # Search might fail if no results or API error
    echo "[]"
    exit 0
}

# Check if results is empty array
if [[ "$RESULTS" == "[]" ]]; then
    echo "[]"
    exit 0
fi

# Process results: extract relevant fields and create preview
echo "$RESULTS" | jq '[.[] | {
    number: .number,
    title: .title,
    state: .state,
    labels: [.labels[].name],
    preview: ((.body // "") | split("\n") | map(select(length > 0)) | .[0:2] | join(" ") | .[0:100])
}]'
