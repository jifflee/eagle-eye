#!/bin/bash
set -euo pipefail
# update-pr-status.sh
# Updates pr-status.json for PR review state tracking
#
# Usage:
#   ./scripts/update-pr-status.sh --issue N --init                    # Initialize new status file
#   ./scripts/update-pr-status.sh --issue N --status approved         # Update review status
#   ./scripts/update-pr-status.sh --issue N --register-file FILE --agent AGENT  # Register file ownership
#   ./scripts/update-pr-status.sh --issue N --add-issue '{"file":...}'          # Add blocking issue
#   ./scripts/update-pr-status.sh --issue N --fix-issue ID --commit SHA         # Mark issue fixed
#   ./scripts/update-pr-status.sh --issue N --add-reviewer AGENT                # Record reviewer ran
#   ./scripts/update-pr-status.sh --issue N --set-pr PR_NUM                     # Set PR number
#   ./scripts/update-pr-status.sh --issue N --sync-github                       # Sync GitHub state
#
# Options:
#   --issue N           Required: Issue number (used to locate status file)
#   --init              Initialize a new pr-status.json file
#   --status STATUS     Set review_state.status (pending|in_review|needs_fixes|approved|merged)
#   --register-file F   Register a file as written by --agent
#   --agent AGENT       Agent name (required with --register-file)
#   --add-issue JSON    Add a blocking issue from review (JSON object)
#   --fix-issue ID      Mark a blocking issue as fixed
#   --commit SHA        Commit SHA (used with --fix-issue)
#   --add-reviewer A    Add reviewer to reviewers_run list
#   --set-pr N          Set the PR number
#   --sync-github       Sync github_state from GitHub API
#   --dry-run           Show what would be changed without writing
#
# Environment:
#   PR_STATUS_FILE      Override status file location
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Status file not found (and not --init)
#   3 - jq error

set -e

# Configuration
SCHEMA_VERSION="1.0.0"

# Parse arguments
ISSUE_NUMBER=""
ACTION=""
STATUS_VALUE=""
FILE_PATH=""
AGENT_NAME=""
ISSUE_JSON=""
FIX_ISSUE_ID=""
COMMIT_SHA=""
REVIEWER_NAME=""
PR_NUMBER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --issue)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --init)
      ACTION="init"
      shift
      ;;
    --status)
      ACTION="status"
      STATUS_VALUE="$2"
      shift 2
      ;;
    --register-file)
      ACTION="register_file"
      FILE_PATH="$2"
      shift 2
      ;;
    --agent)
      AGENT_NAME="$2"
      shift 2
      ;;
    --add-issue)
      ACTION="add_issue"
      ISSUE_JSON="$2"
      shift 2
      ;;
    --fix-issue)
      ACTION="fix_issue"
      FIX_ISSUE_ID="$2"
      shift 2
      ;;
    --commit)
      COMMIT_SHA="$2"
      shift 2
      ;;
    --add-reviewer)
      ACTION="add_reviewer"
      REVIEWER_NAME="$2"
      shift 2
      ;;
    --set-pr)
      ACTION="set_pr"
      PR_NUMBER="$2"
      shift 2
      ;;
    --sync-github)
      ACTION="sync_github"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      head -50 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [ -z "$ISSUE_NUMBER" ]; then
  echo "Error: --issue N is required" >&2
  exit 1
fi

if [ -z "$ACTION" ]; then
  echo "Error: No action specified" >&2
  exit 1
fi

# Validate issue number is numeric
if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: Issue number must be numeric" >&2
  exit 1
fi

# Find or create status file location
find_status_file() {
  local issue="$1"

  # Check environment override
  if [ -n "$PR_STATUS_FILE" ]; then
    echo "$PR_STATUS_FILE"
    return 0
  fi

  # Check current directory (worktree context)
  if [ -f "pr-status.json" ]; then
    echo "pr-status.json"
    return 0
  fi

  # Check .worktrees/issue-N/
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$repo_root" ] && [ -f "$repo_root/.worktrees/issue-$issue/pr-status.json" ]; then
    echo "$repo_root/.worktrees/issue-$issue/pr-status.json"
    return 0
  fi

  # Check /tmp/worker-N/ (container context)
  if [ -f "/tmp/worker-$issue/pr-status.json" ]; then
    echo "/tmp/worker-$issue/pr-status.json"
    return 0
  fi

  # Check /workspace/ (container root)
  if [ -f "/workspace/pr-status.json" ]; then
    echo "/workspace/pr-status.json"
    return 0
  fi

  # Default location for new files
  echo "pr-status.json"
  return 1
}

# Get the status file path
STATUS_FILE=$(find_status_file "$ISSUE_NUMBER") || true

# Determine branch name
get_branch_name() {
  local issue="$1"
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "")
  if [ -z "$branch" ]; then
    branch="feat/issue-$issue"
  fi
  echo "$branch"
}

# Initialize a new status file
init_status() {
  local issue="$1"
  local branch
  branch=$(get_branch_name "$issue")
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat <<EOF
{
  "version": "$SCHEMA_VERSION",
  "issue_number": $issue,
  "pr_number": null,
  "branch": "$branch",
  "review_state": {
    "status": "pending",
    "iteration": 0,
    "last_review": null,
    "reviewers_run": []
  },
  "implementation_agents": {},
  "blocking_issues": [],
  "github_state": {
    "mergeable": null,
    "merge_state": null,
    "ci_status": null,
    "checks": []
  },
  "history": [],
  "metadata": {
    "created_at": "$timestamp",
    "updated_at": "$timestamp",
    "sprint_work_version": "2.0"
  }
}
EOF
}

# Update timestamp in metadata
update_timestamp() {
  local json="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "$json" | jq --arg ts "$timestamp" '.metadata.updated_at = $ts'
}

# Read current status file
read_status() {
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "{}"
  fi
}

# Write status file
write_status() {
  local json="$1"

  if [ "$DRY_RUN" = true ]; then
    echo "=== DRY RUN: Would write to $STATUS_FILE ===" >&2
    echo "$json" | jq .
    return 0
  fi

  # Ensure parent directory exists
  local dir
  dir=$(dirname "$STATUS_FILE")
  if [ "$dir" != "." ] && [ ! -d "$dir" ]; then
    mkdir -p "$dir"
  fi

  # Write with pretty formatting
  echo "$json" | jq . > "$STATUS_FILE"
  echo "Updated: $STATUS_FILE" >&2
}

# Execute the requested action
case "$ACTION" in
  init)
    if [ -f "$STATUS_FILE" ] && [ "$DRY_RUN" != true ]; then
      echo "Warning: Status file already exists at $STATUS_FILE" >&2
      echo "Use a different action to update it" >&2
      exit 0
    fi
    STATUS_FILE="${STATUS_FILE:-pr-status.json}"
    NEW_STATUS=$(init_status "$ISSUE_NUMBER")
    write_status "$NEW_STATUS"
    ;;

  status)
    # Validate status value
    case "$STATUS_VALUE" in
      pending|in_review|needs_fixes|approved|merged) ;;
      *)
        echo "Error: Invalid status value: $STATUS_VALUE" >&2
        echo "Valid values: pending, in_review, needs_fixes, approved, merged" >&2
        exit 1
        ;;
    esac

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    CURRENT=$(read_status)
    UPDATED=$(echo "$CURRENT" | jq --arg status "$STATUS_VALUE" '.review_state.status = $status')

    # If moving to in_review, increment iteration
    if [ "$STATUS_VALUE" = "in_review" ]; then
      UPDATED=$(echo "$UPDATED" | jq '.review_state.iteration += 1 | .review_state.reviewers_run = []')
      # Add history entry
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      ITERATION=$(echo "$UPDATED" | jq '.review_state.iteration')
      UPDATED=$(echo "$UPDATED" | jq --arg ts "$TIMESTAMP" --argjson iter "$ITERATION" \
        '.history += [{"iteration": $iter, "timestamp": $ts, "action": "review_started", "details": {}}]')
    fi

    # If approved or merged, add history entry
    if [ "$STATUS_VALUE" = "approved" ] || [ "$STATUS_VALUE" = "merged" ]; then
      TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      ITERATION=$(echo "$UPDATED" | jq '.review_state.iteration')
      UPDATED=$(echo "$UPDATED" | jq --arg ts "$TIMESTAMP" --argjson iter "$ITERATION" --arg action "$STATUS_VALUE" \
        '.history += [{"iteration": $iter, "timestamp": $ts, "action": $action, "details": {}}]')
      UPDATED=$(echo "$UPDATED" | jq --arg ts "$TIMESTAMP" '.review_state.last_review = $ts')
    fi

    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  register_file)
    if [ -z "$FILE_PATH" ]; then
      echo "Error: --register-file requires a file path" >&2
      exit 1
    fi
    if [ -z "$AGENT_NAME" ]; then
      echo "Error: --register-file requires --agent" >&2
      exit 1
    fi

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    CURRENT=$(read_status)
    # Add file to agent's list if not already present
    UPDATED=$(echo "$CURRENT" | jq --arg agent "$AGENT_NAME" --arg file "$FILE_PATH" '
      .implementation_agents[$agent] = (
        (.implementation_agents[$agent] // []) + [$file] | unique
      )
    ')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  add_issue)
    if [ -z "$ISSUE_JSON" ]; then
      echo "Error: --add-issue requires a JSON object" >&2
      exit 1
    fi

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    # Validate JSON
    if ! echo "$ISSUE_JSON" | jq . >/dev/null 2>&1; then
      echo "Error: Invalid JSON for --add-issue" >&2
      exit 1
    fi

    CURRENT=$(read_status)
    ITERATION=$(echo "$CURRENT" | jq '.review_state.iteration')
    COUNT=$(echo "$CURRENT" | jq '.blocking_issues | length')
    REVIEWER=$(echo "$ISSUE_JSON" | jq -r '.reviewer // "unknown"')

    # Generate ID if not provided
    ISSUE_ID=$(echo "$ISSUE_JSON" | jq -r '.id // empty')
    if [ -z "$ISSUE_ID" ]; then
      ISSUE_ID="${REVIEWER}-${ITERATION}-${COUNT}"
    fi

    # Determine owning agent from file
    FILE=$(echo "$ISSUE_JSON" | jq -r '.file // ""')
    OWNING_AGENT="unknown"
    if [ -n "$FILE" ]; then
      # Find which agent owns this file
      OWNING_AGENT=$(echo "$CURRENT" | jq -r --arg file "$FILE" '
        .implementation_agents | to_entries[] |
        select(.value[] == $file) | .key
      ' | head -1)
      [ -z "$OWNING_AGENT" ] && OWNING_AGENT="unknown"
    fi

    # Build complete issue object
    COMPLETE_ISSUE=$(echo "$ISSUE_JSON" | jq --arg id "$ISSUE_ID" --arg owner "$OWNING_AGENT" '
      . + {
        "id": $id,
        "owning_agent": (.owning_agent // $owner),
        "status": (.status // "open"),
        "fix_commit": (.fix_commit // null)
      }
    ')

    UPDATED=$(echo "$CURRENT" | jq --argjson issue "$COMPLETE_ISSUE" '.blocking_issues += [$issue]')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  fix_issue)
    if [ -z "$FIX_ISSUE_ID" ]; then
      echo "Error: --fix-issue requires an issue ID" >&2
      exit 1
    fi

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found." >&2
      exit 2
    fi

    CURRENT=$(read_status)

    # Check if issue exists
    EXISTS=$(echo "$CURRENT" | jq --arg id "$FIX_ISSUE_ID" '.blocking_issues | map(select(.id == $id)) | length')
    if [ "$EXISTS" = "0" ]; then
      echo "Error: Issue ID not found: $FIX_ISSUE_ID" >&2
      exit 1
    fi

    UPDATED=$(echo "$CURRENT" | jq --arg id "$FIX_ISSUE_ID" --arg commit "${COMMIT_SHA:-}" '
      .blocking_issues = [
        .blocking_issues[] |
        if .id == $id then
          . + {"status": "fixed", "fix_commit": (if $commit != "" then $commit else null end)}
        else
          .
        end
      ]
    ')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  add_reviewer)
    if [ -z "$REVIEWER_NAME" ]; then
      echo "Error: --add-reviewer requires a reviewer name" >&2
      exit 1
    fi

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    CURRENT=$(read_status)
    UPDATED=$(echo "$CURRENT" | jq --arg reviewer "$REVIEWER_NAME" '
      .review_state.reviewers_run = (
        (.review_state.reviewers_run // []) + [$reviewer] | unique
      )
    ')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  set_pr)
    if [ -z "$PR_NUMBER" ]; then
      echo "Error: --set-pr requires a PR number" >&2
      exit 1
    fi

    if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
      echo "Error: PR number must be numeric" >&2
      exit 1
    fi

    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    CURRENT=$(read_status)
    UPDATED=$(echo "$CURRENT" | jq --argjson pr "$PR_NUMBER" '.pr_number = $pr')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  sync_github)
    if [ ! -f "$STATUS_FILE" ]; then
      echo "Error: Status file not found. Use --init first." >&2
      exit 2
    fi

    CURRENT=$(read_status)
    PR_NUM=$(echo "$CURRENT" | jq -r '.pr_number // empty')

    if [ -z "$PR_NUM" ] || [ "$PR_NUM" = "null" ]; then
      echo "Error: No PR number set. Use --set-pr first." >&2
      exit 1
    fi

    # Fetch GitHub PR state
    GH_STATE=$(gh pr view "$PR_NUM" --json mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null || echo '{}')

    if [ "$GH_STATE" = "{}" ]; then
      echo "Warning: Could not fetch PR state from GitHub" >&2
      exit 0
    fi

    MERGEABLE=$(echo "$GH_STATE" | jq '.mergeable')
    MERGE_STATE=$(echo "$GH_STATE" | jq -r '.mergeStateStatus // "unknown"')

    # Parse CI status from checks
    CHECKS=$(echo "$GH_STATE" | jq '.statusCheckRollup // []')
    CI_STATUS="pending"
    if echo "$CHECKS" | jq -e 'length > 0' >/dev/null; then
      FAILURE=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "failure")] | length')
      SUCCESS=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == "SUCCESS" or .conclusion == "success")] | length')
      PENDING=$(echo "$CHECKS" | jq '[.[] | select(.conclusion == null or .conclusion == "")] | length')
      TOTAL=$(echo "$CHECKS" | jq 'length')

      if [ "$FAILURE" -gt 0 ]; then
        CI_STATUS="failure"
      elif [ "$PENDING" -gt 0 ]; then
        CI_STATUS="pending"
      elif [ "$SUCCESS" = "$TOTAL" ]; then
        CI_STATUS="success"
      fi
    fi

    # Build checks array
    CHECKS_ARRAY=$(echo "$CHECKS" | jq '[.[] | {
      name: .name,
      status: (if .status then .status else "completed" end),
      conclusion: .conclusion
    }]')

    UPDATED=$(echo "$CURRENT" | jq \
      --argjson mergeable "$MERGEABLE" \
      --arg merge_state "$MERGE_STATE" \
      --arg ci_status "$CI_STATUS" \
      --argjson checks "$CHECKS_ARRAY" '
      .github_state = {
        mergeable: $mergeable,
        merge_state: $merge_state,
        ci_status: $ci_status,
        checks: $checks
      }
    ')
    UPDATED=$(update_timestamp "$UPDATED")
    write_status "$UPDATED"
    ;;

  *)
    echo "Error: Unknown action: $ACTION" >&2
    exit 1
    ;;
esac
