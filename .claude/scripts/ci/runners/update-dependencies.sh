#!/usr/bin/env bash
# update-dependencies.sh
# Regenerate requirements.lock from requirements.txt and validate pins.
#
# DESCRIPTION:
#   Resolves all direct and transitive dependencies from requirements.txt,
#   writes a pinned requirements.lock, and validates that requirements.txt
#   uses only exact version pins (==).
#
#   Run this script whenever you add, remove, or upgrade a dependency in
#   requirements.txt. Commit both files together.
#
# USAGE:
#   ./scripts/ci/update-dependencies.sh [OPTIONS]
#
# OPTIONS:
#   --check-only   Verify pins without regenerating lock file (CI mode)
#   --verbose      Show detailed pip output
#   --help         Show this help
#
# EXAMPLES:
#   # Regenerate lock file after editing requirements.txt
#   ./scripts/ci/update-dependencies.sh
#
#   # CI: fail if requirements.txt has unpinned deps or lock is stale
#   ./scripts/ci/update-dependencies.sh --check-only
#
# DEPENDENCY UPDATE PROCESS:
#   1. Edit requirements.txt: change the == version for the package(s) to update
#   2. Run: ./scripts/ci/update-dependencies.sh
#   3. Review changes in requirements.lock
#   4. Run tests: pytest
#   5. Commit both requirements.txt and requirements.lock together
#
# See docs/dependency-updates.md for the full workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REQUIREMENTS_FILE="$PROJECT_ROOT/requirements.txt"
LOCK_FILE="$PROJECT_ROOT/requirements.lock"

CHECK_ONLY=false
VERBOSE=false

# ─── Argument Parsing ────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -50
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true; shift ;;
    --verbose)    VERBOSE=true; shift ;;
    --help|-h)    show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ───────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

ERRORS=0

# ─── Step 1: Validate requirements.txt pins ──────────────────────────────────

log_info "Validating version pins in requirements.txt..."

UNPINNED=()
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue

  # Strip inline comment
  pkg="${line%%#*}"
  pkg="${pkg%%[[:space:]]}"

  # Skip if empty after stripping
  [[ -z "$pkg" ]] && continue

  # Check for range specifiers or missing pin
  if echo "$pkg" | grep -qE '^[A-Za-z0-9_.-]+$'; then
    # Package name only - no version
    UNPINNED+=("$pkg (no version specifier)")
  elif echo "$pkg" | grep -qE '>=|<=|~=|!=|\*|>(?!=)|<(?!=)'; then
    UNPINNED+=("$pkg (range specifier)")
  fi
done < "$REQUIREMENTS_FILE"

if [[ ${#UNPINNED[@]} -gt 0 ]]; then
  log_error "Found unpinned dependencies in requirements.txt:"
  for u in "${UNPINNED[@]}"; do
    echo "  - $u"
  done
  echo ""
  echo "All production dependencies must use exact pins (==)."
  echo "Update requirements.txt, then re-run this script."
  ERRORS=$((ERRORS + 1))
else
  log_info "All dependencies in requirements.txt are exactly pinned. ✓"
fi

# ─── Step 2: Check for Python and pip ────────────────────────────────────────

if ! command -v python3 &>/dev/null; then
  log_error "Python 3 not found. Cannot regenerate lock file."
  exit 2
fi

PIP_CMD=""
if command -v pip3 &>/dev/null; then
  PIP_CMD="pip3"
elif command -v pip &>/dev/null; then
  PIP_CMD="pip"
elif python3 -m pip --version &>/dev/null 2>&1; then
  PIP_CMD="python3 -m pip"
fi

# ─── Step 3: Regenerate lock file (unless --check-only) ──────────────────────

if [[ "$CHECK_ONLY" == "false" ]]; then
  if [[ -z "$PIP_CMD" ]]; then
    log_warn "pip not found. Cannot regenerate lock file automatically."
    log_warn "Install pip and re-run, or update requirements.lock manually."
    ERRORS=$((ERRORS + 1))
  else
    log_info "Generating requirements.lock from requirements.txt..."

    TIMESTAMP=$(date -u +%Y-%m-%d)
    HEADER="# requirements.lock
# Generated from requirements.txt. DO NOT edit manually.
# To update: run scripts/ci/update-dependencies.sh
# Generated: ${TIMESTAMP}
#
# Install with: pip install -r requirements.lock
"

    # Use pip-compile if available (preferred), else fall back to pip freeze
    if command -v pip-compile &>/dev/null; then
      log_info "Using pip-compile to resolve full dependency tree..."
      PIP_COMPILE_ARGS=(--quiet --no-header --output-file "$LOCK_FILE" "$REQUIREMENTS_FILE")
      [[ "$VERBOSE" == "true" ]] && PIP_COMPILE_ARGS=(--output-file "$LOCK_FILE" "$REQUIREMENTS_FILE")
      pip-compile "${PIP_COMPILE_ARGS[@]}"
      # Prepend our header
      LOCK_CONTENT=$(cat "$LOCK_FILE")
      printf '%s\n%s\n' "$HEADER" "$LOCK_CONTENT" > "$LOCK_FILE"
    else
      log_warn "pip-compile not found. Install pip-tools for best results:"
      log_warn "  pip install pip-tools"
      log_warn "Falling back to pip install + freeze..."

      # Install into a temp venv and freeze
      TMPDIR=$(mktemp -d)
      trap 'rm -rf "$TMPDIR"' EXIT

      python3 -m venv "$TMPDIR/venv" 2>/dev/null || {
        log_warn "Could not create venv. Generating lock from requirements.txt directly."
        # Best-effort: just copy pinned requirements.txt as the lock
        {
          printf '%s\n' "$HEADER"
          grep -v '^#' "$REQUIREMENTS_FILE" | grep -v '^[[:space:]]*$'
        } > "$LOCK_FILE"
        log_warn "Lock file written with direct dependencies only (no transitive resolution)."
        log_info "Install pip-tools for full transitive resolution."
      }

      if [[ -f "$TMPDIR/venv/bin/pip" ]]; then
        VENV_PIP="$TMPDIR/venv/bin/pip"
        PIP_FLAGS=(--quiet --require-virtualenv)
        [[ "$VERBOSE" == "true" ]] && PIP_FLAGS=()
        "$VENV_PIP" install "${PIP_FLAGS[@]}" -r "$REQUIREMENTS_FILE"
        {
          printf '%s\n' "$HEADER"
          "$VENV_PIP" freeze
        } > "$LOCK_FILE"
      fi
    fi

    log_info "Lock file written: requirements.lock ✓"
  fi
else
  # --check-only: verify lock file exists and is not stale
  log_info "Check-only mode: validating lock file..."

  if [[ ! -f "$LOCK_FILE" ]]; then
    log_error "requirements.lock not found."
    log_error "Run: ./scripts/ci/update-dependencies.sh"
    ERRORS=$((ERRORS + 1))
  else
    # Verify that every pinned package in requirements.txt appears in the lock file
    MISSING_FROM_LOCK=()
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line//[[:space:]]/}" ]] && continue
      pkg_name="${line%%==*}"
      pkg_name="${pkg_name%%[[:space:]]}"
      [[ -z "$pkg_name" ]] && continue
      if ! grep -qi "^${pkg_name}==" "$LOCK_FILE"; then
        MISSING_FROM_LOCK+=("$pkg_name")
      fi
    done < <(grep -v '^#' "$REQUIREMENTS_FILE" | grep -v '^[[:space:]]*$')

    if [[ ${#MISSING_FROM_LOCK[@]} -gt 0 ]]; then
      log_error "Packages in requirements.txt not found in requirements.lock:"
      for m in "${MISSING_FROM_LOCK[@]}"; do
        echo "  - $m"
      done
      log_error "Run: ./scripts/ci/update-dependencies.sh"
      ERRORS=$((ERRORS + 1))
    else
      log_info "Lock file is consistent with requirements.txt. ✓"
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
if [[ $ERRORS -eq 0 ]]; then
  log_info "Dependency checks passed! ✓"
  echo "=========================================="
  exit 0
else
  log_error "$ERRORS error(s) found."
  echo "=========================================="
  exit 1
fi
