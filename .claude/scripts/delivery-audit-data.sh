#!/bin/bash
set -euo pipefail
# delivery-audit-data.sh
# Gathers issue and PR delivery data for validation and alignment analysis
#
# Usage: ./scripts/delivery-audit-data.sh [MILESTONE]
#
# Outputs structured JSON with all metrics needed for /delivery-audit

set -e

MILESTONE="${1:-}"

# Create temp directory for intermediate files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Get milestone if not specified (use earliest due date)
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Get milestone metadata
gh api repos/:owner/:repo/milestones --jq '.[] | select(.title=="'"$MILESTONE"'") | {title: .title, due_on: .due_on, open_issues: .open_issues, closed_issues: .closed_issues, description: .description}' > "$TMPDIR/milestone.json"

# Get all closed issues in milestone with PR references
gh issue list --milestone "$MILESTONE" --state closed \
  --json number,title,closedAt,labels,body \
  > "$TMPDIR/closed_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/closed_issues.json"

# Get all open issues with pr:merged label (stale label check)
gh issue list --milestone "$MILESTONE" --state open --label "pr:merged" \
  --json number,title,labels,updatedAt \
  > "$TMPDIR/stale_pr_merged.json" 2>/dev/null || echo "[]" > "$TMPDIR/stale_pr_merged.json"

# Get all merged PRs for the milestone
# This requires searching PRs with milestone in the query
gh pr list --state merged --search "milestone:\"$MILESTONE\"" \
  --json number,title,mergedAt,closingIssuesReferences,body \
  --limit 500 \
  > "$TMPDIR/merged_prs.json" 2>/dev/null || echo "[]" > "$TMPDIR/merged_prs.json"

# Get epic issues in milestone to check child completion
gh issue list --milestone "$MILESTONE" --label "epic" --state all \
  --json number,title,state,body,closedAt \
  > "$TMPDIR/epic_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/epic_issues.json"

# Get all issues in milestone for reference
gh issue list --milestone "$MILESTONE" --state all \
  --json number,title,state,closedAt,labels,body \
  > "$TMPDIR/all_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/all_issues.json"

# Calculate dates for timeline analysis
TODAY=$(date +%Y-%m-%d)
WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d 2>/dev/null || echo "")
MONTH_AGO=$(date -v-30d +%Y-%m-%d 2>/dev/null || date -d "30 days ago" +%Y-%m-%d 2>/dev/null || echo "")

# Count metrics
TOTAL_CLOSED=$(jq 'length' "$TMPDIR/closed_issues.json")
TOTAL_MERGED_PRS=$(jq 'length' "$TMPDIR/merged_prs.json")
STALE_PR_LABELS=$(jq 'length' "$TMPDIR/stale_pr_merged.json")
TOTAL_EPICS=$(jq 'length' "$TMPDIR/epic_issues.json")

# Build output JSON using jq with file inputs
jq -n \
  --slurpfile milestone "$TMPDIR/milestone.json" \
  --slurpfile closed_issues "$TMPDIR/closed_issues.json" \
  --slurpfile stale_pr_merged "$TMPDIR/stale_pr_merged.json" \
  --slurpfile merged_prs "$TMPDIR/merged_prs.json" \
  --slurpfile epic_issues "$TMPDIR/epic_issues.json" \
  --slurpfile all_issues "$TMPDIR/all_issues.json" \
  --argjson total_closed "$TOTAL_CLOSED" \
  --argjson total_merged_prs "$TOTAL_MERGED_PRS" \
  --argjson stale_pr_labels "$STALE_PR_LABELS" \
  --argjson total_epics "$TOTAL_EPICS" \
  --arg today "$TODAY" \
  --arg week_ago "$WEEK_AGO" \
  --arg month_ago "$MONTH_AGO" \
  '{
    milestone: $milestone[0],
    today: $today,
    week_ago: $week_ago,
    month_ago: $month_ago,
    counts: {
      total_issues: ($all_issues[0] | length),
      closed_issues: $total_closed,
      merged_prs: $total_merged_prs,
      stale_pr_merged_labels: $stale_pr_labels,
      epics: $total_epics
    },
    closed_issues: $closed_issues[0],
    merged_prs: $merged_prs[0],
    stale_pr_merged: $stale_pr_merged[0],
    epic_issues: $epic_issues[0],
    all_issues: $all_issues[0]
  }'
