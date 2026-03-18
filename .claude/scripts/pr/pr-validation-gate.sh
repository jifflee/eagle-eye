#!/usr/bin/env bash
# pr-validation-gate.sh
# PR validation gate that replaces GitHub required status checks.
# Blocks /pr-merge unless all checks pass.
#
# Usage:
#   ./scripts/pr-validation-gate.sh <PR_NUMBER> [OPTIONS]
#
# Options:
#   --json              Output JSON format (default: human)
#   --quick             Skip slow checks (security, docs) - essential checks only
#   --no-cache          Bypass result cache, force re-run all checks
#   --checks LIST       Comma-separated checks: tests,security,quality,docs,lint (default: all)
#   --block-on-warn     Treat warnings as failures (strict mode)
#   --report FILE       Write JSON report to FILE (default: .pr-gate-<PR>.json)
#   --verbose           Show detailed output from each check
#   --dry-run           Show what would run without running checks
#
# Exit Codes:
#   0 - PASS: all checks passed, PR is gate-clear for merge
#   1 - FAIL: one or more checks failed, merge blocked
#   2 - WARN: checks passed with warnings (non-blocking by default)
#   3 - ERROR: invalid arguments or script failure
#
# Check Categories:
#   tests        - Run local test suite (validate-test-existence.sh, test-runner.sh)
#   security     - Security scan (scripts/ci/security-scan.sh --full)
#   dependencies - Dependency vulnerability review (scripts/ci/dep-review.sh)
#   licenses     - Dependency license compliance (scripts/ci/validators/dep-license-check.sh)
#   quality      - Code quality scan (scan-code-quality.sh)
#   docs         - Documentation freshness (scan-docs.sh)
#   lint         - Script linting (check-naming-conventions.sh, shellcheck)
#
# Caching:
#   Results are cached in .pr-gate-cache/ keyed by PR number + HEAD commit SHA.
#   Cache is invalidated when the PR branch HEAD changes.
#   Use --no-cache to bypass.
#
# Integration with /pr-merge:
#   /pr-merge calls this gate before executing any merge. If exit code is 1,
#   the merge is blocked and the failure report is displayed.
#   Set PR_GATE_SKIP=1 env var to bypass gate (emergency use only).
#
# Related:
#   - Issue #847 - Add PR validation gate for merge readiness
#   - Issue #845 - Parent: PR lifecycle automation
#   - scripts/pr-validate.sh     - Basic PR structural validation
#   - scripts/check-merge-readiness.sh - Label-based readiness check
#   - scripts/ci/run-pipeline.sh - Full CI pipeline orchestrator

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.pr-gate-cache"

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/gate-common.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

PR_NUMBER=""
OUTPUT_FORMAT="human"
QUICK_MODE=false
NO_CACHE=false
CHECKS_LIST="tests,security,dependencies,licenses,quality,docs,lint"
BLOCK_ON_WARN=false
REPORT_FILE=""
VERBOSE=false
DRY_RUN=false

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)         OUTPUT_FORMAT="json"; shift ;;
    --quick)        QUICK_MODE=true; shift ;;
    --no-cache)     NO_CACHE=true; shift ;;
    --checks)       CHECKS_LIST="$2"; shift 2 ;;
    --block-on-warn) BLOCK_ON_WARN=true; shift ;;
    --report)       REPORT_FILE="$2"; shift 2 ;;
    --verbose)      VERBOSE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h)      show_help ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        echo "ERROR: Unknown argument: $1" >&2
        echo "Run with --help for usage." >&2
        exit 3
      fi
      shift
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ -z "$PR_NUMBER" ]]; then
  echo "ERROR: PR number required." >&2
  echo "Usage: $0 <PR_NUMBER> [OPTIONS]" >&2
  exit 3
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  exit 3
fi

# Set default report file
if [[ -z "$REPORT_FILE" ]]; then
  REPORT_FILE="$REPO_ROOT/.pr-gate-${PR_NUMBER}.json"
fi

# ─── Logging ──────────────────────────────────────────────────────────────────
# Note: Using log_info, log_warn, log_error from lib/common.sh

log_verbose() {
  if [[ "$VERBOSE" == "true" && "$OUTPUT_FORMAT" != "json" ]]; then
    log_debug "$@"
  fi
}

log_step() {
  if [[ "$OUTPUT_FORMAT" != "json" ]]; then
    log_info "[CHECK] $*"
  fi
}

# ─── Cache Helpers ────────────────────────────────────────────────────────────
# Note: Using gate_* functions from lib/gate-common.sh

# Wrapper for PR-specific cache file naming
get_cache_file() {
  local pr_num="$1"
  local head_sha="$2"
  gate_get_cache_file "$CACHE_DIR" "gate-${pr_num}" "$head_sha"
}

check_cache() {
  local pr_num="$1"
  local head_sha="$2"
  gate_check_cache "$CACHE_DIR" "gate-${pr_num}" "$head_sha" 30 "$NO_CACHE"
}

write_cache() {
  local pr_num="$1"
  local head_sha="$2"
  local result_json="$3"
  gate_write_cache "$CACHE_DIR" "gate-${pr_num}" "$head_sha" "$result_json"
}

# ─── Check: Tests ─────────────────────────────────────────────────────────────

run_check_tests() {
  local status="pass"
  local output=""
  local remediations=()

  # Check if test runner exists
  if [[ -f "$SCRIPT_DIR/test-runner.sh" ]]; then
    log_verbose "Running test-runner.sh..."
    local tmp_out; tmp_out=$(mktemp)
    if ! timeout 120 "$SCRIPT_DIR/test-runner.sh" --quick 2>&1 > "$tmp_out"; then
      status="fail"
      output=$(cat "$tmp_out")
      remediations+=("Fix failing tests before merging: ./scripts/test-runner.sh")
    else
      output=$(cat "$tmp_out")
    fi
    rm -f "$tmp_out"
  elif [[ -f "$SCRIPT_DIR/validate-test-existence.sh" ]]; then
    # Fallback: verify tests exist for changed code
    log_verbose "Running validate-test-existence.sh..."
    local tmp_out; tmp_out=$(mktemp)
    if ! timeout 60 "$SCRIPT_DIR/validate-test-existence.sh" 2>&1 > "$tmp_out"; then
      status="warn"
      output=$(cat "$tmp_out")
      remediations+=("Add tests for new code. See: ./scripts/validate-test-existence.sh")
    else
      output=$(cat "$tmp_out")
    fi
    rm -f "$tmp_out"
  else
    status="skip"
    output="No test runner found (test-runner.sh or validate-test-existence.sh)"
    remediations+=("Create a test runner at scripts/test-runner.sh")
  fi

  # Also check test distribution
  if [[ "$status" == "pass" ]] && [[ -f "$SCRIPT_DIR/validate-test-distribution.sh" ]]; then
    log_verbose "Running validate-test-distribution.sh..."
    local tmp_out; tmp_out=$(mktemp)
    local dist_exit=0
    timeout 30 "$SCRIPT_DIR/validate-test-distribution.sh" 2>&1 > "$tmp_out" || dist_exit=$?
    if [[ $dist_exit -ne 0 ]]; then
      status="warn"
      output+=$'\n'"Test distribution issues: $(cat "$tmp_out")"
      remediations+=("Improve test distribution: ./scripts/validate-test-distribution.sh")
    fi
    rm -f "$tmp_out"
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "tests" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: Security ──────────────────────────────────────────────────────────

run_check_security() {
  local status="pass"
  local output=""
  local remediations=()
  local security_report="$REPO_ROOT/security-report.json"

  local security_script="$SCRIPT_DIR/ci/security-scan.sh"
  if [[ ! -f "$security_script" ]]; then
    # Try alternate path
    security_script="$SCRIPT_DIR/security-scan.sh"
  fi

  if [[ -f "$security_script" && -x "$security_script" ]]; then
    log_verbose "Running security scan..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$security_script" \
      --full \
      --categories "secrets,owasp,dependencies" \
      --severity "high" \
      --output "$security_report" \
      2>&1 > "$tmp_out" || exit_code=$?
    output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        ;;
      1)
        # Medium/low findings - warn but don't block
        status="warn"
        remediations+=("Review security findings: cat $security_report")
        remediations+=("Run: ./scripts/ci/security-scan.sh --full --verbose")
        ;;
      2)
        # Critical/high findings - block merge
        status="fail"
        remediations+=("Fix critical/high security findings before merging")
        remediations+=("View report: cat $security_report")
        remediations+=("Run: ./scripts/ci/security-scan.sh --full --severity high --verbose")
        ;;
      *)
        status="warn"
        output+=$'\n'"Security scanner exited with code $exit_code"
        remediations+=("Check security scanner installation: ./scripts/ci/security-scan.sh --help")
        ;;
    esac
  else
    # Try the Python scanner directly
    local py_scanner="$SCRIPT_DIR/security-scan.py"
    if [[ -f "$py_scanner" ]]; then
      log_verbose "Running Python security scanner..."
      local tmp_out; tmp_out=$(mktemp)
      local exit_code=0
      timeout 120 python3 "$py_scanner" \
        --mode full \
        --source-dir "$REPO_ROOT" \
        --categories "secrets,owasp,dependencies" \
        --severity-threshold "high" \
        --output-file "$security_report" \
        2>&1 > "$tmp_out" || exit_code=$?
      output=$(cat "$tmp_out")
      rm -f "$tmp_out"

      if [[ $exit_code -ge 2 ]]; then
        status="fail"
        remediations+=("Fix critical/high security findings: cat $security_report")
      elif [[ $exit_code -eq 1 ]]; then
        status="warn"
        remediations+=("Review security warnings: cat $security_report")
      fi
    else
      status="skip"
      output="Security scanner not found (scripts/ci/security-scan.sh or scripts/security-scan.py)"
      remediations+=("Install security scanner: see docs/standards/CI_PIPELINE.md")
    fi
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "security" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: Dependency Review ─────────────────────────────────────────────────

run_check_dependencies() {
  local status="pass"
  local output=""
  local remediations=()
  local dep_report="$REPO_ROOT/.dep-audit/dep-review.json"

  local dep_review_script="$SCRIPT_DIR/ci/dep-review.sh"
  if [[ -f "$dep_review_script" && -x "$dep_review_script" ]]; then
    log_verbose "Running dependency review..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 180 "$dep_review_script" \
      --base dev \
      --blocking-level high \
      --output "$dep_report" \
      2>&1 > "$tmp_out" || exit_code=$?
    output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="No new critical/high vulnerabilities introduced"
        ;;
      1)
        # New vulnerabilities found - block merge
        status="fail"
        output="PR introduces new dependency vulnerabilities (blocking)"
        remediations+=("Fix dependency vulnerabilities before merging")
        remediations+=("View report: cat $dep_report")
        remediations+=("Run: ./scripts/ci/dep-review.sh --verbose")
        remediations+=("Remediate: npm audit fix / pip install --upgrade <package>")
        ;;
      *)
        status="warn"
        output="Dependency review check error (exit code $exit_code)"
        remediations+=("Check dep-review.sh installation: ./scripts/ci/dep-review.sh --help")
        ;;
    esac
  else
    status="skip"
    output="Dependency review scanner not found (scripts/ci/dep-review.sh)"
    remediations+=("Install dependency scanner: see scripts/ci/install-ci-tools.sh")
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "dependencies" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: License Compliance ────────────────────────────────────────────────

run_check_licenses() {
  local status="pass"
  local output=""
  local remediations=()
  local license_report="$REPO_ROOT/.dep-audit/license-check.json"

  local license_script="$SCRIPT_DIR/ci/validators/dep-license-check.sh"
  if [[ -f "$license_script" && -x "$license_script" ]]; then
    log_verbose "Running license compliance check..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$license_script" \
      --output-dir "$REPO_ROOT/.dep-audit" \
      --format summary \
      2>&1 > "$tmp_out" || exit_code=$?
    output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        # Extract summary if available
        if [[ -f "$license_report" ]] && jq empty "$license_report" 2>/dev/null; then
          local flagged
          flagged=$(jq -r '.summary.flagged_for_review + .summary.unknown' "$license_report" 2>/dev/null || echo "0")
          if [[ $flagged -gt 0 ]]; then
            status="warn"
            output="License check passed with $flagged package(s) flagged for review"
            remediations+=("Review flagged packages: cat $license_report")
            remediations+=("Update license policy if needed: config/license-policy.json")
          else
            output="All dependency licenses approved"
          fi
        else
          output="License compliance check passed"
        fi
        ;;
      1)
        # Blocked licenses found
        status="fail"
        output="Dependencies with blocked/incompatible licenses found"
        remediations+=("Fix license compliance issues before merging")
        remediations+=("View report: cat $license_report")
        remediations+=("Run: ./scripts/ci/validators/dep-license-check.sh --verbose")
        remediations+=("Remove or replace packages with incompatible licenses")
        ;;
      *)
        status="warn"
        output="License check error (exit code $exit_code)"
        remediations+=("Check license checker: ./scripts/ci/validators/dep-license-check.sh --help")
        remediations+=("Ensure SBOM is generated: ./scripts/ci/validators/generate-sbom.sh")
        ;;
    esac
  else
    status="skip"
    output="License compliance checker not found (scripts/ci/validators/dep-license-check.sh)"
    remediations+=("License checker is available at scripts/ci/validators/dep-license-check.sh")
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "licenses" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: Code Quality ──────────────────────────────────────────────────────

run_check_quality() {
  local status="pass"
  local output=""
  local remediations=()
  local quality_report="$REPO_ROOT/.refactor/findings-code.json"

  local quality_script="$SCRIPT_DIR/scan-code-quality.sh"
  if [[ -f "$quality_script" && -x "$quality_script" ]]; then
    log_verbose "Running code quality scan..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$quality_script" \
      --changed-files-only \
      --categories "modularize,naming" \
      --output-file "$quality_report" \
      2>&1 > "$tmp_out" || exit_code=$?
    output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="warn"
      remediations+=("Review code quality findings: cat $quality_report")
      remediations+=("Run full scan: ./scripts/scan-code-quality.sh --verbose")
    fi
  else
    # Fallback: check naming conventions
    local naming_script="$SCRIPT_DIR/ci/check-naming-conventions.sh"
    if [[ -f "$naming_script" && -x "$naming_script" ]]; then
      log_verbose "Running naming convention check..."
      local tmp_out; tmp_out=$(mktemp)
      local exit_code=0
      timeout 60 "$naming_script" 2>&1 > "$tmp_out" || exit_code=$?
      output=$(cat "$tmp_out")
      rm -f "$tmp_out"

      if [[ $exit_code -ne 0 ]]; then
        status="fail"
        remediations+=("Fix naming convention violations: ./scripts/ci/check-naming-conventions.sh")
        remediations+=("See: docs/standards/ for naming guidelines")
      fi
    else
      status="skip"
      output="Code quality scanner not found (scripts/scan-code-quality.sh)"
      remediations+=("Install quality scanner or add scripts/ci/check-naming-conventions.sh")
    fi
  fi

  # Also run refactor lint if available
  local refactor_script="$SCRIPT_DIR/ci/refactor-lint.sh"
  if [[ "$status" != "fail" ]] && [[ -f "$refactor_script" && -x "$refactor_script" ]]; then
    log_verbose "Running refactor lint..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$refactor_script" --scope changed --severity high 2>&1 > "$tmp_out" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      output+=$'\n'"Refactor lint: $(cat "$tmp_out")"
      if [[ "$status" == "pass" ]]; then
        status="warn"
      fi
      remediations+=("Address high-severity refactor findings: ./scripts/ci/refactor-lint.sh --scope changed --severity high")
    fi
    rm -f "$tmp_out"
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "quality" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: Documentation Freshness ──────────────────────────────────────────

run_check_docs() {
  local status="pass"
  local output=""
  local remediations=()
  local docs_report="$REPO_ROOT/.refactor/findings-docs.json"

  local docs_script="$SCRIPT_DIR/scan-docs.sh"
  if [[ -f "$docs_script" && -x "$docs_script" ]]; then
    log_verbose "Running documentation freshness scan..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 120 "$docs_script" \
      --changed-files-only \
      --categories "obsolete,stale" \
      --output-file "$docs_report" \
      2>&1 > "$tmp_out" || exit_code=$?
    output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="warn"
      remediations+=("Update stale/obsolete documentation: cat $docs_report")
      remediations+=("Run: ./scripts/scan-docs.sh --verbose for details")
    fi
  else
    # Fallback: check README freshness heuristically
    local readme="$REPO_ROOT/README.md"
    if [[ -f "$readme" ]]; then
      # Check if README references files that no longer exist (basic check)
      local broken_refs=0
      while IFS= read -r line; do
        if echo "$line" | grep -qE '\[.*\]\(\.\/'; then
          local ref_path
          ref_path=$(echo "$line" | grep -oE '\(\.\/[^)]+\)' | tr -d '()' | head -1)
          if [[ -n "$ref_path" ]] && [[ ! -e "$REPO_ROOT/$ref_path" ]]; then
            broken_refs=$((broken_refs + 1))
          fi
        fi
      done < "$readme"

      if [[ $broken_refs -gt 0 ]]; then
        status="warn"
        output="README.md has $broken_refs potentially broken local links"
        remediations+=("Fix broken documentation links in README.md")
      else
        status="pass"
        output="Documentation freshness check passed (basic link validation)"
      fi
    else
      status="skip"
      output="Documentation scanner not found (scripts/scan-docs.sh)"
      remediations+=("Add docs scanner at scripts/scan-docs.sh or create README.md")
    fi
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "docs" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check: Lint ──────────────────────────────────────────────────────────────

run_check_lint() {
  local status="pass"
  local output=""
  local remediations=()

  # Run naming conventions check
  local naming_script="$SCRIPT_DIR/ci/check-naming-conventions.sh"
  if [[ -f "$naming_script" && -x "$naming_script" ]]; then
    log_verbose "Running naming conventions check..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 60 "$naming_script" 2>&1 > "$tmp_out" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output+="Naming violations: $(cat "$tmp_out")"$'\n'
      remediations+=("Fix naming convention violations: ./scripts/ci/check-naming-conventions.sh")
    fi
    rm -f "$tmp_out"
  fi

  # Run script size check (advisory)
  local size_script="$SCRIPT_DIR/ci/check-script-sizes.sh"
  if [[ -f "$size_script" && -x "$size_script" ]]; then
    log_verbose "Running script size check..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$size_script" 2>&1 > "$tmp_out" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      output+="Script size warnings: $(cat "$tmp_out" | head -5)"$'\n'
      if [[ "$status" == "pass" ]]; then
        status="warn"
      fi
      remediations+=("Consider splitting large scripts (advisory): ./scripts/ci/check-script-sizes.sh")
    fi
    rm -f "$tmp_out"
  fi

  # Run shellcheck if available (optional, non-blocking)
  if command -v shellcheck &>/dev/null && [[ "$QUICK_MODE" != "true" ]]; then
    log_verbose "Running shellcheck on changed scripts..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    # Find changed .sh files
    local changed_scripts
    changed_scripts=$(git diff --name-only HEAD 2>/dev/null | grep '\.sh$' | head -20 || true)
    if [[ -n "$changed_scripts" ]]; then
      echo "$changed_scripts" | while IFS= read -r script; do
        if [[ -f "$REPO_ROOT/$script" ]]; then
          shellcheck -f gcc "$REPO_ROOT/$script" 2>&1 >> "$tmp_out" || exit_code=1
        fi
      done
      if [[ -s "$tmp_out" ]]; then
        output+="ShellCheck: $(cat "$tmp_out" | head -10)"$'\n'
        if [[ "$status" == "pass" ]]; then
          status="warn"
        fi
        remediations+=("Fix shellcheck warnings in changed scripts")
      fi
    fi
    rm -f "$tmp_out"
  fi

  # Check for lint-doc-size if available
  local lint_doc_script="$SCRIPT_DIR/lint-doc-size.sh"
  if [[ -f "$lint_doc_script" && -x "$lint_doc_script" ]]; then
    log_verbose "Running doc size lint..."
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$lint_doc_script" 2>&1 > "$tmp_out" || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
      output+="Doc size lint: $(cat "$tmp_out" | head -5)"$'\n'
      if [[ "$status" == "pass" ]]; then
        status="warn"
      fi
      remediations+=("Trim oversized documentation files: ./scripts/lint-doc-size.sh")
    fi
    rm -f "$tmp_out"
  fi

  if [[ -z "$output" ]]; then
    output="All lint checks passed"
  fi

  local remediations_json
  remediations_json=$(printf '%s\n' "${remediations[@]+"${remediations[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg name "lint" \
    --arg status "$status" \
    --arg output "$output" \
    --argjson remediations "$remediations_json" \
    '{name: $name, status: $status, output: $output, remediations: $remediations}'
}

# ─── Check Dispatcher ─────────────────────────────────────────────────────────

run_check() {
  local check_name="$1"
  local start_time
  start_time=$(date +%s)

  log_step "Running $check_name check..."

  local result=""
  case "$check_name" in
    tests)        result=$(run_check_tests) ;;
    security)     result=$(run_check_security) ;;
    dependencies) result=$(run_check_dependencies) ;;
    licenses)     result=$(run_check_licenses) ;;
    quality)      result=$(run_check_quality) ;;
    docs)         result=$(run_check_docs) ;;
    lint)         result=$(run_check_lint) ;;
    *)
      result=$(jq -n --arg name "$check_name" \
        '{name: $name, status: "skip", output: "Unknown check category", remediations: []}')
      ;;
  esac

  local end_time; end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Inject duration into result (with validation)
  if echo "$result" | jq empty 2>/dev/null; then
    echo "$result" | jq --argjson dur "$duration" '. + {duration_seconds: $dur}'
  else
    # Fallback if result is not valid JSON
    jq -n \
      --arg name "$check_name" \
      --arg output "Check function returned invalid JSON" \
      --argjson dur "$duration" \
      '{name: $name, status: "error", output: $output, remediations: [], duration_seconds: $dur}'
  fi
}

# ─── Report Generation ────────────────────────────────────────────────────────

build_gate_report() {
  local pr_num="$1"
  local head_sha="$2"
  local checks_json="$3"
  local gate_status="$4"
  local gate_summary="$5"
  local duration="$6"

  # Use gate_build_report and add pr_number field
  gate_build_report "PR #${pr_num}" "$head_sha" "$checks_json" "$gate_status" "$gate_summary" "$duration" | \
    jq --arg pr_number "$pr_num" '. + {pr_number: ($pr_number | tonumber)}'
}

print_human_report() {
  local report="$1"

  local gate_status gate_summary pr_num head_sha duration
  gate_status=$(echo "$report" | jq -r '.gate_status')
  gate_summary=$(echo "$report" | jq -r '.gate_summary')
  pr_num=$(echo "$report" | jq -r '.pr_number')
  head_sha=$(echo "$report" | jq -r '.head_sha')
  duration=$(echo "$report" | jq -r '.duration_seconds')

  # Print header
  gate_print_report_header "PR Validation Gate" "PR #${pr_num}" "$head_sha" "$duration"

  # Print each check result
  echo "$report" | jq -r '.checks[] | "\(.name) \(.status) \(.duration_seconds // 0)"' | \
  while IFS=' ' read -r name status dur; do
    gate_print_check_result "$name" "$status" "$dur"
  done

  # Print failures and remediations
  gate_print_failures "$report"

  # Print overall result
  gate_print_status "$gate_status" "$gate_summary" "PR #${pr_num}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  # Emergency bypass for /pr-merge
  if [[ "${PR_GATE_SKIP:-0}" == "1" ]]; then
    log_warn "PR_GATE_SKIP=1 detected - bypassing validation gate (emergency use only)"
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      jq -n --arg pr "$PR_NUMBER" \
        '{pr_number: ($pr | tonumber), gate_status: "SKIP", gate_summary: "Gate bypassed via PR_GATE_SKIP=1", checks: []}'
    else
      echo -e "${YELLOW}⚠ Gate bypassed (PR_GATE_SKIP=1)${NC}"
    fi
    exit 0
  fi

  # Get PR HEAD SHA for caching
  local head_sha
  head_sha=$(gate_get_pr_head_sha "$PR_NUMBER")
  if [[ -z "$head_sha" ]]; then
    head_sha=$(gate_get_head_sha)
  fi

  log_verbose "PR #$PR_NUMBER, HEAD SHA: ${head_sha:0:12}"

  # Check cache first (returns 0 and prints JSON if cache hit)
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    if cached=$(check_cache "$PR_NUMBER" "$head_sha" 2>/dev/null); then
      echo "$cached"
      gate_status=$(echo "$cached" | jq -r '.gate_status')
      case "$gate_status" in
        PASS|WARN) exit 0 ;;
        FAIL) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  else
    local cached
    if cached=$(check_cache "$PR_NUMBER" "$head_sha" 2>/dev/null); then
      log_info "Using cached gate result (use --no-cache to refresh)"
      print_human_report "$cached"
      gate_status=$(echo "$cached" | jq -r '.gate_status')
      case "$gate_status" in
        PASS|WARN) exit 0 ;;
        FAIL) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  fi

  # Parse checks list
  IFS=',' read -ra CHECKS_ARRAY <<< "$CHECKS_LIST"

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN - PR #$PR_NUMBER validation gate would run:"
    echo "  Checks:     ${CHECKS_ARRAY[*]}"
    echo "  Quick mode: $QUICK_MODE"
    echo "  Caching:    $([ "$NO_CACHE" == "true" ] && echo "disabled" || echo "enabled")"
    echo "  Report:     $REPORT_FILE"
    exit 0
  fi

  if [[ "$OUTPUT_FORMAT" != "json" ]]; then
    echo ""
    echo -e "${BOLD}PR Validation Gate${NC} - PR #${PR_NUMBER}"
    echo -e "Checks: ${CHECKS_ARRAY[*]}  |  Quick: $QUICK_MODE  |  SHA: ${head_sha:0:12}"
    echo "────────────────────────────────────────────────"
    echo ""
  fi

  local pipeline_start
  pipeline_start=$(date +%s)

  # Skip slow checks in quick mode
  if [[ "$QUICK_MODE" == "true" ]]; then
    # Keep only: lint, tests (basic)
    CHECKS_ARRAY=("lint" "tests")
    log_info "Quick mode: running lint and tests only"
  fi

  # Run all checks and collect results
  local checks_results=()
  for check in "${CHECKS_ARRAY[@]}"; do
    local result
    result=$(run_check "$check")
    checks_results+=("$result")

    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
      local c_status
      c_status=$(echo "$result" | jq -r '.status')
      local c_dur
      c_dur=$(echo "$result" | jq -r '.duration_seconds // 0')
      local icon color
      case "$c_status" in
        pass) icon="✓"; color="$GREEN" ;;
        fail) icon="✗"; color="$RED" ;;
        warn) icon="⚠"; color="$YELLOW" ;;
        skip) icon="○"; color="$CYAN" ;;
        *)    icon="?"; color="$NC" ;;
      esac
      echo -e "  ${color}${icon}${NC} $check ... $c_status (${c_dur}s)"
    fi
  done

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - pipeline_start))

  # Build checks JSON array
  local checks_json="["
  local first=true
  for result in "${checks_results[@]}"; do
    if [[ "$first" != "true" ]]; then checks_json+=","; fi
    checks_json+="$result"
    first=false
  done
  checks_json+="]"

  # Determine overall gate status
  local gate_status gate_summary exit_code
  gate_status=$(gate_determine_status "$checks_json" "$BLOCK_ON_WARN")
  gate_summary=$(gate_generate_summary "$gate_status" "$checks_json" "$BLOCK_ON_WARN")

  case "$gate_status" in
    PASS) exit_code=0 ;;
    WARN) exit_code=2 ;;
    FAIL) exit_code=1 ;;
    *) exit_code=0 ;;
  esac

  # Build final report
  local report
  report=$(build_gate_report \
    "$PR_NUMBER" \
    "$head_sha" \
    "$checks_json" \
    "$gate_status" \
    "$gate_summary" \
    "$total_duration")

  # Write report to file
  echo "$report" > "$REPORT_FILE"
  log_verbose "Gate report written to: $REPORT_FILE"

  # Cache result
  write_cache "$PR_NUMBER" "$head_sha" "$report" 2>/dev/null || true

  # Output
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    echo "$report"
  else
    print_human_report "$report"
    echo "  Report saved: $REPORT_FILE"
    echo ""
  fi

  exit $exit_code
}

main "$@"
