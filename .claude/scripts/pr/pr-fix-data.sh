#!/bin/bash
set -euo pipefail
# pr-fix-data.sh
# Data gathering script for /pr-fix skill
# Batches all gh API calls and analysis into single execution
#
# Usage: ./scripts/pr-fix-data.sh [--dry-run] [--severity LEVEL] [--agent AGENT] [--issue-id ID]
#
# Output: JSON with blocking issues grouped by agent, ready for fixing

set -e

# Parse arguments
DRY_RUN=false
SEVERITY="error"
FILTER_AGENT=""
FILTER_ISSUE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --severity)
            SEVERITY="$2"
            shift 2
            ;;
        --agent)
            FILTER_AGENT="$2"
            shift 2
            ;;
        --issue-id)
            FILTER_ISSUE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Check for pr-status.json
if [ ! -f "./pr-status.json" ]; then
    echo '{"error": "pr-status.json not found", "suggestion": "Run /pr-review-internal first"}' | jq .
    exit 1
fi

# Read pr-status.json
PR_STATUS=$(cat ./pr-status.json)

# Extract data
BLOCKING_ISSUES=$(echo "$PR_STATUS" | jq '.blocking_issues // []')
IMPL_AGENTS=$(echo "$PR_STATUS" | jq '.implementation_agents // {}')
PR_NUMBER=$(echo "$PR_STATUS" | jq -r '.pr_number // "unknown"')
ISSUE_NUMBER=$(echo "$PR_STATUS" | jq -r '.issue_number // "unknown"')

# Count total issues
TOTAL_COUNT=$(echo "$BLOCKING_ISSUES" | jq 'length')

if [ "$TOTAL_COUNT" -eq 0 ]; then
    jq -n '{
        "status": "no_issues",
        "message": "No blocking issues to fix. PR is ready for merge.",
        "pr_number": "'"$PR_NUMBER"'",
        "issue_number": "'"$ISSUE_NUMBER"'",
        "dry_run": '"$DRY_RUN"'
    }'
    exit 0
fi

# Filter by severity
if [ "$SEVERITY" = "all" ]; then
    FILTERED_ISSUES="$BLOCKING_ISSUES"
elif [ "$SEVERITY" = "error" ]; then
    FILTERED_ISSUES=$(echo "$BLOCKING_ISSUES" | jq '[.[] | select(.severity == "error" or .severity == null)]')
else
    FILTERED_ISSUES=$(echo "$BLOCKING_ISSUES" | jq --arg sev "$SEVERITY" '[.[] | select(.severity == $sev)]')
fi

# Filter by issue ID if specified
if [ -n "$FILTER_ISSUE" ]; then
    FILTERED_ISSUES=$(echo "$FILTERED_ISSUES" | jq --arg id "$FILTER_ISSUE" '[.[] | select(.id == $id)]')
fi

# Group issues by owning agent
GROUPED=$(echo "$FILTERED_ISSUES" | jq --argjson impl "$IMPL_AGENTS" '
    # For each issue, determine owning agent
    map(. as $issue |
        # Use explicit owning_agent if set
        if .owning_agent then
            . + {derived_agent: .owning_agent}
        # Otherwise, look up file in implementation_agents
        elif .file then
            ($impl | to_entries | map(select(.value | if type == "array" then index($issue.file) else . == $issue.file end)) | .[0].key // "unknown") as $agent |
            . + {derived_agent: $agent}
        else
            . + {derived_agent: "unknown"}
        end
    ) |
    # Group by derived_agent
    group_by(.derived_agent) |
    map({
        agent: .[0].derived_agent,
        issues: .,
        files: [.[].file] | unique | map(select(. != null)),
        issue_count: length
    })
')

# Filter by agent if specified
if [ -n "$FILTER_AGENT" ]; then
    GROUPED=$(echo "$GROUPED" | jq --arg agent "$FILTER_AGENT" '[.[] | select(.agent == $agent)]')
fi

# Calculate summary
FILTERED_COUNT=$(echo "$FILTERED_ISSUES" | jq 'length')
AGENT_COUNT=$(echo "$GROUPED" | jq 'length')
UNKNOWN_COUNT=$(echo "$GROUPED" | jq '[.[] | select(.agent == "unknown")] | length')

# Build output JSON
jq -n \
    --argjson grouped "$GROUPED" \
    --argjson impl_agents "$IMPL_AGENTS" \
    --arg pr_number "$PR_NUMBER" \
    --arg issue_number "$ISSUE_NUMBER" \
    --arg severity "$SEVERITY" \
    --argjson total "$TOTAL_COUNT" \
    --argjson filtered "$FILTERED_COUNT" \
    --argjson agent_count "$AGENT_COUNT" \
    --argjson unknown "$UNKNOWN_COUNT" \
    --argjson dry_run "$DRY_RUN" \
    '{
        "status": "needs_fixes",
        "pr_number": $pr_number,
        "issue_number": $issue_number,
        "severity_filter": $severity,
        "dry_run": $dry_run,
        "summary": {
            "total_issues": $total,
            "filtered_issues": $filtered,
            "agents_to_invoke": $agent_count,
            "unknown_agent_issues": $unknown
        },
        "agent_groups": $grouped,
        "implementation_agents": $impl_agents,
        "recommendations": (
            if $unknown > 0 then
                ["Some issues have unknown owning agents - check implementation_agents mapping"]
            else
                []
            end +
            if $agent_count == 0 then
                ["No issues match the current filters"]
            else
                []
            end
        )
    }'
