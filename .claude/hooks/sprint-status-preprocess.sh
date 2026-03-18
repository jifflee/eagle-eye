#!/bin/bash
# sprint-status-preprocess.sh
# Claude Code hook that preprocesses sprint-status data before skill execution
#
# Triggered on UserPromptSubmit when the prompt contains "/sprint-status"
# Runs sprint-status-data.sh and caches output so the skill reads cached data
# instead of making live API calls (saving tokens on output processing)
#
# Input: JSON via stdin with { prompt, session_id, ... }
# Output: Cache file at /tmp/sprint-status-cache.json
# Exit: 0 = allow prompt to proceed

set -euo pipefail

# Get project root
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
CACHE_FILE="/tmp/sprint-status-cache.json"
CACHE_TTL=30  # Cache valid for 30 seconds (reduced for minimal cache - issue #395)

# Read JSON from stdin
json_input=$(cat)

# Extract prompt text
prompt=$(echo "$json_input" | jq -r '.prompt // ""' 2>/dev/null || echo "")

# Only trigger for sprint-status invocations
if ! echo "$prompt" | grep -qi "sprint-status"; then
    exit 0
fi

# Check if cache is still fresh (avoid re-running within TTL)
if [ -f "$CACHE_FILE" ]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if [ "$cache_age" -lt "$CACHE_TTL" ]; then
        # Cache is fresh, skip regeneration
        exit 0
    fi
fi

# Extract flags from prompt for passthrough
# Default to minimal mode (issue #395) unless --full or other data flags requested
# Minimal cache contains only: counts, by_status, by_priority, recommended_next, flags
# Full cache contains all sections including open_issues, PR status, health metrics
flags="--minimal"  # Default to minimal for token efficiency (~3-5KB cache)

# Check for flags that override minimal mode
if echo "$prompt" | grep -qi "\-\-all"; then
    flags="--all"  # All milestones mode
elif echo "$prompt" | grep -qi "\-\-full"; then
    flags="--full"  # Full mode with all sections
elif echo "$prompt" | grep -qi "\-\-velocity"; then
    flags="--velocity"  # Velocity metrics (implies default mode, not minimal)
elif echo "$prompt" | grep -qi "\-\-deps"; then
    flags="--deps"  # Dependencies (implies full mode)
fi

# Run the data script and cache output
DATA_SCRIPT="$PROJECT_ROOT/scripts/sprint/sprint-status-data.sh"
if [ -x "$DATA_SCRIPT" ]; then
    # Run in background-safe mode (no interactive prompts)
    "$DATA_SCRIPT" $flags > "$CACHE_FILE" 2>/dev/null || {
        # If script fails, remove stale cache
        rm -f "$CACHE_FILE"
    }
fi

# Always exit 0 to allow the prompt to proceed
exit 0
