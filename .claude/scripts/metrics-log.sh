#!/bin/bash
set -euo pipefail
# metrics-log.sh
# Core logging utility for agent performance observability
# size-ok: multi-mode logging utility with start/update/end lifecycle and validation
#
# Usage:
#   ./scripts/metrics-log.sh --start --agent NAME --model MODEL --phase PHASE [--skill NAME] [--task DESC]
#   ./scripts/metrics-log.sh --update --id UUID --tokens-input N --tokens-output N
#   ./scripts/metrics-log.sh --end --id UUID --status STATUS [--commit HASH] [--notes TEXT]
#   ./scripts/metrics-log.sh --log (full entry via JSON stdin)
#
# Environment:
#   CLAUDE_METRICS_ENABLED=false  # Disable metrics collection
#   CLAUDE_METRICS_FILE           # Override default file location
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Metrics disabled
#   3 - File write error

set -e

# Configuration
# Detect main repo (even if in worktree) - metrics should aggregate to main repo
get_main_repo() {
  local toplevel git_common main_git
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo "."

  # Check if in worktree (.git is a file, not directory)
  if [ -f "$toplevel/.git" ]; then
    # In a worktree - get main repo from git-common-dir
    git_common=$(git rev-parse --git-common-dir 2>/dev/null)
    # Remove /worktrees/<name> suffix if present
    main_git="${git_common%/worktrees/*}"
    # Remove /.git suffix to get repo root
    echo "${main_git%/.git}"
  else
    # Not in worktree - return toplevel
    echo "$toplevel"
  fi
}

# Get worktree metadata for metrics tagging
get_worktree_info() {
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo ""

  if [ -f "$toplevel/.git" ]; then
    local branch issue_num
    branch=$(git branch --show-current 2>/dev/null || echo "")
    issue_num=""
    if [[ "$branch" =~ issue-([0-9]+) ]]; then
      issue_num="${BASH_REMATCH[1]}"
    fi
    echo "$issue_num"
  else
    echo ""
  fi
}

MAIN_REPO=$(get_main_repo)
WORKTREE_ISSUE=$(get_worktree_info)
METRICS_DIR="${CLAUDE_METRICS_DIR:-$MAIN_REPO/.claude}"
METRICS_FILE="${CLAUDE_METRICS_FILE:-$METRICS_DIR/metrics.jsonl}"
SCHEMA_VERSION="1.1"

# Check if metrics collection is enabled
if [ "${CLAUDE_METRICS_ENABLED:-true}" = "false" ]; then
  # Silent exit when disabled
  exit 2
fi

# Ensure metrics directory exists with secure permissions
ensure_metrics_dir() {
  if [ ! -d "$METRICS_DIR" ]; then
    mkdir -p "$METRICS_DIR"
    chmod 700 "$METRICS_DIR"  # Directory: user-only access
  fi
  # Ensure metrics file has secure permissions on first creation
  if [ ! -f "$METRICS_FILE" ]; then
    touch "$METRICS_FILE"
    chmod 600 "$METRICS_FILE"  # File: user read/write only
  fi
}

# Generate UUID (cross-platform)
generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: use openssl or date-based
    openssl rand -hex 16 2>/dev/null | sed 's/\(..\)/\1/g; s/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/' || \
    echo "$(date +%s)-$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')"
  fi
}

# Get ISO 8601 timestamp in UTC
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get milliseconds since epoch
get_epoch_ms() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: use python or perl for milliseconds
    python3 -c "import time; print(int(time.time() * 1000))" 2>/dev/null || \
    perl -MTime::HiRes -e 'printf("%.0f\n",Time::HiRes::time()*1000)' 2>/dev/null || \
    echo "$(($(date +%s) * 1000))"
  else
    # Linux: date supports %N for nanoseconds
    echo "$(($(date +%s%N) / 1000000))"
  fi
}

# Validate required fields for an action
validate_start() {
  local agent="$1" model="$2" phase="$3"
  if [ -z "$agent" ] || [ -z "$model" ] || [ -z "$phase" ]; then
    echo "Error: --start requires --agent, --model, and --phase" >&2
    exit 1
  fi
}

# Validate token count (must be non-negative integer)
validate_token_count() {
  local value="$1" name="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $name must be a non-negative integer, got: $value" >&2
    exit 1
  fi
}

# Validate status value
validate_status() {
  local status="$1"
  case "$status" in
    completed|in_progress|blocked|escalated|error)
      return 0
      ;;
    *)
      echo "Error: --status must be one of: completed, in_progress, blocked, escalated, error" >&2
      echo "Got: $status" >&2
      exit 1
      ;;
  esac
}

# Validate SDLC phase value
# Valid phases align with SDLC workflow: spec, design, implement, test, docs, review, deploy, other
validate_phase() {
  local phase="$1"
  case "$phase" in
    spec|design|implement|test|docs|review|deploy|other)
      return 0
      ;;
    *)
      echo "Error: --phase must be one of: spec, design, implement, test, docs, review, deploy, other" >&2
      echo "Got: $phase" >&2
      exit 1
      ;;
  esac
}

# =============================================================================
# SECURITY VALIDATIONS (Issue #165)
# Defense-in-depth input validation for metrics ingestion
# =============================================================================

# Field length limits (prevents DoS via oversized payloads)
MAX_AGENT_LEN=64
MAX_SKILL_LEN=64
MAX_TASK_DESC_LEN=500
MAX_NOTES_LEN=1000
MAX_MILESTONE_LEN=100
MAX_COMMIT_LEN=40
MAX_MODEL_LEN=16
MAX_PHASE_LEN=32

# Validate field length
validate_field_length() {
  local value="$1" field="$2" max_length="$3"
  if [ -z "$value" ]; then
    return 0  # Empty values are allowed
  fi
  local actual_length=${#value}
  if [ "$actual_length" -gt "$max_length" ]; then
    echo "Error: $field exceeds max length $max_length (got $actual_length chars)" >&2
    exit 1
  fi
}

# Validate model value (enum check)
validate_model() {
  local model="$1"
  case "$model" in
    haiku|sonnet|opus)
      return 0
      ;;
    *)
      echo "Error: --model must be one of: haiku, sonnet, opus" >&2
      echo "Got: $model" >&2
      exit 1
      ;;
  esac
}

# Detect potentially dangerous injection patterns
# Returns 0 if safe, 1 if suspicious pattern detected
validate_no_injection() {
  local text="$1" field="$2"
  if [ -z "$text" ]; then
    return 0  # Empty values are safe
  fi

  # Check for shell command injection patterns
  # $( ) - command substitution
  # `backticks` - legacy command substitution
  # && or || followed by commands - command chaining
  # ; followed by dangerous commands
  if [[ "$text" =~ \$\( ]] || [[ "$text" =~ \` ]]; then
    echo "Error: $field contains shell substitution pattern (\$() or backticks)" >&2
    exit 1
  fi

  # Check for script/html injection (defense-in-depth for display)
  if [[ "$text" =~ \<script ]] || [[ "$text" =~ javascript: ]]; then
    echo "Error: $field contains potential script injection" >&2
    exit 1
  fi

  return 0
}

# Detect secrets that should not be logged
# Patterns: AWS keys, API keys, tokens, private keys
validate_no_secrets() {
  local text="$1" field="$2"
  if [ -z "$text" ]; then
    return 0  # Empty values are safe
  fi

  # AWS Access Key ID (AKIA followed by 16 uppercase alphanumeric)
  if [[ "$text" =~ AKIA[0-9A-Z]{16} ]]; then
    echo "Error: $field appears to contain an AWS access key" >&2
    exit 1
  fi

  # OpenAI API key (sk- followed by alphanumeric)
  if [[ "$text" =~ sk-[a-zA-Z0-9]{20,} ]]; then
    echo "Error: $field appears to contain an API key (sk-...)" >&2
    exit 1
  fi

  # GitHub token (ghp_, gho_, ghu_, ghs_, ghr_ followed by alphanumeric)
  if [[ "$text" =~ gh[pousr]_[a-zA-Z0-9]{36} ]]; then
    echo "Error: $field appears to contain a GitHub token" >&2
    exit 1
  fi

  # Anthropic API key (sk-ant- prefix)
  if [[ "$text" =~ sk-ant-[a-zA-Z0-9-]{90,} ]]; then
    echo "Error: $field appears to contain an Anthropic API key" >&2
    exit 1
  fi

  # Generic private key header
  if [[ "$text" =~ -----BEGIN[[:space:]]+(RSA[[:space:]]+)?PRIVATE[[:space:]]+KEY----- ]]; then
    echo "Error: $field appears to contain a private key" >&2
    exit 1
  fi

  return 0
}

# Strip non-printable characters (defense against null byte injection)
sanitize_input() {
  local text="$1"
  # Remove null bytes and other control characters (keep newlines, tabs)
  echo "$text" | tr -d '\000-\010\013\014\016-\037'
}

# Comprehensive field validation (combines all checks)
validate_text_field() {
  local value="$1" field="$2" max_length="$3"

  # Sanitize first
  value=$(sanitize_input "$value")

  # Check length
  validate_field_length "$value" "$field" "$max_length"

  # Check for injection patterns
  validate_no_injection "$value" "$field"

  # Check for secrets
  validate_no_secrets "$value" "$field"

  # Return sanitized value
  echo "$value"
}

# Validate git commit hash format
validate_commit_hash() {
  local commit="$1"
  if [ -z "$commit" ]; then
    return 0  # Empty is allowed
  fi

  # Git commit hash is 40 hex characters (full) or 7+ (short)
  if ! [[ "$commit" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "Error: --commit must be a valid git hash (7-40 hex characters)" >&2
    echo "Got: $commit" >&2
    exit 1
  fi
}

# Discover known agent names from agent definition files
# Searches: core/agents/, packs/*/agents/, domains/*/agents/
get_known_agents() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root="."

  # Find all agent definition markdown files
  find "$repo_root" \
    \( -path "$repo_root/.git" -prune \) -o \
    \( -name "*.md" -path "*agents/*" -print \) 2>/dev/null | \
    while read -r file; do
      # Extract agent name from filename (remove .md extension)
      basename "$file" .md
    done | sort -u
}

# Validate agent name against known agents
# Warns but allows unknown agents (to support new agents not yet defined)
validate_agent_name() {
  local agent="$1"
  if [ -z "$agent" ]; then
    return 0  # Empty is allowed
  fi

  # Check if agent name validation is disabled
  if [ "${CLAUDE_METRICS_SKIP_AGENT_VALIDATION:-false}" = "true" ]; then
    return 0
  fi

  # Get list of known agents
  local known_agents
  known_agents=$(get_known_agents)

  # Check if agent is in known list
  if echo "$known_agents" | grep -qx "$agent"; then
    return 0  # Known agent
  fi

  # Unknown agent - warn but allow
  # This allows for new agents that haven't been formally defined yet
  echo "Warning: Unknown agent name '$agent' (not found in agents/*.md)" >&2
  echo "         Known agents: $(echo "$known_agents" | tr '\n' ' ' | head -c 200)..." >&2

  # Return 0 to allow (warn-only mode)
  # To make this strict, change to: exit 1
  return 0
}

# =============================================================================
# END SECURITY VALIDATIONS
# =============================================================================

# Append entry to metrics file (atomic write)
append_entry() {
  local entry="$1"
  ensure_metrics_dir

  # Validate JSON before writing
  if ! echo "$entry" | jq -e . >/dev/null 2>&1; then
    echo "Error: Invalid JSON entry" >&2
    exit 3
  fi

  # Atomic append
  echo "$entry" >> "$METRICS_FILE"
}

# Create start entry
create_start_entry() {
  local id="$1" agent="$2" model="$3" phase="$4" skill="$5" task="$6" action="$7" milestone="$8"
  local timestamp start_ms
  timestamp=$(get_timestamp)
  start_ms=$(get_epoch_ms)

  jq -cn \
    --arg schema_version "$SCHEMA_VERSION" \
    --arg timestamp "$timestamp" \
    --arg id "$id" \
    --arg agent "$agent" \
    --arg skill "$skill" \
    --arg action "${action:-invocation}" \
    --arg model "$model" \
    --arg phase "$phase" \
    --argjson start_time "$start_ms" \
    --arg milestone "$milestone" \
    --arg task "$task" \
    --arg worktree_issue "$WORKTREE_ISSUE" \
    '{
      schema_version: $schema_version,
      timestamp: $timestamp,
      invocation_id: $id,
      agent: (if $agent == "" then null else $agent end),
      skill: (if $skill == "" then null else $skill end),
      action: $action,
      model: $model,
      phase: $phase,
      start_time: $start_time,
      end_time: null,
      duration_ms: null,
      tokens_input: null,
      tokens_output: null,
      tokens_total: null,
      status: "in_progress",
      git_commit: null,
      milestone: (if $milestone == "" then null else $milestone end),
      task_description: (if $task == "" then null else $task end),
      worktree_issue: (if $worktree_issue == "" then null else $worktree_issue end),
      notes: null
    }'
}

# Update entry with token counts (finds and updates in-place)
update_tokens() {
  local id="$1" tokens_input="$2" tokens_output="$3"
  local tokens_total=$((tokens_input + tokens_output))

  # Use temp file for atomic update
  local temp_file
  temp_file=$(mktemp) || { echo "Error: Failed to create temp file" >&2; exit 3; }

  if ! jq --arg id "$id" \
     --argjson tokens_input "$tokens_input" \
     --argjson tokens_output "$tokens_output" \
     --argjson tokens_total "$tokens_total" \
     'if .invocation_id == $id then
        . + {tokens_input: $tokens_input, tokens_output: $tokens_output, tokens_total: $tokens_total}
      else . end' "$METRICS_FILE" > "$temp_file"; then
    rm -f "$temp_file"
    echo "Error: Failed to update metrics file" >&2
    exit 3
  fi
  mv "$temp_file" "$METRICS_FILE"
}

# Complete entry (updates end_time, duration, status)
complete_entry() {
  local id="$1" status="$2" commit="$3" notes="$4"
  local end_ms
  end_ms=$(get_epoch_ms)

  # Use temp file for atomic update
  local temp_file
  temp_file=$(mktemp) || { echo "Error: Failed to create temp file" >&2; exit 3; }

  if ! jq --arg id "$id" \
     --arg status "$status" \
     --arg commit "$commit" \
     --arg notes "$notes" \
     --argjson end_time "$end_ms" \
     'if .invocation_id == $id then
        . + {
          end_time: $end_time,
          duration_ms: ($end_time - .start_time),
          status: $status,
          git_commit: (if $commit == "" then null else $commit end),
          notes: (if $notes == "" then null else $notes end)
        }
      else . end' "$METRICS_FILE" > "$temp_file"; then
    rm -f "$temp_file"
    echo "Error: Failed to complete metrics entry" >&2
    exit 3
  fi
  mv "$temp_file" "$METRICS_FILE"
}

# Parse command line arguments
ACTION=""
AGENT=""
MODEL=""
PHASE=""
SKILL=""
TASK=""
INVOCATION_ACTION=""
MILESTONE=""
ID=""
TOKENS_INPUT=""
TOKENS_OUTPUT=""
STATUS=""
COMMIT=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --start)
      ACTION="start"
      shift
      ;;
    --update)
      ACTION="update"
      shift
      ;;
    --end)
      ACTION="end"
      shift
      ;;
    --log)
      ACTION="log"
      shift
      ;;
    --agent)
      AGENT="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --phase)
      PHASE="$2"
      shift 2
      ;;
    --skill)
      SKILL="$2"
      shift 2
      ;;
    --task)
      TASK="$2"
      shift 2
      ;;
    --action)
      INVOCATION_ACTION="$2"
      shift 2
      ;;
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    --id)
      ID="$2"
      shift 2
      ;;
    --tokens-input)
      TOKENS_INPUT="$2"
      shift 2
      ;;
    --tokens-output)
      TOKENS_OUTPUT="$2"
      shift 2
      ;;
    --status)
      STATUS="$2"
      shift 2
      ;;
    --commit)
      COMMIT="$2"
      shift 2
      ;;
    --notes)
      NOTES="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 --start|--update|--end|--log [OPTIONS]"
      echo ""
      echo "Actions:"
      echo "  --start    Start tracking an agent invocation"
      echo "  --update   Update token counts for an invocation"
      echo "  --end      Complete an invocation"
      echo "  --log      Log a complete entry from JSON stdin"
      echo ""
      echo "Options for --start:"
      echo "  --agent NAME      Agent name (required, max ${MAX_AGENT_LEN} chars)"
      echo "  --model MODEL     Model used: haiku|sonnet|opus (required)"
      echo "  --phase PHASE     SDLC phase (required): spec|design|implement|test|docs|review|deploy|other"
      echo "  --skill NAME      Skill name (optional, max ${MAX_SKILL_LEN} chars)"
      echo "  --task DESC       Task description (optional, max ${MAX_TASK_DESC_LEN} chars)"
      echo "  --action ACTION   Action type (optional, default: invocation)"
      echo "  --milestone NAME  Milestone name (optional, max ${MAX_MILESTONE_LEN} chars)"
      echo ""
      echo "Options for --update:"
      echo "  --id UUID           Invocation ID (required)"
      echo "  --tokens-input N    Input tokens (required)"
      echo "  --tokens-output N   Output tokens (required)"
      echo ""
      echo "Options for --end:"
      echo "  --id UUID       Invocation ID (required)"
      echo "  --status STATUS Status: completed|blocked|escalated|error (required)"
      echo "  --commit HASH   Git commit hash (optional, 7-40 hex chars)"
      echo "  --notes TEXT    Additional notes (optional, max ${MAX_NOTES_LEN} chars)"
      echo ""
      echo "Environment:"
      echo "  CLAUDE_METRICS_ENABLED=false  Disable metrics collection"
      echo "  CLAUDE_METRICS_FILE           Override default file location"
      echo ""
      echo "Security: Input validation rejects shell injection patterns, secret patterns"
      echo "          (API keys, tokens), and enforces field length limits."
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Execute action
case $ACTION in
  start)
    # Basic required field validation
    validate_start "$AGENT" "$MODEL" "$PHASE"

    # Security validations (Issue #165)
    # Validate model enum
    validate_model "$MODEL"

    # Validate SDLC phase enum (Issue #833)
    validate_phase "$PHASE"

    # Validate field lengths and content
    AGENT=$(validate_text_field "$AGENT" "--agent" "$MAX_AGENT_LEN")
    PHASE=$(validate_text_field "$PHASE" "--phase" "$MAX_PHASE_LEN")

    # Validate agent name against known agents (warns for unknown)
    validate_agent_name "$AGENT"

    # Optional fields
    if [ -n "$SKILL" ]; then
      SKILL=$(validate_text_field "$SKILL" "--skill" "$MAX_SKILL_LEN")
    fi
    if [ -n "$TASK" ]; then
      TASK=$(validate_text_field "$TASK" "--task" "$MAX_TASK_DESC_LEN")
    fi
    if [ -n "$MILESTONE" ]; then
      MILESTONE=$(validate_text_field "$MILESTONE" "--milestone" "$MAX_MILESTONE_LEN")
    fi

    ID=$(generate_uuid)
    ENTRY=$(create_start_entry "$ID" "$AGENT" "$MODEL" "$PHASE" "$SKILL" "$TASK" "$INVOCATION_ACTION" "$MILESTONE")
    append_entry "$ENTRY"
    # Output the invocation ID for callers to use
    echo "$ID"
    ;;
  update)
    if [ -z "$ID" ] || [ -z "$TOKENS_INPUT" ] || [ -z "$TOKENS_OUTPUT" ]; then
      echo "Error: --update requires --id, --tokens-input, and --tokens-output" >&2
      exit 1
    fi
    validate_token_count "$TOKENS_INPUT" "--tokens-input"
    validate_token_count "$TOKENS_OUTPUT" "--tokens-output"
    update_tokens "$ID" "$TOKENS_INPUT" "$TOKENS_OUTPUT"
    ;;
  end)
    if [ -z "$ID" ] || [ -z "$STATUS" ]; then
      echo "Error: --end requires --id and --status" >&2
      exit 1
    fi
    validate_status "$STATUS"

    # Security validations for --end fields (Issue #165)
    if [ -n "$COMMIT" ]; then
      validate_commit_hash "$COMMIT"
    fi
    if [ -n "$NOTES" ]; then
      NOTES=$(validate_text_field "$NOTES" "--notes" "$MAX_NOTES_LEN")
    fi

    complete_entry "$ID" "$STATUS" "$COMMIT" "$NOTES"

    # Update utilization state after work completion (if available)
    # This is a side-effect - no token cost
    UTILIZATION_SCRIPT="$(dirname "$0")/utilization-state.sh"
    if [ -x "$UTILIZATION_SCRIPT" ] && [ -n "$TOKENS_TOTAL" ]; then
      # Extract usage percentage from metrics (placeholder - implement based on quota tracking)
      # For now, mark work as completed in session state
      "$UTILIZATION_SCRIPT" --mark-in-progress 2>/dev/null || true
    fi
    ;;
  log)
    # Read JSON from stdin and validate
    ENTRY=$(cat)

    # Security validation for --log action (Issue #165)
    # Extract fields from JSON and validate them
    if ! echo "$ENTRY" | jq -e . >/dev/null 2>&1; then
      echo "Error: --log requires valid JSON input" >&2
      exit 1
    fi

    # Validate field lengths in JSON entry
    LOG_AGENT=$(echo "$ENTRY" | jq -r '.agent // empty')
    LOG_TASK=$(echo "$ENTRY" | jq -r '.task_description // empty')
    LOG_NOTES=$(echo "$ENTRY" | jq -r '.notes // empty')
    LOG_COMMIT=$(echo "$ENTRY" | jq -r '.git_commit // empty')
    LOG_MODEL=$(echo "$ENTRY" | jq -r '.model // empty')

    if [ -n "$LOG_AGENT" ]; then
      validate_text_field "$LOG_AGENT" "agent" "$MAX_AGENT_LEN" >/dev/null
    fi
    if [ -n "$LOG_TASK" ]; then
      validate_text_field "$LOG_TASK" "task_description" "$MAX_TASK_DESC_LEN" >/dev/null
    fi
    if [ -n "$LOG_NOTES" ]; then
      validate_text_field "$LOG_NOTES" "notes" "$MAX_NOTES_LEN" >/dev/null
    fi
    if [ -n "$LOG_COMMIT" ]; then
      validate_commit_hash "$LOG_COMMIT"
    fi
    if [ -n "$LOG_MODEL" ]; then
      validate_model "$LOG_MODEL"
    fi

    append_entry "$ENTRY"
    ;;
  *)
    echo "Error: Must specify --start, --update, --end, or --log" >&2
    exit 1
    ;;
esac
