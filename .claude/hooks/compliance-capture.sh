#!/bin/bash
set -euo pipefail
# compliance-capture.sh
# Claude Code PostToolUse hook for capturing coding standard violations
# with agent attribution.
#
# Receives JSON via stdin with:
#   - tool_name: "Write" or "Edit"
#   - tool_input: { file_path, ... }
#   - tool_response: { ... }
#   - session_id, cwd, hook_event_name
#   - agent context from CLAUDE_AGENT_NAME env var (when invoked via Task tool)
#
# Behavior:
#   - Runs lightweight checks on the modified file
#   - Checks: script size (>300 lines), naming conventions, shellcheck warnings
#   - Logs violations to .claude/metrics.jsonl via compliance-log.sh
#   - Non-blocking: violations are logged but never prevent tool use
#
# Exit codes: 0 = success (always non-blocking)

# Do NOT use set -e; we want non-blocking behavior throughout
set -uo pipefail

# Get project root from env or derive from script location
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
COMPLIANCE_LOG_SCRIPT="$PROJECT_ROOT/scripts/compliance-log.sh"

# Check if compliance collection is enabled
if [ "${CLAUDE_METRICS_ENABLED:-true}" = "false" ]; then
  exit 0
fi

# Check if compliance log script exists
if [ ! -x "$COMPLIANCE_LOG_SCRIPT" ]; then
  exit 0
fi

# Read JSON from stdin
json_input=$(cat)

# Only process PostToolUse events
hook_event="${HOOK_EVENT_NAME:-}"
if [ -z "${hook_event}" ]; then
  hook_event=$(echo "${json_input}" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
fi

if [ "${hook_event}" != "PostToolUse" ]; then
  exit 0
fi

# Only process Write and Edit tools
tool_name=$(echo "${json_input}" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
if [ "${tool_name}" != "Write" ] && [ "${tool_name}" != "Edit" ]; then
  exit 0
fi

# Extract the file path from tool input
file_path=$(echo "${json_input}" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# Skip if no file path
if [ -z "${file_path}" ]; then
  exit 0
fi

# Resolve to absolute path if relative
if [[ "${file_path}" != /* ]]; then
  cwd=$(echo "${json_input}" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  if [ -n "${cwd}" ]; then
    file_path="${cwd}/${file_path}"
  else
    file_path="${PROJECT_ROOT}/${file_path}"
  fi
fi

# Skip if file does not exist
if [ ! -f "${file_path}" ]; then
  exit 0
fi

# Determine agent attribution:
# 1. CLAUDE_AGENT_NAME env var (set by Task tool invocation context)
# 2. CLAUDE_SUBAGENT_TYPE env var (alternate form)
# 3. "main-claude" as fallback (direct Claude session)
agent_name="${CLAUDE_AGENT_NAME:-${CLAUDE_SUBAGENT_TYPE:-}}"
if [ -z "${agent_name}" ]; then
  agent_name="main-claude"
fi

# Extract session ID for correlation
session_id=$(echo "${json_input}" | jq -r '.session_id // ""' 2>/dev/null || echo "")

# Helper: log a compliance violation (non-blocking)
log_violation() {
  local violation_type="$1"
  local severity="$2"
  local rule_id="$3"
  local message="$4"

  "$COMPLIANCE_LOG_SCRIPT" \
    --agent "${agent_name}" \
    --file "${file_path}" \
    --violation-type "${violation_type}" \
    --severity "${severity}" \
    --rule "${rule_id}" \
    --message "${message}" \
    --session "${session_id}" \
    2>/dev/null || true
}

# Determine file extension
file_ext="${file_path##*.}"
file_basename=$(basename "${file_path}")

# ─── Check 1: Script size violation ──────────────────────────────────────────
# Shell scripts over 300 lines are flagged as "Large" and over 500 as "EXCEEDED"
if [[ "${file_ext}" == "sh" || "${file_ext}" == "bash" ]]; then
  line_count=$(wc -l < "${file_path}" 2>/dev/null | tr -d ' ' || echo "0")

  if [[ "${line_count}" =~ ^[0-9]+$ ]]; then
    # Check for size-ok annotation (exempts the file from size checks)
    has_size_ok=false
    if head -30 "${file_path}" 2>/dev/null | grep -q '^# size-ok:'; then
      has_size_ok=true
    fi

    if [ "${has_size_ok}" = "false" ]; then
      if [ "${line_count}" -gt 500 ]; then
        log_violation "size" "error" "script-size-exceeded" \
          "Script exceeds hard limit: ${line_count} lines (limit: 500). Consider splitting."
      elif [ "${line_count}" -gt 300 ]; then
        log_violation "size" "warning" "script-size-large" \
          "Script is large: ${line_count} lines (warning threshold: 300). Review for splitting."
      fi
    fi
  fi
fi

# ─── Check 2: Naming convention violations ────────────────────────────────────
# Shell scripts should follow: lowercase-with-hyphens.sh
if [[ "${file_ext}" == "sh" || "${file_ext}" == "bash" ]]; then
  # Only check scripts in scripts/ or .claude/hooks/
  if [[ "${file_path}" == */scripts/* ]] || [[ "${file_path}" == */.claude/hooks/* ]]; then
    if [[ ! "${file_basename}" =~ ^[a-z][a-z0-9-]*\.(sh|bash)$ ]]; then
      log_violation "naming" "warning" "script-naming-convention" \
        "Script name '${file_basename}' does not follow lowercase-with-hyphens convention."
    fi
  fi
fi

# Python files should follow: lowercase_with_underscores.py
if [[ "${file_ext}" == "py" ]]; then
  if [[ "${file_path}" == */scripts/* ]]; then
    if [[ ! "${file_basename}" =~ ^[a-z][a-z0-9_]*\.py$ ]]; then
      log_violation "naming" "warning" "python-naming-convention" \
        "Python file '${file_basename}' should use lowercase_with_underscores convention."
    fi
  fi
fi

# ─── Check 3: shellcheck lint violations ──────────────────────────────────────
# Run shellcheck on shell scripts and log findings
if [[ "${file_ext}" == "sh" || "${file_ext}" == "bash" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then
    # Run shellcheck, capture output
    shellcheck_errors=0
    shellcheck_warnings=0

    # Count errors (SC codes with severity=error)
    shellcheck_out=$(timeout 10 shellcheck --format=json "${file_path}" 2>/dev/null || echo "[]")

    if [ -n "${shellcheck_out}" ] && [ "${shellcheck_out}" != "[]" ]; then
      # Count by severity
      shellcheck_errors=$(echo "${shellcheck_out}" | jq '[.[] | select(.level == "error")] | length' 2>/dev/null || echo "0")
      shellcheck_warnings=$(echo "${shellcheck_out}" | jq '[.[] | select(.level == "warning")] | length' 2>/dev/null || echo "0")

      if [[ "${shellcheck_errors}" =~ ^[0-9]+$ ]] && [ "${shellcheck_errors}" -gt 0 ]; then
        # Get first error details for the message
        first_error=$(echo "${shellcheck_out}" | jq -r '[.[] | select(.level == "error")] | first | "SC\(.code): \(.message)"' 2>/dev/null || echo "shellcheck errors found")
        log_violation "lint" "error" "shellcheck-error" \
          "${shellcheck_errors} shellcheck error(s). First: ${first_error}"
      fi

      if [[ "${shellcheck_warnings}" =~ ^[0-9]+$ ]] && [ "${shellcheck_warnings}" -gt 0 ]; then
        first_warning=$(echo "${shellcheck_out}" | jq -r '[.[] | select(.level == "warning")] | first | "SC\(.code): \(.message)"' 2>/dev/null || echo "shellcheck warnings found")
        log_violation "lint" "warning" "shellcheck-warning" \
          "${shellcheck_warnings} shellcheck warning(s). First: ${first_warning}"
      fi
    fi
  fi
fi

# ─── Check 4: Python lint violations ─────────────────────────────────────────
# Run ruff on Python files and log findings
if [[ "${file_ext}" == "py" ]]; then
  if command -v ruff >/dev/null 2>&1; then
    ruff_out=$(timeout 10 ruff check --output-format=json "${file_path}" 2>/dev/null || echo "[]")

    if [ -n "${ruff_out}" ] && [ "${ruff_out}" != "[]" ]; then
      error_count=$(echo "${ruff_out}" | jq '[.[] | select(.cell == null)] | length' 2>/dev/null || echo "0")

      if [[ "${error_count}" =~ ^[0-9]+$ ]] && [ "${error_count}" -gt 0 ]; then
        first_issue=$(echo "${ruff_out}" | jq -r 'first | "\(.code): \(.message)"' 2>/dev/null || echo "ruff violations found")
        log_violation "lint" "warning" "ruff-lint" \
          "${error_count} ruff violation(s). First: ${first_issue}"
      fi
    fi
  fi
fi

# ─── Check 5: Format violations ──────────────────────────────────────────────
# Check if Python file needs formatting (ruff format --check)
if [[ "${file_ext}" == "py" ]]; then
  if command -v ruff >/dev/null 2>&1; then
    if ! timeout 5 ruff format --check --quiet "${file_path}" 2>/dev/null; then
      log_violation "format" "warning" "ruff-format" \
        "Python file '${file_basename}' needs formatting (ruff format)."
    fi
  fi
fi

# Always exit 0 - hook is non-blocking
exit 0
