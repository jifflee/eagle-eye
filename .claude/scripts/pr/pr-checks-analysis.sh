#!/bin/bash
set -euo pipefail
# pr-checks-analysis.sh
# Analyzes PR checks and provides remediation guidance for failing checks
#
# Usage: ./scripts/pr-checks-analysis.sh <PR_NUMBER>
#        ./scripts/pr-checks-analysis.sh --milestone <MILESTONE>
#
# Outputs JSON with check status, failures, and remediation suggestions

set -e

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

# Parse arguments
PR_NUMBER=""
MILESTONE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    *)
      PR_NUMBER="$1"
      shift
      ;;
  esac
done

# Function to analyze a single PR
analyze_pr() {
  local pr_num="$1"

  # Get PR checks (detailsUrl may not be available in all gh versions)
  local checks
  checks=$(gh pr checks "$pr_num" --json name,state,description 2>/dev/null || echo '[]')

  # Get PR merge status
  local pr_info
  pr_info=$(gh pr view "$pr_num" --json mergeable,mergeStateStatus,reviewDecision,isDraft 2>/dev/null || echo '{}')

  local mergeable merge_state review_decision is_draft
  mergeable=$(echo "$pr_info" | jq -r '.mergeable // "UNKNOWN"')
  merge_state=$(echo "$pr_info" | jq -r '.mergeStateStatus // "UNKNOWN"')
  review_decision=$(echo "$pr_info" | jq -r '.reviewDecision // ""')
  is_draft=$(echo "$pr_info" | jq -r '.isDraft // false')

  # Analyze checks
  local analysis
  analysis=$(echo "$checks" | jq '
    {
      total: length,
      passed: [.[] | select(.state == "SUCCESS" or .state == "SKIPPED")] | length,
      failed: [.[] | select(.state == "FAILURE")] | length,
      pending: [.[] | select(.state == "PENDING" or .state == "QUEUED")] | length,
      failures: [.[] | select(.state == "FAILURE") | {
        name: .name,
        description: (.description // "")
      }],
      pending_checks: [.[] | select(.state == "PENDING" or .state == "QUEUED") | .name]
    }
  ')

  # Generate remediation suggestions based on check names
  local remediations
  remediations=$(echo "$analysis" | jq '
    .failures | map({
      check: .name,
      suggestion: (
        if .name | test("lint|eslint|prettier"; "i") then
          "Run `npm run lint:fix` or `make lint-fix` to auto-fix linting issues"
        elif .name | test("test|jest|pytest|vitest"; "i") then
          "Run tests locally with `npm test` or `make test` to see failures"
        elif .name | test("type|typescript|tsc"; "i") then
          "Run `npm run type-check` or `tsc --noEmit` to see type errors"
        elif .name | test("build"; "i") then
          "Run `npm run build` or `make build` locally to debug build failures"
        elif .name | test("security|snyk|dependabot"; "i") then
          "Review security alerts and update vulnerable dependencies"
        elif .name | test("coverage"; "i") then
          "Add more tests to meet coverage threshold"
        elif .name | test("validate|check-pr"; "i") then
          "Check workflow requirements - may need PR to exist first or meet naming conventions"
        else
          "Check GitHub Actions run for details"
        end
      )
    })
  ')

  # Determine overall status and recommended action
  local can_merge recommended_action
  if [ "$is_draft" = "true" ]; then
    can_merge="false"
    recommended_action="Mark PR as ready for review"
  elif [ "$merge_state" = "CLEAN" ] && [ "$review_decision" = "APPROVED" ]; then
    can_merge="true"
    recommended_action="Ready to merge"
  elif [ "$merge_state" = "CLEAN" ]; then
    can_merge="false"
    recommended_action="Awaiting review approval"
  elif [ "$merge_state" = "UNSTABLE" ]; then
    can_merge="false"
    recommended_action="Fix failing CI checks"
  elif [ "$merge_state" = "BLOCKED" ]; then
    can_merge="false"
    recommended_action="Resolve merge conflicts or policy blocks"
  elif [ "$merge_state" = "BEHIND" ]; then
    can_merge="false"
    recommended_action="Update branch with base"
  else
    can_merge="false"
    recommended_action="Waiting for checks to complete"
  fi

  # Build output
  jq -n \
    --argjson analysis "$analysis" \
    --argjson remediations "$remediations" \
    --arg pr_number "$pr_num" \
    --arg mergeable "$mergeable" \
    --arg merge_state "$merge_state" \
    --arg review_decision "$review_decision" \
    --argjson is_draft "$is_draft" \
    --argjson can_merge "$can_merge" \
    --arg recommended_action "$recommended_action" \
    '{
      pr_number: ($pr_number | tonumber),
      mergeable: $mergeable,
      merge_state: $merge_state,
      review_decision: $review_decision,
      is_draft: $is_draft,
      can_merge: $can_merge,
      recommended_action: $recommended_action,
      checks: $analysis,
      remediations: $remediations
    }'
}

# If single PR specified
if [ -n "$PR_NUMBER" ]; then
  analyze_pr "$PR_NUMBER"
  exit 0
fi

# If milestone specified, analyze all open PRs for that milestone
if [ -n "$MILESTONE" ]; then
  # Get milestone issue numbers
  MILESTONE_ISSUES=$(gh issue list --milestone "$MILESTONE" --state all --json number --jq '[.[].number]' 2>/dev/null)

  # Get all open PRs
  ALL_PRS=$(gh pr list --state open --json number,body 2>/dev/null)

  # Filter to PRs linked to milestone issues
  LINKED_PRS=$(echo "$ALL_PRS" | jq --argjson issues "$MILESTONE_ISSUES" '
    [.[] |
      . as $pr |
      (($pr.body // "") | capture("(?i)(?:fixes|closes|resolves) #(?<num>[0-9]+)") | .num | tonumber) as $linked |
      select($linked != null and ($issues | index($linked))) |
      .number
    ]
  ')

  # Analyze each PR
  RESULTS="[]"
  for pr_num in $(echo "$LINKED_PRS" | jq -r '.[]'); do
    pr_analysis=$(analyze_pr "$pr_num")
    RESULTS=$(echo "$RESULTS" | jq --argjson new "$pr_analysis" '. + [$new]')
  done

  # Summary
  echo "$RESULTS" | jq '{
    prs: .,
    summary: {
      total: length,
      ready_to_merge: [.[] | select(.can_merge == true)] | length,
      needs_fixes: [.[] | select(.checks.failed > 0)] | length,
      awaiting_review: [.[] | select(.merge_state == "CLEAN" and .review_decision == "")] | length
    }
  }'
  exit 0
fi

# No arguments - show usage
echo '{"error": "Usage: pr-checks-analysis.sh <PR_NUMBER> or --milestone <MILESTONE>"}'
exit 1
