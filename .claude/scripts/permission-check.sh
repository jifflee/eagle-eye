#!/usr/bin/env bash
# permission-check.sh - Tier-based auto-approval mechanism
# Part of Issue #225 - Permission enforcement layer
# Extended for Issue #203 - Skill permission pre-approval
#
# Behavior Matrix:
#   T0/T1: Auto-approve (always)
#   T2: Prompt once per session, then cache
#   T3: Always prompt
#
# Skill Pre-Approval (Issue #203):
#   When --skill-file is provided, declared scripts may be auto-approved
#   if their tier <= skill's max_tier (and tier < T3)
#
# Usage:
#   permission-check.sh --command "gh issue close 123"
#   permission-check.sh --category github --operation issue.close
#   permission-check.sh --check-only --command "git push"
#   permission-check.sh --session-status
#   permission-check.sh --command "./scripts/foo.sh" --skill-file skill.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PERMISSION_CHECK_REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Configuration
CLAUDE_DIR="${CLAUDE_DIR:-${REPO_ROOT}/.claude}"
SESSION_FILE="${SESSION_FILE:-${CLAUDE_DIR}/session-permissions.json}"
ACTIONS_FILE="${ACTIONS_FILE:-${CLAUDE_DIR}/actions.jsonl}"
SESSION_TIMEOUT_HOURS="${SESSION_TIMEOUT_HOURS:-8}"  # Session expires after 8 hours

# --- Session Management ---

# Get or create session ID
get_session_id() {
  local current_session_file="${CLAUDE_DIR}/.current-session"

  if [[ -f "${current_session_file}" ]]; then
    cat "${current_session_file}"
  else
    # Generate new session ID
    local new_id
    new_id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s)
    echo "${new_id}" > "${current_session_file}"
    echo "${new_id}"
  fi
}

# Initialize session permissions file if needed
init_session() {
  local session_id
  session_id=$(get_session_id)

  # Create .claude directory if it doesn't exist
  mkdir -p "${CLAUDE_DIR}"

  # Check if session file exists and is valid
  if [[ -f "${SESSION_FILE}" ]]; then
    local file_session_id
    file_session_id=$(jq -r '.session_id // empty' "${SESSION_FILE}" 2>/dev/null || true)

    if [[ "${file_session_id}" == "${session_id}" ]]; then
      # Check for expiry
      if is_session_expired; then
        create_new_session "${session_id}"
      fi
      return 0
    fi
  fi

  # Create new session
  create_new_session "${session_id}"
}

# Create a new session permissions file
create_new_session() {
  local session_id="${1}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  cat > "${SESSION_FILE}" <<EOF
{
  "schema_version": "1.0",
  "session_id": "${session_id}",
  "started_at": "${timestamp}",
  "approvals": {
    "T2": {},
    "T3": {}
  }
}
EOF
}

# Check if current session has expired
is_session_expired() {
  if [[ ! -f "${SESSION_FILE}" ]]; then
    return 0  # No session = expired
  fi

  local started_at
  started_at=$(jq -r '.started_at // empty' "${SESSION_FILE}" 2>/dev/null || true)

  if [[ -z "${started_at}" ]]; then
    return 0
  fi

  # Convert to epoch and compare
  local start_epoch current_epoch timeout_seconds

  if date --version >/dev/null 2>&1; then
    # GNU date
    start_epoch=$(date -d "${started_at}" +%s 2>/dev/null || echo 0)
  else
    # BSD date (macOS)
    start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "${started_at}" +%s 2>/dev/null || echo 0)
  fi

  current_epoch=$(date +%s)
  timeout_seconds=$((SESSION_TIMEOUT_HOURS * 3600))

  if (( current_epoch - start_epoch > timeout_seconds )); then
    return 0  # Expired
  fi

  return 1  # Not expired
}

# Check if an operation is cached for T2
is_t2_cached() {
  local operation="${1}"

  if [[ ! -f "${SESSION_FILE}" ]]; then
    return 1
  fi

  local cached
  cached=$(jq -r --arg op "${operation}" \
    '.approvals.T2[$op].approved_at // empty' "${SESSION_FILE}" 2>/dev/null || true)

  [[ -n "${cached}" ]]
}

# Cache T2 approval
cache_t2_approval() {
  local operation="${1}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Use jq to update the session file
  local tmp_file
  tmp_file=$(mktemp)

  jq --arg op "${operation}" --arg ts "${timestamp}" \
    '.approvals.T2[$op] = {"approved_at": $ts, "scope": "session"}' \
    "${SESSION_FILE}" > "${tmp_file}" && mv "${tmp_file}" "${SESSION_FILE}"
}

# --- Action Audit Logging ---

log_action() {
  local tier="${1}"
  local category="${2}"
  local operation="${3}"
  local command="${4}"
  local decision="${5}"
  local auto_approved="${6}"
  local source="${7:-unknown}"

  local timestamp session_id
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  session_id=$(get_session_id)

  # Create actions file if it doesn't exist
  mkdir -p "$(dirname "${ACTIONS_FILE}")"

  # Append action record (JSONL format)
  jq -cn \
    --arg ts "${timestamp}" \
    --arg sid "${session_id}" \
    --arg tier "${tier}" \
    --arg cat "${category}" \
    --arg op "${operation}" \
    --arg cmd "${command}" \
    --arg dec "${decision}" \
    --argjson auto "${auto_approved}" \
    --arg src "${source}" \
    '{
      timestamp: $ts,
      session_id: $sid,
      tier: {assigned: $tier},
      action: {category: $cat, operation: $op, command: $cmd},
      approval: {approved: ($dec == "approved"), auto_approved: $auto},
      result: {status: (if $dec == "approved" then "success" else $dec end)},
      source: {name: $src}
    }' >> "${ACTIONS_FILE}"
}

# --- Skill Pre-Approval (Issue #203) ---

# Extract script name from command for skill permission check
extract_script_name() {
  local command="${1}"

  # Match patterns like:
  # ./scripts/foo.sh -> foo.sh
  # /path/to/scripts/bar.sh -> bar.sh
  # bash scripts/baz.sh -> baz.sh

  # Try to extract .sh script name from command
  if [[ "${command}" =~ ([^/[:space:]]+\.sh) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Check skill pre-approval for a command
# Returns JSON: {"pre_approved": bool, "reason": string, "declared_tier": tier}
check_skill_preapproval() {
  local command="${1}"
  local skill_file="${2}"
  local actual_tier="${3}"

  # No skill context - no pre-approval
  if [[ -z "${skill_file}" || ! -f "${skill_file}" ]]; then
    echo '{"pre_approved":false,"reason":"no_skill_context"}'
    return
  fi

  # Extract script name from command
  local script_name
  script_name=$(extract_script_name "${command}")

  if [[ -z "${script_name}" ]]; then
    echo '{"pre_approved":false,"reason":"not_a_script"}'
    return
  fi

  # Use parse-skill-permissions.sh to check effective tier
  local effective_result
  effective_result=$("${SCRIPT_DIR}/parse-skill-permissions.sh" \
    --skill-file "${skill_file}" \
    --effective-tier "${script_name}" \
    --actual-tier "${actual_tier}" 2>/dev/null || echo '{"auto_approved":false,"reason":"parse_error"}')

  local auto_approved reason effective_tier
  auto_approved=$(echo "${effective_result}" | jq -r '.auto_approved')
  reason=$(echo "${effective_result}" | jq -r '.reason')
  effective_tier=$(echo "${effective_result}" | jq -r '.effective_tier // empty')

  jq -cn \
    --argjson pre_approved "${auto_approved}" \
    --arg reason "${reason}" \
    --arg declared_tier "${effective_tier}" \
    --arg script_name "${script_name}" \
    '{
      pre_approved: $pre_approved,
      reason: $reason,
      declared_tier: (if $declared_tier == "" then null else $declared_tier end),
      script_name: $script_name
    }'
}

# --- Permission Check Core ---

# Check permission and return decision
# Returns: approved|prompt|denied
# Exit codes: 0=approved, 1=prompt needed, 2=denied
check_permission() {
  local command="${1:-}"
  local category="${2:-}"
  local operation="${3:-}"
  local check_only="${4:-false}"
  local source="${5:-unknown}"
  local skill_file="${6:-}"

  # Initialize session
  init_session

  # Look up tier using tier-lookup.sh
  local tier_result tier
  tier_result=$("${SCRIPT_DIR}/tier-lookup.sh" \
    ${command:+--command "${command}"} \
    ${category:+--category "${category}"} \
    ${operation:+--operation "${operation}"} \
    --format json 2>/dev/null || echo '{"tier":"T2","source":"error"}')

  tier=$(echo "${tier_result}" | jq -r '.tier')
  local lookup_category lookup_operation
  lookup_category=$(echo "${tier_result}" | jq -r '.category // empty')
  lookup_operation=$(echo "${tier_result}" | jq -r '.operation // empty')

  # Use looked-up values if provided values were empty
  category="${category:-${lookup_category}}"
  operation="${operation:-${lookup_operation}}"

  local decision="approved"
  local auto_approved=true
  local exit_code=0
  local skill_preapproval='{"pre_approved":false}'

  # --- Issue #203: Skill Pre-Approval Check ---
  # Before standard tier logic, check if skill declares this script for pre-approval
  if [[ -n "${skill_file}" && -n "${command}" ]]; then
    skill_preapproval=$(check_skill_preapproval "${command}" "${skill_file}" "${tier}")

    local skill_pre_approved
    skill_pre_approved=$(echo "${skill_preapproval}" | jq -r '.pre_approved')

    if [[ "${skill_pre_approved}" == "true" ]]; then
      # Skill pre-approval takes precedence for T0/T1/T2 scripts
      decision="approved"
      auto_approved=true
      exit_code=0

      # Log the action with skill pre-approval info
      if [[ "${check_only}" != "true" ]]; then
        log_action "${tier}" "${category}" "${operation}" "${command}" "${decision}" "${auto_approved}" "${source}"
      fi

      # Output result with skill pre-approval info
      jq -cn \
        --arg tier "${tier}" \
        --arg decision "${decision}" \
        --argjson auto_approved "${auto_approved}" \
        --arg category "${category}" \
        --arg operation "${operation}" \
        --arg command "${command}" \
        --argjson skill_preapproval "${skill_preapproval}" \
        '{
          tier: $tier,
          decision: $decision,
          auto_approved: $auto_approved,
          category: (if $category == "" then null else $category end),
          operation: (if $operation == "" then null else $operation end),
          command: (if $command == "" then null else $command end),
          action_required: false,
          skill_preapproval: $skill_preapproval
        }'

      return "${exit_code}"
    fi
  fi
  # --- End Issue #203 ---

  case "${tier}" in
    T0|T1)
      # Auto-approve, no prompting needed
      decision="approved"
      auto_approved=true
      exit_code=0
      ;;
    T2)
      # Check session cache
      if is_t2_cached "${operation}"; then
        decision="approved"
        auto_approved=true
        exit_code=0
      else
        if [[ "${check_only}" == "true" ]]; then
          decision="prompt"
          auto_approved=false
          exit_code=1
        else
          # Would prompt user here - for now, return that prompt is needed
          decision="prompt"
          auto_approved=false
          exit_code=1
        fi
      fi
      ;;
    T3)
      # Always prompt
      decision="prompt"
      auto_approved=false
      exit_code=1
      ;;
    *)
      # Unknown tier - treat as T2
      decision="prompt"
      auto_approved=false
      exit_code=1
      ;;
  esac

  # Log the action (unless check_only)
  if [[ "${check_only}" != "true" ]]; then
    log_action "${tier}" "${category}" "${operation}" "${command}" "${decision}" "${auto_approved}" "${source}"
  fi

  # Output result
  local output_json
  output_json=$(jq -cn \
    --arg tier "${tier}" \
    --arg decision "${decision}" \
    --argjson auto_approved "${auto_approved}" \
    --arg category "${category}" \
    --arg operation "${operation}" \
    --arg command "${command}" \
    '{
      tier: $tier,
      decision: $decision,
      auto_approved: $auto_approved,
      category: (if $category == "" then null else $category end),
      operation: (if $operation == "" then null else $operation end),
      command: (if $command == "" then null else $command end),
      action_required: ($decision != "approved")
    }')

  # Add skill_preapproval info if skill_file was provided (even if not pre-approved)
  if [[ -n "${skill_file}" ]]; then
    output_json=$(echo "${output_json}" | jq --argjson sp "${skill_preapproval}" '. + {skill_preapproval: $sp}')
  fi

  echo "${output_json}"
  return "${exit_code}"
}

# Approve a T2 operation (call after user approves)
approve_operation() {
  local operation="${1}"
  local source="${2:-user}"

  init_session

  # Get tier info to validate this is actually T2
  local tier_result tier
  tier_result=$("${SCRIPT_DIR}/tier-lookup.sh" --category "${3:-}" --operation "${operation}" --format json 2>/dev/null || echo '{"tier":"T2"}')
  tier=$(echo "${tier_result}" | jq -r '.tier')

  if [[ "${tier}" == "T2" ]]; then
    cache_t2_approval "${operation}"
    log_action "${tier}" "${3:-}" "${operation}" "" "approved" false "${source}"
    echo '{"status": "cached", "operation": "'"${operation}"'", "tier": "T2"}'
  else
    echo '{"status": "not_applicable", "operation": "'"${operation}"'", "tier": "'"${tier}"'", "reason": "Only T2 operations can be session-cached"}'
  fi
}

# Get session status
get_session_status() {
  init_session

  local session_id started_at
  session_id=$(jq -r '.session_id' "${SESSION_FILE}" 2>/dev/null || echo "unknown")
  started_at=$(jq -r '.started_at' "${SESSION_FILE}" 2>/dev/null || echo "unknown")

  local t2_cached
  t2_cached=$(jq -r '.approvals.T2 | keys | length' "${SESSION_FILE}" 2>/dev/null || echo "0")

  local expired="false"
  if is_session_expired; then
    expired="true"
  fi

  jq -cn \
    --arg sid "${session_id}" \
    --arg started "${started_at}" \
    --arg t2_count "${t2_cached}" \
    --argjson expired "${expired}" \
    --argjson timeout "${SESSION_TIMEOUT_HOURS}" \
    '{
      session_id: $sid,
      started_at: $started,
      expired: $expired,
      timeout_hours: $timeout,
      t2_cached_count: ($t2_count | tonumber),
      t2_cached_operations: []
    }' | jq --slurpfile session "${SESSION_FILE}" \
    '.t2_cached_operations = ($session[0].approvals.T2 | keys)'
}

# Clear session (for testing or manual reset)
clear_session() {
  rm -f "${SESSION_FILE}" "${CLAUDE_DIR}/.current-session"
  echo '{"status": "cleared"}'
}

# --- Usage ---

usage() {
  cat <<'EOF'
Usage: permission-check.sh [OPTIONS]

Tier-based permission enforcement for Claude Code operations.

Permission modes:
  --command CMD          Check permission for a command
  --category CAT         Category for lookup (with --operation)
  --operation OP         Operation for lookup (with --category)
  --check-only           Only check, don't log or cache
  --source NAME          Source skill/agent name for logging
  --skill-file FILE      Skill file for pre-approval (Issue #203)

Actions:
  --approve OP           Cache T2 approval for an operation
  --session-status       Show current session status
  --clear-session        Clear session and start fresh

Options:
  --format FORMAT        Output format: json (default)
  -h, --help             Show this help

Tier Behavior:
  T0/T1  Auto-approve always
  T2     Prompt once per session, then cached
  T3     Always prompt (never cached)

Skill Pre-Approval (--skill-file):
  When a skill file is provided, scripts declared in the skill's
  permissions block may be auto-approved if:
  - Script is declared in the skill's "scripts" array
  - Script's tier <= skill's "max_tier"
  - Script's tier < T3 (T3 always prompts)

Exit codes:
  0 - Approved (can proceed)
  1 - Prompt needed (ask user)
  2 - Denied or error

Examples:
  # Check if a command is auto-approved
  permission-check.sh --command "git status"

  # Check operation in a category
  permission-check.sh --category github --operation pr.merge

  # Cache T2 approval after user confirms
  permission-check.sh --approve pr.create --category github

  # Check with skill context for pre-approval
  permission-check.sh --command "./scripts/my-script.sh" --skill-file skill.md

  # Get session info
  permission-check.sh --session-status
EOF
}

# --- Main ---

main() {
  local command="" category="" operation="" source="unknown"
  local skill_file=""
  local check_only=false
  local mode="check"

  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --command)
        command="${2}"
        shift 2
        ;;
      --category)
        category="${2}"
        shift 2
        ;;
      --operation)
        operation="${2}"
        shift 2
        ;;
      --source)
        source="${2}"
        shift 2
        ;;
      --skill-file)
        skill_file="${2}"
        shift 2
        ;;
      --check-only)
        check_only=true
        shift
        ;;
      --approve)
        mode="approve"
        operation="${2}"
        shift 2
        ;;
      --session-status)
        mode="status"
        shift
        ;;
      --clear-session)
        mode="clear"
        shift
        ;;
      --format)
        # Currently only JSON is supported
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option '${1}'" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "${mode}" in
    check)
      if [[ -z "${command}" && ( -z "${category}" || -z "${operation}" ) ]]; then
        echo "ERROR: Provide --command or both --category and --operation" >&2
        exit 2
      fi
      check_permission "${command}" "${category}" "${operation}" "${check_only}" "${source}" "${skill_file}"
      ;;
    approve)
      if [[ -z "${operation}" ]]; then
        echo "ERROR: --approve requires an operation name" >&2
        exit 2
      fi
      approve_operation "${operation}" "${source}" "${category}"
      ;;
    status)
      get_session_status
      ;;
    clear)
      clear_session
      ;;
    *)
      echo "ERROR: Unknown mode '${mode}'" >&2
      exit 2
      ;;
  esac
}

main "$@"
