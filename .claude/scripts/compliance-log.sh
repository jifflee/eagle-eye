#!/bin/bash
# compliance-log.sh
# Logs coding standard violations per agent to metrics.jsonl
# size-ok: compliance event logger with validation and attribution
#
# Usage:
#   ./scripts/compliance-log.sh \
#     --agent NAME \
#     --file FILE_PATH \
#     --violation-type TYPE \
#     --severity SEVERITY \
#     [--rule RULE_ID] \
#     [--message MSG] \
#     [--session SESSION_ID]
#
# Violation types: lint, format, naming, size, security, structure
# Severity levels: error, warning, info
#
# Environment:
#   CLAUDE_METRICS_ENABLED=false  # Disable compliance collection
#   CLAUDE_METRICS_FILE           # Override default file location
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Metrics disabled
#   3 - File write error

set -euo pipefail

# Detect main repo (even if in worktree) - metrics aggregate to main repo
get_main_repo() {
  local toplevel git_common main_git
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo "."

  if [ -f "$toplevel/.git" ]; then
    git_common=$(git rev-parse --git-common-dir 2>/dev/null)
    main_git="${git_common%/worktrees/*}"
    echo "${main_git%/.git}"
  else
    echo "$toplevel"
  fi
}

# Get worktree issue number (if in worktree)
get_worktree_issue() {
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
WORKTREE_ISSUE=$(get_worktree_issue)
METRICS_DIR="${CLAUDE_METRICS_DIR:-$MAIN_REPO/.claude}"
METRICS_FILE="${CLAUDE_METRICS_FILE:-$METRICS_DIR/metrics.jsonl}"
SCHEMA_VERSION="1.1"

# Check if metrics collection is enabled
if [ "${CLAUDE_METRICS_ENABLED:-true}" = "false" ]; then
  exit 2
fi

# Field length limits
MAX_AGENT_LEN=64
MAX_FILE_LEN=512
MAX_RULE_LEN=128
MAX_MESSAGE_LEN=500
MAX_SESSION_LEN=128

# Validate required field
require_field() {
  local value="$1" name="$2"
  if [ -z "$value" ]; then
    echo "Error: --${name} is required" >&2
    exit 1
  fi
}

# Validate violation type
validate_violation_type() {
  local vtype="$1"
  case "$vtype" in
    lint|format|naming|size|security|structure)
      return 0
      ;;
    *)
      echo "Error: --violation-type must be one of: lint, format, naming, size, security, structure" >&2
      echo "Got: $vtype" >&2
      exit 1
      ;;
  esac
}

# Validate severity level
validate_severity() {
  local sev="$1"
  case "$sev" in
    error|warning|info)
      return 0
      ;;
    *)
      echo "Error: --severity must be one of: error, warning, info" >&2
      echo "Got: $sev" >&2
      exit 1
      ;;
  esac
}

# Validate field length
validate_length() {
  local value="$1" name="$2" max="$3"
  if [ -z "$value" ]; then
    return 0
  fi
  local len=${#value}
  if [ "$len" -gt "$max" ]; then
    echo "Error: --${name} exceeds max length ${max} (got ${len})" >&2
    exit 1
  fi
}

# Detect shell injection patterns (basic defense)
validate_no_injection() {
  local text="$1" field="$2"
  if [ -z "$text" ]; then
    return 0
  fi
  if [[ "$text" =~ \$\( ]] || [[ "$text" =~ \` ]]; then
    echo "Error: $field contains shell substitution pattern" >&2
    exit 1
  fi
}

# Get ISO 8601 timestamp in UTC
get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Generate UUID (cross-platform)
generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    openssl rand -hex 16 2>/dev/null | sed 's/\(..\)/\1/g; s/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/' || \
    echo "$(date +%s)-$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')"
  fi
}

# Ensure metrics directory and file exist
ensure_metrics_dir() {
  if [ ! -d "$METRICS_DIR" ]; then
    mkdir -p "$METRICS_DIR"
    chmod 700 "$METRICS_DIR"
  fi
  if [ ! -f "$METRICS_FILE" ]; then
    touch "$METRICS_FILE"
    chmod 600 "$METRICS_FILE"
  fi
}

# Append entry to metrics file
append_entry() {
  local entry="$1"
  ensure_metrics_dir

  if ! echo "$entry" | jq -e . >/dev/null 2>&1; then
    echo "Error: Invalid JSON entry" >&2
    exit 3
  fi

  echo "$entry" >> "$METRICS_FILE"
}

# Parse arguments
AGENT=""
FILE_PATH=""
VIOLATION_TYPE=""
SEVERITY=""
RULE_ID=""
MESSAGE=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT="$2"
      shift 2
      ;;
    --file)
      FILE_PATH="$2"
      shift 2
      ;;
    --violation-type)
      VIOLATION_TYPE="$2"
      shift 2
      ;;
    --severity)
      SEVERITY="$2"
      shift 2
      ;;
    --rule)
      RULE_ID="$2"
      shift 2
      ;;
    --message)
      MESSAGE="$2"
      shift 2
      ;;
    --session)
      SESSION_ID="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 --agent NAME --file PATH --violation-type TYPE --severity LEVEL [OPTIONS]"
      echo ""
      echo "Required:"
      echo "  --agent NAME          Agent that produced the violation (max ${MAX_AGENT_LEN} chars)"
      echo "  --file PATH           File path where violation occurred (max ${MAX_FILE_LEN} chars)"
      echo "  --violation-type TYPE lint|format|naming|size|security|structure"
      echo "  --severity LEVEL      error|warning|info"
      echo ""
      echo "Optional:"
      echo "  --rule RULE_ID        Specific rule/check identifier (max ${MAX_RULE_LEN} chars)"
      echo "  --message MSG         Human-readable violation description (max ${MAX_MESSAGE_LEN} chars)"
      echo "  --session SESSION_ID  Claude session ID for correlation (max ${MAX_SESSION_LEN} chars)"
      echo ""
      echo "Environment:"
      echo "  CLAUDE_METRICS_ENABLED=false  Disable compliance logging"
      echo "  CLAUDE_METRICS_FILE           Override default file location"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Validate required fields
require_field "$AGENT" "agent"
require_field "$FILE_PATH" "file"
require_field "$VIOLATION_TYPE" "violation-type"
require_field "$SEVERITY" "severity"

# Validate enum fields
validate_violation_type "$VIOLATION_TYPE"
validate_severity "$SEVERITY"

# Validate field lengths
validate_length "$AGENT" "agent" "$MAX_AGENT_LEN"
validate_length "$FILE_PATH" "file" "$MAX_FILE_LEN"
validate_length "$RULE_ID" "rule" "$MAX_RULE_LEN"
validate_length "$MESSAGE" "message" "$MAX_MESSAGE_LEN"
validate_length "$SESSION_ID" "session" "$MAX_SESSION_LEN"

# Validate no injection in free-text fields
validate_no_injection "$MESSAGE" "--message"
validate_no_injection "$RULE_ID" "--rule"

# Build the compliance event entry
ID=$(generate_uuid)
TIMESTAMP=$(get_timestamp)

ENTRY=$(jq -cn \
  --arg schema_version "$SCHEMA_VERSION" \
  --arg timestamp "$TIMESTAMP" \
  --arg id "$ID" \
  --arg agent "$AGENT" \
  --arg file_path "$FILE_PATH" \
  --arg violation_type "$VIOLATION_TYPE" \
  --arg severity "$SEVERITY" \
  --arg rule_id "$RULE_ID" \
  --arg message "$MESSAGE" \
  --arg session_id "$SESSION_ID" \
  --arg worktree_issue "$WORKTREE_ISSUE" \
  '{
    schema_version: $schema_version,
    timestamp: $timestamp,
    event_type: "compliance_violation",
    invocation_id: $id,
    agent: (if $agent == "" then null else $agent end),
    file_path: (if $file_path == "" then null else $file_path end),
    violation_type: $violation_type,
    severity: $severity,
    rule_id: (if $rule_id == "" then null else $rule_id end),
    message: (if $message == "" then null else $message end),
    session_id: (if $session_id == "" then null else $session_id end),
    worktree_issue: (if $worktree_issue == "" then null else $worktree_issue end)
  }')

append_entry "$ENTRY"
