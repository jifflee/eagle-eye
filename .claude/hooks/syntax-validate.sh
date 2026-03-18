#!/bin/bash
set -euo pipefail
# syntax-validate.sh
# Claude Code PostToolUse hook for syntax validation after Write/Edit
#
# Validates syntax of edited files so Claude can self-correct immediately.
# Runs after auto-format.sh in the hook chain.
#
# Checks:
#   - Shell scripts (*.sh): bash -n syntax check
#   - Python files (*.py): python3 -m py_compile
#   - JSON files (*.json): jq validation
#   - YAML files (*.yml, *.yaml): python3 yaml.safe_load
#
# Output:
#   - Prints clear error messages to stderr for Claude to read
#   - Prefixed with [syntax-validate] for easy identification
#
# Exit codes: 0 = always (non-blocking, but surfaces errors clearly)

set -uo pipefail

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

# Extract file path
file_path=$(echo "${json_input}" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
if [[ -z "${file_path}" ]]; then
  exit 0
fi

# Resolve relative path
if [[ "${file_path}" != /* ]]; then
  cwd=$(echo "${json_input}" | jq -r '.cwd // ""' 2>/dev/null || echo "")
  if [[ -n "${cwd}" ]]; then
    file_path="${cwd}/${file_path}"
  fi
fi

# Skip if file does not exist
if [[ ! -f "${file_path}" ]]; then
  exit 0
fi

file_ext="${file_path##*.}"
file_basename=$(basename "${file_path}")

# ─── Shell scripts ────────────────────────────────────────────────────────────
if [[ "${file_ext}" == "sh" || "${file_ext}" == "bash" ]]; then
  syntax_output=$(bash -n "${file_path}" 2>&1)
  if [[ $? -ne 0 ]]; then
    echo "[syntax-validate] SYNTAX ERROR in ${file_basename}:" >&2
    echo "${syntax_output}" | while IFS= read -r line; do
      echo "[syntax-validate]   ${line}" >&2
    done
    echo "[syntax-validate] Fix the syntax error above before proceeding." >&2
  fi

# ─── Python files ─────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "py" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    syntax_output=$(python3 -m py_compile "${file_path}" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "[syntax-validate] SYNTAX ERROR in ${file_basename}:" >&2
      echo "${syntax_output}" | while IFS= read -r line; do
        echo "[syntax-validate]   ${line}" >&2
      done
      echo "[syntax-validate] Fix the syntax error above before proceeding." >&2
      # Clean up __pycache__ from py_compile
      pycache_dir=$(dirname "${file_path}")/__pycache__
      rm -rf "${pycache_dir}" 2>/dev/null || true
    fi
  fi

# ─── JSON files ───────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "json" ]]; then
  if command -v jq >/dev/null 2>&1; then
    syntax_output=$(jq '.' "${file_path}" >/dev/null 2>&1)
    if [[ $? -ne 0 ]]; then
      # Get the actual error message
      error_msg=$(jq '.' "${file_path}" 2>&1 >/dev/null || true)
      echo "[syntax-validate] INVALID JSON in ${file_basename}:" >&2
      echo "[syntax-validate]   ${error_msg}" >&2
      echo "[syntax-validate] Fix the JSON syntax error above before proceeding." >&2
    fi
  fi

# ─── YAML files ───────────────────────────────────────────────────────────────
elif [[ "${file_ext}" == "yml" || "${file_ext}" == "yaml" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    syntax_output=$(python3 -c "
import yaml, sys
try:
    with open('${file_path}') as f:
        yaml.safe_load(f)
except yaml.YAMLError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
except ImportError:
    sys.exit(0)
" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "[syntax-validate] INVALID YAML in ${file_basename}:" >&2
      echo "${syntax_output}" | while IFS= read -r line; do
        echo "[syntax-validate]   ${line}" >&2
      done
      echo "[syntax-validate] Fix the YAML syntax error above before proceeding." >&2
    fi
  fi
fi

# Always exit 0 - non-blocking but informative
exit 0
