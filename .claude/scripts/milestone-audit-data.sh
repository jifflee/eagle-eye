#!/bin/bash
set -euo pipefail
# milestone-audit-data.sh
# Gathers all milestone audit data in a single pass for token-efficient Claude analysis
#
# Usage: ./scripts/milestone-audit-data.sh [MILESTONE] [--include-closed]
#
# Options:
#   MILESTONE        Milestone name (default: earliest open milestone)
#   --include-closed Also fetch info about closed milestones with open issues
#
# Outputs structured JSON with all metrics needed for /milestone-audit

set -e

MILESTONE=""
INCLUDE_CLOSED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --include-closed)
      INCLUDE_CLOSED=true
      shift
      ;;
    *)
      if [ -z "$MILESTONE" ]; then
        MILESTONE="$1"
      fi
      shift
      ;;
  esac
done

# Create temp directory for intermediate files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Get milestone if not specified (use earliest due date)
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty' 2>/dev/null || echo "")
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Get milestone metadata (search both open and closed milestones)
gh api "repos/:owner/:repo/milestones?state=all&per_page=100" \
  --jq '.[] | select(.title=="'"$MILESTONE"'") | {title: .title, state: .state, due_on: .due_on, open_issues: .open_issues, closed_issues: .closed_issues, description: .description, number: .number}' \
  > "$TMPDIR/milestone.json" 2>/dev/null || echo '{}' > "$TMPDIR/milestone.json"

# Get all milestone issues with full details
gh issue list --milestone "$MILESTONE" --state all \
  --json number,title,state,labels,updatedAt,createdAt,body \
  > "$TMPDIR/milestone_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/milestone_issues.json"

# Get open issues for quality analysis
gh issue list --milestone "$MILESTONE" --state open \
  --json number,title,labels,body,createdAt,updatedAt \
  > "$TMPDIR/open_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/open_issues.json"

# Get issues without milestone (potential orphans)
gh issue list --no-milestone --state open \
  --json number,title,labels,body,createdAt \
  > "$TMPDIR/orphan_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/orphan_issues.json"

# Ensure orphan file has content
if [ ! -s "$TMPDIR/orphan_issues.json" ]; then
  echo "[]" > "$TMPDIR/orphan_issues.json"
fi

# Count by status label
BACKLOG=$(gh issue list --milestone "$MILESTONE" --label "backlog" --state open --json number 2>/dev/null | jq length || echo 0)
IN_PROGRESS=$(gh issue list --milestone "$MILESTONE" --label "in-progress" --state open --json number 2>/dev/null | jq length || echo 0)
BLOCKED=$(gh issue list --milestone "$MILESTONE" --label "blocked" --state open --json number 2>/dev/null | jq length || echo 0)

# Count by type
BUGS=$(gh issue list --milestone "$MILESTONE" --label "bug" --state open --json number 2>/dev/null | jq length || echo 0)
FEATURES=$(gh issue list --milestone "$MILESTONE" --label "feature" --state open --json number 2>/dev/null | jq length || echo 0)
TECH_DEBT=$(gh issue list --milestone "$MILESTONE" --label "tech-debt" --state open --json number 2>/dev/null | jq length || echo 0)

# Count by priority
P0=$(gh issue list --milestone "$MILESTONE" --label "P0" --state open --json number 2>/dev/null | jq length || echo 0)
P1=$(gh issue list --milestone "$MILESTONE" --label "P1" --state open --json number 2>/dev/null | jq length || echo 0)
P2=$(gh issue list --milestone "$MILESTONE" --label "P2" --state open --json number 2>/dev/null | jq length || echo 0)
P3=$(gh issue list --milestone "$MILESTONE" --label "P3" --state open --json number 2>/dev/null | jq length || echo 0)

# Get in-progress issues for staleness check
gh issue list --milestone "$MILESTONE" --label "in-progress" --state open \
  --json number,title,updatedAt,createdAt \
  > "$TMPDIR/in_progress_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/in_progress_issues.json"

# Get blocked issues for context check
gh issue list --milestone "$MILESTONE" --label "blocked" --state open \
  --json number,title,body,updatedAt \
  > "$TMPDIR/blocked_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/blocked_issues.json"

# Calculate dates
TODAY=$(date +%Y-%m-%d)
WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d 2>/dev/null || echo "")

# Get milestone state for health analysis
MILESTONE_STATE=$(cat "$TMPDIR/milestone.json" | jq -r '.state // "open"')

# Completion correctness check: if milestone is closed but has open issues, flag it
CLOSED_WITH_OPEN="false"
if [ "$MILESTONE_STATE" = "closed" ] && [ "$(cat "$TMPDIR/open_issues.json" | jq 'length')" -gt 0 ]; then
  CLOSED_WITH_OPEN="true"
fi

# Optional: gather closed milestones with open issues (for full correctness audit)
echo "[]" > "$TMPDIR/closed_ms_orphans.json"
if [ "$INCLUDE_CLOSED" = "true" ]; then
  gh api "repos/:owner/:repo/milestones?state=closed&per_page=100" \
    --jq '[.[] | select(.open_issues > 0) | {number: .number, title: .title, open_issues: .open_issues}]' \
    2>/dev/null > "$TMPDIR/closed_ms_orphans.json" || echo "[]" > "$TMPDIR/closed_ms_orphans.json"
fi

# Build output JSON using jq with file inputs
jq -n \
  --slurpfile milestone "$TMPDIR/milestone.json" \
  --slurpfile milestone_issues "$TMPDIR/milestone_issues.json" \
  --slurpfile open_issues "$TMPDIR/open_issues.json" \
  --slurpfile orphan_issues "$TMPDIR/orphan_issues.json" \
  --slurpfile in_progress_issues "$TMPDIR/in_progress_issues.json" \
  --slurpfile blocked_issues "$TMPDIR/blocked_issues.json" \
  --slurpfile closed_ms_orphans "$TMPDIR/closed_ms_orphans.json" \
  --argjson backlog "$BACKLOG" \
  --argjson in_progress "$IN_PROGRESS" \
  --argjson blocked "$BLOCKED" \
  --argjson bugs "$BUGS" \
  --argjson features "$FEATURES" \
  --argjson tech_debt "$TECH_DEBT" \
  --argjson p0 "$P0" \
  --argjson p1 "$P1" \
  --argjson p2 "$P2" \
  --argjson p3 "$P3" \
  --arg today "$TODAY" \
  --arg week_ago "$WEEK_AGO" \
  --arg milestone_state "$MILESTONE_STATE" \
  --argjson closed_with_open "$CLOSED_WITH_OPEN" \
  '{
    milestone: $milestone[0],
    milestone_state: $milestone_state,
    closed_with_open_issues: $closed_with_open,
    today: $today,
    week_ago: $week_ago,
    counts: {
      total: ($milestone_issues[0] | length),
      open: ($open_issues[0] | length),
      closed: (($milestone_issues[0] | length) - ($open_issues[0] | length))
    },
    by_status: {
      backlog: $backlog,
      in_progress: $in_progress,
      blocked: $blocked
    },
    by_type: {
      bug: $bugs,
      feature: $features,
      tech_debt: $tech_debt
    },
    by_priority: {
      p0: $p0,
      p1: $p1,
      p2: $p2,
      p3: $p3
    },
    milestone_issues: $milestone_issues[0],
    open_issues: $open_issues[0],
    orphan_issues: $orphan_issues[0],
    in_progress_issues: $in_progress_issues[0],
    blocked_issues: $blocked_issues[0],
    closed_milestones_with_orphans: $closed_ms_orphans[0]
  }'
