#!/bin/bash
# epic-milestone-audit-data.sh
# Audits all epics and milestones for completion correctness
#
# Usage:
#   ./scripts/epic-milestone-audit-data.sh               # Audit all milestones + epics
#   ./scripts/epic-milestone-audit-data.sh --milestone N  # Audit specific milestone
#   ./scripts/epic-milestone-audit-data.sh --closed       # Include closed milestones
#   ./scripts/epic-milestone-audit-data.sh --epics-only   # Only audit epics
#   ./scripts/epic-milestone-audit-data.sh --milestones-only # Only audit milestones
#
# Outputs structured JSON with:
#   - closed_milestones_with_open_issues: Orphaned open issues in closed milestones
#   - epics_with_open_children: Epics still open but all children done
#   - incorrectly_closed_issues: Issues closed without PR or acceptance criteria
#   - open_epics_with_incomplete_children: Epics open with pending child work
#   - milestone_pr_cross_reference: Issues missing linked PRs
#   - summary: Aggregate counts and health score

set -euo pipefail

# Parse arguments
MILESTONE_FILTER=""
INCLUDE_CLOSED=false
EPICS_ONLY=false
MILESTONES_ONLY=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_FILTER="${2:-}"
      shift 2
      ;;
    --closed)
      INCLUDE_CLOSED=true
      shift
      ;;
    --epics-only)
      EPICS_ONLY=true
      shift
      ;;
    --milestones-only)
      MILESTONES_ONLY=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--milestone NAME] [--closed] [--epics-only] [--milestones-only]"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

TODAY=$(date +%Y-%m-%d)

# ─────────────────────────────────────────────
# MILESTONE AUDIT
# ─────────────────────────────────────────────

if [ "$EPICS_ONLY" != "true" ]; then

  # Get all milestones (open + closed if requested)
  MILESTONE_STATE="open"
  if [ "$INCLUDE_CLOSED" = "true" ] || [ -n "$MILESTONE_FILTER" ]; then
    MILESTONE_STATE="all"
  fi

  gh api repos/:owner/:repo/milestones \
    --paginate \
    -q ".[] | {number: .number, title: .title, state: .state, due_on: .due_on, open_issues: .open_issues, closed_issues: .closed_issues, description: .description}" \
    2>/dev/null | jq -s '.' > "$TMPDIR/milestones.json" || echo "[]" > "$TMPDIR/milestones.json"

  # Get closed milestones specifically for orphan check
  gh api "repos/:owner/:repo/milestones?state=closed&per_page=100" \
    --paginate \
    -q ".[] | {number: .number, title: .title, state: .state, open_issues: .open_issues, closed_issues: .closed_issues}" \
    2>/dev/null | jq -s '.' > "$TMPDIR/closed_milestones.json" || echo "[]" > "$TMPDIR/closed_milestones.json"

  # For each closed milestone with open_issues > 0, get those issues
  CLOSED_MS_WITH_OPEN=$(cat "$TMPDIR/closed_milestones.json" | jq '[.[] | select(.open_issues > 0)]')
  echo "$CLOSED_MS_WITH_OPEN" > "$TMPDIR/closed_ms_with_open.json"

  # Gather orphaned open issues in each closed milestone
  ORPHAN_RESULTS="[]"
  CLOSED_COUNT=$(echo "$CLOSED_MS_WITH_OPEN" | jq 'length')
  if [ "$CLOSED_COUNT" -gt 0 ]; then
    echo "$CLOSED_MS_WITH_OPEN" | jq -r '.[].title' | while IFS= read -r ms_title; do
      MS_NUM=$(echo "$CLOSED_MS_WITH_OPEN" | jq -r --arg t "$ms_title" '.[] | select(.title == $t) | .number')
      ISSUES=$(gh issue list \
        --milestone "$ms_title" \
        --state open \
        --json number,title,labels,state,createdAt,updatedAt \
        --limit 100 2>/dev/null || echo "[]")
      echo "$ISSUES" | jq --arg ms "$ms_title" --argjson ms_num "$MS_NUM" \
        '[.[] | {milestone: $ms, milestone_number: $ms_num, number: .number, title: .title, state: .state, labels: [.labels[].name], created_at: .createdAt, updated_at: .updatedAt}]' \
        >> "$TMPDIR/orphan_parts.json"
    done
    # Merge all orphan parts
    if ls "$TMPDIR/orphan_parts.json" 2>/dev/null; then
      jq -s 'add // []' "$TMPDIR/orphan_parts.json" > "$TMPDIR/orphan_issues_in_closed_ms.json"
    else
      echo "[]" > "$TMPDIR/orphan_issues_in_closed_ms.json"
    fi
  else
    echo "[]" > "$TMPDIR/orphan_issues_in_closed_ms.json"
  fi

  # Check open milestone issues for missing PRs (acceptance criteria validation)
  # Get open milestone issues closed without a linked PR
  OPEN_MS_STATE="open"
  if [ -n "$MILESTONE_FILTER" ]; then
    gh issue list \
      --milestone "$MILESTONE_FILTER" \
      --state closed \
      --json number,title,labels,closedAt,body \
      --limit 200 2>/dev/null | \
      jq '[.[] | select((.body // "") | test("closes|fixes|resolves|#[0-9]+"; "i") | not) | {number: .number, title: .title, labels: [.labels[].name], closed_at: .closedAt, has_pr_link: false}]' \
      > "$TMPDIR/closed_no_pr.json" || echo "[]" > "$TMPDIR/closed_no_pr.json"
  else
    # For active open milestones, check recently closed issues
    gh issue list \
      --state closed \
      --json number,title,labels,closedAt,body,milestone \
      --limit 200 2>/dev/null | \
      jq '[.[] | select(.milestone != null) | select((.body // "") | test("closes|fixes|resolves|#[0-9]+"; "i") | not) | {number: .number, title: .title, milestone: .milestone.title, labels: [.labels[].name], closed_at: .closedAt, has_pr_link: false}]' \
      > "$TMPDIR/closed_no_pr.json" || echo "[]" > "$TMPDIR/closed_no_pr.json"
  fi

else
  # Epic-only mode - create empty milestone files
  echo "[]" > "$TMPDIR/milestones.json"
  echo "[]" > "$TMPDIR/closed_milestones.json"
  echo "[]" > "$TMPDIR/orphan_issues_in_closed_ms.json"
  echo "[]" > "$TMPDIR/closed_no_pr.json"
fi

# ─────────────────────────────────────────────
# EPIC AUDIT
# ─────────────────────────────────────────────

if [ "$MILESTONES_ONLY" != "true" ]; then

  # Get all issues labeled 'epic' (both open and closed)
  gh issue list \
    --label "epic" \
    --state all \
    --json number,title,state,labels,body,milestone,closedAt,createdAt,updatedAt \
    --limit 200 2>/dev/null > "$TMPDIR/all_epics.json" || echo "[]" > "$TMPDIR/all_epics.json"

  EPIC_COUNT=$(jq 'length' "$TMPDIR/all_epics.json")

  # For each epic, get its children via parent:N label
  > "$TMPDIR/epic_audit_parts.json"

  if [ "$EPIC_COUNT" -gt 0 ]; then
    jq -r '.[].number' "$TMPDIR/all_epics.json" | while IFS= read -r epic_num; do
      EPIC_DATA=$(jq --argjson n "$epic_num" '.[] | select(.number == $n)' "$TMPDIR/all_epics.json")
      EPIC_STATE=$(echo "$EPIC_DATA" | jq -r '.state')
      EPIC_TITLE=$(echo "$EPIC_DATA" | jq -r '.title')

      # Get children with parent:N label
      CHILDREN=$(gh issue list \
        --label "parent:${epic_num}" \
        --state all \
        --json number,title,state,labels,closedAt,createdAt \
        --limit 100 2>/dev/null || echo "[]")

      TOTAL=$(echo "$CHILDREN" | jq 'length')
      OPEN=$(echo "$CHILDREN" | jq '[.[] | select(.state == "OPEN")] | length')
      CLOSED=$(echo "$CHILDREN" | jq '[.[] | select(.state == "CLOSED")] | length')
      PCT=$(echo "$CHILDREN" | jq 'if length > 0 then ([.[] | select(.state == "CLOSED")] | length) * 100 / length | floor else 0 end')

      # Classify: stale open epic with all children closed
      IS_STALE_OPEN="false"
      if [ "$EPIC_STATE" = "OPEN" ] && [ "$TOTAL" -gt 0 ] && [ "$OPEN" -eq 0 ]; then
        IS_STALE_OPEN="true"
      fi

      # Classify: closed epic with open children (incorrectly closed)
      HAS_ORPHANED_CHILDREN="false"
      if [ "$EPIC_STATE" = "CLOSED" ] && [ "$OPEN" -gt 0 ]; then
        HAS_ORPHANED_CHILDREN="true"
      fi

      # Classify: epic with no children (potentially empty)
      IS_EMPTY="false"
      if [ "$TOTAL" -eq 0 ]; then
        IS_EMPTY="true"
      fi

      jq -n \
        --argjson epic_num "$epic_num" \
        --arg epic_title "$EPIC_TITLE" \
        --arg epic_state "$EPIC_STATE" \
        --argjson children "$CHILDREN" \
        --argjson total "$TOTAL" \
        --argjson open "$OPEN" \
        --argjson closed "$CLOSED" \
        --argjson pct "$PCT" \
        --argjson is_stale_open "$IS_STALE_OPEN" \
        --argjson has_orphaned_children "$HAS_ORPHANED_CHILDREN" \
        --argjson is_empty "$IS_EMPTY" \
        '{
          epic_number: $epic_num,
          epic_title: $epic_title,
          epic_state: $epic_state,
          is_stale_open: $is_stale_open,
          has_orphaned_children: $has_orphaned_children,
          is_empty: $is_empty,
          children: {
            total: $total,
            open: $open,
            closed: $closed,
            percent_complete: $pct,
            items: [$children[] | {
              number: .number,
              title: .title,
              state: .state,
              labels: [.labels[].name]
            }]
          }
        }' >> "$TMPDIR/epic_audit_parts.json"
    done
  fi

  # Merge epic audit results
  if [ -s "$TMPDIR/epic_audit_parts.json" ]; then
    jq -s '.' "$TMPDIR/epic_audit_parts.json" > "$TMPDIR/epic_audit.json"
  else
    echo "[]" > "$TMPDIR/epic_audit.json"
  fi

  # Extract stale open epics (open but all children done)
  jq '[.[] | select(.is_stale_open == true)]' "$TMPDIR/epic_audit.json" > "$TMPDIR/stale_open_epics.json"

  # Extract incorrectly closed epics (closed but has open children)
  jq '[.[] | select(.has_orphaned_children == true)]' "$TMPDIR/epic_audit.json" > "$TMPDIR/incorrectly_closed_epics.json"

  # Extract empty epics
  jq '[.[] | select(.is_empty == true)]' "$TMPDIR/epic_audit.json" > "$TMPDIR/empty_epics.json"

  # Extract healthy epics (open, has children, some still open)
  jq '[.[] | select(.epic_state == "OPEN" and .is_empty == false and .is_stale_open == false)]' \
    "$TMPDIR/epic_audit.json" > "$TMPDIR/active_epics.json"

else
  echo "[]" > "$TMPDIR/epic_audit.json"
  echo "[]" > "$TMPDIR/stale_open_epics.json"
  echo "[]" > "$TMPDIR/incorrectly_closed_epics.json"
  echo "[]" > "$TMPDIR/empty_epics.json"
  echo "[]" > "$TMPDIR/active_epics.json"
fi

# ─────────────────────────────────────────────
# CROSS-REFERENCE: Issues closed without linked PR
# ─────────────────────────────────────────────

# Get recent merged PRs to cross-reference
gh pr list \
  --state merged \
  --json number,title,mergedAt,body \
  --limit 100 2>/dev/null | \
  jq '[.[] | {pr_number: .number, title: .title, merged_at: .mergedAt, closes_issues: [.body // "" | scan("#[0-9]+") | ltrimstr("#") | tonumber? // empty]}]' \
  > "$TMPDIR/merged_prs.json" || echo "[]" > "$TMPDIR/merged_prs.json"

# ─────────────────────────────────────────────
# BUILD FINAL OUTPUT
# ─────────────────────────────────────────────

# Compute summary counts
ORPHAN_COUNT=$(jq 'length' "$TMPDIR/orphan_issues_in_closed_ms.json")
STALE_EPICS_COUNT=$(jq 'length' "$TMPDIR/stale_open_epics.json")
INCORRECTLY_CLOSED_COUNT=$(jq 'length' "$TMPDIR/incorrectly_closed_epics.json")
EMPTY_EPICS_COUNT=$(jq 'length' "$TMPDIR/empty_epics.json")
NO_PR_COUNT=$(jq 'length' "$TMPDIR/closed_no_pr.json")
TOTAL_EPICS=$(jq 'length' "$TMPDIR/epic_audit.json")
CLOSED_MS_COUNT=$(jq 'length' "$TMPDIR/closed_milestones.json")

# Health score calculation:
# Start at 100, deduct for each problem found
HEALTH_SCORE=100
HEALTH_SCORE=$((HEALTH_SCORE - ORPHAN_COUNT * 10))
HEALTH_SCORE=$((HEALTH_SCORE - STALE_EPICS_COUNT * 5))
HEALTH_SCORE=$((HEALTH_SCORE - INCORRECTLY_CLOSED_COUNT * 15))
HEALTH_SCORE=$((HEALTH_SCORE - EMPTY_EPICS_COUNT * 3))
if [ "$HEALTH_SCORE" -lt 0 ]; then HEALTH_SCORE=0; fi

# Health status label
HEALTH_STATUS="Good"
if [ "$HEALTH_SCORE" -lt 80 ]; then HEALTH_STATUS="Warning"; fi
if [ "$HEALTH_SCORE" -lt 50 ]; then HEALTH_STATUS="Critical"; fi

jq -n \
  --slurpfile orphan_issues_in_closed_ms "$TMPDIR/orphan_issues_in_closed_ms.json" \
  --slurpfile stale_open_epics "$TMPDIR/stale_open_epics.json" \
  --slurpfile incorrectly_closed_epics "$TMPDIR/incorrectly_closed_epics.json" \
  --slurpfile empty_epics "$TMPDIR/empty_epics.json" \
  --slurpfile active_epics "$TMPDIR/active_epics.json" \
  --slurpfile all_epics "$TMPDIR/epic_audit.json" \
  --slurpfile closed_milestones "$TMPDIR/closed_milestones.json" \
  --slurpfile closed_no_pr "$TMPDIR/closed_no_pr.json" \
  --slurpfile merged_prs "$TMPDIR/merged_prs.json" \
  --argjson orphan_count "$ORPHAN_COUNT" \
  --argjson stale_epics_count "$STALE_EPICS_COUNT" \
  --argjson incorrectly_closed_count "$INCORRECTLY_CLOSED_COUNT" \
  --argjson empty_epics_count "$EMPTY_EPICS_COUNT" \
  --argjson no_pr_count "$NO_PR_COUNT" \
  --argjson total_epics "$TOTAL_EPICS" \
  --argjson closed_ms_count "$CLOSED_MS_COUNT" \
  --argjson health_score "$HEALTH_SCORE" \
  --arg health_status "$HEALTH_STATUS" \
  --arg today "$TODAY" \
  '{
    generated_at: $today,
    health: {
      score: $health_score,
      status: $health_status
    },
    summary: {
      total_epics: $total_epics,
      stale_open_epics: $stale_epics_count,
      incorrectly_closed_epics: $incorrectly_closed_count,
      empty_epics: $empty_epics_count,
      closed_milestones_audited: $closed_ms_count,
      orphan_issues_in_closed_milestones: $orphan_count,
      closed_issues_missing_pr: $no_pr_count
    },
    findings: {
      orphan_issues_in_closed_milestones: $orphan_issues_in_closed_ms[0],
      stale_open_epics: $stale_open_epics[0],
      incorrectly_closed_epics: $incorrectly_closed_epics[0],
      empty_epics: $empty_epics[0],
      active_epics: $active_epics[0],
      closed_issues_missing_pr_link: $closed_no_pr[0]
    },
    reference: {
      closed_milestones: $closed_milestones[0],
      merged_prs: $merged_prs[0],
      all_epics: $all_epics[0]
    }
  }'
