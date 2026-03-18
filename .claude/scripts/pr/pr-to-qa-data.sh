#!/bin/bash
set -euo pipefail
# pr-to-qa-data.sh
# Gathers data for promoting dev branch to qa
#
# Usage:
#   ./scripts/pr-to-qa-data.sh                        # Get promotion readiness
#   ./scripts/pr-to-qa-data.sh --changelog            # Include changelog generation
#   ./scripts/pr-to-qa-data.sh --release-gate         # Run full release readiness gate
#   ./scripts/pr-to-qa-data.sh --release-gate --dry-run  # Preview release gate
#   ./scripts/pr-to-qa-data.sh --milestone "sprint-2/8"  # Filter by milestone
#   ./scripts/pr-to-qa-data.sh --selective            # Only promote:qa labeled work
#   ./scripts/pr-to-qa-data.sh --list-candidates      # Show promotable work
#
# Outputs structured JSON with branch state and promotion status

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source rate limit utility
if [ -f "$SCRIPT_DIR/lib/api-rate-limit.sh" ]; then
  source "$SCRIPT_DIR/lib/api-rate-limit.sh"
fi

# Source changelog cache utility
if [ -f "$SCRIPT_DIR/lib/changelog-cache.sh" ]; then
  source "$SCRIPT_DIR/lib/changelog-cache.sh"
fi

INCLUDE_CHANGELOG=false
RUN_RELEASE_GATE=false
RELEASE_GATE_DRY_RUN=false
MILESTONE_FILTER=""
SELECTIVE_MODE=false
LIST_CANDIDATES=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --changelog)
      INCLUDE_CHANGELOG=true
      shift
      ;;
    --release-gate)
      RUN_RELEASE_GATE=true
      shift
      ;;
    --dry-run)
      RELEASE_GATE_DRY_RUN=true
      shift
      ;;
    --milestone)
      MILESTONE_FILTER="$2"
      shift 2
      ;;
    --selective)
      SELECTIVE_MODE=true
      shift
      ;;
    --list-candidates)
      LIST_CANDIDATES=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Fetch latest
git fetch origin 2>/dev/null || true

# Function to check for branch divergence (main has commits not in dev)
check_branch_divergence() {
  local diverged_count=0
  local diverged_commits=""

  if git rev-parse --verify origin/main >/dev/null 2>&1 && git rev-parse --verify origin/dev >/dev/null 2>&1; then
    diverged_count=$(git log --oneline origin/main --not origin/dev --no-merges 2>/dev/null | wc -l)
    if [ "$diverged_count" -gt 0 ]; then
      diverged_commits=$(git log --oneline origin/main --not origin/dev --no-merges 2>/dev/null | head -10)
    fi
  fi

  echo "{\"diverged\": $([ "$diverged_count" -gt 0 ] && echo "true" || echo "false"), \"count\": $diverged_count, \"commits\": $(echo "$diverged_commits" | jq -R -s -c 'split("\n") | map(select(length > 0))')}"
}

# Function to get branch state
get_branch_state() {
  local ahead=0
  local behind=0

  if git rev-parse --verify origin/dev >/dev/null 2>&1 && git rev-parse --verify origin/qa >/dev/null 2>&1; then
    ahead=$(git rev-list --count origin/qa..origin/dev 2>/dev/null || echo 0)
    behind=$(git rev-list --count origin/dev..origin/qa 2>/dev/null || echo 0)
  elif git rev-parse --verify origin/dev >/dev/null 2>&1; then
    # qa branch doesn't exist yet - all dev commits are ahead
    ahead=$(git rev-list --count origin/dev 2>/dev/null || echo 0)
    behind=0
  fi

  echo "{\"ahead\": $ahead, \"behind\": $behind}"
}

# Function to get commits for changelog
get_commits() {
  if git rev-parse --verify origin/qa >/dev/null 2>&1; then
    git log --oneline origin/qa..origin/dev 2>/dev/null || echo ""
  else
    # qa branch doesn't exist yet - show recent dev commits
    git log --oneline origin/dev -20 2>/dev/null || echo ""
  fi
}

# Function to categorize commits
categorize_commits() {
  local commits="$1"

  local features=""
  local fixes=""
  local other=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE '^[a-f0-9]+ feat'; then
      features="$features\"$(echo "$line" | sed 's/"/\\"/g')\","
    elif echo "$line" | grep -qiE '^[a-f0-9]+ fix'; then
      fixes="$fixes\"$(echo "$line" | sed 's/"/\\"/g')\","
    else
      other="$other\"$(echo "$line" | sed 's/"/\\"/g')\","
    fi
  done <<< "$commits"

  # Remove trailing commas
  features="${features%,}"
  fixes="${fixes%,}"
  other="${other%,}"

  echo "{\"features\": [${features}], \"fixes\": [${fixes}], \"other\": [${other}]}"
}

# Function to get PRs with promote:qa label
# Uses REST API to reduce GraphQL rate limit usage
get_promote_qa_prs() {
  local result

  # Check rate limit before making call
  if type check_rate_limit >/dev/null 2>&1; then
    check_rate_limit "core" >/dev/null 2>&1 || true
  fi

  # Use REST API via gh pr list (minimizes fields to reduce response size)
  result=$(gh pr list --base dev --state merged --label "promote:qa" \
    --json number,title,mergedAt,labels 2>/dev/null || echo "[]")

  # Ensure we return valid JSON array
  if [ -z "$result" ] || [ "$result" = "" ]; then
    echo "[]"
  else
    echo "$result"
  fi
}

# Function to get PRs for a specific milestone
get_milestone_prs() {
  local milestone="$1"
  gh pr list --base dev --state merged --search "milestone:\"$milestone\"" \
    --json number,title,mergedAt,milestone \
    --jq '.[] | {number: .number, title: .title, merged_at: .mergedAt, milestone: .milestone.title}' 2>/dev/null || echo "[]"
}

# Function to validate milestone completeness
# Uses REST API (already using gh api which is REST)
check_milestone_completeness() {
  local milestone="$1"
  local milestone_data

  # Check rate limit before making call
  if type check_rate_limit >/dev/null 2>&1; then
    check_rate_limit "core" >/dev/null 2>&1 || true
  fi

  milestone_data=$(gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$milestone\")" 2>/dev/null || echo "{}")

  if [ -z "$milestone_data" ] || [ "$milestone_data" = "{}" ]; then
    echo '{"complete": false, "reason": "milestone not found", "open_issues": 0, "total_issues": 0}'
    return
  fi

  local open_issues
  local closed_issues
  open_issues=$(echo "$milestone_data" | jq -r '.open_issues')
  closed_issues=$(echo "$milestone_data" | jq -r '.closed_issues')
  local total=$((open_issues + closed_issues))

  if [ "$open_issues" -eq 0 ] && [ "$total" -gt 0 ]; then
    echo "{\"complete\": true, \"open_issues\": $open_issues, \"total_issues\": $total}"
  else
    echo "{\"complete\": false, \"reason\": \"milestone has open issues\", \"open_issues\": $open_issues, \"total_issues\": $total}"
  fi
}

# Function to list promotion candidates
list_promotion_candidates() {
  local mode="$1"  # "selective" or "milestone"
  local milestone="$2"

  if [ "$mode" = "selective" ]; then
    local prs
    prs=$(gh pr list --base dev --state merged --label "promote:qa" \
      --json number,title,mergedAt,author \
      --jq '.[] | "PR #\(.number): \(.title) (merged: \(.mergedAt[:10]), author: \(.author.login))"' 2>/dev/null || echo "")

    if [ -z "$prs" ]; then
      echo '{"mode": "selective", "count": 0, "candidates": [], "message": "No PRs with promote:qa label found"}'
    else
      local count
      count=$(echo "$prs" | wc -l)
      local candidates_json=""
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        candidates_json="$candidates_json\"$(echo "$line" | sed 's/"/\\"/g')\","
      done <<< "$prs"
      candidates_json="${candidates_json%,}"
      echo "{\"mode\": \"selective\", \"count\": $count, \"candidates\": [${candidates_json}]}"
    fi
  elif [ "$mode" = "milestone" ]; then
    local milestone_info
    milestone_info=$(check_milestone_completeness "$milestone")
    local is_complete
    is_complete=$(echo "$milestone_info" | jq -r '.complete')

    local prs
    prs=$(gh pr list --base dev --state merged --search "milestone:\"$milestone\"" \
      --json number,title,mergedAt,author \
      --jq '.[] | "PR #\(.number): \(.title) (merged: \(.mergedAt[:10]), author: \(.author.login))"' 2>/dev/null || echo "")

    local count=0
    local candidates_json=""
    if [ -n "$prs" ]; then
      count=$(echo "$prs" | wc -l)
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        candidates_json="$candidates_json\"$(echo "$line" | sed 's/"/\\"/g')\","
      done <<< "$prs"
      candidates_json="${candidates_json%,}"
    fi

    echo "{\"mode\": \"milestone\", \"milestone\": \"$milestone\", \"complete\": $is_complete, \"count\": $count, \"candidates\": [${candidates_json}], \"milestone_info\": $milestone_info}"
  else
    echo '{"mode": "full", "message": "Full promotion - all commits from dev to qa"}'
  fi
}

# Handle --list-candidates mode
if [ "$LIST_CANDIDATES" = true ]; then
  if [ "$SELECTIVE_MODE" = true ]; then
    list_promotion_candidates "selective" ""
  elif [ -n "$MILESTONE_FILTER" ]; then
    list_promotion_candidates "milestone" "$MILESTONE_FILTER"
  else
    list_promotion_candidates "full" ""
  fi
  exit 0
fi

# Get data
branch_state=$(get_branch_state)
branch_divergence=$(check_branch_divergence)

# Check if qa branch exists
qa_exists=true
if ! git rev-parse --verify origin/qa >/dev/null 2>&1; then
  qa_exists=false
fi

# Check CI status on dev
ci_status=$(gh run list --branch dev --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo "unknown")

# Check for open PRs to dev
open_prs=$(gh pr list --base dev --state open --json number --jq 'length' 2>/dev/null || echo 0)

# Check for existing PR to qa
existing_pr=$(gh pr list --head dev --base qa --state open --json number,url --jq '.[0] // null' 2>/dev/null)
# Ensure valid JSON
if [ -z "$existing_pr" ] || [ "$existing_pr" = "" ]; then
  existing_pr="null"
fi

# Determine promotion mode
promotion_mode="full"
milestone_completeness='null'
selective_prs='null'

if [ -n "$MILESTONE_FILTER" ]; then
  promotion_mode="milestone"
  milestone_completeness=$(check_milestone_completeness "$MILESTONE_FILTER")
elif [ "$SELECTIVE_MODE" = true ]; then
  promotion_mode="selective"
  selective_prs=$(get_promote_qa_prs)
fi

# Determine if ready
ahead=$(echo "$branch_state" | jq '.ahead')
can_promote=false
block_reasons='[]'

# Check for branch divergence (main has commits not in dev)
diverged=$(echo "$branch_divergence" | jq -r '.diverged')
diverged_count=$(echo "$branch_divergence" | jq -r '.count')

# Base readiness checks
if [ "$ahead" -eq 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["no commits ahead of qa"]')
elif [ "$diverged" = "true" ]; then
  block_reasons=$(echo "$block_reasons" | jq --arg count "$diverged_count" '. + ["main has \($count) commits not in dev - must sync before promotion"]')
elif [ "$open_prs" -gt 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["open PRs to dev"]')
elif [ "$ci_status" != "success" ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["CI not passing on dev"]')
else
  can_promote=true
fi

# Additional checks for milestone mode
if [ "$promotion_mode" = "milestone" ] && [ "$can_promote" = true ]; then
  local milestone_complete
  milestone_complete=$(echo "$milestone_completeness" | jq -r '.complete')
  if [ "$milestone_complete" != "true" ]; then
    can_promote=false
    local reason
    reason=$(echo "$milestone_completeness" | jq -r '.reason // "milestone incomplete"')
    block_reasons=$(echo "$block_reasons" | jq --arg reason "$reason" '. + [$reason]')
  fi
fi

# Additional checks for selective mode
if [ "$promotion_mode" = "selective" ] && [ "$can_promote" = true ]; then
  local pr_count
  pr_count=$(echo "$selective_prs" | jq 'length' 2>/dev/null || echo 0)
  if [ "$pr_count" -eq 0 ]; then
    can_promote=false
    block_reasons=$(echo "$block_reasons" | jq '. + ["no PRs with promote:qa label"]')
  fi
fi

# Get changelog if requested
changelog='null'
if [ "$INCLUDE_CHANGELOG" = true ] && [ "$ahead" -gt 0 ]; then
  commits=$(get_commits)
  changelog=$(categorize_commits "$commits")

  # Cache the changelog for later use in qa→main promotion
  # This reduces API calls during the final release step
  if type cache_promotion_metadata >/dev/null 2>&1 && [ "$changelog" != "null" ]; then
    # Get PR number if available (will be set when this is used from auto-promote-to-qa.sh)
    local pr_num="${PR_NUMBER:-0}"
    cache_promotion_metadata "dev" "qa" "$pr_num" "" "$changelog" 2>/dev/null || true
  fi
fi

# Run release readiness gate if requested
release_readiness='null'
if [ "$RUN_RELEASE_GATE" = true ]; then
  RELEASE_SCRIPT="$SCRIPT_DIR/release-readiness.sh"
  if [ -f "$RELEASE_SCRIPT" ]; then
    RELEASE_REPORT_FILE="/tmp/pr-to-qa-release-gate-$$.json"
    RELEASE_GATE_ARGS=(--target-branch dev --report "$RELEASE_REPORT_FILE" --no-report)

    if [ "$RELEASE_GATE_DRY_RUN" = true ]; then
      RELEASE_GATE_ARGS+=(--dry-run)
    fi

    RELEASE_EXIT=0
    "$RELEASE_SCRIPT" HEAD "${RELEASE_GATE_ARGS[@]}" >/dev/null 2>&1 || RELEASE_EXIT=$?

    # Re-run with --report to actually write the JSON report
    RELEASE_GATE_ARGS=(--target-branch dev --report "$RELEASE_REPORT_FILE")
    if [ "$RELEASE_GATE_DRY_RUN" = true ]; then
      RELEASE_GATE_ARGS+=(--dry-run)
    fi
    "$RELEASE_SCRIPT" HEAD "${RELEASE_GATE_ARGS[@]}" >/dev/null 2>&1 || true

    if [ -f "$RELEASE_REPORT_FILE" ]; then
      release_readiness=$(cat "$RELEASE_REPORT_FILE")
      rm -f "$RELEASE_REPORT_FILE"
    else
      # Build minimal status from exit code
      GATE_STATUS="unknown"
      case "$RELEASE_EXIT" in
        0) GATE_STATUS="ready" ;;
        1) GATE_STATUS="blocked" ;;
        2) GATE_STATUS="ready_with_warnings" ;;
      esac
      release_readiness="{\"status\":\"$GATE_STATUS\",\"exit_code\":$RELEASE_EXIT}"
    fi

    # Block promotion if release gate is blocked
    if [ "$RELEASE_EXIT" -eq 1 ]; then
      block_reasons=$(echo "$block_reasons" | jq '. + ["release readiness gate failed (blocking gates)"]')
      can_promote=false
    fi
  else
    release_readiness='{"status":"skip","reason":"release-readiness.sh not found"}'
  fi
fi

cat <<EOF
{
  "branch_state": $branch_state,
  "branch_divergence": $branch_divergence,
  "qa_branch_exists": $qa_exists,
  "promotion_mode": "$promotion_mode",
  "milestone_filter": $([ -n "$MILESTONE_FILTER" ] && echo "\"$MILESTONE_FILTER\"" || echo "null"),
  "selective_mode": $SELECTIVE_MODE,
  "readiness": {
    "ci_status": "$ci_status",
    "open_prs_to_dev": $open_prs,
    "can_promote": $can_promote,
    "block_reasons": $block_reasons
  },
  "existing_pr": $existing_pr,
  "changelog": $changelog,
  "release_readiness": $release_readiness,
  "milestone_completeness": $milestone_completeness,
  "selective_prs": $selective_prs,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
