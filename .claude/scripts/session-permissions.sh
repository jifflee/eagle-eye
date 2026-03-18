#!/usr/bin/env bash
# session-permissions.sh - Manage session-scoped permission cache for T2 operations
# Part of Issue #225 - Tier-based auto-approval mechanism
#
# Usage:
#   session-permissions.sh --check T2 create-pr      # Check if approved
#   session-permissions.sh --approve T2 create-pr    # Mark as approved
#   session-permissions.sh --session-id              # Get current session ID
#   session-permissions.sh --new-session             # Start new session
#   session-permissions.sh --list                    # List all approvals
#   session-permissions.sh --clear                   # Clear session

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SESSION_PERM_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CACHE_DIR="$REPO_ROOT/.claude"
CACHE_FILE="$CACHE_DIR/session-permissions.json"
SESSION_FILE="$CACHE_DIR/.current-session"

# Default session expiry: 24 hours (in seconds)
SESSION_EXPIRY_SECONDS="${SESSION_EXPIRY_SECONDS:-86400}"

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

get_epoch() {
  date +%s
}

# --- Session Management ---

# Get or create session ID
get_session_id() {
  if [[ -f "$SESSION_FILE" ]]; then
    cat "$SESSION_FILE"
  else
    create_new_session
  fi
}

# Create new session and initialize cache
create_new_session() {
  local session_id
  session_id="$(generate_uuid)"

  mkdir -p "$CACHE_DIR"
  echo "$session_id" > "$SESSION_FILE"

  # Initialize empty cache
  jq -n \
    --arg session_id "$session_id" \
    --arg started_at "$(get_timestamp)" \
    '{
      schema_version: "1.0",
      session_id: $session_id,
      started_at: $started_at,
      approvals: {
        T2: {},
        T3: {}
      }
    }' > "$CACHE_FILE"

  echo "$session_id"
}

# Check if session is expired
is_session_expired() {
  if [[ ! -f "$CACHE_FILE" ]]; then
    return 0  # No cache = expired
  fi

  local started_at
  started_at=$(jq -r '.started_at // empty' "$CACHE_FILE" 2>/dev/null)

  if [[ -z "$started_at" ]]; then
    return 0  # No timestamp = expired
  fi

  # Convert ISO timestamp to epoch (cross-platform)
  local started_epoch
  if date --version >/dev/null 2>&1; then
    # GNU date
    started_epoch=$(date -d "$started_at" +%s 2>/dev/null) || return 0
  else
    # BSD date (macOS)
    started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" +%s 2>/dev/null) || return 0
  fi

  local now_epoch
  now_epoch=$(get_epoch)
  local age=$((now_epoch - started_epoch))

  if [[ "$age" -gt "$SESSION_EXPIRY_SECONDS" ]]; then
    return 0  # Expired
  fi

  return 1  # Not expired
}

# Validate session - check if current session matches cache
validate_session() {
  if [[ ! -f "$SESSION_FILE" || ! -f "$CACHE_FILE" ]]; then
    return 1
  fi

  local current_session cached_session
  current_session=$(cat "$SESSION_FILE")
  cached_session=$(jq -r '.session_id // empty' "$CACHE_FILE" 2>/dev/null)

  if [[ "$current_session" != "$cached_session" ]]; then
    return 1  # Session mismatch
  fi

  if is_session_expired; then
    return 1  # Expired
  fi

  return 0  # Valid
}

# Ensure valid session exists
ensure_valid_session() {
  if ! validate_session; then
    create_new_session >/dev/null
  fi
}

# --- Permission Cache Operations ---

# Check if an operation is already approved in this session
# Returns 0 (true) if approved, 1 (false) if not
check_approval() {
  local tier="$1"
  local operation="$2"

  ensure_valid_session

  if [[ ! -f "$CACHE_FILE" ]]; then
    return 1
  fi

  local approved
  approved=$(jq -r --arg tier "$tier" --arg op "$operation" \
    '.approvals[$tier][$op].approved_at // empty' "$CACHE_FILE" 2>/dev/null)

  if [[ -n "$approved" ]]; then
    return 0  # Approved
  fi

  return 1  # Not approved
}

# Mark an operation as approved in this session
approve_operation() {
  local tier="$1"
  local operation="$2"
  local scope="${3:-session}"  # session or one-time

  ensure_valid_session

  # Read current cache
  local current
  current=$(cat "$CACHE_FILE")

  # Add approval
  echo "$current" | jq \
    --arg tier "$tier" \
    --arg op "$operation" \
    --arg approved_at "$(get_timestamp)" \
    --arg scope "$scope" \
    '.approvals[$tier][$op] = {
      approved_at: $approved_at,
      scope: $scope
    }' > "$CACHE_FILE.tmp"

  mv "$CACHE_FILE.tmp" "$CACHE_FILE"

  echo "Approved: $tier/$operation (scope: $scope)"
}

# Revoke an approval
revoke_approval() {
  local tier="$1"
  local operation="$2"

  if [[ ! -f "$CACHE_FILE" ]]; then
    echo "No session cache found"
    return 1
  fi

  local current
  current=$(cat "$CACHE_FILE")

  echo "$current" | jq \
    --arg tier "$tier" \
    --arg op "$operation" \
    'del(.approvals[$tier][$op])' > "$CACHE_FILE.tmp"

  mv "$CACHE_FILE.tmp" "$CACHE_FILE"

  echo "Revoked: $tier/$operation"
}

# List all approvals in current session
list_approvals() {
  ensure_valid_session

  if [[ ! -f "$CACHE_FILE" ]]; then
    echo "No approvals in current session"
    return 0
  fi

  local session_id started_at
  session_id=$(jq -r '.session_id' "$CACHE_FILE")
  started_at=$(jq -r '.started_at' "$CACHE_FILE")

  echo "Session: $session_id"
  echo "Started: $started_at"
  echo ""
  echo "Approvals:"

  jq -r '
    .approvals | to_entries[] |
    .key as $tier |
    .value | to_entries[] |
    "  \($tier)/\(.key): approved at \(.value.approved_at) (scope: \(.value.scope))"
  ' "$CACHE_FILE" 2>/dev/null || echo "  (none)"
}

# Clear session and start fresh
clear_session() {
  rm -f "$SESSION_FILE" "$CACHE_FILE"
  echo "Session cleared"
}

# Get session info as JSON
get_session_info() {
  ensure_valid_session

  if [[ ! -f "$CACHE_FILE" ]]; then
    jq -n '{
      valid: false,
      reason: "no_cache"
    }'
    return
  fi

  local session_id started_at approval_count
  session_id=$(jq -r '.session_id' "$CACHE_FILE")
  started_at=$(jq -r '.started_at' "$CACHE_FILE")
  approval_count=$(jq '[.approvals | .[] | keys | length] | add // 0' "$CACHE_FILE")

  jq -n \
    --arg session_id "$session_id" \
    --arg started_at "$started_at" \
    --argjson approval_count "$approval_count" \
    --argjson expiry_seconds "$SESSION_EXPIRY_SECONDS" \
    '{
      valid: true,
      session_id: $session_id,
      started_at: $started_at,
      approval_count: $approval_count,
      expiry_seconds: $expiry_seconds
    }'
}

# --- Usage ---

usage() {
  cat <<'EOF'
Usage: session-permissions.sh [OPTIONS]

Manage session-scoped permission cache for T2 operations.

Check/Approve:
  --check TIER OPERATION      Check if operation is approved (exit code 0=yes)
  --approve TIER OPERATION    Mark operation as approved for this session
  --revoke TIER OPERATION     Revoke an approval

Session management:
  --session-id                Get current session ID
  --new-session               Start new session (clears approvals)
  --clear                     Clear session and all approvals
  --info                      Get session info as JSON

List:
  --list                      List all approvals in current session

Environment:
  SESSION_EXPIRY_SECONDS      Session expiry time (default: 86400 = 24h)

Examples:
  session-permissions.sh --check T2 create-pr
  session-permissions.sh --approve T2 git-push
  session-permissions.sh --list

Exit codes:
  0 - Success (or approval exists for --check)
  1 - No approval (for --check) or error
EOF
}

# --- Main ---

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  local mode=""
  local tier="" operation="" scope="session"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        mode="check"
        tier="$2"
        operation="$3"
        shift 3
        ;;
      --approve)
        mode="approve"
        tier="$2"
        operation="$3"
        shift 3
        ;;
      --revoke)
        mode="revoke"
        tier="$2"
        operation="$3"
        shift 3
        ;;
      --scope)
        scope="$2"
        shift 2
        ;;
      --session-id)
        get_session_id
        exit 0
        ;;
      --new-session)
        create_new_session
        exit 0
        ;;
      --clear)
        clear_session
        exit 0
        ;;
      --list)
        list_approvals
        exit 0
        ;;
      --info)
        get_session_info
        exit 0
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

  # Validate tier
  case "$tier" in
    T0|T1|T2|T3) ;;
    *) echo "ERROR: Invalid tier '$tier' (must be T0|T1|T2|T3)" >&2; exit 1 ;;
  esac

  case "$mode" in
    check)
      if check_approval "$tier" "$operation"; then
        exit 0
      else
        exit 1
      fi
      ;;
    approve)
      approve_operation "$tier" "$operation" "$scope"
      ;;
    revoke)
      revoke_approval "$tier" "$operation"
      ;;
    *)
      echo "ERROR: No operation specified" >&2
      exit 1
      ;;
  esac
}

main "$@"
