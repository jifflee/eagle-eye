#!/bin/bash
# n8n-webhook.sh
# Claude Code hook for triggering n8n workflows via webhooks
#
# This hook can be attached to various Claude Code events to notify
# n8n of significant occurrences (PR created, work completed, etc.)
#
# Receives JSON via stdin with:
#   - tool_name: The tool that was used
#   - tool_input: Tool input parameters
#   - tool_response (PostToolUse only): Tool output
#   - session_id, cwd, hook_event_name
#
# Environment variables:
#   N8N_WEBHOOK_URL      Base URL for n8n webhooks (default: http://localhost:5678)
#   N8N_WEBHOOK_ENABLED  Enable/disable webhooks (default: true)
#   N8N_WEBHOOK_TIMEOUT  Timeout in seconds (default: 5)
#   N8N_WEBHOOK_ASYNC    Fire-and-forget mode (default: true)
#
# Exit codes: 0 = success (always returns 0 to not block Claude)

set -euo pipefail

# Configuration
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-http://localhost:5678}"
N8N_WEBHOOK_ENABLED="${N8N_WEBHOOK_ENABLED:-true}"
N8N_WEBHOOK_TIMEOUT="${N8N_WEBHOOK_TIMEOUT:-5}"
N8N_WEBHOOK_ASYNC="${N8N_WEBHOOK_ASYNC:-true}"

# Exit early if webhooks are disabled
if [[ "${N8N_WEBHOOK_ENABLED}" = "false" ]]; then
  exit 0
fi

# Read JSON from stdin
json_input=$(cat)

# Extract hook event type
hook_event="${HOOK_EVENT_NAME:-unknown}"
if [[ "${hook_event}" = "unknown" ]]; then
  hook_event=$(echo "${json_input}" | jq -r '.hook_event_name // "unknown"')
fi

# Extract common fields
tool_name=$(echo "${json_input}" | jq -r '.tool_name // ""')
session_id=$(echo "${json_input}" | jq -r '.session_id // ""')
cwd=$(echo "${json_input}" | jq -r '.cwd // ""')

# Helper: Send webhook notification
send_webhook() {
  local path="$1"
  local payload="$2"
  local url="${N8N_WEBHOOK_URL}/webhook/${path}"

  # Add timestamp and metadata to payload
  payload=$(echo "${payload}" | jq \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg session_id "${session_id}" \
    --arg source "claude-code-hook" \
    '. + {timestamp: $timestamp, session_id: $session_id, source: $source}')

  if [[ "${N8N_WEBHOOK_ASYNC}" = "true" ]]; then
    # Fire-and-forget: don't wait for response
    curl -sf -X POST "${url}" \
      -H "Content-Type: application/json" \
      -d "${payload}" \
      --max-time "${N8N_WEBHOOK_TIMEOUT}" \
      >/dev/null 2>&1 &
  else
    # Synchronous: wait for response (but don't block on failure)
    curl -sf -X POST "${url}" \
      -H "Content-Type: application/json" \
      -d "${payload}" \
      --max-time "${N8N_WEBHOOK_TIMEOUT}" \
      >/dev/null 2>&1 || true
  fi
}

# Helper: Detect if we're in a worktree and get issue number
get_issue_context() {
  local worktree_name issue_number=""

  # Try to detect from directory name
  worktree_name=$(basename "${cwd}")
  if [[ "${worktree_name}" =~ -issue-([0-9]+)$ ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi

  # Try to detect from environment
  if [[ -z "${issue_number}" ]] && [[ -n "${SPRINT_ISSUE:-}" ]]; then
    issue_number="${SPRINT_ISSUE}"
  fi

  # Try to detect from sprint state
  if [[ -z "${issue_number}" ]] && [[ -f "${cwd}/.sprint-state.json" ]]; then
    issue_number=$(jq -r '.issue.number // empty' "${cwd}/.sprint-state.json" 2>/dev/null || true)
  fi

  echo "${issue_number}"
}

# Helper: Get repository info
get_repo_info() {
  local repo=""
  if command -v gh &>/dev/null; then
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || true)
  fi
  if [[ -z "${repo}" ]]; then
    repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+/[^.]+)(\.git)?$|\1|' || true)
  fi
  echo "${repo}"
}

# ============================================================
# Event Handlers
# ============================================================

# Handle PR creation (gh pr create)
handle_pr_created() {
  local command="$1"
  local output="$2"

  # Extract PR number from output (gh pr create outputs the PR URL)
  local pr_number pr_url
  pr_url=$(echo "${output}" | grep -oE 'https://github.com/[^/]+/[^/]+/pull/[0-9]+' | head -1 || true)
  pr_number=$(echo "${pr_url}" | grep -oE '[0-9]+$' || true)

  if [[ -n "${pr_number}" ]]; then
    local issue_number repo
    issue_number=$(get_issue_context)
    repo=$(get_repo_info)

    local payload
    payload=$(jq -n \
      --arg event "pr_created" \
      --arg pr_number "${pr_number}" \
      --arg pr_url "${pr_url}" \
      --arg issue_number "${issue_number}" \
      --arg repo "${repo}" \
      '{event: $event, pr_number: $pr_number, pr_url: $pr_url, issue_number: $issue_number, repo: $repo}')

    send_webhook "github-pr-events" "${payload}"

    # Also trigger PR validation workflow (replaces pr-creation-validate.sh hook)
    # Issue #654: Migrated from shell hook to n8n for retry, error handling, monitoring
    send_webhook "pr-creation-validate" "${payload}"
  fi
}

# Handle PR merge (gh pr merge)
handle_pr_merged() {
  local command="$1"

  # Extract PR number from command
  local pr_number
  pr_number=$(echo "${command}" | grep -oE 'gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' || true)

  if [[ -n "${pr_number}" ]]; then
    local repo
    repo=$(get_repo_info)

    local payload
    payload=$(jq -n \
      --arg event "pr_merged" \
      --arg pr_number "${pr_number}" \
      --arg repo "${repo}" \
      '{event: $event, pr_number: $pr_number, repo: $repo}')

    send_webhook "github-pr-events" "${payload}"
  fi
}

# Handle issue state changes
handle_issue_update() {
  local command="$1"
  local action=""

  # Detect action from command
  if [[ "${command}" =~ gh[[:space:]]issue[[:space:]]close ]]; then
    action="closed"
  elif [[ "${command}" =~ --add-label[[:space:]]\"?in-progress ]]; then
    action="started"
  elif [[ "${command}" =~ --add-label[[:space:]]\"?blocked ]]; then
    action="blocked"
  elif [[ "${command}" =~ --remove-label[[:space:]]\"?in-progress ]]; then
    action="paused"
  fi

  if [[ -n "${action}" ]]; then
    # Extract issue number from command
    local issue_number
    issue_number=$(echo "${command}" | grep -oE 'gh[[:space:]]+issue[[:space:]]+(edit|close)[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)

    # Fallback to context
    if [[ -z "${issue_number}" ]]; then
      issue_number=$(get_issue_context)
    fi

    if [[ -n "${issue_number}" ]]; then
      local repo
      repo=$(get_repo_info)

      local payload
      payload=$(jq -n \
        --arg event "issue_update" \
        --arg action "${action}" \
        --arg issue_number "${issue_number}" \
        --arg repo "${repo}" \
        '{event: $event, action: $action, issue_number: $issue_number, repo: $repo}')

      send_webhook "github-issue-webhook" "${payload}"
    fi
  fi
}

# Handle work completion (sprint-work creates work-state.json updates)
handle_work_completed() {
  local command="$1"
  local exit_code="$2"

  # Check if this is a sprint completion script
  if [[ "${command}" =~ sprint-orchestrator|worktree-complete|container-sprint-workflow ]]; then
    local issue_number repo status
    issue_number=$(get_issue_context)
    repo=$(get_repo_info)
    status=$( [[ "${exit_code}" = "0" ]] && echo "success" || echo "failure" )

    local payload
    payload=$(jq -n \
      --arg event "work_completed" \
      --arg status "${status}" \
      --arg issue_number "${issue_number}" \
      --arg repo "${repo}" \
      --arg exit_code "${exit_code}" \
      '{event: $event, status: $status, issue_number: $issue_number, repo: $repo, exit_code: $exit_code}')

    send_webhook "work-completed" "${payload}"
  fi
}

# Handle container status (for container monitoring)
handle_container_event() {
  local command="$1"
  local output="$2"

  # Check for container-related commands
  if [[ "${command}" =~ container-launch|docker[[:space:]]run|docker[[:space:]]kill ]]; then
    local issue_number container_name action
    issue_number=$(get_issue_context)

    if [[ "${command}" =~ docker[[:space:]]kill ]]; then
      action="stopped"
      container_name=$(echo "${command}" | grep -oE 'claude-tastic-issue-[0-9]+' || true)
    elif [[ "${command}" =~ container-launch ]]; then
      action="launched"
      container_name="claude-tastic-issue-${issue_number}"
    else
      action="started"
      container_name=$(echo "${command}" | grep -oE 'claude-tastic-issue-[0-9]+' || true)
    fi

    if [[ -n "${container_name}" ]]; then
      local repo
      repo=$(get_repo_info)

      local payload
      payload=$(jq -n \
        --arg event "container_event" \
        --arg action "${action}" \
        --arg container "${container_name}" \
        --arg issue_number "${issue_number}" \
        --arg repo "${repo}" \
        '{event: $event, action: $action, container: $container, issue_number: $issue_number, repo: $repo}')

      send_webhook "container-events" "${payload}"
    fi
  fi
}

# ============================================================
# Main Event Router
# ============================================================

# Only process PostToolUse events
if [[ "${hook_event}" != "PostToolUse" ]]; then
  exit 0
fi

# Only process Bash tool for now
if [[ "${tool_name}" != "Bash" ]]; then
  exit 0
fi

# Extract command and response
command=$(echo "${json_input}" | jq -r '.tool_input.command // ""')
exit_code=$(echo "${json_input}" | jq -r '.tool_response.exit_code // 0')
stdout=$(echo "${json_input}" | jq -r '.tool_response.stdout // ""')

# Skip if no command
if [[ -z "${command}" ]]; then
  exit 0
fi

# Skip if command failed (usually not interesting for notifications)
# Exception: work completion failures ARE interesting
if [[ "${exit_code}" != "0" ]] && ! [[ "${command}" =~ sprint-orchestrator|worktree-complete ]]; then
  exit 0
fi

# Route to appropriate handler based on command pattern
# Using if/elif for more reliable pattern matching
if [[ "${command}" == *"gh pr create"* ]]; then
  handle_pr_created "${command}" "${stdout}"
elif [[ "${command}" == *"gh pr merge"* ]]; then
  handle_pr_merged "${command}"
elif [[ "${command}" == *"gh issue"*"--add-label"* ]] || [[ "${command}" == *"gh issue"*"--remove-label"* ]] || [[ "${command}" == *"gh issue close"* ]]; then
  handle_issue_update "${command}"
elif [[ "${command}" == *"sprint-orchestrator"* ]] || [[ "${command}" == *"worktree-complete"* ]] || [[ "${command}" == *"container-sprint-workflow"* ]]; then
  handle_work_completed "${command}" "${exit_code}"
elif [[ "${command}" == *"container-launch"* ]] || [[ "${command}" == *"docker run"* ]] || [[ "${command}" == *"docker kill"* ]]; then
  handle_container_event "${command}" "${stdout}"
fi

# Always exit 0 to not block Claude
exit 0
