#!/usr/bin/env bash
# action-log.sh - Core action logging utility for audit trail
# Logs all skill/agent operations to .claude/actions.jsonl
# Part of Issue #228 - Action Audit Log (#216)
# size-ok: multi-command audit utility with log/query/rotate/validate modes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${ACTION_LOG_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LOG_DIR="$REPO_ROOT/.claude"
LOG_FILE="$LOG_DIR/actions.jsonl"
REGISTRY_FILE="$LOG_DIR/tier-registry.json"
SESSION_FILE="$LOG_DIR/.current-session"
MAX_LOG_SIZE_MB=10
MAX_LOG_FILES=5

# --- Helper Functions ---

generate_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    # Fallback: generate pseudo-UUID from /dev/urandom
    od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}'
  fi
}

get_timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

get_repo_name() {
  local url
  url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null) || { echo "unknown/unknown"; return; }
  # Strip .git suffix, then extract owner/repo
  url="${url%.git}"
  echo "$url" | grep -oE '[^/:]+/[^/:]+$' || echo "unknown/unknown"
}

get_branch() {
  git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

# --- Session Management ---

get_current_session() {
  if [[ -f "$SESSION_FILE" ]]; then
    cat "$SESSION_FILE"
  else
    new_session
  fi
}

new_session() {
  local session_id
  session_id="$(generate_uuid)"
  mkdir -p "$LOG_DIR"
  echo "$session_id" > "$SESSION_FILE"
  echo "$session_id"
}

# --- Sanitization ---

sanitize_value() {
  local value="$1"
  # Remove potential secrets: tokens, keys, passwords
  # Order matters: specific patterns first, then general patterns
  value=$(echo "$value" | sed -E \
    -e 's/Bearer [A-Za-z0-9._\-]+/Bearer <REDACTED>/g' \
    -e 's/ghp_[A-Za-z0-9_]+/<GITHUB_TOKEN_REDACTED>/g' \
    -e 's/gho_[A-Za-z0-9_]+/<GITHUB_OAUTH_REDACTED>/g' \
    -e 's/sk-[A-Za-z0-9_]+/<API_KEY_REDACTED>/g' \
    -e 's/(password|passwd|pwd)=([^ "&]+)/\1=<REDACTED>/gi' \
    -e 's/(api[_-]?key|secret|token)=([^ "&]+)/\1=<REDACTED>/gi')
  echo "$value"
}

# --- Auto-Classification ---

classify_from_registry() {
  local category="$1"
  local operation="$2"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "T2"  # Safe default
    return
  fi

  # Look up in categories section
  local tier
  tier=$(jq -r --arg cat "$category" --arg op "$operation" \
    '.categories[$cat][$op] // empty' "$REGISTRY_FILE" 2>/dev/null)

  if [[ -n "$tier" ]]; then
    echo "$tier"
    return
  fi

  echo ""  # Not found in registry
}

classify_from_command() {
  local command="$1"

  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo ""
    return
  fi

  # Match against command_patterns (try-catch for regex safety)
  local result
  result=$(jq -r --arg cmd "$command" '
    [.command_patterns[] | . as $p |
      try (if ($cmd | test($p.pattern)) then $p.tier else empty end)
      catch empty
    ] | first // empty
  ' "$REGISTRY_FILE" 2>/dev/null)

  echo "$result"
}

auto_classify() {
  local category="$1"
  local operation="$2"
  local command="${3:-}"

  # 1. Try registry lookup by category+operation
  local tier
  tier=$(classify_from_registry "$category" "$operation")
  if [[ -n "$tier" ]]; then
    echo "$tier|registry"
    return
  fi

  # 2. Try command pattern matching
  if [[ -n "$command" ]]; then
    tier=$(classify_from_command "$command")
    if [[ -n "$tier" ]]; then
      echo "$tier|pattern"
      return
    fi
  fi

  # 3. Default to T2 (safe default - requires session-once approval)
  echo "T2|default"
}

# --- Log Rotation ---

rotate_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    return
  fi

  local size_bytes
  size_bytes=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
  local max_bytes=$((MAX_LOG_SIZE_MB * 1024 * 1024))

  if [[ "$size_bytes" -ge "$max_bytes" ]]; then
    # Rotate existing backups
    for i in $(seq $((MAX_LOG_FILES - 1)) -1 1); do
      if [[ -f "${LOG_FILE}.${i}" ]]; then
        mv "${LOG_FILE}.${i}" "${LOG_FILE}.$((i + 1))"
      fi
    done
    # Rotate current to .1
    mv "$LOG_FILE" "${LOG_FILE}.1"
    # Remove oldest if over limit
    if [[ -f "${LOG_FILE}.$((MAX_LOG_FILES + 1))" ]]; then
      rm -f "${LOG_FILE}.$((MAX_LOG_FILES + 1))"
    fi
  fi
}

# --- JSON Validation ---

validate_json() {
  local json="$1"
  if echo "$json" | jq empty 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# --- Core Log Function ---

log_action() {
  local source_type="${1:-}"
  local source_name="${2:-}"
  local category="${3:-}"
  local operation="${4:-}"
  local tier="${5:-}"
  local status="${6:-success}"
  local command="${7:-}"
  local duration_ms="${8:-0}"
  local invocation_id="${9:-}"

  # Validate required fields
  if [[ -z "$source_type" || -z "$source_name" || -z "$category" || -z "$operation" ]]; then
    echo "ERROR: Missing required fields (source_type, source_name, category, operation)" >&2
    return 1
  fi

  # Validate source_type
  case "$source_type" in
    skill|agent|hook|manual) ;;
    *) echo "ERROR: Invalid source_type '$source_type' (must be skill|agent|hook|manual)" >&2; return 1 ;;
  esac

  # Validate status
  case "$status" in
    success|failure|blocked|timeout) ;;
    *) echo "ERROR: Invalid status '$status' (must be success|failure|blocked|timeout)" >&2; return 1 ;;
  esac

  # Auto-classify tier if not provided
  local tier_source="explicit"
  if [[ -z "$tier" ]]; then
    local classification
    classification=$(auto_classify "$category" "$operation" "$command")
    tier="${classification%%|*}"
    tier_source="${classification##*|}"
  fi

  # Validate tier format
  case "$tier" in
    T0|T1|T2|T3) ;;
    *) echo "ERROR: Invalid tier '$tier' (must be T0|T1|T2|T3)" >&2; return 1 ;;
  esac

  # Sanitize command if provided
  local sanitized_command=""
  if [[ -n "$command" ]]; then
    sanitized_command=$(sanitize_value "$command")
  fi

  # Generate IDs
  local action_id
  action_id="$(generate_uuid)"
  local session_id
  session_id="$(get_current_session)"
  if [[ -z "$invocation_id" ]]; then
    invocation_id="$(generate_uuid)"
  fi

  # Get context
  local repo branch
  repo="$(get_repo_name)"
  branch="$(get_branch)"

  # Build JSON entry (compact single-line for JSONL)
  local json_entry
  json_entry=$(jq -cn \
    --arg schema_version "1.0" \
    --arg timestamp "$(get_timestamp)" \
    --arg action_id "$action_id" \
    --arg session_id "$session_id" \
    --arg invocation_id "$invocation_id" \
    --arg source_type "$source_type" \
    --arg source_name "$source_name" \
    --arg category "$category" \
    --arg operation "$operation" \
    --arg command "$sanitized_command" \
    --arg tier "$tier" \
    --arg tier_source "$tier_source" \
    --arg status "$status" \
    --argjson duration_ms "$duration_ms" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    '{
      schema_version: $schema_version,
      timestamp: $timestamp,
      action_id: $action_id,
      session_id: $session_id,
      invocation_id: $invocation_id,
      source: {
        type: $source_type,
        name: $source_name
      },
      action: {
        category: $category,
        operation: $operation,
        command: (if $command == "" then null else $command end)
      },
      tier: {
        assigned: $tier,
        source: $tier_source
      },
      result: {
        status: $status,
        duration_ms: $duration_ms
      },
      context: {
        repo: $repo,
        branch: $branch
      }
    }')

  # Validate JSON before writing
  if ! validate_json "$json_entry"; then
    echo "ERROR: Generated invalid JSON" >&2
    return 1
  fi

  # Container mode: emit to stdout marker and skip file write
  # Logs are extracted from container stdout after exit
  local container_mode=false
  if [ "${CLAUDE_CONTAINER_MODE:-}" = "true" ] || [ -f "/.dockerenv" ]; then
    container_mode=true
  fi

  if [ "$container_mode" = "true" ]; then
    # Emit marker for extraction (no file write in container)
    echo "ACTION_LOG=$json_entry"
  else
    # Normal mode: write to file
    # Ensure log directory exists
    mkdir -p "$LOG_DIR"

    # Rotate if needed
    rotate_logs

    # Append to log file
    echo "$json_entry" >> "$LOG_FILE"
  fi

  # Output action_id for reference
  echo "$action_id"
}

# --- Usage ---

usage() {
  cat <<'EOF'
Usage: action-log.sh [OPTIONS]

Log an action:
  action-log.sh \
    --source-type skill \
    --source-name sprint-work \
    --category github \
    --operation issue.close \
    [--tier T3] \
    [--status success] \
    [--command "gh issue close 123"] \
    [--duration-ms 450] \
    [--invocation-id UUID]

Session management:
  action-log.sh --current-session    # Get current session ID
  action-log.sh --new-session        # Start new session

Query helpers:
  action-log.sh --log-file           # Print log file path
  action-log.sh --validate           # Validate log file integrity

Options:
  --source-type TYPE    Source type (skill|agent|hook|manual) [required]
  --source-name NAME    Source name (e.g., sprint-work) [required]
  --category CAT        Action category (github|git|file|shell|api) [required]
  --operation OP        Operation name (e.g., issue.close) [required]
  --tier TIER           Permission tier (T0|T1|T2|T3) [auto-detected if omitted]
  --status STATUS       Result status (success|failure|blocked|timeout) [default: success]
  --command CMD         Actual command executed (sanitized before storage)
  --duration-ms MS      Duration in milliseconds [default: 0]
  --invocation-id UUID  Link to metrics invocation ID
  --current-session     Print current session ID
  --new-session         Start and print new session ID
  --log-file            Print log file path
  --validate            Validate log file JSON integrity
  -h, --help            Show this help
EOF
}

# --- Validate Log File ---

validate_log() {
  if [[ ! -f "$LOG_FILE" ]]; then
    echo "No log file found at $LOG_FILE"
    return 0
  fi

  local total=0
  local valid=0
  local invalid=0

  while IFS= read -r line; do
    total=$((total + 1))
    if echo "$line" | jq empty 2>/dev/null; then
      valid=$((valid + 1))
    else
      invalid=$((invalid + 1))
      echo "Invalid JSON on line $total" >&2
    fi
  done < "$LOG_FILE"

  echo "Total: $total, Valid: $valid, Invalid: $invalid"
  if [[ "$invalid" -gt 0 ]]; then
    return 1
  fi
  return 0
}

# --- Main ---

main() {
  local source_type="" source_name="" category="" operation=""
  local tier="" status="success" command="" duration_ms="0" invocation_id=""

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-type)   source_type="$2"; shift 2 ;;
      --source-name)   source_name="$2"; shift 2 ;;
      --category)      category="$2"; shift 2 ;;
      --operation)     operation="$2"; shift 2 ;;
      --tier)          tier="$2"; shift 2 ;;
      --status)        status="$2"; shift 2 ;;
      --command)       command="$2"; shift 2 ;;
      --duration-ms)   duration_ms="$2"; shift 2 ;;
      --invocation-id) invocation_id="$2"; shift 2 ;;
      --current-session)
        get_current_session
        exit 0
        ;;
      --new-session)
        new_session
        exit 0
        ;;
      --log-file)
        echo "$LOG_FILE"
        exit 0
        ;;
      --validate)
        validate_log
        exit $?
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  log_action "$source_type" "$source_name" "$category" "$operation" \
    "$tier" "$status" "$command" "$duration_ms" "$invocation_id"
}

main "$@"
