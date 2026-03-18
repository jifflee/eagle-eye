#!/usr/bin/env bash
# ============================================================
# Script: test-runner.sh
# Purpose: Auto-discovery test runner - maps changed files to their test
#          suites and runs only relevant tests.
#
# Usage:
#   ./scripts/test-runner.sh [MODE] [OPTIONS]
#
# Modes (one of, default: --fast):
#   --fast               Run only tests affected by changed files
#   --full               Run the complete test suite
#   --list               List file-to-test mappings without running
#
# Options:
#   --changed FILES      Comma-separated changed files (overrides git detection)
#   --base-ref REF       Git ref to diff against (default: HEAD~1)
#   --test-dir DIR       Test directory (default: tests/)
#   --source-dirs DIRS   Comma-separated source dirs (default: scripts,src,core)
#   --output FILE        Write JSON report to FILE
#   --format FMT         Output format: json|summary (default: json)
#   --config FILE        Custom mapping config (.test-runner.json)
#   --no-run             Discover mappings only; do not execute tests
#   --coverage           Enable coverage delta reporting
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0   All tests passed (or no tests found)
#   1   One or more tests failed
#   2   Fatal error (missing dependencies, invalid arguments)
#
# File-to-test mapping conventions:
#   scripts/foo.sh         -> tests/scripts/test-foo.sh
#   scripts/foo-bar.sh     -> tests/scripts/test-foo-bar.sh
#   src/my_module.py       -> tests/test_my_module.py
#   core/utils/helper.sh   -> tests/scripts/test-helper.sh
#
# Config file (.test-runner.json):
#   {
#     "mappings": {
#       "scripts/special.sh": ["tests/scripts/test-special.sh"],
#       "src/api/*": ["tests/integration/test-api-integration.sh"]
#     }
#   }
#
# Examples:
#   # Fast mode: run tests for changed files
#   ./scripts/test-runner.sh --fast
#
#   # Full suite run
#   ./scripts/test-runner.sh --full
#
#   # List what tests would run for a specific file
#   ./scripts/test-runner.sh --list --changed scripts/foo.sh
#
#   # Run tests for specific changed files with JSON output
#   ./scripts/test-runner.sh --fast --changed "scripts/foo.sh,src/bar.py" --output report.json
#
#   # Full run with coverage delta and summary format
#   ./scripts/test-runner.sh --full --coverage --format summary
#
# CI integration:
#   # In .ci-config.json, add to any mode's checks:
#   { "name": "test-runner-fast", "script": "../../test-runner.sh", "args": "--fast --format json" }

set -euo pipefail

# ─── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PYTHON_SCRIPT="$SCRIPT_DIR/test-runner.py"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────

MODE="--fast"
CHANGED=""
BASE_REF="HEAD~1"
TEST_DIR="tests"
SOURCE_DIRS="scripts,src,core"
OUTPUT_FILE=""
FORMAT="json"
CONFIG_FILE=".test-runner.json"
NO_RUN=false
COVERAGE=false
VERBOSE=false

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)         MODE="--fast"; shift ;;
    --full)         MODE="--full"; shift ;;
    --list)         MODE="--list"; shift ;;
    --changed)      CHANGED="$2"; shift 2 ;;
    --base-ref)     BASE_REF="$2"; shift 2 ;;
    --test-dir)     TEST_DIR="$2"; shift 2 ;;
    --source-dirs)  SOURCE_DIRS="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --format)       FORMAT="$2"; shift 2 ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --no-run)       NO_RUN=true; shift ;;
    --coverage)     COVERAGE=true; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --help|-h)      show_help ;;
    *)
      echo -e "${RED}ERROR:${NC} Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

# Require Python 3
PYTHON_CMD=""
for py in python3 python; do
  if command -v "$py" &>/dev/null; then
    if "$py" -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
      PYTHON_CMD="$py"
      break
    fi
  fi
done

if [[ -z "$PYTHON_CMD" ]]; then
  echo -e "${RED}ERROR:${NC} Python 3.8+ is required to run test-runner.sh" >&2
  echo "Install Python 3.8 or later and retry." >&2
  exit 2
fi

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
  echo -e "${RED}ERROR:${NC} test-runner.py not found at: $PYTHON_SCRIPT" >&2
  exit 2
fi

# ─── Banner ───────────────────────────────────────────────────────────────────

if [[ "$FORMAT" != "json" ]] || [[ "$VERBOSE" == "true" ]]; then
  echo ""
  echo -e "${BOLD}Test Runner${NC}"
  echo -e "Mode: ${CYAN}${MODE#--}${NC}  |  Format: $FORMAT"
  echo "────────────────────────────────────────"
  echo ""
fi

# ─── Build Python Args ────────────────────────────────────────────────────────

PYTHON_ARGS=("$MODE")
PYTHON_ARGS+=("--base-ref" "$BASE_REF")
PYTHON_ARGS+=("--test-dir" "$TEST_DIR")
PYTHON_ARGS+=("--source-dirs" "$SOURCE_DIRS")
PYTHON_ARGS+=("--output-format" "$FORMAT")
PYTHON_ARGS+=("--config" "$CONFIG_FILE")

[[ -n "$CHANGED" ]]     && PYTHON_ARGS+=("--changed" "$CHANGED")
[[ -n "$OUTPUT_FILE" ]] && PYTHON_ARGS+=("--output" "$OUTPUT_FILE")
[[ "$NO_RUN" == "true" ]]   && PYTHON_ARGS+=("--no-run")
[[ "$COVERAGE" == "true" ]] && PYTHON_ARGS+=("--coverage")
[[ "$VERBOSE" == "true" ]]  && PYTHON_ARGS+=("--verbose")

# ─── Run ──────────────────────────────────────────────────────────────────────

cd "$REPO_ROOT"
exec "$PYTHON_CMD" "$PYTHON_SCRIPT" "${PYTHON_ARGS[@]}"
