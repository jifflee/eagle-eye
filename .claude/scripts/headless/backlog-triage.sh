#!/usr/bin/env bash
# ============================================================
# Script: backlog-triage.sh
# Purpose: Generate prioritized backlog summary for headless mode consumption
# Usage: ./scripts/headless/backlog-triage.sh [OPTIONS]
# Dependencies: bash, jq, gh (GitHub CLI)
# ============================================================
#
# DESCRIPTION:
#   Headless-mode compatible script that analyzes the backlog and generates:
#   - Prioritized issue list with intelligent scoring
#   - Stale issue detection (not updated in N days)
#   - Epic/milestone health summary
#   - Recommended next actions
#   - Issues needing label updates or triage
#
# OPTIONS:
#   --milestone NAME         Analyze specific milestone (default: active milestone)
#   --output-file FILE       Path to write JSON report (default: backlog-triage-report.json)
#   --format FORMAT          Output format: json|markdown (default: json)
#   --stale-days N           Consider issues stale after N days (default: 30)
#   --include-closed         Include closed issues in analysis
#   --verbose                Verbose output
#   --help                   Show this help
#
# OUTPUT:
#   JSON or Markdown report suitable for Claude headless mode consumption
#   Exit code 0: success
#   Exit code 1: issues found requiring attention
#   Exit code 2: fatal error
#
# HEADLESS MODE USAGE:
#   ./scripts/headless/backlog-triage.sh --format markdown | claude -p -
#   OR
#   claude -p "Review the backlog triage report at backlog-triage-report.json"

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

MILESTONE="${MILESTONE:-}"
OUTPUT_FILE="${OUTPUT_FILE:-backlog-triage-report.json}"
FORMAT="${FORMAT:-json}"
STALE_DAYS="${STALE_DAYS:-30}"
INCLUDE_CLOSED="${INCLUDE_CLOSED:-false}"
VERBOSE="${VERBOSE:-false}"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || die "Failed to change to repo root"

# ─── Argument parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -30
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --milestone)         MILESTONE="$2"; shift 2 ;;
    --output-file)       OUTPUT_FILE="$2"; shift 2 ;;
    --format)            FORMAT="$2"; shift 2 ;;
    --stale-days)        STALE_DAYS="$2"; shift 2 ;;
    --include-closed)    INCLUDE_CLOSED="true"; shift ;;
    --verbose)           VERBOSE="true"; shift ;;
    --help|-h)           show_help ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

require_command "gh"
require_command "jq"

# Check GitHub CLI authentication
if ! gh auth status &>/dev/null; then
  die "GitHub CLI not authenticated. Run: gh auth login"
fi

# ─── Helper Functions ─────────────────────────────────────────────────────────

log_verbose() {
  if [ "$VERBOSE" = "true" ]; then
    log_info "$@"
  fi
}

# Calculate days since last update
days_since_update() {
  local updated_at="$1"
  local now_epoch=$(date +%s)
  local updated_epoch=$(date -d "$updated_at" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || echo "$now_epoch")
  local diff_seconds=$((now_epoch - updated_epoch))
  echo $((diff_seconds / 86400))
}

# ─── Main Analysis Logic ──────────────────────────────────────────────────────

log_info "Starting backlog triage analysis..."

# Get active milestone if not specified
if [ -z "$MILESTONE" ]; then
  log_verbose "Detecting active milestone..."
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty' 2>/dev/null || echo "")

  if [ -z "$MILESTONE" ]; then
    log_warn "No active milestone found, analyzing all open issues"
  else
    log_verbose "Using active milestone: $MILESTONE"
  fi
fi

# Fetch issues
log_verbose "Fetching issues..."

ISSUE_ARGS=("--state" "open" "--json" "number,title,body,labels,createdAt,updatedAt,assignees,milestone,comments")

if [ -n "$MILESTONE" ]; then
  ISSUE_ARGS+=("--milestone" "$MILESTONE")
fi

OPEN_ISSUES=$(gh issue list "${ISSUE_ARGS[@]}" 2>/dev/null || echo '[]')

if [ "$INCLUDE_CLOSED" = "true" ]; then
  CLOSED_ISSUES=$(gh issue list --state closed "${ISSUE_ARGS[@]}" --limit 50 2>/dev/null || echo '[]')
else
  CLOSED_ISSUES='[]'
fi

# ─── Analyze Issues ───────────────────────────────────────────────────────────

log_verbose "Analyzing issues..."

ANALYSIS=$(echo "$OPEN_ISSUES" | jq --argjson stale_days "$STALE_DAYS" '
  # Priority scoring algorithm
  def calculate_priority_score:
    . as $issue |
    0 +
    # Severity labels
    (if ($issue.labels | map(.name) | any(. == "P0")) then 100
     elif ($issue.labels | map(.name) | any(. == "P1")) then 75
     elif ($issue.labels | map(.name) | any(. == "P2")) then 50
     elif ($issue.labels | map(.name) | any(. == "P3")) then 25
     else 40 end) +
    # Type modifiers
    (if ($issue.labels | map(.name) | any(. == "bug")) then 20
     elif ($issue.labels | map(.name) | any(. == "epic")) then -10
     else 0 end) +
    # Status modifiers
    (if ($issue.labels | map(.name) | any(. == "in-progress")) then 15
     elif ($issue.labels | map(.name) | any(. == "blocked")) then -20
     else 0 end) +
    # Comment activity bonus
    (if ($issue.comments > 5) then 10 else 0 end) +
    # Assignment bonus
    (if ($issue.assignees | length > 0) then 5 else 0 end);

  # Classify triage needs
  def needs_triage:
    . as $issue |
    ($issue.labels | map(.name)) as $labels |
    {
      missing_priority: ($labels | any(. | test("^P[0-3]$")) | not),
      missing_type: ($labels | any(. | test("^(bug|feature|tech-debt|docs|epic)$")) | not),
      missing_status: ($labels | any(. | test("^(backlog|in-progress|blocked)$")) | not),
      needs_triage_label: ($labels | any(. == "needs-triage"))
    } |
    .needs_triage = (.missing_priority or .missing_type or .missing_status or .needs_triage_label);

  # Calculate staleness
  def is_stale:
    . as $issue |
    (now - ($issue.updatedAt | fromdateiso8601)) / 86400 as $days_stale |
    {
      days_stale: ($days_stale | floor),
      is_stale: ($days_stale > $stale_days)
    };

  # Process each issue
  map(
    . as $issue |
    . + {
      priority_score: calculate_priority_score,
      triage_status: needs_triage,
      staleness: is_stale
    }
  )
')

# ─── Generate Statistics ──────────────────────────────────────────────────────

TOTAL_ISSUES=$(echo "$ANALYSIS" | jq 'length')
STALE_ISSUES=$(echo "$ANALYSIS" | jq '[.[] | select(.staleness.is_stale)] | length')
NEEDS_TRIAGE=$(echo "$ANALYSIS" | jq '[.[] | select(.triage_status.needs_triage)] | length')
IN_PROGRESS=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "in-progress"))] | length')
BLOCKED=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "blocked"))] | length')

# Priority breakdown
P0_COUNT=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "P0"))] | length')
P1_COUNT=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "P1"))] | length')
P2_COUNT=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "P2"))] | length')
P3_COUNT=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "P3"))] | length')
NO_PRIORITY=$(echo "$ANALYSIS" | jq '[.[] | select(.triage_status.missing_priority)] | length')

# Type breakdown
BUGS=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "bug"))] | length')
FEATURES=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "feature"))] | length')
TECH_DEBT=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "tech-debt"))] | length')
DOCS=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "docs"))] | length')
EPICS=$(echo "$ANALYSIS" | jq '[.[] | select(.labels | map(.name) | any(. == "epic"))] | length')

# Get top priority issues (highest score)
TOP_ISSUES=$(echo "$ANALYSIS" | jq 'sort_by(-.priority_score) | .[0:10]')

# Get stale issues
STALE_ISSUE_LIST=$(echo "$ANALYSIS" | jq '[.[] | select(.staleness.is_stale)] | sort_by(-.staleness.days_stale) | .[0:10]')

# Get issues needing triage
TRIAGE_NEEDED_LIST=$(echo "$ANALYSIS" | jq '[.[] | select(.triage_status.needs_triage)] | sort_by(-.priority_score) | .[0:10]')

# ─── Generate Recommendations ─────────────────────────────────────────────────

RECOMMENDATIONS='[]'

if [ "$STALE_ISSUES" -gt 0 ]; then
  RECOMMENDATIONS=$(echo "$RECOMMENDATIONS" | jq --argjson count "$STALE_ISSUES" \
    '. += [{
      type: "stale_issues",
      severity: "medium",
      count: $count,
      message: "\($count) issues have not been updated in \($stale_days) days",
      action: "Review stale issues and close obsolete ones or add updates"
    }]')
fi

if [ "$NEEDS_TRIAGE" -gt 0 ]; then
  RECOMMENDATIONS=$(echo "$RECOMMENDATIONS" | jq --argjson count "$NEEDS_TRIAGE" \
    '. += [{
      type: "needs_triage",
      severity: "high",
      count: $count,
      message: "\($count) issues are missing labels (priority, type, or status)",
      action: "Run issue triage to apply appropriate labels"
    }]')
fi

if [ "$BLOCKED" -gt 3 ]; then
  RECOMMENDATIONS=$(echo "$RECOMMENDATIONS" | jq --argjson count "$BLOCKED" \
    '. += [{
      type: "blocked_issues",
      severity: "high",
      count: $count,
      message: "\($count) issues are blocked",
      action: "Review blocked issues and resolve blockers"
    }]')
fi

if [ "$P0_COUNT" -gt 5 ]; then
  RECOMMENDATIONS=$(echo "$RECOMMENDATIONS" | jq --argjson count "$P0_COUNT" \
    '. += [{
      type: "too_many_p0",
      severity: "critical",
      count: $count,
      message: "\($count) P0 issues - priority inflation detected",
      action: "Review P0 issues and re-prioritize as needed"
    }]')
fi

# ─── Generate Final Report ────────────────────────────────────────────────────

REPORT=$(jq -n \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg milestone "$MILESTONE" \
  --argjson total "$TOTAL_ISSUES" \
  --argjson stale "$STALE_ISSUES" \
  --argjson needs_triage "$NEEDS_TRIAGE" \
  --argjson in_progress "$IN_PROGRESS" \
  --argjson blocked "$BLOCKED" \
  --argjson p0 "$P0_COUNT" \
  --argjson p1 "$P1_COUNT" \
  --argjson p2 "$P2_COUNT" \
  --argjson p3 "$P3_COUNT" \
  --argjson no_priority "$NO_PRIORITY" \
  --argjson bugs "$BUGS" \
  --argjson features "$FEATURES" \
  --argjson tech_debt "$TECH_DEBT" \
  --argjson docs "$DOCS" \
  --argjson epics "$EPICS" \
  --argjson top_issues "$TOP_ISSUES" \
  --argjson stale_issues "$STALE_ISSUE_LIST" \
  --argjson triage_needed "$TRIAGE_NEEDED_LIST" \
  --argjson recommendations "$RECOMMENDATIONS" \
  '{
    analysis_type: "backlog_triage",
    timestamp: $timestamp,
    milestone: $milestone,
    summary: {
      total_issues: $total,
      stale_issues: $stale,
      needs_triage: $needs_triage,
      in_progress: $in_progress,
      blocked: $blocked
    },
    priority_breakdown: {
      P0: $p0,
      P1: $p1,
      P2: $p2,
      P3: $p3,
      no_priority: $no_priority
    },
    type_breakdown: {
      bugs: $bugs,
      features: $features,
      tech_debt: $tech_debt,
      docs: $docs,
      epics: $epics
    },
    top_priority_issues: $top_issues,
    stale_issues: $stale_issues,
    needs_triage: $triage_needed,
    recommendations: $recommendations
  }')

# ─── Output ───────────────────────────────────────────────────────────────────

if [ "$FORMAT" = "markdown" ]; then
  # Generate markdown report
  cat <<EOF
# Backlog Triage Report

**Generated:** $(date)
**Milestone:** ${MILESTONE:-All Open Issues}

## Summary

- **Total Open Issues:** $TOTAL_ISSUES
- **Stale Issues (>$STALE_DAYS days):** $STALE_ISSUES
- **Needs Triage:** $NEEDS_TRIAGE
- **In Progress:** $IN_PROGRESS
- **Blocked:** $BLOCKED

## Priority Breakdown

| Priority | Count |
|----------|-------|
| P0 (Critical) | $P0_COUNT |
| P1 (High) | $P1_COUNT |
| P2 (Medium) | $P2_COUNT |
| P3 (Low) | $P3_COUNT |
| No Priority | $NO_PRIORITY |

## Type Breakdown

| Type | Count |
|------|-------|
| Bugs | $BUGS |
| Features | $FEATURES |
| Tech Debt | $TECH_DEBT |
| Docs | $DOCS |
| Epics | $EPICS |

## Recommendations

EOF

  echo "$RECOMMENDATIONS" | jq -r '.[] | "### [\(.severity | ascii_upcase)] \(.type)\n\n**Count:** \(.count)\n\n**Message:** \(.message)\n\n**Action:** \(.action)\n\n---\n"'

  cat <<EOF

## Top Priority Issues

EOF

  echo "$TOP_ISSUES" | jq -r '.[] | "- [#\(.number)](\(.html_url // "")) \(.title) (Score: \(.priority_score))"'

  if [ "$STALE_ISSUES" -gt 0 ]; then
    cat <<EOF

## Stale Issues (Not Updated in $STALE_DAYS Days)

EOF

    echo "$STALE_ISSUE_LIST" | jq -r '.[] | "- [#\(.number)](\(.html_url // "")) \(.title) (Stale for \(.staleness.days_stale) days)"'
  fi

  if [ "$NEEDS_TRIAGE" -gt 0 ]; then
    cat <<EOF

## Issues Needing Triage

EOF

    echo "$TRIAGE_NEEDED_LIST" | jq -r '.[] | "- [#\(.number)](\(.html_url // "")) \(.title)"'
  fi

else
  # JSON output
  echo "$REPORT" | jq '.'

  if [ "$OUTPUT_FILE" != "-" ]; then
    echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
    log_success "Report written to: $OUTPUT_FILE"
  fi
fi

# ─── Exit Status ──────────────────────────────────────────────────────────────

ATTENTION_NEEDED=0

if [ "$NEEDS_TRIAGE" -gt 0 ]; then
  ATTENTION_NEEDED=1
fi

if [ "$STALE_ISSUES" -gt 5 ]; then
  ATTENTION_NEEDED=1
fi

if [ "$ATTENTION_NEEDED" -eq 1 ]; then
  log_warn "Backlog analysis complete. Issues found requiring attention."
  exit 1
else
  log_success "Backlog analysis complete. No critical issues found."
  exit 0
fi
