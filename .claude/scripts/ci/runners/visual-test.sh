#!/usr/bin/env bash
# ============================================================
# Script: visual-test.sh
# Purpose: CI check for browser-based visual regression testing
#
# Runs Playwright visual regression tests with URL allowlist enforcement.
# All browser connections are restricted to known, in-scope URLs only.
# External connections are blocked by default.
#
# Usage:
#   ./scripts/ci/visual-test.sh [OPTIONS]
#
# Options:
#   --base-url URL       Base URL for the application (default: http://localhost:3000)
#   --update-baselines   Capture new baselines instead of comparing
#   --allowed-urls LIST  Comma-separated allowed URLs (overrides .ci-config.json)
#   --tolerance FLOAT    Pixel diff tolerance 0.0-1.0 (default: 0.01)
#   --report-dir DIR     Output directory for visual reports (default: test-results/visual)
#   --timeout SECS       Test timeout in seconds (default: 120)
#   --headless           Run in headless mode (default: true)
#   --docker             Run in Docker container for isolation
#   --no-fail            Exit 0 even if visual tests fail (for optional CI check)
#   --dry-run            Show configuration without running tests
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  All visual tests passed (or no-fail mode)
#   1  One or more visual tests failed
#   2  Fatal error (missing dependencies, blocked URL, configuration error)
#
# Security:
#   - URL allowlist is enforced — only in-scope URLs are permitted
#   - All external connections are blocked by default
#   - Blocked connection attempts are logged to test-results/blocked-connections.log
#   - Configure allowed URLs via VISUAL_TEST_ALLOWED_URLS env var or .ci-config.json
#
# CI Integration:
#   This script is an optional check for visual regression testing.
#   Add to .ci-config.json under modes.pre-pr or modes.pre-release:
#     {
#       "name": "visual-tests",
#       "script": "visual-test.sh",
#       "args": "--no-fail",
#       "description": "Browser-based visual regression tests"
#     }
#
# Adding Visual Tests:
#   1. Add test cases to tests/e2e/visual/visual-regression.spec.ts
#   2. Run once with --update-baselines to capture baseline images
#   3. Subsequent runs compare against baselines and report regressions
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

BASE_URL="${E2E_BASE_URL:-http://localhost:3000}"
UPDATE_BASELINES="${UPDATE_VISUAL_BASELINES:-false}"
ALLOWED_URLS="${VISUAL_TEST_ALLOWED_URLS:-}"
TOLERANCE="0.01"
REPORT_DIR="$REPO_ROOT/test-results/visual"
TIMEOUT=120
HEADLESS=true
USE_DOCKER=false
NO_FAIL=false
DRY_RUN=false
VERBOSE=false
TEST_PATTERN="tests/e2e/visual/visual-regression.spec.ts"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url)         BASE_URL="$2"; shift 2 ;;
    --update-baselines) UPDATE_BASELINES=true; shift ;;
    --allowed-urls)     ALLOWED_URLS="$2"; shift 2 ;;
    --tolerance)        TOLERANCE="$2"; shift 2 ;;
    --report-dir)       REPORT_DIR="$2"; shift 2 ;;
    --timeout)          TIMEOUT="$2"; shift 2 ;;
    --headless)         HEADLESS=true; shift ;;
    --no-headless)      HEADLESS=false; shift ;;
    --docker)           USE_DOCKER=true; shift ;;
    --no-fail)          NO_FAIL=true; shift ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --verbose)          VERBOSE=true; shift ;;
    --help|-h)          show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_verbose() { if [[ "$VERBOSE" == "true" ]]; then echo -e "${CYAN}[DEBUG]${NC} $*"; fi; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $*"; }

# ─── Security: URL Allowlist Validation ────────────────────────────────────────

validate_url_allowlist() {
  log_step "Validating URL allowlist configuration..."

  # Load allowlist from config
  local config_file="$REPO_ROOT/.ci-config.json"
  local allowed_patterns=()

  if [[ -n "$ALLOWED_URLS" ]]; then
    # Environment variable takes precedence
    IFS=',' read -ra allowed_patterns <<< "$ALLOWED_URLS"
    log_info "URL allowlist loaded from VISUAL_TEST_ALLOWED_URLS env var"
  elif [[ -f "$config_file" ]]; then
    # Try to load from .ci-config.json
    local config_urls
    config_urls=$(jq -r '.visual_testing.allowed_urls[]? // empty' "$config_file" 2>/dev/null || true)
    if [[ -n "$config_urls" ]]; then
      while IFS= read -r url; do
        allowed_patterns+=("$url")
      done <<< "$config_urls"
      log_info "URL allowlist loaded from .ci-config.json"
    fi
  fi

  # If no custom allowlist, use defaults
  if [[ ${#allowed_patterns[@]} -eq 0 ]]; then
    allowed_patterns=(
      "http://localhost"
      "https://localhost"
      "http://127.0.0.1"
      "https://127.0.0.1"
      "http://10.69.5."
      "http://172.28."
    )
    log_info "Using default URL allowlist (localhost/127.0.0.1/10.69.5.*/172.28.*)"
  fi

  log_verbose "Allowed URL patterns: ${allowed_patterns[*]}"

  # Validate BASE_URL against allowlist
  local base_url_allowed=false
  for pattern in "${allowed_patterns[@]}"; do
    if [[ "$BASE_URL" == "$pattern"* ]]; then
      base_url_allowed=true
      break
    fi
  done

  if [[ "$base_url_allowed" != "true" ]]; then
    log_error "SECURITY: Base URL '$BASE_URL' is NOT in the URL allowlist!"
    log_error "Allowed patterns: ${allowed_patterns[*]}"
    log_error "Set VISUAL_TEST_ALLOWED_URLS or configure visual_testing.allowed_urls in .ci-config.json"
    exit 2
  fi

  log_info "✓ Base URL '$BASE_URL' is permitted by allowlist"
  echo ""
}

# ─── Prerequisite Checks ──────────────────────────────────────────────────────

check_prerequisites() {
  local missing=()

  if ! command -v node &>/dev/null; then
    missing+=("node")
  fi

  if ! command -v npx &>/dev/null; then
    missing+=("npx")
  fi

  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 2
  fi

  # Check if Playwright is installed
  if ! npx --no playwright --version &>/dev/null 2>&1; then
    log_warn "Playwright does not appear to be installed."
    log_warn "Run: npm install -D @playwright/test && npx playwright install"
    if [[ "$NO_FAIL" == "true" ]]; then
      log_warn "Skipping visual tests (--no-fail mode)"
      exit 0
    fi
    exit 2
  fi

  # Check if test file exists
  local test_file="$REPO_ROOT/$TEST_PATTERN"
  if [[ ! -f "$test_file" ]]; then
    log_error "Visual test file not found: $test_file"
    exit 2
  fi

  log_verbose "Prerequisites check passed"
}

# ─── Docker Execution ────────────────────────────────────────────────────────

run_in_docker() {
  log_step "Running visual tests in Docker container (isolated mode)..."

  local compose_file="$REPO_ROOT/tests/e2e/docker/docker-compose.e2e.yml"
  if [[ ! -f "$compose_file" ]]; then
    log_error "Docker Compose file not found: $compose_file"
    exit 2
  fi

  if ! command -v docker &>/dev/null; then
    log_error "Docker is required for isolated mode"
    exit 2
  fi

  local env_args=(
    "-e" "E2E_BASE_URL=$BASE_URL"
    "-e" "UPDATE_VISUAL_BASELINES=$UPDATE_BASELINES"
    "-e" "PLAYWRIGHT_TEST_MATCH=visual-regression.spec.ts"
  )

  if [[ -n "$ALLOWED_URLS" ]]; then
    env_args+=("-e" "VISUAL_TEST_ALLOWED_URLS=$ALLOWED_URLS")
  fi

  docker-compose -f "$compose_file" run "${env_args[@]}" playwright \
    npx playwright test "$TEST_PATTERN" \
    --reporter=json \
    --output="$REPORT_DIR"
}

# ─── Local Execution ─────────────────────────────────────────────────────────

run_locally() {
  log_step "Running visual tests locally..."

  # Set up environment
  export E2E_BASE_URL="$BASE_URL"
  export UPDATE_VISUAL_BASELINES="$UPDATE_BASELINES"

  if [[ -n "$ALLOWED_URLS" ]]; then
    export VISUAL_TEST_ALLOWED_URLS="$ALLOWED_URLS"
  fi

  # Build playwright args
  local playwright_args=(
    "playwright" "test"
    "$TEST_PATTERN"
    "--timeout" "$((TIMEOUT * 1000))"
  )

  if [[ "$HEADLESS" == "true" ]]; then
    playwright_args+=("--headed=false")
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    playwright_args+=("--reporter=list")
  else
    playwright_args+=("--reporter=json,list")
  fi

  # Ensure report directory exists
  mkdir -p "$REPORT_DIR"

  # Run playwright
  local exit_code=0
  cd "$REPO_ROOT"
  npx "${playwright_args[@]}" \
    --output="$REPORT_DIR/playwright-artifacts" \
    2>&1 | tee "$REPORT_DIR/visual-test-output.log" || exit_code=$?

  return $exit_code
}

# ─── Report Parsing ───────────────────────────────────────────────────────────

parse_and_display_report() {
  local report_file="$REPORT_DIR/visual-test-report.json"

  if [[ ! -f "$report_file" ]]; then
    log_verbose "No visual test report found at: $report_file"
    return
  fi

  echo ""
  echo -e "${BOLD}Visual Test Report${NC}"
  echo "────────────────────────────────────────"

  local passed failed new_baselines errors total
  total=$(jq -r '.summary.total // 0' "$report_file" 2>/dev/null || echo "0")
  passed=$(jq -r '.summary.passed // 0' "$report_file" 2>/dev/null || echo "0")
  failed=$(jq -r '.summary.failed // 0' "$report_file" 2>/dev/null || echo "0")
  new_baselines=$(jq -r '.summary.newBaselines // 0' "$report_file" 2>/dev/null || echo "0")
  errors=$(jq -r '.summary.errors // 0' "$report_file" 2>/dev/null || echo "0")

  echo "  Total:         $total visual checks"
  echo -e "  Passed:        ${GREEN}$passed${NC}"
  [[ "$failed" -gt 0 ]] && echo -e "  Failed:        ${RED}$failed${NC}" || echo "  Failed:        $failed"
  [[ "$new_baselines" -gt 0 ]] && echo -e "  New baselines: ${YELLOW}$new_baselines${NC}"
  [[ "$errors" -gt 0 ]] && echo -e "  Errors:        ${RED}$errors${NC}"

  # Show blocked connections
  local blocked_count
  blocked_count=$(jq -r '.blockedConnections | length // 0' "$report_file" 2>/dev/null || echo "0")
  if [[ "$blocked_count" -gt 0 ]]; then
    echo ""
    echo -e "  ${YELLOW}⚠ SECURITY: $blocked_count connection(s) were blocked:${NC}"
    jq -r '.blockedConnections[] | "    - \(.url)"' "$report_file" 2>/dev/null || true
  fi

  # Show failed tests
  if [[ "$failed" -gt 0 ]]; then
    echo ""
    echo -e "  ${RED}Failed visual checks:${NC}"
    jq -r '.results[] | select(.status == "fail") | "    ✗ \(.name) (\(.diffPercent // 0 | . * 100 | round / 100)% diff)"' \
      "$report_file" 2>/dev/null || true
  fi

  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}Visual Regression Testing${NC}"
  echo -e "Base URL: ${CYAN}$BASE_URL${NC}  |  Tolerance: ${TOLERANCE}  |  Update baselines: $UPDATE_BASELINES"
  echo "────────────────────────────────────────"
  echo ""

  # Security: validate URL allowlist FIRST (even in dry-run)
  validate_url_allowlist

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Visual test configuration:"
    echo "  Base URL:         $BASE_URL"
    echo "  Update baselines: $UPDATE_BASELINES"
    echo "  Tolerance:        $TOLERANCE"
    echo "  Report dir:       $REPORT_DIR"
    echo "  Timeout:          ${TIMEOUT}s"
    echo "  Headless:         $HEADLESS"
    echo "  Docker:           $USE_DOCKER"
    echo "  Test pattern:     $TEST_PATTERN"
    if [[ -n "$ALLOWED_URLS" ]]; then
      echo "  Allowed URLs:     $ALLOWED_URLS"
    fi
    echo ""
    exit 0
  fi

  # Check prerequisites
  check_prerequisites

  # Run tests
  local exit_code=0

  if [[ "$USE_DOCKER" == "true" ]]; then
    run_in_docker || exit_code=$?
  else
    run_locally || exit_code=$?
  fi

  # Parse and display report
  parse_and_display_report

  # Check for blocked connections log
  local blocked_log="$REPORT_DIR/../blocked-connections.log"
  if [[ -f "$blocked_log" ]]; then
    local blocked_count
    blocked_count=$(wc -l < "$blocked_log" | tr -d ' ')
    if [[ "$blocked_count" -gt 0 ]]; then
      echo -e "${YELLOW}⚠ SECURITY ALERT: $blocked_count blocked connection attempt(s) logged${NC}"
      echo "  See: $blocked_log"
      echo ""
    fi
  fi

  # Final status
  if [[ "$exit_code" -eq 0 ]]; then
    echo -e "${GREEN}✓ Visual regression tests passed${NC}"
  else
    echo -e "${RED}✗ Visual regression tests failed (exit: $exit_code)${NC}"
    if [[ "$NO_FAIL" == "true" ]]; then
      log_warn "Continuing despite failures (--no-fail mode)"
      exit 0
    fi
  fi

  echo ""
  exit "$exit_code"
}

main "$@"
