#!/usr/bin/env bash
# Purpose: Run shellcheck on all shell scripts in the repository
# Usage: ./scripts/ci/shellcheck.sh [--changed-only] [--severity=<level>]
#
# Options:
#   --changed-only    Only check files changed vs. origin/main (useful for PR checks)
#   --severity=LEVEL  Override severity: error|warning|info|style (default: from .shellcheckrc)
#
# Exit codes:
#   0  All scripts pass
#   1  One or more scripts have shellcheck errors
#   2  shellcheck not installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CHANGED_ONLY=false
SEVERITY=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --changed-only)
      CHANGED_ONLY=true
      ;;
    --severity=*)
      SEVERITY="${arg#*=}"
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--changed-only] [--severity=error|warning|info|style]" >&2
      exit 1
      ;;
  esac
done

# Check shellcheck is available
if ! command -v shellcheck &>/dev/null; then
  echo "ERROR: shellcheck is not installed." >&2
  echo "  Ubuntu/Debian: sudo apt-get install shellcheck" >&2
  echo "  macOS:         brew install shellcheck" >&2
  echo "  Alpine:        apk add shellcheck" >&2
  exit 2
fi

cd "${REPO_ROOT}"

# Build file list
if [[ "${CHANGED_ONLY}" == "true" ]]; then
  BASE_REF="${GITHUB_BASE_REF:-main}"
  SCRIPTS=$(git diff --name-only "origin/${BASE_REF}...HEAD" 2>/dev/null \
    | grep '\.sh$' \
    | xargs -I{} find . -name "$(basename {})" -type f 2>/dev/null \
    || true)
  if [[ -z "${SCRIPTS}" ]]; then
    echo "No shell script changes detected against origin/${BASE_REF}. Nothing to check."
    exit 0
  fi
else
  # All .sh files, excluding node_modules, .git, and third-party dirs
  SCRIPTS=$(find . \
    -not \( -path './.git/*' -prune \) \
    -not \( -path './node_modules/*' -prune \) \
    -not \( -path './.venv/*' -prune \) \
    -not \( -path './venv/*' -prune \) \
    -name '*.sh' \
    -type f \
    | sort)
fi

TOTAL=0
ERRORS=0
WARNINGS_LIST=()

# Build shellcheck flags
SC_FLAGS=()
if [[ -f "${REPO_ROOT}/.shellcheckrc" ]]; then
  # .shellcheckrc is auto-loaded by shellcheck; just note it
  echo "Using .shellcheckrc for configuration."
fi
if [[ -n "${SEVERITY}" ]]; then
  SC_FLAGS+=("--severity=${SEVERITY}")
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ShellCheck Analysis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

while IFS= read -r script; do
  [[ -f "${script}" ]] || continue
  TOTAL=$((TOTAL + 1))

  if ! shellcheck "${SC_FLAGS[@]}" "${script}" 2>&1; then
    ERRORS=$((ERRORS + 1))
    WARNINGS_LIST+=("${script}")
  fi
done <<< "${SCRIPTS}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "ShellCheck Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Checked : ${TOTAL} scripts"
echo "  Passed  : $((TOTAL - ERRORS)) scripts"
echo "  Failed  : ${ERRORS} scripts"

if [[ ${ERRORS} -gt 0 ]]; then
  echo ""
  echo "Scripts with issues:"
  for s in "${WARNINGS_LIST[@]}"; do
    echo "  - ${s}"
  done
  echo ""
  echo "FAILED: ${ERRORS}/${TOTAL} scripts have shellcheck issues."
  exit 1
fi

echo ""
echo "✅ All ${TOTAL} scripts passed shellcheck."
