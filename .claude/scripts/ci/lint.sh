#!/usr/bin/env bash
# Purpose: Run linting for Python and shell scripts
# Usage: ./scripts/ci/lint.sh [--python] [--shell] [--changed-only]
#
# By default runs all linters. Use flags to select specific linters.
#
# Python linting:
#   Uses ruff (fast Python linter) if available, falls back to flake8.
#   Configuration is read from pyproject.toml [tool.ruff].
#
# Shell linting:
#   Delegates to scripts/ci/shellcheck.sh for shellcheck analysis.
#
# Options:
#   --python        Run Python linter only
#   --shell         Run shell linter (shellcheck) only
#   --changed-only  Only lint files changed vs. origin/main
#   --fix           Auto-fix issues where possible (Python only)
#
# Exit codes:
#   0  All linters pass
#   1  One or more linters reported issues

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUN_PYTHON=true
RUN_SHELL=true
CHANGED_ONLY=false
AUTO_FIX=false
FAILED=0

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --python)
      RUN_SHELL=false
      ;;
    --shell)
      RUN_PYTHON=false
      ;;
    --changed-only)
      CHANGED_ONLY=true
      ;;
    --fix)
      AUTO_FIX=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--python] [--shell] [--changed-only] [--fix]" >&2
      exit 1
      ;;
  esac
done

cd "${REPO_ROOT}"

# ─── Helper ──────────────────────────────────────────────────────────────────

section() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── Python Linting ───────────────────────────────────────────────────────────

lint_python() {
  section "Python Linting"

  # Collect Python files to lint
  if [[ "${CHANGED_ONLY}" == "true" ]]; then
    BASE_REF="${GITHUB_BASE_REF:-main}"
    PY_FILES=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null \
      | grep '\.py$' || true)
    if [[ -z "${PY_FILES}" ]]; then
      echo "No Python file changes detected. Skipping Python linting."
      return 0
    fi
  else
    PY_FILES=$(find . \
      -not \( -path './.git/*' -prune \) \
      -not \( -path './node_modules/*' -prune \) \
      -not \( -path './.venv/*' -prune \) \
      -not \( -path './venv/*' -prune \) \
      -not \( -path './__pycache__/*' -prune \) \
      -name '*.py' \
      -type f \
      | sort)
  fi

  if [[ -z "${PY_FILES}" ]]; then
    echo "No Python files found. Skipping."
    return 0
  fi

  local py_count
  py_count=$(echo "${PY_FILES}" | wc -l | tr -d ' ')
  echo "Linting ${py_count} Python file(s)..."

  # Try ruff first (fast, configured via pyproject.toml)
  if command -v ruff &>/dev/null; then
    echo "Using ruff (configured via pyproject.toml)"
    local ruff_args=("check")
    if [[ "${AUTO_FIX}" == "true" ]]; then
      ruff_args+=("--fix")
      echo "Auto-fix mode enabled."
    fi

    if [[ "${CHANGED_ONLY}" == "true" ]]; then
      # Pass files explicitly
      # shellcheck disable=SC2086
      if ruff "${ruff_args[@]}" ${PY_FILES}; then
        echo "✅ Python (ruff): PASSED"
      else
        echo "❌ Python (ruff): FAILED"
        FAILED=$((FAILED + 1))
      fi
    else
      if ruff "${ruff_args[@]}" .; then
        echo "✅ Python (ruff): PASSED"
      else
        echo "❌ Python (ruff): FAILED"
        FAILED=$((FAILED + 1))
      fi
    fi

    # Also run ruff format check
    local fmt_args=("format")
    if [[ "${AUTO_FIX}" == "false" ]]; then
      fmt_args+=("--check")
    fi
    echo ""
    echo "Running ruff format check..."
    if [[ "${CHANGED_ONLY}" == "true" ]]; then
      # shellcheck disable=SC2086
      if ruff "${fmt_args[@]}" ${PY_FILES}; then
        echo "✅ Python format (ruff): PASSED"
      else
        echo "❌ Python format (ruff): FAILED"
        FAILED=$((FAILED + 1))
      fi
    else
      if ruff "${fmt_args[@]}" .; then
        echo "✅ Python format (ruff): PASSED"
      else
        echo "❌ Python format (ruff): FAILED"
        FAILED=$((FAILED + 1))
      fi
    fi

  elif command -v flake8 &>/dev/null; then
    echo "Using flake8 (ruff not found)"
    # shellcheck disable=SC2086
    if flake8 ${PY_FILES}; then
      echo "✅ Python (flake8): PASSED"
    else
      echo "❌ Python (flake8): FAILED"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "⚠ No Python linter found. Install ruff: pip install ruff"
    echo "  Skipping Python linting."
  fi
}

# ─── Shell Linting ────────────────────────────────────────────────────────────

lint_shell() {
  section "Shell Linting (shellcheck)"

  local sc_script="${SCRIPT_DIR}/shellcheck.sh"
  if [[ ! -x "${sc_script}" ]]; then
    echo "⚠ ${sc_script} not found or not executable." >&2
    FAILED=$((FAILED + 1))
    return
  fi

  local sc_args=()
  if [[ "${CHANGED_ONLY}" == "true" ]]; then
    sc_args+=("--changed-only")
  fi

  if "${sc_script}" "${sc_args[@]}"; then
    echo "✅ Shell (shellcheck): PASSED"
  else
    echo "❌ Shell (shellcheck): FAILED"
    FAILED=$((FAILED + 1))
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CI Lint Runner"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "${RUN_PYTHON}" == "true" ]] && lint_python
[[ "${RUN_SHELL}"  == "true" ]] && lint_shell

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${FAILED} -eq 0 ]]; then
  echo "✅ All linters passed."
  exit 0
else
  echo "❌ ${FAILED} linter(s) reported issues."
  exit 1
fi
