#!/usr/bin/env bash
# ============================================================
# Script: qa-gate.sh
# Purpose: QA validation gate for qa branch before main promotion
# Usage: ./scripts/qa-gate.sh [OPTIONS]
#
# DESCRIPTION:
#   Runs automated quality checks against the qa branch to validate
#   readiness before promoting to main. Sits between /pr-to-qa and
#   /pr-to-main in the promotion flow.
#
# OPTIONS:
#   --quick             Run fast subset (skip full test suite)
#   --full              Run all checks with verbose output
#   --json              Output JSON format
#   --no-cache          Bypass result cache, force re-run all checks
#   --quiet             Minimal output (exit code only)
#   --verbose           Show detailed output from each check
#   --dry-run           Show what would run without running checks
#   --create-issues     Create GitHub issues for blocking/warning findings
#   --pr PR_NUMBER      PR number to link in created issues
#   --help              Show this help
#
# EXIT CODES:
#   0 - PASS: all gates passed
#   1 - FAIL: blocking gate(s) failed
#   2 - WARN: non-blocking warnings only
#   3 - ERROR: gate script failed to run
#
# GATE CHECKS (5 categories):
#   1. Tests     - Full test suite + coverage        [BLOCKING]
#   2. Security  - Sensitivity scan + dep audit      [BLOCKING]
#   3. Licenses  - Dependency license compliance     [BLOCKING]
#   4. Quality   - Design compliance + naming        [WARNING]
#   5. Docs      - Documentation freshness           [WARNING]
#
# CACHE:
#   Results cached for 30 minutes per HEAD SHA in .qa-gate-cache/
#   Use --no-cache to force re-run
#
# ISSUE CREATION:
#   Use --create-issues to automatically create GitHub issues for findings.
#   - Each FAIL or WARN finding generates a tracked issue
#   - Issues include check details, remediation steps, and reproduction commands
#   - Duplicate detection prevents re-creating existing issues
#   - Issues labeled with: bug, gate-finding, P1/P2 (based on blocking status)
#   - Use --pr NUMBER to link issues to the promotion PR
#   Example: ./scripts/qa-gate.sh --create-issues --pr 789
#
# INTEGRATION:
#   - Run after /pr-to-qa creates PR (qa branch ready)
#   - Run before /pr-to-main to validate qa branch
#   - dev -> qa (pr-to-qa) -> QA GATE -> main (pr-to-main)
#   - Related: Issue #1056 - Formalized gate findings → issue creation
#
# Related:
#   - scripts/pr/pre-promote-qa-gate.sh   - Pre-promotion gate for dev->qa
#   - scripts/pr/pre-promote-main-gate.sh - Pre-promotion gate for qa->main
#   - .claude/commands/qa-gate.md      - Skill definition
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.qa-gate-cache"
CACHE_TTL_MINUTES=30

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/gate-common.sh"

# BOLD and CYAN already defined by common.sh (readonly)

# ─── Defaults ─────────────────────────────────────────────────────────────────

NO_CACHE=false
QUIET=false
JSON_OUTPUT=false
VERBOSE=false
DRY_RUN=false
QUICK=false
FULL=false
CREATE_ISSUES=false
PR_NUMBER=""

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -50
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)          QUICK=true; shift ;;
    --full)           FULL=true; VERBOSE=true; shift ;;
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

# ─── Logging Helpers ──────────────────────────────────────────────────────────

log_step() {
  if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
    log_info "[CHECK] $*"
  fi
}

# ─── Cache Helpers ────────────────────────────────────────────────────────────

check_cache() {
  local head_sha="$1"
  gate_check_cache "$CACHE_DIR" "qa-gate" "$head_sha" "$CACHE_TTL_MINUTES" "$NO_CACHE"
}

write_cache() {
  local head_sha="$1"
  local result_json="$2"
  gate_write_cache "$CACHE_DIR" "qa-gate" "$head_sha" "$result_json"
}

# ─── Gate 1: Tests ────────────────────────────────────────────────────────────

run_gate_tests() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running test suite..."

  local test_runner="$SCRIPT_DIR/test-runner.sh"
  if [[ -f "$test_runner" && -x "$test_runner" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0

    if [[ "$QUICK" == "true" ]]; then
      timeout 120 "$test_runner" --fast > "$tmp_out" 2>&1 || exit_code=$?
    else
      timeout 300 "$test_runner" --full > "$tmp_out" 2>&1 || exit_code=$?
    fi
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Test suite failed with exit code $exit_code"
    else
      local test_count
      test_count=$(echo "$details" | grep -oE '[0-9]+ tests? (passed|ran)' | grep -oE '[0-9]+' | head -1 || echo "0")
      local mode="full"
      [[ "$QUICK" == "true" ]] && mode="fast"
      output="Test suite passed ($test_count tests, $mode mode)"
    fi
  else
    status="fail"
    output="Test runner not found (scripts/test-runner.sh)"
  fi

  # Coverage check (skip in quick mode)
  if [[ "$QUICK" != "true" && "$status" == "pass" ]]; then
    local coverage_script="$SCRIPT_DIR/check-test-coverage.sh"
    if [[ -f "$coverage_script" && -x "$coverage_script" ]]; then
      local cov_out; cov_out=$(mktemp)
      local cov_exit=0
      timeout 60 "$coverage_script" > "$cov_out" 2>&1 || cov_exit=$?
      local cov_details
      cov_details=$(cat "$cov_out")
      rm -f "$cov_out"

      if [[ $cov_exit -ne 0 ]]; then
        status="fail"
        output="$output; coverage check failed (exit $cov_exit)"
        details="$details\n---\n$cov_details"
      else
        output="$output; coverage OK"
      fi
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Run ./scripts/test-runner.sh --full to see failures","Fix failing tests before promoting to main"]'
  gate_build_check_result "tests" "$status" "$output" "$details" "$duration" true "$remediations"
}

# ─── Gate 2: Security ─────────────────────────────────────────────────────────

run_gate_security() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)
  local issues_found=0

  log_step "Running security checks..."

  # 2a: Sensitivity scan
  local sensitivity_script="$SCRIPT_DIR/ci/validators/sensitivity-scan.sh"
  if [[ -f "$sensitivity_script" && -x "$sensitivity_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$sensitivity_script" > "$tmp_out" 2>&1 || exit_code=$?
    local scan_details
    scan_details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Sensitivity scan found issues"
      details="$scan_details"
      issues_found=$((issues_found + 1))
    fi
  else
    status="fail"
    output="Sensitivity scanner not found"
    issues_found=$((issues_found + 1))
  fi

  # 2b: Dependency audit
  local dep_script="$SCRIPT_DIR/ci/validators/dep-audit.sh"
  if [[ -f "$dep_script" && -x "$dep_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$dep_script" > "$tmp_out" 2>&1 || exit_code=$?
    local dep_details
    dep_details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      if [[ "$status" == "pass" ]]; then
        status="fail"
        output="Dependency audit found vulnerabilities"
      else
        output="$output; dependency audit also found vulnerabilities"
      fi
      details="$details\n---\n$dep_details"
      issues_found=$((issues_found + 1))
    fi
  fi

  if [[ "$status" == "pass" ]]; then
    output="Security checks passed (sensitivity scan + dep audit)"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Run ./scripts/ci/validators/sensitivity-scan.sh to see findings","Run ./scripts/ci/validators/dep-audit.sh to check dependencies","Fix all security issues before promoting to main"]'
  gate_build_check_result "security" "$status" "$output" "$details" "$duration" true "$remediations"
}

# ─── Gate 3: License Compliance ───────────────────────────────────────────────

run_gate_licenses() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running dependency license compliance check..."

  local license_script="$SCRIPT_DIR/ci/validators/dep-license-check.sh"
  local license_report="$REPO_ROOT/.dep-audit/license-check.json"

  if [[ -f "$license_script" && -x "$license_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0

    # Run with strict mode in QA gate (block on flagged licenses)
    timeout 120 "$license_script" \
      --output-dir "$REPO_ROOT/.dep-audit" \
      --format summary \
      --strict \
      > "$tmp_out" 2>&1 || exit_code=$?

    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -eq 0 ]]; then
      # Extract counts from report
      if [[ -f "$license_report" ]]; then
        local total flagged
        total=$(jq -r '.summary.total_packages' "$license_report" 2>/dev/null || echo "0")
        flagged=$(jq -r '.summary.flagged_for_review + .summary.unknown' "$license_report" 2>/dev/null || echo "0")

        if [[ $flagged -gt 0 ]]; then
          output="License check passed with $flagged package(s) flagged for review (total: $total packages)"
        else
          output="All $total dependency licenses approved"
        fi
      else
        output="License compliance check passed"
      fi
    elif [[ $exit_code -eq 1 ]]; then
      status="fail"
      if [[ -f "$license_report" ]]; then
        local blocked flagged
        blocked=$(jq -r '.summary.blocked' "$license_report" 2>/dev/null || echo "0")
        flagged=$(jq -r '.summary.flagged_for_review' "$license_report" 2>/dev/null || echo "0")

        if [[ $blocked -gt 0 ]]; then
          output="License compliance FAILED: $blocked package(s) with blocked licenses"
        elif [[ $flagged -gt 0 ]]; then
          output="License compliance FAILED (strict mode): $flagged package(s) require review"
        else
          output="License compliance failed"
        fi
      else
        output="License compliance failed (see details)"
      fi
    else
      status="fail"
      output="License check error (exit code $exit_code)"
    fi
  else
    status="fail"
    output="License compliance checker not found (scripts/ci/validators/dep-license-check.sh)"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Review license report: cat .dep-audit/license-check.json","Remove or replace packages with incompatible licenses","Update license policy if needed: config/license-policy.json","Run: ./scripts/ci/validators/dep-license-check.sh --verbose"]'
  gate_build_check_result "licenses" "$status" "$output" "$details" "$duration" true "$remediations"
}

# ─── Gate 4: Container Security ───────────────────────────────────────────────

run_gate_container_security() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running container security scan..."

  # Scan Docker images used in deployment
  # Priority: sprint-worker image (used by container-launch.sh)
  local images_to_scan=()

  # Check if sprint-worker image exists
  if docker image inspect "claude-dev-env:latest" &>/dev/null; then
    images_to_scan+=("claude-dev-env:latest")
  fi

  # Check if custom sprint worker image exists
  if docker image inspect "claude-sprint-worker:latest" &>/dev/null; then
    images_to_scan+=("claude-sprint-worker:latest")
  fi

  # If no images found, skip with warning
  if [[ ${#images_to_scan[@]} -eq 0 ]]; then
    status="warn"
    output="No container images found to scan (build images first)"
    details="Expected images: claude-dev-env:latest or claude-sprint-worker:latest"
    log_step "  (no images to scan - skipping)"
  else
    local container_script="$SCRIPT_DIR/ci/validators/container-scan.sh"
    if [[ -f "$container_script" && -x "$container_script" ]]; then
      local scan_failed=false
      local scan_count=0

      for image in "${images_to_scan[@]}"; do
        scan_count=$((scan_count + 1))
        local tmp_out; tmp_out=$(mktemp)
        local tmp_report; tmp_report=$(mktemp).json
        local exit_code=0

        log_step "  Scanning: $image"

        timeout 300 "$container_script" \
          --image "$image" \
          --severity "MEDIUM" \
          --output "$tmp_report" \
          --install-trivy \
          > "$tmp_out" 2>&1 || exit_code=$?

        local scan_output
        scan_output=$(cat "$tmp_out")
        rm -f "$tmp_out"

        # Exit code 2 = critical/high vulns (blocking)
        if [[ $exit_code -eq 2 ]]; then
          status="fail"
          output="Critical/high vulnerabilities in container images"
          details="$details\n--- Image: $image ---\n$scan_output"
          scan_failed=true
        # Exit code 1 = medium/low vulns (warning)
        elif [[ $exit_code -eq 1 ]]; then
          if [[ "$status" == "pass" ]]; then
            status="warn"
            output="Medium/low vulnerabilities in container images"
          fi
          details="$details\n--- Image: $image ---\n$scan_output"
        # Exit code 3 = scan error
        elif [[ $exit_code -eq 3 ]]; then
          status="fail"
          output="Container scan failed for $image"
          details="$details\n--- Image: $image ---\n$scan_output"
          scan_failed=true
        else
          # Exit code 0 = clean
          details="$details\n--- Image: $image ---\nNo vulnerabilities found"
        fi

        rm -f "$tmp_report"
      done

      if [[ "$status" == "pass" ]]; then
        output="Container security scan passed ($scan_count image(s) scanned, no vulnerabilities)"
      elif [[ "$status" == "warn" ]]; then
        output="Container security: medium/low vulnerabilities found in $scan_count image(s)"
      fi
    else
      status="warn"
      output="Container scanner not found (scripts/ci/validators/container-scan.sh)"
      details="Install container-scan.sh for container vulnerability scanning"
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Run docker build to create images for scanning","Run ./scripts/ci/validators/container-scan.sh --image <name> to scan specific images","Rebuild images with updated base images to resolve CVEs","Critical/high vulnerabilities block deployment"]'
  gate_build_check_result "container-security" "$status" "$output" "$details" "$duration" true "$remediations"
}

# ─── Gate 5: Quality ──────────────────────────────────────────────────────────

run_gate_quality() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)
  local warnings=0

  log_step "Running quality checks..."

  # 3a: Design compliance
  local design_script="$SCRIPT_DIR/ci/validators/design-compliance.sh"
  if [[ -f "$design_script" && -x "$design_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$design_script" > "$tmp_out" 2>&1 || exit_code=$?
    local design_details
    design_details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="warn"
      output="Design compliance issues found"
      details="$design_details"
      warnings=$((warnings + 1))
    fi
  fi

  # 3b: Naming conventions
  local naming_script="$SCRIPT_DIR/ci/validators/check-naming-conventions.sh"
  if [[ -f "$naming_script" && -x "$naming_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$naming_script" > "$tmp_out" 2>&1 || exit_code=$?
    local naming_details
    naming_details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      if [[ "$status" == "pass" ]]; then
        status="warn"
        output="Naming convention issues found"
      else
        output="$output; naming convention issues also found"
      fi
      details="$details\n---\n$naming_details"
      warnings=$((warnings + 1))
    fi
  fi

  if [[ "$status" == "pass" ]]; then
    output="Quality checks passed (design compliance + naming)"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Run ./scripts/ci/validators/design-compliance.sh to review","Run ./scripts/ci/validators/check-naming-conventions.sh to check","Quality warnings are non-blocking but should be addressed"]'
  gate_build_check_result "quality" "$status" "$output" "$details" "$duration" false "$remediations"
}

# ─── Gate 6: Documentation ────────────────────────────────────────────────────

run_gate_docs() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running documentation checks..."

  local docs_script="$SCRIPT_DIR/scan-docs.sh"
  if [[ -f "$docs_script" && -x "$docs_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$docs_script" --changed-files-only --categories "obsolete,stale" > "$tmp_out" 2>&1 || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="warn"
      output="Stale or obsolete documentation found"
    else
      output="Documentation freshness check passed"
    fi
  else
    # Not having scan-docs is a warning, not a failure
    status="warn"
    output="Documentation scanner not available (scripts/scan-docs.sh)"
    details="Install or create scan-docs.sh for documentation freshness checks"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  local remediations='["Run ./scripts/scan-docs.sh to find stale docs","Update documentation before promoting to main","Doc warnings are non-blocking but improve release quality"]'
  gate_build_check_result "docs" "$status" "$output" "$details" "$duration" false "$remediations"
}

# ─── Report Formatting ────────────────────────────────────────────────────────

print_human_report() {
  local report="$1"

  local gate_status gate_summary duration head_sha
  gate_status=$(echo "$report" | jq -r '.gate_status')
  gate_summary=$(echo "$report" | jq -r '.gate_summary')
  duration=$(echo "$report" | jq -r '.duration_seconds')
  head_sha=$(echo "$report" | jq -r '.head_sha')

  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║  QA VALIDATION GATE                                      ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║${NC}  SHA: ${head_sha:0:12}    Duration: ${duration}s"
  echo -e "${BOLD}║${NC}"

  # Print each check result
  echo "$report" | jq -r '.checks[] | "\(.name)|\(.status)|\(.output)|\(.blocking)"' | \
  while IFS='|' read -r name status output blocking; do
    local icon color block_label
    case "$status" in
      pass) icon="PASS"; color="$GREEN" ;;
      fail) icon="FAIL"; color="$RED" ;;
      warn) icon="WARN"; color="$YELLOW" ;;
      skip) icon="SKIP"; color="$CYAN" ;;
      *)    icon="????"; color="$NC" ;;
    esac
    if [[ "$blocking" == "true" ]]; then
      block_label="[blocking]"
    else
      block_label="[warning]"
    fi
    printf "${BOLD}║${NC}  %b[%s]%b  %-12s %-9s %s\n" "$color" "$icon" "$NC" "$name" "$block_label" "${output:0:30}"
  done

  echo -e "${BOLD}║${NC}"

  # Print result
  case "$gate_status" in
    PASS)
      echo -e "${BOLD}║${NC}  ${GREEN}RESULT: PASS — qa branch is ready for main promotion${NC}"
      ;;
    FAIL)
      echo -e "${BOLD}║${NC}  ${RED}RESULT: FAIL — blocking issues must be fixed${NC}"
      ;;
    WARN)
      echo -e "${BOLD}║${NC}  ${YELLOW}RESULT: WARN — promotion allowed with caution${NC}"
      ;;
    ERROR)
      echo -e "${BOLD}║${NC}  ${RED}RESULT: ERROR — gate could not complete${NC}"
      ;;
  esac

  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Print details for failures/warnings
  local has_issues=false
  while IFS= read -r check_json; do
    local check_name check_status check_output
    check_name=$(echo "$check_json" | jq -r '.name')
    check_status=$(echo "$check_json" | jq -r '.status')
    check_output=$(echo "$check_json" | jq -r '.output // ""')

    if [[ "$check_status" == "fail" || "$check_status" == "warn" ]]; then
      has_issues=true
      if [[ "$check_status" == "fail" ]]; then
        echo -e "  ${RED}[FAIL]${NC} $check_name: $check_output"
      else
        echo -e "  ${YELLOW}[WARN]${NC} $check_name: $check_output"
      fi

      # Print remediations
      local rems
      rems=$(echo "$check_json" | jq -r '.remediations[]? // empty' 2>/dev/null)
      if [[ -n "$rems" ]]; then
        echo "$rems" | while read -r rem; do
          echo "    -> $rem"
        done
      fi
      echo ""
    fi
  done < <(echo "$report" | jq -c '.checks[]')

  if [[ "$has_issues" == "false" ]]; then
    echo -e "  ${GREEN}All checks passed. Ready for /pr-to-main.${NC}"
    echo ""
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local head_sha
  head_sha=$(gate_get_head_sha)

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    local mode="standard"
    [[ "$QUICK" == "true" ]] && mode="quick"
    [[ "$FULL" == "true" ]] && mode="full"

    echo "DRY RUN - QA gate would run the following checks ($mode mode):"
    echo "  1. Tests              - Test suite + coverage threshold        [BLOCKING]"
    echo "  2. Security           - Sensitivity scan + dep audit           [BLOCKING]"
    echo "  3. Licenses           - Dependency license compliance          [BLOCKING]"
    echo "  4. Container Security - Docker image CVE scanning              [BLOCKING]"
    echo "  5. Quality            - Design compliance + naming             [WARNING]"
    echo "  6. Docs               - Documentation freshness                [WARNING]"
    echo ""
    echo "Blocking checks must pass; warnings are informational."
    if [[ "$QUICK" == "true" ]]; then
      echo "Quick mode: fast test suite, skip coverage check"
    fi
    echo "Estimated time: ~1-3 minutes"
    exit 0
  fi

  if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
    echo ""
    log_info "QA Validation Gate (HEAD: ${head_sha:0:12})"
    echo "────────────────────────────────────────────────"
    echo ""
  fi

  # Check cache first
  local cached
  if cached=$(check_cache "$head_sha" 2>/dev/null); then
    if [[ "$JSON_OUTPUT" == "true" ]]; then
      echo "$cached"
    else
      log_info "Using cached gate result (use --no-cache to refresh)"
      print_human_report "$cached"
    fi
    local cached_status
    cached_status=$(echo "$cached" | jq -r '.gate_status')
    case "$cached_status" in
      PASS) exit 0 ;;
      FAIL) exit 1 ;;
      WARN) exit 2 ;;
      *)    exit 0 ;;
    esac
  fi

  local pipeline_start
  pipeline_start=$(date +%s)

  # Run all gates, storing results as compact JSON lines in a temp file
  local results_file; results_file=$(mktemp)
  run_gate_tests | jq -c . >> "$results_file"
  run_gate_security | jq -c . >> "$results_file"
  run_gate_licenses | jq -c . >> "$results_file"
  run_gate_container_security | jq -c . >> "$results_file"
  run_gate_quality | jq -c . >> "$results_file"
  run_gate_docs | jq -c . >> "$results_file"

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - pipeline_start))

  # Build checks JSON array from compact lines
  local checks_json
  checks_json=$(jq -s '.' "$results_file")
  rm -f "$results_file"

  # Determine overall gate status
  local gate_status
  gate_status=$(gate_determine_status "$checks_json" false)

  # Generate summary
  local gate_summary
  gate_summary=$(gate_generate_summary "$gate_status" "$checks_json" false)

  # Build final report
  local report
  report=$(gate_build_report "qa-gate" "$head_sha" "$checks_json" "$gate_status" "$gate_summary" "$total_duration")

  # Cache result
  write_cache "$head_sha" "$report" 2>/dev/null || true

  # Create issues if requested
  if [[ "$CREATE_ISSUES" == "true" ]]; then
    if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
      echo ""
      log_info "Creating GitHub issues from gate findings..."
    fi
    gate_create_issues_from_report "qa-gate" "$report" "$PR_NUMBER" "false"
  fi

  # Output
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo "$report"
  elif [[ "$QUIET" != "true" ]]; then
    print_human_report "$report"
  fi

  # Exit code
  case "$gate_status" in
    PASS) exit 0 ;;
    FAIL) exit 1 ;;
    WARN) exit 2 ;;
    *)    exit 3 ;;
  esac
}

main "$@"
