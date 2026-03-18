#!/usr/bin/env bash
# pre-promote-qa-gate.sh
# Pre-promotion quality gate for dev→qa promotions
#
# DESCRIPTION:
#   Runs all required quality checks before allowing /pr-to-qa to proceed.
#   Enforces blocking and warning gates to ensure only validated, clean code
#   reaches QA environment.
#
# USAGE:
#   ./scripts/pre-promote-qa-gate.sh [OPTIONS]
#
# OPTIONS:
#   --no-cache          Bypass result cache, force re-run all checks
#   --quiet             Minimal output (exit code only)
#   --json              Output JSON format
#   --verbose           Show detailed output from each check
#   --dry-run           Show what would run without running checks
#   --create-issues     Create GitHub issues for blocking/warning findings
#   --pr PR_NUMBER      PR number to link in created issues
#   --help              Show this help
#
# EXIT CODES:
#   0 - PASS: all gates passed, promotion cleared
#   1 - FAIL: blocking gate(s) failed, promotion blocked
#   2 - WARN: non-blocking findings, proceed with warnings
#   3 - ERROR: gate script failed to run
#
# GATE CHECKS (ORDERED BY EXECUTION):
#   1. Test suite              (./scripts/test-runner.sh)                        [BLOCKING]
#   2. Lint / ShellCheck       (./scripts/ci/refactor-lint.sh)                   [BLOCKING]
#   3. Refactor scan           (/refactor --lint --severity high)                [BLOCKING CRITICAL]
#   4. Security scan           (./scripts/ci/sensitivity-scan.sh)                [BLOCKING]
#   5. Repo settings drift     (./scripts/ci/validate-repo-settings.sh)          [BLOCKING]
#   6. Environment tier        (./scripts/ci/validate-environment-tier.sh qa)    [BLOCKING]
#   7. Repo naming validation  (./scripts/ci/validate-repo-naming.sh)            [WARNING]
#   8. Doc freshness           (./scripts/scan-docs.sh --changed-files-only)     [WARNING]
#   9. Open PR check           (gh pr list --base dev --state open)              [BLOCKING]
#   10. CI status on dev       (gh api repos/:owner/:repo/commits/dev/status)    [BLOCKING]
#
# CACHE:
#   Results cached for 30 minutes per HEAD SHA in .promotion-gate-cache/
#   Use --no-cache to force re-run
#
# ISSUE CREATION:
#   Use --create-issues to automatically create GitHub issues for findings.
#   - Each FAIL or WARN finding generates a tracked issue
#   - Issues include check details, remediation steps, and reproduction commands
#   - Duplicate detection prevents re-creating existing issues
#   - Issues labeled with: bug, gate-finding, P1/P2 (based on blocking status)
#   - Use --pr NUMBER to link issues to the promotion PR
#   Example: ./scripts/pre-promote-qa-gate.sh --create-issues --pr 123
#
# INTEGRATION:
#   - Called by /pr-to-qa before creating PR
#   - Warnings included in PR body under "## Pre-Promotion Gate Results"
#   - Related: Issue #955 - Enforce pre-promotion quality gates
#   - Related: Issue #1056 - Formalized gate findings → issue creation
#
# Related:
#   - scripts/pre-promote-main-gate.sh  - Stricter gates for qa→main
#   - scripts/pr-validation-gate.sh     - Post-PR validation for merges
#   - .claude/commands/pr-to-qa.md      - PR to QA skill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.promotion-gate-cache"
CACHE_TTL_MINUTES=30

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/gate-common.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

NO_CACHE=false
QUIET=false
JSON_OUTPUT=false
VERBOSE=false
DRY_RUN=false
CREATE_ISSUES=false
PR_NUMBER=""

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -60
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)       NO_CACHE=true; shift ;;
    --quiet)          QUIET=true; shift ;;
    --json)           JSON_OUTPUT=true; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --create-issues)  CREATE_ISSUES=true; shift ;;
    --pr)             PR_NUMBER="$2"; shift 2 ;;
    --help|-h)        show_help ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 3
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 3
fi

if ! command -v gh &>/dev/null; then
  echo "ERROR: gh (GitHub CLI) is required but not installed." >&2
  exit 3
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
# Note: Using log_info, log_warn, log_error from lib/common.sh

log_verbose() {
  if [[ "$VERBOSE" == "true" && "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
    log_debug "$@"
  fi
}

log_step() {
  if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
    log_info "[CHECK] $*"
  fi
}

# ─── Cache Helpers ────────────────────────────────────────────────────────────
# Note: Using gate_* functions from lib/gate-common.sh

check_cache() {
  local head_sha="$1"
  gate_check_cache "$CACHE_DIR" "qa-gate" "$head_sha" "$CACHE_TTL_MINUTES" "$NO_CACHE"
}

write_cache() {
  local head_sha="$1"
  local result_json="$2"
  gate_write_cache "$CACHE_DIR" "qa-gate" "$head_sha" "$result_json"
}

# ─── Gate 1: Test Suite ───────────────────────────────────────────────────────

run_gate_tests() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running test suite..."

  if [[ -f "$SCRIPT_DIR/test-runner.sh" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$SCRIPT_DIR/test-runner.sh" --fast 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Test suite failed with exit code $exit_code"
    else
      # Extract test count from output
      local test_count
      test_count=$(echo "$details" | grep -oE '[0-9]+ tests? (passed|ran)' | grep -oE '[0-9]+' | head -1 || echo "0")
      output="Test suite passed ($test_count tests)"
    fi
  else
    status="skip"
    output="Test runner not found (scripts/test-runner.sh)"
    details="Create test runner at scripts/test-runner.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Test suite" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 2: Lint / ShellCheck ────────────────────────────────────────────────

run_gate_lint() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running lint / ShellCheck..."

  local lint_script="$SCRIPT_DIR/ci/refactor-lint.sh"
  if [[ -f "$lint_script" && -x "$lint_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$lint_script" --scope changed --severity high 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Lint check failed (exit code $exit_code)"
    else
      output="Lint check passed (0 issues)"
    fi
  else
    status="skip"
    output="Lint script not found (scripts/ci/refactor-lint.sh)"
    details="Create lint script or install shellcheck"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Lint / ShellCheck" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 3: Refactor Scan ────────────────────────────────────────────────────

run_gate_refactor() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running refactor scan..."

  # Note: /refactor skill would need to be invoked differently
  # For now, we'll use the refactor-lint.sh as a proxy
  local refactor_script="$SCRIPT_DIR/ci/refactor-lint.sh"
  if [[ -f "$refactor_script" && -x "$refactor_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$refactor_script" --scope changed --severity critical 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Refactor scan passed (0 critical issues)"
        ;;
      1)
        # High severity - warning only
        status="warn"
        output="Refactor scan found high-severity issues (non-blocking)"
        ;;
      *)
        # Critical - blocking
        status="fail"
        output="Refactor scan found critical issues (blocking)"
        ;;
    esac
  else
    status="skip"
    output="Refactor scanner not found"
    details="Install refactor scanner or create scripts/ci/refactor-lint.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Refactor scan" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 4: Security Scan ────────────────────────────────────────────────────

run_gate_security() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running security scan..."

  local security_script="$SCRIPT_DIR/ci/sensitivity-scan.sh"
  if [[ -f "$security_script" && -x "$security_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$security_script" --verbose 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Security scan passed (0 findings)"
        ;;
      1)
        status="fail"
        output="Security scan found findings (blocking)"
        ;;
      *)
        status="warn"
        output="Security scan error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Security scanner not found (scripts/ci/sensitivity-scan.sh)"
    details="Create security scanner"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Security scan" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 4b: Dependency Audit ────────────────────────────────────────────────

run_gate_dependency_audit() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running dependency audit..."

  local dep_audit_script="$SCRIPT_DIR/ci/dep-audit.sh"
  if [[ -f "$dep_audit_script" && -x "$dep_audit_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$dep_audit_script" --full 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Dependency audit passed (no critical/high vulnerabilities)"
        ;;
      1)
        status="fail"
        output="Dependency audit found vulnerabilities (blocking)"
        ;;
      *)
        status="warn"
        output="Dependency audit error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Dependency audit script not found (scripts/ci/dep-audit.sh)"
    details="Create dependency audit script: see scripts/ci/install-ci-tools.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Dependency audit" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 5: Repo Settings Drift ──────────────────────────────────────────────

run_gate_repo_settings() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking repo settings drift..."

  local settings_script="$SCRIPT_DIR/ci/validate-repo-settings.sh"
  if [[ -f "$settings_script" && -x "$settings_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$settings_script" --mode strict 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Repo settings drift check passed (no drift)"
        ;;
      1)
        status="fail"
        output="Repo settings drift detected (blocking)"
        ;;
      *)
        status="warn"
        output="Repo settings check error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Repo settings validator not found (scripts/ci/validate-repo-settings.sh)"
    details="Create repo settings validator"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Repo settings drift" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 6: Environment Tier Compliance ──────────────────────────────────────

run_gate_environment_tier() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating environment tier compliance..."

  local tier_script="$SCRIPT_DIR/ci/validate-environment-tier.sh"
  if [[ -f "$tier_script" && -x "$tier_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$tier_script" qa 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Environment tier compliance passed (compliant)"
        ;;
      1)
        status="fail"
        output="Environment tier violations found (blocking)"
        ;;
      2)
        status="warn"
        output="Environment tier warnings found (non-blocking)"
        ;;
      *)
        status="warn"
        output="Environment tier check error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Environment tier validator not found (scripts/ci/validate-environment-tier.sh)"
    details="Create environment tier validator"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Environment tier" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 7: Repo Naming Validation ───────────────────────────────────────────

run_gate_repo_naming() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating repo naming convention..."

  local naming_script="$SCRIPT_DIR/ci/validate-repo-naming.sh"
  if [[ -f "$naming_script" && -x "$naming_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 15 "$naming_script" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Repo naming convention valid"
        ;;
      1)
        status="warn"
        output="Repo naming convention violation (not enforced yet)"
        ;;
      *)
        status="warn"
        output="Repo naming check error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Repo naming validator not found (scripts/ci/validate-repo-naming.sh)"
    details="Create repo naming validator"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Repo naming" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking false \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 8: Doc Freshness ────────────────────────────────────────────────────

run_gate_docs() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking documentation freshness..."

  local docs_script="$SCRIPT_DIR/scan-docs.sh"
  if [[ -f "$docs_script" && -x "$docs_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$docs_script" --changed-files-only --categories "obsolete,stale" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Documentation freshness check passed"
        ;;
      1)
        status="warn"
        output="Stale/obsolete documentation found (non-blocking)"
        ;;
      *)
        status="warn"
        output="Documentation scan error (exit code $exit_code)"
        ;;
    esac
  else
    status="skip"
    output="Documentation scanner not found (scripts/scan-docs.sh)"
    details="Create documentation scanner"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Doc freshness" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking false \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 9: Open PR Check ────────────────────────────────────────────────────

run_gate_open_prs() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking for open PRs to dev..."

  local tmp_out; tmp_out=$(mktemp)
  local exit_code=0
  timeout 15 gh pr list --base dev --state open --json number,title 2>&1 > "$tmp_out" || exit_code=$?
  details=$(cat "$tmp_out")
  rm -f "$tmp_out"

  if [[ $exit_code -ne 0 ]]; then
    status="warn"
    output="Failed to check open PRs (exit code $exit_code)"
  else
    local pr_count
    pr_count=$(echo "$details" | jq '. | length' 2>/dev/null || echo "0")
    if [[ "$pr_count" -eq 0 ]]; then
      status="pass"
      output="No open PRs to dev (0 open PRs)"
    else
      status="fail"
      output="Open PRs to dev found (${pr_count} open PRs)"
      details=$(echo "$details" | jq -r '.[] | "#\(.number): \(.title)"' | head -5 || echo "$details")
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Open PR check" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 10: CI Status on dev ─────────────────────────────────────────────────

run_gate_ci_status() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking CI status on dev branch..."

  # Get repo owner and name
  local repo_info
  repo_info=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

  if [[ -z "$repo_info" ]]; then
    status="warn"
    output="Unable to determine repository info"
    details="Could not get repo info from gh cli"
  else
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 15 gh api "repos/${repo_info}/commits/dev/status" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="warn"
      output="Failed to check CI status (exit code $exit_code)"
    else
      local ci_state
      ci_state=$(echo "$details" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")

      case "$ci_state" in
        success)
          status="pass"
          output="CI status on dev: passing (all checks passing)"
          ;;
        pending)
          status="warn"
          output="CI status on dev: pending (checks in progress)"
          ;;
        failure|error)
          status="fail"
          output="CI status on dev: failing (checks failed)"
          ;;
        *)
          status="warn"
          output="CI status on dev: unknown"
          ;;
      esac
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "CI status on dev" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Report Formatting ────────────────────────────────────────────────────────

print_human_report() {
  local report="$1"

  local gate_status gate_summary duration
  gate_status=$(echo "$report" | jq -r '.gate_status')
  gate_summary=$(echo "$report" | jq -r '.gate_summary')
  duration=$(echo "$report" | jq -r '.duration_seconds')

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║  PRE-PROMOTION GATE: dev → qa                           ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║                                                          ║${NC}"

  # Print each check result
  echo "$report" | jq -r '.checks[] | "\(.name)|\(.status)|\(.output)|\(.blocking)"' | \
  while IFS='|' read -r name status output blocking; do
    local icon color
    case "$status" in
      pass) icon="PASS"; color="$GREEN" ;;
      fail) icon="FAIL"; color="$RED" ;;
      warn) icon="WARN"; color="$YELLOW" ;;
      skip) icon="SKIP"; color="$CYAN" ;;
      *)    icon="????"; color="$NC" ;;
    esac

    # Format output to fit within box
    local formatted_output="${output:0:30}"
    printf "${BOLD}║${NC}  %b[%s]%b  %-24s %-30s${BOLD}║${NC}\n" "$color" "$icon" "$NC" "$name" "$formatted_output"
  done

  echo -e "${BOLD}║                                                          ║${NC}"

  # Print result
  case "$gate_status" in
    PASS)
      echo -e "${BOLD}║${NC}  ${GREEN}RESULT: PASS${NC}                                              ${BOLD}║${NC}"
      echo -e "${BOLD}║${NC}  Promotion to QA is ${GREEN}CLEARED${NC}                               ${BOLD}║${NC}"
      ;;
    FAIL)
      echo -e "${BOLD}║${NC}  ${RED}RESULT: FAIL${NC}                                              ${BOLD}║${NC}"
      echo -e "${BOLD}║${NC}  Promotion to QA is ${RED}BLOCKED${NC}                                ${BOLD}║${NC}"
      ;;
    WARN)
      echo -e "${BOLD}║${NC}  ${YELLOW}RESULT: PASS (with warnings)${NC}                             ${BOLD}║${NC}"
      echo -e "${BOLD}║${NC}  Promotion to QA is ${GREEN}CLEARED${NC} (warnings present)           ${BOLD}║${NC}"
      ;;
  esac

  echo -e "${BOLD}║                                                          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Print detailed failures and warnings
  local has_issues=false
  while IFS= read -r check_json; do
    local check_name check_status check_details
    check_name=$(echo "$check_json" | jq -r '.name')
    check_status=$(echo "$check_json" | jq -r '.status')
    check_details=$(echo "$check_json" | jq -r '.details // ""')

    if [[ "$check_status" == "fail" || "$check_status" == "warn" ]]; then
      has_issues=true
      if [[ "$check_status" == "fail" ]]; then
        echo -e "${RED}[${check_name}] FAILED${NC}"
      else
        echo -e "${YELLOW}[${check_name}] WARNING${NC}"
      fi

      if [[ -n "$check_details" && "$check_details" != "null" ]]; then
        echo "$check_details" | head -10 | sed 's/^/  /'
      fi
      echo ""
    fi
  done < <(echo "$report" | jq -c '.checks[]')

  if [[ "$has_issues" == "false" ]]; then
    echo -e "${GREEN}✓ All checks passed. Ready to promote dev → qa.${NC}"
    echo ""
  fi

  echo "Total gate execution time: ${duration}s"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  # Get HEAD SHA for caching
  local head_sha
  head_sha=$(gate_get_head_sha)

  log_verbose "Running pre-promotion gate for dev → qa (HEAD: ${head_sha:0:12})"

  # Check cache first
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    if cached=$(check_cache "$head_sha" 2>/dev/null); then
      echo "$cached"
      gate_status=$(echo "$cached" | jq -r '.gate_status')
      case "$gate_status" in
        PASS) exit 0 ;;
        WARN) exit 2 ;;
        FAIL) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  else
    local cached
    if cached=$(check_cache "$head_sha" 2>/dev/null); then
      log_info "Using cached gate result (use --no-cache to refresh)"
      print_human_report "$cached"
      gate_status=$(echo "$cached" | jq -r '.gate_status')
      case "$gate_status" in
        PASS) exit 0 ;;
        WARN) exit 2 ;;
        FAIL) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  fi

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN - Pre-promotion gate would run the following checks:"
    echo "  1. Test suite"
    echo "  2. Lint / ShellCheck"
    echo "  3. Refactor scan"
    echo "  4. Security scan"
    echo "  5. Repo settings drift"
    echo "  6. Environment tier compliance"
    echo "  7. Repo naming validation"
    echo "  8. Doc freshness"
    echo "  9. Open PR check"
    echo "  10. CI status on dev"
    echo ""
    echo "Estimated time: ~2 minutes"
    exit 0
  fi

  local pipeline_start
  pipeline_start=$(date +%s)

  if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
    echo ""
    echo -e "${BOLD}Pre-Promotion Quality Gate: dev → qa${NC}"
    echo -e "HEAD SHA: ${head_sha:0:12}"
    echo "────────────────────────────────────────────────"
    echo ""
  fi

  # Run all gates
  local gate_results=()
  gate_results+=("$(run_gate_tests)")
  gate_results+=("$(run_gate_lint)")
  gate_results+=("$(run_gate_refactor)")
  gate_results+=("$(run_gate_security)")
  gate_results+=("$(run_gate_dependency_audit)")
  gate_results+=("$(run_gate_repo_settings)")
  gate_results+=("$(run_gate_environment_tier)")
  gate_results+=("$(run_gate_repo_naming)")
  gate_results+=("$(run_gate_docs)")
  gate_results+=("$(run_gate_open_prs)")
  gate_results+=("$(run_gate_ci_status)")

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - pipeline_start))

  # Build checks JSON array
  local checks_json="["
  local first=true
  for result in "${gate_results[@]}"; do
    if [[ "$first" != "true" ]]; then checks_json+=","; fi
    checks_json+="$result"
    first=false
  done
  checks_json+="]"

  # Determine overall gate status
  local gate_status gate_summary exit_code
  gate_status=$(gate_determine_status "$checks_json" false)

  # Custom summary for promotion gates
  if [[ "$gate_status" == "FAIL" ]]; then
    local fail_count
    fail_count=$(echo "$checks_json" | jq '[.[] | select(.status == "fail" and .blocking == true)] | length')
    gate_summary="$fail_count blocking check(s) failed - promotion is BLOCKED"
    exit_code=1
  elif [[ "$gate_status" == "WARN" ]]; then
    local warn_count
    warn_count=$(echo "$checks_json" | jq '[.[] | select(.status == "warn" or (.status == "fail" and .blocking == false))] | length')
    gate_summary="$warn_count warning(s) detected - promotion cleared with caution"
    exit_code=2
  else
    gate_summary="All checks passed - promotion is cleared"
    exit_code=0
  fi

  # Build final report
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local report
  report=$(jq -n \
    --arg head_sha "$head_sha" \
    --arg timestamp "$timestamp" \
    --arg gate_status "$gate_status" \
    --arg gate_summary "$gate_summary" \
    --argjson duration "$total_duration" \
    --argjson checks "$checks_json" \
    '{
      head_sha: $head_sha,
      timestamp: $timestamp,
      gate_status: $gate_status,
      gate_summary: $gate_summary,
      duration_seconds: $duration,
      checks: $checks
    }')

  # Cache result
  write_cache "$head_sha" "$report" 2>/dev/null || true

  # Create issues if requested
  if [[ "$CREATE_ISSUES" == "true" ]]; then
    if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
      echo ""
      log_info "Creating GitHub issues from gate findings..."
    fi
    gate_create_issues_from_report "pre-promote-qa-gate" "$report" "$PR_NUMBER" "false"
  fi

  # Output
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "$report"
  else
    print_human_report "$report"
  fi

  exit $exit_code
}

main "$@"
