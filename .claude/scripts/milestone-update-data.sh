#!/bin/bash
# milestone-update-data.sh
# Prepares milestone update actions based on audit data
#
# Usage:
#   ./scripts/milestone-update-data.sh [milestone_name]
#   ./scripts/milestone-update-data.sh [milestone_name] --labels   # Focus on label compliance
#   ./scripts/milestone-update-data.sh [milestone_name] --dry-run  # Preview mode
#
# Returns JSON with:
#   - Audit summary
#   - Actionable items categorized by type
#   - Label compliance analysis (when --labels flag used)
#   - Recommended actions with prompts
#   - Risk assessment per action

set -euo pipefail

MILESTONE=""
LABELS_MODE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --labels)
      LABELS_MODE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      MILESTONE="$1"
      shift
      ;;
  esac
done

# Run milestone audit first
if [[ -n "$MILESTONE" ]]; then
  AUDIT_DATA=$(./scripts/milestone-audit-data.sh "$MILESTONE")
else
  AUDIT_DATA=$(./scripts/milestone-audit-data.sh)
fi

# Extract milestone name from audit
MILESTONE_NAME=$(echo "$AUDIT_DATA" | jq -r '.milestone.title')

# Label compliance analysis function
analyze_label_compliance() {
  local issues="$1"

  # Required label categories
  # - status: backlog, in-progress, blocked, etc.
  # - type: bug, feature, tech-debt, docs

  echo "$issues" | jq '
    # Define required label patterns
    def has_status: .labels | map(.name) | any(test("^(backlog|in-progress|blocked|wip:|needs-)"));
    def has_type: .labels | map(.name) | any(test("^(bug|feature|tech-debt|docs)$"));

    # Analyze each issue
    [.[] | {
      number,
      title,
      labels: [.labels[].name],
      has_status: has_status,
      has_type: has_type,
      missing: (
        (if has_status then [] else ["status"] end) +
        (if has_type then [] else ["type"] end)
      ),
      compliant: (has_status and has_type)
    }]
  '
}

# Build label compliance data if in labels mode
if [[ "$LABELS_MODE" == "true" ]]; then
  # Get issues from audit data
  ISSUES=$(echo "$AUDIT_DATA" | jq '.milestone_issues // .open_issues // []')

  # Analyze label compliance
  COMPLIANCE=$(analyze_label_compliance "$ISSUES")

  # Categorize issues
  MISSING_STATUS=$(echo "$COMPLIANCE" | jq '[.[] | select(.has_status == false)]')
  MISSING_TYPE=$(echo "$COMPLIANCE" | jq '[.[] | select(.has_type == false)]')
  COMPLIANT=$(echo "$COMPLIANCE" | jq '[.[] | select(.compliant == true)]')
  NON_COMPLIANT=$(echo "$COMPLIANCE" | jq '[.[] | select(.compliant == false)]')

  # Build actionable items with prompts
  STATUS_ACTIONS=$(echo "$MISSING_STATUS" | jq '
    [.[] | {
      number,
      title,
      current_labels: .labels,
      action: "add_backlog",
      auto_fix: true,
      prompt: "Issue #\(.number): \"\(.title)\"\nCurrent labels: \(.labels | join(", "))\n\nWill add: backlog"
    }]
  ')

  TYPE_ACTIONS=$(echo "$MISSING_TYPE" | jq '
    [.[] | {
      number,
      title,
      current_labels: .labels,
      action: "add_type",
      auto_fix: false,
      prompt: "Issue #\(.number): \"\(.title)\"\nCurrent labels: \(.labels | join(", "))\n\nNeeds manual type: bug|feature|tech-debt|docs"
    }]
  ')

  # Count stats
  TOTAL=$(echo "$ISSUES" | jq 'length')
  COMPLIANT_COUNT=$(echo "$COMPLIANT" | jq 'length')
  MISSING_STATUS_COUNT=$(echo "$MISSING_STATUS" | jq 'length')
  MISSING_TYPE_COUNT=$(echo "$MISSING_TYPE" | jq 'length')

  # Output label compliance JSON
  jq -n \
    --arg milestone "$MILESTONE_NAME" \
    --argjson total "$TOTAL" \
    --argjson compliant "$COMPLIANT_COUNT" \
    --argjson missing_status "$MISSING_STATUS_COUNT" \
    --argjson missing_type "$MISSING_TYPE_COUNT" \
    --argjson status_actions "$STATUS_ACTIONS" \
    --argjson type_actions "$TYPE_ACTIONS" \
    --argjson compliant_issues "$COMPLIANT" \
    --argjson dry_run "$DRY_RUN" \
    '{
      mode: "labels",
      dry_run: $dry_run,
      milestone: {
        name: $milestone
      },
      summary: {
        total_issues: $total,
        compliant: $compliant,
        missing_status: $missing_status,
        missing_type: $missing_type,
        compliance_pct: (if $total > 0 then (($compliant / $total) * 100 | floor) else 100 end)
      },
      actions: {
        auto_fixable: $status_actions,
        manual_required: $type_actions
      },
      compliant_issues: $compliant_issues
    }'
  exit 0
fi

# Analyze audit data for actionable items

# 1. Stale in-progress issues (no updates in 3+ days)
STALE_ISSUES=$(echo "$AUDIT_DATA" | jq -r '
  [(.issues // [])[] | select(
    (.labels | map(.name) | index("in-progress")) and
    (.updatedAt | fromdateiso8601) < (now - (3 * 86400))
  ) | {
    number,
    title,
    days_stale: ((now - (.updatedAt | fromdateiso8601)) / 86400 | floor),
    assignees: [.assignees[]?.login] | join(", "),
    action: "mark_blocked",
    risk: "low",
    prompt: "Issue #\(.number): \"\(.title)\"\nStatus: in-progress for \(((now - (.updatedAt | fromdateiso8601)) / 86400 | floor)) days\nLast updated: \(.updatedAt)\n\nRecommended: Mark as blocked"
  }]
')

# 2. Orphaned issues (no milestone, but has backlog label)
ORPHANED_ISSUES=$(gh issue list --json number,title,labels,milestone --limit 100 | jq --arg milestone "$MILESTONE_NAME" -r '
  [.[] | select(
    (.milestone == null) and
    (.labels | map(.name) | index("backlog"))
  ) | . as $issue | {
    number: $issue.number,
    title: $issue.title,
    labels: ([$issue.labels[].name] | join(", ")),
    action: "add_to_milestone",
    target_milestone: $milestone,
    risk: "low",
    prompt: ("Issue #" + ($issue.number | tostring) + ": \"" + $issue.title + "\"\nLabels: " + ([$issue.labels[].name] | join(", ")) + "\n\nRecommended: Add to milestone " + $milestone)
  }]
')

# 3. Completed PR-merged issues still open
COMPLETED_OPEN=$(echo "$AUDIT_DATA" | jq -r '
  [(.issues // [])[] | select(
    .state == "open" and
    (.labels | map(.name) | index("needs-attention") | not)
  ) | . as $issue |
  # Check if there is a merged PR for this issue
  # This requires a separate gh call, simplified here
  {
    number: .number,
    title: .title,
    state: .state,
    action: "close_completed",
    risk: "medium",
    prompt: "Issue #\(.number): \"\(.title)\"\nState: \(.state)\n\nManual verification needed: Check if work is complete"
  }] | map(select(.action != null))
')

# 4. Blocked issues with no blocker comment
BLOCKED_NO_CONTEXT=$(echo "$AUDIT_DATA" | jq -r '
  [(.issues // [])[] | select(
    (.labels | map(.name) | index("blocked"))
  ) | {
    number,
    title,
    action: "add_blocker_comment",
    risk: "low",
    prompt: "Issue #\(.number): \"\(.title)\"\nStatus: blocked\n\nRecommended: Add comment explaining blocker"
  }]
')

# Count actions by category
STALE_COUNT=$(echo "$STALE_ISSUES" | jq 'length')
ORPHANED_COUNT=$(echo "$ORPHANED_ISSUES" | jq 'length')
COMPLETED_COUNT=$(echo "$COMPLETED_OPEN" | jq 'length')
BLOCKED_COUNT=$(echo "$BLOCKED_NO_CONTEXT" | jq 'length')
TOTAL_ACTIONS=$((STALE_COUNT + ORPHANED_COUNT + COMPLETED_COUNT + BLOCKED_COUNT))

# Extract health score from audit
HEALTH_SCORE=$(echo "$AUDIT_DATA" | jq -r '.health.score // 0')

# Build final output
jq -n \
  --argjson audit "$AUDIT_DATA" \
  --argjson stale "$STALE_ISSUES" \
  --argjson orphaned "$ORPHANED_ISSUES" \
  --argjson completed "$COMPLETED_OPEN" \
  --argjson blocked "$BLOCKED_NO_CONTEXT" \
  --argjson health "$HEALTH_SCORE" \
  --argjson total "$TOTAL_ACTIONS" \
  --argjson stale_count "$STALE_COUNT" \
  --argjson orphaned_count "$ORPHANED_COUNT" \
  --argjson completed_count "$COMPLETED_COUNT" \
  --argjson blocked_count "$BLOCKED_COUNT" \
  --arg milestone "$MILESTONE_NAME" \
  '{
    milestone: {
      name: $milestone,
      health_score: $health
    },
    summary: {
      total_actions: $total,
      by_category: {
        stale_in_progress: $stale_count,
        orphaned_issues: $orphaned_count,
        completed_open: $completed_count,
        blocked_no_context: $blocked_count
      }
    },
    actions: {
      stale_issues: $stale,
      orphaned_issues: $orphaned,
      completed_open: $completed,
      blocked_no_context: $blocked
    },
    audit_full: $audit
  }'
