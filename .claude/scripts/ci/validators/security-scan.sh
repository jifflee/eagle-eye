#!/usr/bin/env bash
# ============================================================
# Script: security-scan.sh
# Purpose: CI wrapper for security scanning pipeline
#
# Runs security-scan.py in the appropriate mode:
#   - Pre-commit (lightweight): staged files only, targets < 5 seconds
#   - Pre-PR (full): entire codebase + dependency tree
#
# Usage:
#   ./scripts/ci/security-scan.sh [OPTIONS]
#
# Options:
#   --lightweight    Scan staged files only (pre-commit mode)
#   --full           Scan entire codebase (pre-PR mode, default)
#   --categories     Comma-separated: secrets,owasp,dependencies (default: all)
#   --severity       Minimum severity: critical|high|medium|low (default: low)
#   --output FILE    Write JSON report to FILE (default: security-report.json)
#   --no-fail        Exit 0 even if findings are detected
#   --verbose        Verbose output
#   --dry-run        Show what would be scanned
#   --help           Show this help
#
# Exit codes:
#   0  No security findings
#   1  Medium/low findings only
#   2  Critical/high findings found (blocks CI)
#
# Integration:
#   This script is auto-discovered by run-pipeline.sh via .ci-config.json.
#   Lightweight mode runs in pre-commit; full mode runs in pre-pr/pre-merge/pre-release.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCANNER_SCRIPT="$REPO_ROOT/scripts/security-scan.py"

# ─── Defaults ─────────────────────────────────────────────────────────────────

MODE="full"
CATEGORIES="secrets,owasp,dependencies"
SEVERITY="${SECURITY_SCAN_SEVERITY:-low}"
OUTPUT_FILE="${SECURITY_SCAN_REPORT:-security-report.json}"
NO_FAIL=false
VERBOSE=false
DRY_RUN=false
STAGED_FILES_TMP=""

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lightweight) MODE="lightweight"; shift ;;
    --full)        MODE="full"; shift ;;
    --categories)  CATEGORIES="$2"; shift 2 ;;
    --severity)    SEVERITY="$2"; shift 2 ;;
    --output)      OUTPUT_FILE="$2"; shift 2 ;;
    --no-fail)     NO_FAIL=true; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --help|-h)     show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ ! -f "$SCANNER_SCRIPT" ]]; then
  echo -e "${RED}[ERROR]${NC} Security scanner not found: $SCANNER_SCRIPT" >&2
  exit 2
fi

if ! command -v python3 &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} python3 is required for security scanning" >&2
  exit 2
fi

# ─── Staged Files (lightweight mode) ──────────────────────────────────────────

collect_staged_files() {
  STAGED_FILES_TMP=$(mktemp)
  # Get list of staged files from git
  if git diff --cached --name-only --diff-filter=ACMR 2>/dev/null > "$STAGED_FILES_TMP"; then
    local count
    count=$(wc -l < "$STAGED_FILES_TMP" | tr -d ' ')
    echo -e "${BLUE}[INFO]${NC} Found $count staged file(s) for lightweight scan"
  else
    # Not in a git repo or no staged files - scan nothing
    echo "" > "$STAGED_FILES_TMP"
    echo -e "${YELLOW}[WARN]${NC} No staged files found (not in git repo or nothing staged)"
  fi
}

cleanup_staged_files() {
  if [[ -n "$STAGED_FILES_TMP" ]] && [[ -f "$STAGED_FILES_TMP" ]]; then
    rm -f "$STAGED_FILES_TMP"
  fi
}

trap cleanup_staged_files EXIT

# ─── Build Python Args ────────────────────────────────────────────────────────

build_python_args() {
  local -a args=()

  args+=("--mode" "$MODE")
  args+=("--source-dir" "$REPO_ROOT")
  args+=("--output-file" "$OUTPUT_FILE")
  args+=("--categories" "$CATEGORIES")
  args+=("--severity-threshold" "$SEVERITY")

  if [[ "$MODE" == "lightweight" ]]; then
    collect_staged_files
    args+=("--staged-files" "$STAGED_FILES_TMP")
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    args+=("--verbose")
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    args+=("--dry-run")
  fi

  if [[ "$NO_FAIL" == "true" ]]; then
    args+=("--no-fail")
  fi

  printf '%s\n' "${args[@]}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}Security Scanning Pipeline${NC}"
  echo -e "Mode: ${YELLOW}$MODE${NC}  |  Categories: $CATEGORIES  |  Severity: $SEVERITY"
  echo "────────────────────────────────────────"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run security scanner with:"
    echo "  Mode:       $MODE"
    echo "  Source dir: $REPO_ROOT"
    echo "  Categories: $CATEGORIES"
    echo "  Severity:   $SEVERITY"
    echo "  Output:     $OUTPUT_FILE"
    exit 0
  fi

  # Build args and run scanner
  local -a python_args=()
  while IFS= read -r arg; do
    python_args+=("$arg")
  done < <(build_python_args)

  local exit_code=0
  python3 "$SCANNER_SCRIPT" "${python_args[@]}" || exit_code=$?

  echo ""

  # Interpret exit codes
  case "$exit_code" in
    0)
      echo -e "${GREEN}✓ Security scan passed: no findings${NC}"
      ;;
    1)
      echo -e "${YELLOW}! Security scan: medium/low findings detected (see report: $OUTPUT_FILE)${NC}"
      ;;
    2)
      echo -e "${RED}✗ Security scan FAILED: critical/high findings detected (see report: $OUTPUT_FILE)${NC}"
      ;;
    *)
      echo -e "${RED}✗ Security scanner error (exit code: $exit_code)${NC}" >&2
      ;;
  esac

  exit "$exit_code"
}

main "$@"
