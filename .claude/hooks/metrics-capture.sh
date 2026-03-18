#!/bin/bash
# metrics-capture.sh
# Claude Code hook for capturing Task tool invocations to metrics log
#
# Receives JSON via stdin with:
#   - tool_name: "Task"
#   - tool_input: { subagent_type, model, prompt, description, ... }
#   - tool_response (PostToolUse only): { output, usage.input_tokens, usage.output_tokens, ... }
#   - session_id, cwd, hook_event_name
#
# Usage:
#   PreToolUse hook: Logs invocation start, outputs invocation_id to env
#   PostToolUse hook: Updates invocation with completion status and token counts
#
# Phase detection:
#   SDLC_PHASE env var overrides automatic phase detection (for container workflows)
#   Otherwise, phase is inferred from subagent_type using SDLC phase mapping.
#   Valid phases: spec, design, implement, test, docs, review, deploy, other
#
# Exit codes: 0 = success (allow tool to proceed)

set -euo pipefail

# Get project root from env or derive from script location
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
METRICS_SCRIPT="$PROJECT_ROOT/scripts/metrics-log.sh"

# Check if metrics collection is enabled
if [ "${CLAUDE_METRICS_ENABLED:-true}" = "false" ]; then
  exit 0
fi

# Check if metrics script exists
if [ ! -x "$METRICS_SCRIPT" ]; then
  # Silently skip if metrics script not available
  exit 0
fi

# Read JSON from stdin
json_input=$(cat)

# Extract hook event type
hook_event="${HOOK_EVENT_NAME:-unknown}"
if [ "$hook_event" = "unknown" ]; then
  hook_event=$(echo "$json_input" | jq -r '.hook_event_name // "unknown"')
fi

# Extract tool info
tool_name=$(echo "$json_input" | jq -r '.tool_name // ""')

# Only process Task tool invocations
if [ "$tool_name" != "Task" ]; then
  exit 0
fi

# Extract Task tool parameters
subagent_type=$(echo "$json_input" | jq -r '.tool_input.subagent_type // "unknown"')
description=$(echo "$json_input" | jq -r '.tool_input.description // ""')

# Resolve model: explicit tool_input.model takes precedence,
# then look up the agent's configured model from its frontmatter,
# then fall back to haiku (default per CLAUDE.md 90% target).
#
# This ensures metrics accurately reflect the model used even when
# the Task tool call doesn't explicitly specify a model parameter.
resolve_agent_model() {
  local agent="$1"
  local explicit_model="$2"

  # Explicit model parameter always wins
  if [ -n "$explicit_model" ] && [ "$explicit_model" != "null" ]; then
    echo "$explicit_model"
    return
  fi

  # Look up model from agent config file frontmatter
  # Checks .claude/agents/<agent>.md for 'model:' field
  local agent_file="$PROJECT_ROOT/.claude/agents/${agent}.md"
  if [ -f "$agent_file" ]; then
    local file_model
    file_model=$(grep -E '^model:' "$agent_file" 2>/dev/null | head -1 | sed 's/model:[[:space:]]*//' | tr -d ' \t\r\n' || echo "")
    if [ -n "$file_model" ] && [ "$file_model" != "unspecified" ]; then
      echo "$file_model"
      return
    fi
  fi

  # Well-known sonnet agents (security requires elevated model)
  # Kept as fallback in case agent file is not found
  case "$agent" in
    security-iam-design|security-iam-prepr|pr-security-iam)
      echo "sonnet"
      return
      ;;
  esac

  # Default: haiku (90% target per AGENT_OPTIMIZATION.md)
  echo "haiku"
}

explicit_model=$(echo "$json_input" | jq -r '.tool_input.model // ""')
model=$(resolve_agent_model "$subagent_type" "$explicit_model")
prompt=$(echo "$json_input" | jq -r '.tool_input.prompt // ""')
session_id=$(echo "$json_input" | jq -r '.session_id // ""')

# Truncate description for storage (keep it lean)
if [ ${#description} -gt 100 ]; then
  description="${description:0:97}..."
fi

# Infer SDLC phase from subagent_type
# Maps agent names to SDLC phases: spec, design, implement, test, docs, review, deploy, other
# SDLC_PHASE env var overrides automatic detection (used by container workflows)
infer_sdlc_phase() {
  local agent="$1"

  # Allow container workflow or caller to override via environment variable
  if [ -n "${SDLC_PHASE:-}" ]; then
    echo "$SDLC_PHASE"
    return
  fi

  case "$agent" in
    # Spec / product definition phase
    product-spec-ux|epic-decompose|product-spec*)
      echo "spec"
      ;;
    # Design / architecture phase
    architect|api-designer|data-storage|security-iam-design)
      echo "design"
      ;;
    # Implementation phase
    backend-developer|frontend-developer|refactoring-specialist|database-migration|dependency-manager)
      echo "implement"
      ;;
    # Test / QA phase
    test-qa|pr-test)
      echo "test"
      ;;
    # Documentation phase
    documentation|documentation-librarian|pr-documentation)
      echo "docs"
      ;;
    # Review phase (code review, security review, PR review)
    code-reviewer|pr-code-reviewer|security-iam-prepr|pr-security-iam|guardrails-policy|performance-engineering)
      echo "review"
      ;;
    # Deploy / release phase
    deployment|cicd-workflow|repo-create-release)
      echo "deploy"
      ;;
    # Orchestration / planning (not a distinct SDLC phase but a cross-cutting concern)
    pm-orchestrator|general-purpose|Explore|Plan|Bash)
      echo "other"
      ;;
    # Issue/project management
    repo-workflow|milestone-manager|bug)
      echo "other"
      ;;
    # Default: unknown agent type
    *)
      echo "other"
      ;;
  esac
}

SDLC_PHASE_VALUE=$(infer_sdlc_phase "$subagent_type")

# State directory for correlating pre/post events
STATE_DIR="$PROJECT_ROOT/.claude/.metrics-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true
chmod 700 "$STATE_DIR" 2>/dev/null || true

# Clean up stale state files (older than 1 hour) to prevent accumulation
find "$STATE_DIR" -type f -mmin +60 -delete 2>/dev/null || true

# Create a deterministic key for correlation using session+agent+description hash
# This allows Pre and Post hooks (running in different processes) to correlate
# Include session_id to prevent collisions between concurrent sessions
state_key=$(printf '%s' "${session_id}:${subagent_type}:${description}" | md5sum 2>/dev/null | cut -c1-16 || \
            printf '%s' "${session_id}:${subagent_type}:${description}" | md5 2>/dev/null | cut -c1-16 || \
            printf '%s' "${session_id}_${subagent_type}_${description}" | tr ' ' '_' | cut -c1-32)
STATE_FILE="$STATE_DIR/$state_key"

case "$hook_event" in
  PreToolUse)
    # Start tracking the invocation with inferred SDLC phase
    invocation_id=$("$METRICS_SCRIPT" --start \
      --agent "$subagent_type" \
      --model "$model" \
      --phase "$SDLC_PHASE_VALUE" \
      --task "$description" 2>/dev/null || echo "")

    if [ -n "$invocation_id" ]; then
      # Store invocation ID for PostToolUse correlation
      echo "$invocation_id" > "$STATE_FILE"
    fi
    ;;

  PostToolUse)
    # Complete the invocation tracking
    if [ -f "$STATE_FILE" ]; then
      invocation_id=$(cat "$STATE_FILE")
      rm -f "$STATE_FILE"

      # Determine status from tool response
      status="completed"
      tool_response=$(echo "$json_input" | jq -c '.tool_response // {}')

      # Check if there was an error
      if echo "$tool_response" | jq -e 'has("error")' >/dev/null 2>&1; then
        status="error"
      fi

      # Extract token counts from tool_response if available
      # Claude API response may include usage data with input/output token counts
      # Check multiple possible locations in the response structure
      tokens_input=$(echo "$tool_response" | jq -r '
        .usage.input_tokens //
        .usage.input //
        .input_tokens //
        null' 2>/dev/null)
      tokens_output=$(echo "$tool_response" | jq -r '
        .usage.output_tokens //
        .usage.output //
        .output_tokens //
        null' 2>/dev/null)

      # Update token counts if both values are available and numeric
      if [ "$tokens_input" != "null" ] && [ -n "$tokens_input" ] && \
         [ "$tokens_output" != "null" ] && [ -n "$tokens_output" ] && \
         [[ "$tokens_input" =~ ^[0-9]+$ ]] && [[ "$tokens_output" =~ ^[0-9]+$ ]]; then
        "$METRICS_SCRIPT" --update \
          --id "$invocation_id" \
          --tokens-input "$tokens_input" \
          --tokens-output "$tokens_output" 2>/dev/null || true
      fi

      # Complete the invocation
      "$METRICS_SCRIPT" --end \
        --id "$invocation_id" \
        --status "$status" 2>/dev/null || true
    fi
    ;;

  *)
    # Unknown hook event, ignore
    ;;
esac

# Always exit 0 to allow the tool to proceed
exit 0
