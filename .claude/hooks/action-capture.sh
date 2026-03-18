#!/bin/bash
# action-capture.sh
# Claude Code hook for capturing Bash tool commands to action audit log
#
# Receives JSON via stdin with:
#   - tool_name: "Bash"
#   - tool_input: { command, description, timeout, ... }
#   - tool_response (PostToolUse only): { stdout, stderr, exit_code, ... }
#   - session_id, cwd, hook_event_name
#
# Usage:
#   PostToolUse hook: Logs completed commands to action audit log
#
# Exit codes: 0 = success (allow tool to proceed)

set -euo pipefail

# Get project root from env or derive from script location
get_main_repo() {
  local script_dir toplevel git_common main_git
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  toplevel=$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null) || echo "${script_dir}"

  if [[ -f "${toplevel}/.git" ]]; then
    git_common=$(git -C "${toplevel}" rev-parse --git-common-dir 2>/dev/null)
    main_git="${git_common%/worktrees/*}"
    echo "${main_git%/.git}"
  else
    echo "${toplevel}"
  fi
}

PROJECT_ROOT=$(get_main_repo)
ACTION_LOG_SCRIPT="${PROJECT_ROOT}/scripts/action-log.sh"

# Check if action logging is enabled
if [[ "${CLAUDE_ACTION_LOG_ENABLED:-true}" = "false" ]]; then
  exit 0
fi

# Check if action log script exists
if [[ ! -x "${ACTION_LOG_SCRIPT}" ]]; then
  # Silently skip if action log script not available
  exit 0
fi

# Read JSON from stdin
json_input=$(cat)

# Extract hook event type
hook_event="${HOOK_EVENT_NAME:-unknown}"
if [[ "${hook_event}" = "unknown" ]]; then
  hook_event=$(echo "${json_input}" | jq -r '.hook_event_name // "unknown"')
fi

# Only process PostToolUse events (we log completed commands)
if [[ "${hook_event}" != "PostToolUse" ]]; then
  exit 0
fi

# Extract tool info
tool_name=$(echo "${json_input}" | jq -r '.tool_name // ""')

# Only process Bash tool
if [[ "${tool_name}" != "Bash" ]]; then
  exit 0
fi

# Extract command and response
command=$(echo "${json_input}" | jq -r '.tool_input.command // ""')
# shellcheck disable=SC2034
description=$(echo "${json_input}" | jq -r '.tool_input.description // ""')
# shellcheck disable=SC2034
session_id=$(echo "${json_input}" | jq -r '.session_id // ""')

# Extract response info
exit_code=$(echo "${json_input}" | jq -r '.tool_response.exit_code // 0')
duration_ms=$(echo "${json_input}" | jq -r '.tool_response.duration_ms // 0')

# Skip if no command
if [[ -z "${command}" ]]; then
  exit 0
fi

# Determine status from exit code
status="success"
if [[ "${exit_code}" != "0" ]]; then
  status="failure"
fi

# Classify the command to determine category and operation
# Try to match common patterns
category="shell"
operation="unknown"

# GitHub CLI commands
if [[ "${command}" =~ ^gh[[:space:]] ]]; then
  category="github"
  if [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]list ]]; then
    operation="issue.list"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]view ]]; then
    operation="issue.view"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]create ]]; then
    operation="issue.create"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]edit.*--add-label ]]; then
    operation="issue.add-label"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]edit.*--remove-label ]]; then
    operation="issue.remove-label"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]edit ]]; then
    operation="issue.edit"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]close ]]; then
    operation="issue.close"
  elif [[ "${command}" =~ ^gh[[:space:]]issue[[:space:]]comment ]]; then
    operation="issue.comment"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]list ]]; then
    operation="pr.list"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]view ]]; then
    operation="pr.view"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]create ]]; then
    operation="pr.create"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]merge ]]; then
    operation="pr.merge"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]close ]]; then
    operation="pr.close"
  elif [[ "${command}" =~ ^gh[[:space:]]pr[[:space:]]checks ]]; then
    operation="pr.checks"
  elif [[ "${command}" =~ ^gh[[:space:]]api ]]; then
    operation="api.call"
  else
    operation="other"
  fi
# Git commands
elif [[ "${command}" =~ ^git[[:space:]] ]]; then
  category="git"
  if [[ "${command}" =~ ^git[[:space:]]status ]]; then
    operation="status"
  elif [[ "${command}" =~ ^git[[:space:]]log ]]; then
    operation="log"
  elif [[ "${command}" =~ ^git[[:space:]]diff ]]; then
    operation="diff"
  elif [[ "${command}" =~ ^git[[:space:]]show ]]; then
    operation="show"
  elif [[ "${command}" =~ ^git[[:space:]]branch ]]; then
    operation="branch.list"
  elif [[ "${command}" =~ ^git[[:space:]]checkout ]]; then
    operation="checkout"
  elif [[ "${command}" =~ ^git[[:space:]]add ]]; then
    operation="add"
  elif [[ "${command}" =~ ^git[[:space:]]commit ]]; then
    operation="commit"
  elif [[ "${command}" =~ ^git[[:space:]]push[[:space:]].*(-f|--force) ]]; then
    operation="push.force"
  elif [[ "${command}" =~ ^git[[:space:]]push ]]; then
    operation="push"
  elif [[ "${command}" =~ ^git[[:space:]]pull ]]; then
    operation="pull"
  elif [[ "${command}" =~ ^git[[:space:]]merge ]]; then
    operation="merge"
  elif [[ "${command}" =~ ^git[[:space:]]rebase ]]; then
    operation="rebase"
  elif [[ "${command}" =~ ^git[[:space:]]reset[[:space:]]--hard ]]; then
    operation="reset.hard"
  elif [[ "${command}" =~ ^git[[:space:]]clean ]]; then
    operation="clean"
  elif [[ "${command}" =~ ^git[[:space:]]stash ]]; then
    operation="stash"
  else
    operation="other"
  fi
# File operations
elif [[ "${command}" =~ ^(rm|mv|cp|mkdir)[[:space:]] ]]; then
  category="file"
  if [[ "${command}" =~ ^rm[[:space:]]+-r ]]; then
    operation="delete-recursive"
  elif [[ "${command}" =~ ^rm[[:space:]] ]]; then
    operation="delete"
  elif [[ "${command}" =~ ^mv[[:space:]] ]]; then
    operation="move"
  elif [[ "${command}" =~ ^cp[[:space:]] ]]; then
    operation="copy"
  elif [[ "${command}" =~ ^mkdir[[:space:]] ]]; then
    operation="create-dir"
  fi
# Script execution
elif [[ "${command}" =~ ^\./scripts/ ]]; then
  category="shell"
  # Extract script name
  script_name=$(echo "${command}" | sed -E 's|^\./scripts/([^[:space:]]+).*|\1|')
  operation="script.${script_name}"
fi

# Log the action (auto-classification will assign tier)
"${ACTION_LOG_SCRIPT}" \
  --source-type hook \
  --source-name "bash-capture" \
  --category "${category}" \
  --operation "${operation}" \
  --command "${command}" \
  --status "${status}" \
  --duration-ms "${duration_ms:-0}" \
  >/dev/null 2>&1 || true

# Always exit 0 to allow the tool to proceed
exit 0
