#!/bin/bash
set -euo pipefail
# sprint-status-repo-ci.sh
# Detects repo-level CI failures (failures on main branches: main, dev, qa)
# These are distinct from worktree/PR-level failures and need separate resolution
#
# Usage: ./scripts/sprint-status-repo-ci.sh
#
# Outputs JSON with repo-level CI status

set -e

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

# Main branches to check for repo-level CI failures
MAIN_BRANCHES=("main" "dev" "qa")

# Get list of active (not disabled) workflows
ACTIVE_WORKFLOWS=$(gh workflow list --json name,state 2>/dev/null | jq -r '[.[] | select(.state == "active") | .name] | @json')

# Get repo info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
  echo '{"available": false, "error": "Could not determine repository"}'
  exit 0
fi

# Function to get latest workflow runs for a branch
get_branch_ci_status() {
  local branch="$1"

  # Check if branch exists
  if ! gh api "repos/:owner/:repo/branches/$branch" &>/dev/null; then
    echo '[]'
    return
  fi

  # Get latest run for each workflow on this branch
  gh run list --branch "$branch" --limit 50 --json conclusion,workflowName,event,status,databaseId,createdAt,headSha 2>/dev/null | jq --arg branch "$branch" '
    # Group by workflow name and take most recent
    group_by(.workflowName) |
    map(sort_by(.createdAt) | reverse | .[0]) |
    # Filter to completed runs only and add branch info
    [.[] | select(.status == "completed") | . + {branch: $branch}]
  '
}

# Collect CI status for all main branches
ALL_BRANCH_STATUS="[]"
for branch in "${MAIN_BRANCHES[@]}"; do
  BRANCH_STATUS=$(get_branch_ci_status "$branch")
  ALL_BRANCH_STATUS=$(echo "$ALL_BRANCH_STATUS" | jq --argjson new "$BRANCH_STATUS" '. + $new')
done

# Analyze results (filter to only active workflows)
ANALYSIS=$(echo "$ALL_BRANCH_STATUS" | jq --argjson active "$ACTIVE_WORKFLOWS" '
  # Filter to only active workflows
  [.[] | select(.workflowName as $wf | $active | index($wf))] |
  # Separate failures from successes
  {
    failures: [.[] | select(.conclusion == "failure")],
    successes: [.[] | select(.conclusion == "success")],
    all_runs: .
  } |
  # Add summary stats
  . + {
    summary: {
      total_workflows: (.all_runs | length),
      failing: (.failures | length),
      passing: (.successes | length),
      branches_affected: (.failures | [.[].branch] | unique),
      has_failures: ((.failures | length) > 0)
    }
  } |
  # Generate remediation guidance for each failure
  . + {
    remediations: [.failures[] | {
      workflow: .workflowName,
      branch: .branch,
      run_id: .databaseId,
      guidance: (
        if .workflowName | test("protect-main|protect-qa"; "i") then
          "Branch protection workflow - check if branch needs to exist or if workflow conditions are met"
        elif .workflowName | test("validate"; "i") then
          "Validation workflow - run locally to identify issues: make validate or npm run validate"
        elif .workflowName | test("test"; "i") then
          "Test workflow - run tests locally: make test or npm test"
        elif .workflowName | test("standards|lint"; "i") then
          "Standards/lint workflow - run linting locally: make lint or npm run lint"
        elif .workflowName | test("auto-"; "i") then
          "Automation workflow - check workflow configuration and trigger conditions"
        else
          "Check GitHub Actions workflow logs for details"
        end
      ),
      view_command: "gh run view \(.databaseId) --log-failed"
    }]
  }
')

# Build final output
echo "$ANALYSIS" | jq '{
  available: true,
  repo_level_ci: {
    has_failures: .summary.has_failures,
    failing_count: .summary.failing,
    passing_count: .summary.passing,
    branches_affected: .summary.branches_affected,
    failures: [.failures[] | {
      workflow: .workflowName,
      branch: .branch,
      run_id: .databaseId,
      created_at: .createdAt
    }],
    remediations: .remediations
  }
}'
