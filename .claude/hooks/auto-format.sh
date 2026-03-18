#!/bin/bash
set -euo pipefail
# auto-format.sh
# Claude Code PostToolUse hook for auto-formatting code after Write/Edit tool use
#
# Receives JSON via stdin with:
#   - tool_name: "Write" or "Edit"
#   - tool_input: { file_path, content, ... }
#   - tool_response: { ... }
#   - session_id, cwd, hook_event_name
#
# Behavior:
#   - Python files: run ruff format + ruff check --fix (if ruff available)
#   - Shell scripts: run shellcheck (reporting only, non-blocking)
#   - JS/TS files: run prettier --write (if prettier available)
#   - Completes in <2s per file
#   - Non-blocking: format failures warn but do not block agent work
#
# Exit codes: 0 = success (always, never blocks tool use)

# Do NOT use set -e; we want non-blocking behavior throughout
set -uo pipefail

# Timeout for each formatter in seconds (keep total <2s)
FORMATTER_TIMEOUT=5

# Get project root from env or derive from script location
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Read JSON from stdin
json_input=$(cat)

# Only process PostToolUse events
hook_event="${HOOK_EVENT_NAME:-}"
if [[ -z "${hook_event}" ]]; then
  hook_event=$(echo "${json_input}" | jq -r '.hook_event_name // ""' 2>/dev/null || echo "")
fi

if [[ "${hook_event}" != "PostToolUse" ]]; then
  exit 0
fi

# Only process Write and Edit tools
tool_name=$(echo "${json_input}" | jq -r '.tool_name // ""' 2>/dev/null || echo "")
if [[ "${tool_name}" != "Write" && "${tool_name}" != "Edit" ]]; then
  exit 0
fi

# Extract the file path from tool input
file_path=$(echo "${json_input}" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")

# Skip if no file path
if [[ -z "${file_path}" ]]; then
  exit 0
fi

# Resolve to absolute path if relative
if [[ "${file_path}" != /* ]]; then
  cwd=$(echo "${json_input}" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  if [[ -n "${cwd}" ]]; then
    file_path="${cwd}/${file_path}"
  else
    file_path="${PROJECT_ROOT}/${file_path}"
  fi
fi

# Skip if file does not exist
if [[ ! -f "${file_path}" ]]; then
  exit 0
fi

# Determine file extension
file_ext="${file_path##*.}"
file_basename=$(basename "${file_path}")

# Helper: warn without blocking
warn() {
  echo "[auto-format] WARNING: $*" >&2
}

# Helper: run a command with timeout, non-blocking on failure
run_formatter() {
  local label="$1"
  shift
  local timeout_seconds="${FORMATTER_TIMEOUT}"

  # Use timeout command if available
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "${timeout_seconds}" "$@" 2>/dev/null; then
      warn "${label} failed or timed out on ${file_path} (non-blocking)"
    fi
  else
    # No timeout command - run directly, still non-blocking
    if ! "$@" 2>/dev/null; then
      warn "${label} failed on ${file_path} (non-blocking)"
    fi
  fi
}

# ─── Python files ────────────────────────────────────────────────────────────
if [[ "${file_ext}" == "py" ]]; then
  if command -v ruff >/dev/null 2>&1; then
    run_formatter "ruff format" ruff format --quiet "${file_path}"
    run_formatter "ruff check --fix" ruff check --fix --quiet "${file_path}"
  fi

# ─── Shell scripts ────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "sh" || "${file_ext}" == "bash" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck is reporting only - we capture output and warn, never block
    shellcheck_output=$(timeout "${FORMATTER_TIMEOUT}" shellcheck --severity=warning "${file_path}" 2>&1 || true)
    if [[ -n "${shellcheck_output}" ]]; then
      warn "shellcheck findings in ${file_path}:"
      echo "${shellcheck_output}" | while IFS= read -r line; do
        echo "[auto-format]   ${line}" >&2
      done
    fi
  fi

# ─── JS / TS files ────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "js" || "${file_ext}" == "ts" || \
        "${file_ext}" == "jsx" || "${file_ext}" == "tsx" || \
        "${file_ext}" == "mjs" || "${file_ext}" == "cjs" ]]; then
  if command -v prettier >/dev/null 2>&1; then
    run_formatter "prettier" prettier --write --log-level=warn "${file_path}"
  fi

# ─── JSON files ───────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "json" ]]; then
  if command -v prettier >/dev/null 2>&1; then
    run_formatter "prettier" prettier --write --log-level=warn "${file_path}"
  fi

fi

# Always exit 0 - hook is non-blocking
exit 0
