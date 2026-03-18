#!/usr/bin/env bash
# test-scan.sh
# Test quality scanner: dead fixtures, duplicate tests, coverage gaps, flaky indicators.
#
# DESCRIPTION:
#   READ-ONLY analysis of test quality issues. Produces findings in
#   refactor-finding.schema.json format. Does NOT modify any files.
#
#   Scan categories:
#     1. dead-fixtures    - Test data files never referenced by any test
#     2. duplicate-tests  - Multiple tests covering the same scenario
#     3. coverage-gaps    - Public functions/exports with no test coverage
#     4. flaky            - Tests using sleep, external services, or non-deterministic data
#
# USAGE:
#   ./scripts/test-scan.sh [OPTIONS]
#
# OPTIONS:
#   --output-file FILE        Output findings JSON (default: .refactor/test-findings.json)
#   --source-dir DIR          Source directory to scan (default: current directory)
#   --categories LIST         Comma-separated: dead-fixtures,duplicate-tests,coverage-gaps,flaky
#   --severity-threshold LVL  Minimum severity to report: critical|high|medium|low (default: low)
#   --format json|summary     Output format (default: json)
#   --project-type TYPE       Force project type: python|nodejs|auto (default: auto)
#   --dry-run                 Print what would be scanned, do not write output
#   --verbose                 Verbose logging
#   --help                    Show this help
#
# OUTPUT:
#   JSON array of findings conforming to refactor-finding.schema.json
#   Exit code 0: No findings
#   Exit code 1: Medium/low findings only
#   Exit code 2: Critical or high findings found
#
# EXAMPLES:
#   # Full scan with defaults
#   ./scripts/test-scan.sh
#
#   # Scan only flaky indicators and coverage gaps
#   ./scripts/test-scan.sh --categories flaky,coverage-gaps
#
#   # Only report high/critical findings
#   ./scripts/test-scan.sh --severity-threshold high
#
#   # Output to custom file
#   ./scripts/test-scan.sh --output-file /tmp/test-quality.json
#
#   # Force Python project type
#   ./scripts/test-scan.sh --project-type python

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────

OUTPUT_FILE="${OUTPUT_FILE:-.refactor/test-findings.json}"
SOURCE_DIR="${SOURCE_DIR:-.}"
CATEGORIES="${CATEGORIES:-dead-fixtures,duplicate-tests,coverage-gaps,flaky}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-low}"
FORMAT="${FORMAT:-json}"
PROJECT_TYPE="${PROJECT_TYPE:-auto}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument Parsing ────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -55
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)        OUTPUT_FILE="$2"; shift 2 ;;
    --source-dir)         SOURCE_DIR="$2"; shift 2 ;;
    --categories)         CATEGORIES="$2"; shift 2 ;;
    --severity-threshold) SEVERITY_THRESHOLD="$2"; shift 2 ;;
    --format)             FORMAT="$2"; shift 2 ;;
    --project-type)       PROJECT_TYPE="$2"; shift 2 ;;
    --dry-run)            DRY_RUN="true"; shift ;;
    --verbose)            VERBOSE="true"; shift ;;
    --help|-h)            show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ───────────────────────────────────────────────────────────────

log() {
  echo "[test-scan] $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[test-scan:verbose] $*" >&2
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

PYTHON_SCRIPT="${SCRIPT_DIR}/test-scan.py"

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
  log "ERROR: test-scan.py not found at: $PYTHON_SCRIPT"
  exit 2
fi

# Build Python args
PYTHON_ARGS=(
  --source-dir "$SOURCE_DIR"
  --output-file "$OUTPUT_FILE"
  --categories "$CATEGORIES"
  --severity-threshold "$SEVERITY_THRESHOLD"
  --format "$FORMAT"
  --project-type "$PROJECT_TYPE"
)

if [[ "$DRY_RUN" == "true" ]]; then
  PYTHON_ARGS+=(--dry-run)
fi

if [[ "$VERBOSE" == "true" ]]; then
  PYTHON_ARGS+=(--verbose)
fi

log "Test scanner starting..."
log "  Source dir:         $SOURCE_DIR"
log "  Output file:        $OUTPUT_FILE"
log "  Categories:         $CATEGORIES"
log "  Severity threshold: $SEVERITY_THRESHOLD"
log "  Project type:       $PROJECT_TYPE"

if [[ "$DRY_RUN" == "true" ]]; then
  log "DRY-RUN: would scan $SOURCE_DIR"
  log "DRY-RUN: output → $OUTPUT_FILE"
  exit 0
fi

# Prefer python3 over python
PYTHON_CMD="python3"
if ! command -v python3 &>/dev/null; then
  if command -v python &>/dev/null; then
    PYTHON_CMD="python"
  else
    log "ERROR: Python 3 not found. Install Python 3.8+ to run test-scan."
    exit 2
  fi
fi

"$PYTHON_CMD" "$PYTHON_SCRIPT" "${PYTHON_ARGS[@]}"
