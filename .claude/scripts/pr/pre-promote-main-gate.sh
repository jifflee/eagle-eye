#!/usr/bin/env bash
# pre-promote-main-gate.sh
# Pre-promotion quality gate for qa→main promotions (STRICTER)
#
# DESCRIPTION:
#   Runs all required quality checks before allowing /pr-to-main to proceed.
#   Enforces stricter thresholds than dev→qa gate to ensure production readiness.
#   ALL warnings become blocking for production promotion.
#
# USAGE:
#   ./scripts/pre-promote-main-gate.sh [OPTIONS]
#
# OPTIONS:
#   --no-cache          Bypass result cache, force re-run all checks
#   --quiet             Minimal output (exit code only)
#   --json              Output JSON format
#   --verbose           Show detailed output from each check
#   --dry-run           Show what would run without running checks
#   --bypass            Emergency bypass (requires justification in PR)
#   --create-issues     Create GitHub issues for blocking/warning findings
#   --pr PR_NUMBER      PR number to link in created issues
#   --help              Show this help
#
# EXIT CODES:
#   0 - PASS: all gates passed, promotion cleared
#   1 - FAIL: blocking gate(s) failed, promotion blocked
#   2 - WARN: non-blocking findings (N/A for main - all are blocking)
#   3 - ERROR: gate script failed to run
#
# GATE CHECKS (ORDERED BY EXECUTION) - ALL BLOCKING:
#   1. Test suite              (./scripts/test-runner.sh --full)               [BLOCKING]
#   2. Lint / ShellCheck       (./scripts/ci/refactor-lint.sh)                 [BLOCKING]
#   3. Refactor scan           (/refactor --lint --severity medium)            [BLOCKING]
#   4. Security scan           (./scripts/ci/sensitivity-scan.sh)              [BLOCKING]
#   5. Repo settings drift     (./scripts/ci/validate-repo-settings.sh)        [BLOCKING]
#   6. Environment tier        (./scripts/ci/validate-environment-tier.sh main)[BLOCKING]
#   7. Repo naming validation  (./scripts/ci/validate-repo-naming.sh)          [BLOCKING]
#   8. Doc freshness           (./scripts/scan-docs.sh --changed-files-only)   [BLOCKING]
#   9. Changelog exists        (CHANGELOG.md or docs/CHANGELOG.md)             [BLOCKING]
#   10. Version tag valid      (git tag matches expected version)              [BLOCKING]
#   11. Open PR check          (gh pr list --base qa --state open)             [BLOCKING]
#   12. CI status on qa        (gh api repos/:owner/:repo/commits/qa/status)   [BLOCKING]
#   13. QA sign-off            (dev→qa PR merged with approval)                [BLOCKING]
#
# DIFFERENCES FROM dev→qa GATE:
#   - Full test suite (not --fast)
#   - Refactor severity: medium (not just critical/high)
#   - All warnings are BLOCKING (repo naming, doc freshness)
#   - Additional: changelog required
#   - Additional: version tag validation
#   - Checks qa branch instead of dev
#
# CACHE:
#   Results cached for 15 minutes per HEAD SHA in .promotion-gate-cache/
#   Use --no-cache to force re-run
#
# ISSUE CREATION:
#   Use --create-issues to automatically create GitHub issues for findings.
#   - Each FAIL or WARN finding generates a tracked issue
#   - Issues include check details, remediation steps, and reproduction commands
#   - Duplicate detection prevents re-creating existing issues
#   - Issues labeled with: bug, gate-finding, P1/P2 (based on blocking status)
#   - Use --pr NUMBER to link issues to the promotion PR
#   Example: ./scripts/pre-promote-main-gate.sh --create-issues --pr 456
#
# INTEGRATION:
#   - Called by /pr-to-main before creating PR
#   - All findings block promotion (no warnings allowed)
#   - Related: Issue #955 - Enforce pre-promotion quality gates
#   - Related: Issue #1056 - Formalized gate findings → issue creation
#
# Related:
#   - scripts/pre-promote-qa-gate.sh    - Less strict gates for dev→qa
#   - scripts/pr-validation-gate.sh     - Post-PR validation for merges
#   - .claude/commands/pr-to-main.md    - PR to Main skill

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.promotion-gate-cache"
CACHE_TTL_MINUTES=15  # Shorter TTL for production gate

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/gate-common.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

NO_CACHE=false
QUIET=false
JSON_OUTPUT=false
VERBOSE=false
DRY_RUN=false
BYPASS=false
CREATE_ISSUES=false
PR_NUMBER=""

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -70
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cache)       NO_CACHE=true; shift ;;
    --quiet)          QUIET=true; shift ;;
    --json)           JSON_OUTPUT=true; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --bypass)         BYPASS=true; shift ;;
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
  gate_check_cache "$CACHE_DIR" "main-gate" "$head_sha" "$CACHE_TTL_MINUTES" "$NO_CACHE"
}

write_cache() {
  local head_sha="$1"
  local result_json="$2"
  gate_write_cache "$CACHE_DIR" "main-gate" "$head_sha" "$result_json"
}

# ─── Gate 1: Test Suite (FULL) ────────────────────────────────────────────────

run_gate_tests() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running full test suite..."

  if [[ -f "$SCRIPT_DIR/test-runner.sh" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 300 "$SCRIPT_DIR/test-runner.sh" --full 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Full test suite failed with exit code $exit_code"
    else
      local test_count
      test_count=$(echo "$details" | grep -oE '[0-9]+ tests? (passed|ran)' | grep -oE '[0-9]+' | head -1 || echo "0")
      output="Full test suite passed ($test_count tests)"
    fi
  else
    status="fail"
    output="Test runner not found (scripts/test-runner.sh) - REQUIRED for production"
    details="Create test runner at scripts/test-runner.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Test suite (full)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 2: Lint / ShellCheck (STRICT) ───────────────────────────────────────

run_gate_lint() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running strict lint / ShellCheck..."

  local lint_script="$SCRIPT_DIR/ci/refactor-lint.sh"
  if [[ -f "$lint_script" && -x "$lint_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$lint_script" --scope changed --severity medium 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Lint check failed (exit code $exit_code) - ALL issues must be fixed for production"
    else
      output="Lint check passed (0 issues)"
    fi
  else
    status="fail"
    output="Lint script not found (scripts/ci/refactor-lint.sh) - REQUIRED for production"
    details="Create lint script or install shellcheck"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Lint / ShellCheck (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 3: Refactor Scan (MEDIUM+) ──────────────────────────────────────────

run_gate_refactor() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running refactor scan (medium+ severity)..."

  local refactor_script="$SCRIPT_DIR/ci/refactor-lint.sh"
  if [[ -f "$refactor_script" && -x "$refactor_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$refactor_script" --scope changed --severity medium 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Refactor scan found medium+ issues - ALL must be fixed for production"
    else
      output="Refactor scan passed (0 medium+ issues)"
    fi
  else
    status="fail"
    output="Refactor scanner not found - REQUIRED for production"
    details="Install refactor scanner or create scripts/ci/refactor-lint.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Refactor scan (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 4: Security Scan (STRICT) ───────────────────────────────────────────

run_gate_security() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running strict security scan..."

  local security_script="$SCRIPT_DIR/ci/sensitivity-scan.sh"
  if [[ -f "$security_script" && -x "$security_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$security_script" --verbose 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Security scan found findings - MUST be clean for production"
    else
      output="Security scan passed (0 findings)"
    fi
  else
    status="fail"
    output="Security scanner not found - REQUIRED for production"
    details="Create security scanner at scripts/ci/sensitivity-scan.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Security scan (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 4b: Dependency Audit (STRICT) ───────────────────────────────────────

run_gate_dependency_audit() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Running dependency audit (strict mode)..."

  local dep_audit_script="$SCRIPT_DIR/ci/dep-audit.sh"
  if [[ -f "$dep_audit_script" && -x "$dep_audit_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    # Strict mode: fail on ANY vulnerability (including medium/low)
    timeout 120 "$dep_audit_script" --full --strict 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    case $exit_code in
      0)
        status="pass"
        output="Dependency audit passed (no vulnerabilities found)"
        ;;
      1)
        status="fail"
        output="Dependency audit found vulnerabilities - MUST fix for production"
        ;;
      *)
        status="fail"
        output="Dependency audit error (exit code $exit_code) - BLOCKING for production"
        ;;
    esac
  else
    status="fail"
    output="Dependency audit script not found - REQUIRED for production"
    details="Install dependency audit: see scripts/ci/install-ci-tools.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Dependency audit (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 5: Repo Settings Drift (STRICT) ─────────────────────────────────────

run_gate_repo_settings() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking repo settings drift (strict)..."

  local settings_script="$SCRIPT_DIR/ci/validate-repo-settings.sh"
  if [[ -f "$settings_script" && -x "$settings_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$settings_script" --mode strict 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Repo settings drift detected - MUST be aligned for production"
    else
      output="Repo settings drift check passed (no drift)"
    fi
  else
    status="fail"
    output="Repo settings validator not found - REQUIRED for production"
    details="Create repo settings validator at scripts/ci/validate-repo-settings.sh"
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

# ─── Gate 6: Environment Tier (PRODUCTION) ────────────────────────────────────

run_gate_environment_tier() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating production tier compliance..."

  local tier_script="$SCRIPT_DIR/ci/validate-environment-tier.sh"
  if [[ -f "$tier_script" && -x "$tier_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 30 "$tier_script" prod 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Production tier violations found - MUST be compliant for production"
    else
      output="Production tier compliance passed"
    fi
  else
    status="fail"
    output="Environment tier validator not found - REQUIRED for production"
    details="Create environment tier validator at scripts/ci/validate-environment-tier.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Environment tier (prod)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 7: Repo Naming (BLOCKING FOR MAIN) ──────────────────────────────────

run_gate_repo_naming() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating repo naming convention (strict)..."

  local naming_script="$SCRIPT_DIR/ci/validate-repo-naming.sh"
  if [[ -f "$naming_script" && -x "$naming_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 15 "$naming_script" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Repo naming convention violation - MUST be fixed for production"
    else
      output="Repo naming convention valid"
    fi
  else
    status="fail"
    output="Repo naming validator not found - REQUIRED for production"
    details="Create repo naming validator at scripts/ci/validate-repo-naming.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Repo naming (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 8: Doc Freshness (BLOCKING FOR MAIN) ───────────────────────────────

run_gate_docs() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking documentation freshness (strict)..."

  local docs_script="$SCRIPT_DIR/scan-docs.sh"
  if [[ -f "$docs_script" && -x "$docs_script" ]]; then
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 90 "$docs_script" --changed-files-only --categories "obsolete,stale" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Stale/obsolete documentation found - MUST be updated for production"
    else
      output="Documentation freshness check passed"
    fi
  else
    status="fail"
    output="Documentation scanner not found - REQUIRED for production"
    details="Create documentation scanner at scripts/scan-docs.sh"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Doc freshness (strict)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 9: Changelog Exists ─────────────────────────────────────────────────

run_gate_changelog() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating changelog exists..."

  # Check for CHANGELOG.md in common locations
  local changelog_paths=(
    "$REPO_ROOT/CHANGELOG.md"
    "$REPO_ROOT/docs/CHANGELOG.md"
    "$REPO_ROOT/CHANGELOG.txt"
  )

  local changelog_found=false
  for path in "${changelog_paths[@]}"; do
    if [[ -f "$path" ]]; then
      changelog_found=true
      # Check if file is non-empty
      if [[ ! -s "$path" ]]; then
        status="fail"
        output="Changelog file exists but is empty: $path"
        details="Add release notes to changelog before promoting to production"
      else
        output="Changelog exists and is populated: $(basename "$path")"
      fi
      break
    fi
  done

  if [[ "$changelog_found" == "false" ]]; then
    status="fail"
    output="No changelog found (CHANGELOG.md or docs/CHANGELOG.md) - REQUIRED for production"
    details="Create CHANGELOG.md with release notes"
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Changelog exists" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 10: Version Tag Valid ───────────────────────────────────────────────

run_gate_version_tag() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating version tag..."

  # Get latest tag
  local latest_tag
  latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "")

  if [[ -z "$latest_tag" ]]; then
    status="fail"
    output="No version tags found - REQUIRED for production release"
    details="Create a version tag (e.g., git tag v1.0.0) before promoting to production"
  else
    # Check if tag matches semver pattern
    if echo "$latest_tag" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+'; then
      output="Version tag valid: $latest_tag"

      # Check if tag points to current HEAD or recent commit
      local tag_sha
      tag_sha=$(git rev-list -n 1 "$latest_tag" 2>/dev/null || echo "")
      local head_sha
      head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

      if [[ "$tag_sha" != "$head_sha" ]]; then
        # Check if tag is within last 10 commits
        local commits_since_tag
        commits_since_tag=$(git rev-list --count "${latest_tag}..HEAD" 2>/dev/null || echo "0")
        if [[ $commits_since_tag -gt 10 ]]; then
          status="warn"
          output="Version tag exists but is $commits_since_tag commits behind HEAD: $latest_tag"
          details="Consider creating a new tag for this release"
        else
          output="Version tag valid and recent: $latest_tag ($commits_since_tag commits behind)"
        fi
      fi
    else
      status="fail"
      output="Version tag does not match semver format: $latest_tag"
      details="Version tags must follow semver (e.g., v1.0.0, 2.1.3)"
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Version tag valid" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 11: Open PR Check (to qa) ───────────────────────────────────────────

run_gate_open_prs() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking for open PRs to qa..."

  local tmp_out; tmp_out=$(mktemp)
  local exit_code=0
  timeout 15 gh pr list --base qa --state open --json number,title 2>&1 > "$tmp_out" || exit_code=$?
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
      output="No open PRs to qa (0 open PRs)"
    else
      status="fail"
      output="Open PRs to qa found (${pr_count} open PRs) - MUST be merged before promoting to production"
      details=$(echo "$details" | jq -r '.[] | "#\(.number): \(.title)"' | head -5 || echo "$details")
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "Open PR check (qa)" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 12: CI Status on qa ─────────────────────────────────────────────────

run_gate_ci_status() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Checking CI status on qa branch..."

  # Get repo owner and name
  local repo_info
  repo_info=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

  if [[ -z "$repo_info" ]]; then
    status="fail"
    output="Unable to determine repository info - REQUIRED for production"
    details="Could not get repo info from gh cli"
  else
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 15 gh api "repos/${repo_info}/commits/qa/status" 2>&1 > "$tmp_out" || exit_code=$?
    details=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Failed to check CI status - REQUIRED for production"
    else
      local ci_state
      ci_state=$(echo "$details" | jq -r '.state // "unknown"' 2>/dev/null || echo "unknown")

      case "$ci_state" in
        success)
          status="pass"
          output="CI status on qa: passing (all checks passing)"
          ;;
        pending)
          status="fail"
          output="CI status on qa: pending - MUST wait for checks to complete before production"
          ;;
        failure|error)
          status="fail"
          output="CI status on qa: failing - MUST be fixed before promoting to production"
          ;;
        *)
          status="fail"
          output="CI status on qa: unknown - cannot promote without confirmed CI pass"
          ;;
      esac
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "CI status on qa" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking true \
    '{name: $name, status: $status, output: $output, details: $details, duration_seconds: $duration, blocking: $blocking}'
}

# ─── Gate 13: QA Sign-off (dev→qa PR merged with approval) ──────────────────

run_gate_qa_signoff() {
  local status="pass"
  local output=""
  local details=""
  local duration=0
  local start_time; start_time=$(date +%s)

  log_step "Validating QA sign-off (dev→qa PR merged with approval)..."

  # Get repo info
  local repo_info
  repo_info=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

  if [[ -z "$repo_info" ]]; then
    status="fail"
    output="Unable to determine repository info"
    details="Could not get repo info from gh cli"
  else
    # Find the most recent merged PR from dev→qa
    local tmp_out; tmp_out=$(mktemp)
    local exit_code=0
    timeout 15 gh pr list --base qa --head dev --state merged --limit 1 \
      --json number,title,mergedAt,reviews,mergedBy 2>&1 > "$tmp_out" || exit_code=$?
    local pr_data
    pr_data=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -ne 0 ]]; then
      status="fail"
      output="Failed to query merged QA PRs (exit code $exit_code)"
      details="$pr_data"
    else
      local pr_count
      pr_count=$(echo "$pr_data" | jq '. | length' 2>/dev/null || echo "0")

      if [[ "$pr_count" -eq 0 ]]; then
        status="fail"
        output="No merged dev→qa PR found - QA promotion must happen before main promotion"
        details="Run /release:promote-qa first, then merge the QA PR after validation"
      else
        local pr_number pr_title merged_at review_count
        pr_number=$(echo "$pr_data" | jq -r '.[0].number')
        pr_title=$(echo "$pr_data" | jq -r '.[0].title')
        merged_at=$(echo "$pr_data" | jq -r '.[0].mergedAt')

        # Check for approvals on the merged PR
        local approval_count
        approval_count=$(echo "$pr_data" | jq '[.[0].reviews[]? | select(.state == "APPROVED")] | length' 2>/dev/null || echo "0")

        if [[ "$approval_count" -gt 0 ]]; then
          status="pass"
          output="QA sign-off verified: PR #${pr_number} merged with ${approval_count} approval(s)"
          details="PR: #${pr_number} - ${pr_title}\nMerged: ${merged_at}\nApprovals: ${approval_count}"
        else
          status="fail"
          output="QA PR #${pr_number} was merged WITHOUT approval - QA sign-off required"
          details="PR #${pr_number} (${pr_title}) was merged at ${merged_at} but has 0 approvals.\nAt least 1 approval is required to confirm QA validation was completed.\nReview the QA checklist on the PR and approve before promoting to main."
        fi
      fi
    fi
  fi

  local end_time; end_time=$(date +%s)
  duration=$((end_time - start_time))

  jq -n \
    --arg name "QA sign-off (dev→qa merged+approved)" \
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
  echo -e "${BOLD}║  PRE-PROMOTION GATE: qa → main (PRODUCTION)             ║${NC}"
  echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
  echo -e "${BOLD}║  ${RED}STRICT MODE: ALL WARNINGS ARE BLOCKING${NC}                  ${BOLD}║${NC}"
  echo -e "${BOLD}║                                                          ║${NC}"

  # Print each check result
  echo "$report" | jq -r '.checks[] | "\(.name)|\(.status)|\(.output)"' | \
  while IFS='|' read -r name status output; do
    local icon color
    case "$status" in
      pass) icon="PASS"; color="$GREEN" ;;
      fail) icon="FAIL"; color="$RED" ;;
      warn) icon="WARN"; color="$YELLOW" ;;
      skip) icon="SKIP"; color="$CYAN" ;;
      *)    icon="????"; color="$NC" ;;
    esac

    # Format output to fit within box
    local formatted_output="${output:0:26}"
    printf "${BOLD}║${NC}  %b[%s]%b  %-28s %-26s${BOLD}║${NC}\n" "$color" "$icon" "$NC" "$name" "$formatted_output"
  done

  echo -e "${BOLD}║                                                          ║${NC}"

  # Print result
  case "$gate_status" in
    PASS)
      echo -e "${BOLD}║${NC}  ${GREEN}RESULT: PASS - PRODUCTION READY${NC}                         ${BOLD}║${NC}"
      echo -e "${BOLD}║${NC}  Promotion to main/production is ${GREEN}CLEARED${NC}                 ${BOLD}║${NC}"
      ;;
    FAIL)
      echo -e "${BOLD}║${NC}  ${RED}RESULT: FAIL - NOT PRODUCTION READY${NC}                     ${BOLD}║${NC}"
      echo -e "${BOLD}║${NC}  Promotion to main/production is ${RED}BLOCKED${NC}                 ${BOLD}║${NC}"
      ;;
  esac

  echo -e "${BOLD}║                                                          ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Print detailed failures
  local has_issues=false
  while IFS= read -r check_json; do
    local check_name check_status check_details
    check_name=$(echo "$check_json" | jq -r '.name')
    check_status=$(echo "$check_json" | jq -r '.status')
    check_details=$(echo "$check_json" | jq -r '.details // ""')

    if [[ "$check_status" == "fail" || "$check_status" == "warn" ]]; then
      has_issues=true
      echo -e "${RED}[${check_name}] FAILED (BLOCKING)${NC}"

      if [[ -n "$check_details" && "$check_details" != "null" ]]; then
        echo "$check_details" | head -10 | sed 's/^/  /'
      fi
      echo ""
    fi
  done < <(echo "$report" | jq -c '.checks[]')

  if [[ "$has_issues" == "false" ]]; then
    echo -e "${GREEN}✓ All production gates passed. Ready to promote qa → main.${NC}"
    echo ""
  fi

  echo "Total gate execution time: ${duration}s"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  # Emergency bypass check
  if [[ "$BYPASS" == "true" ]]; then
    log_warn "EMERGENCY BYPASS requested - skipping all production gates"
    log_warn "This should ONLY be used for critical hotfixes"
    log_warn "Ensure justification is documented in the PR"
    if [[ "$JSON_OUTPUT" == "true" ]]; then
      jq -n '{gate_status: "BYPASS", gate_summary: "Emergency bypass - gates skipped", checks: []}'
    else
      echo -e "${YELLOW}⚠ Production gates bypassed (--bypass flag)${NC}"
    fi
    exit 0
  fi

  # Get HEAD SHA for caching
  local head_sha
  head_sha=$(gate_get_head_sha)

  log_verbose "Running pre-promotion gate for qa → main (HEAD: ${head_sha:0:12})"

  # Check cache first
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    if cached=$(check_cache "$head_sha" 2>/dev/null); then
      echo "$cached"
      gate_status=$(echo "$cached" | jq -r '.gate_status')
      case "$gate_status" in
        PASS) exit 0 ;;
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
        FAIL) exit 1 ;;
        *) exit 0 ;;
      esac
    fi
  fi

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN - Pre-promotion gate for PRODUCTION would run the following checks:"
    echo "  1. Test suite (FULL)"
    echo "  2. Lint / ShellCheck (STRICT)"
    echo "  3. Refactor scan (medium+ severity)"
    echo "  4. Security scan (STRICT)"
    echo "  5. Repo settings drift (STRICT)"
    echo "  6. Environment tier compliance (production)"
    echo "  7. Repo naming validation (BLOCKING)"
    echo "  8. Doc freshness (BLOCKING)"
    echo "  9. Changelog exists (REQUIRED)"
    echo "  10. Version tag valid (REQUIRED)"
    echo "  11. Open PR check (to qa)"
    echo "  12. CI status on qa (STRICT)"
    echo "  13. QA sign-off (dev→qa PR merged with approval)"
    echo ""
    echo "ALL checks are BLOCKING for production promotion"
    echo "Estimated time: ~3-4 minutes"
    exit 0
  fi

  local pipeline_start
  pipeline_start=$(date +%s)

  if [[ "$QUIET" != "true" && "$JSON_OUTPUT" != "true" ]]; then
    echo ""
    echo -e "${BOLD}${RED}Pre-Promotion Quality Gate: qa → main (PRODUCTION)${NC}"
    echo -e "${RED}STRICT MODE: All warnings are blocking${NC}"
    echo -e "HEAD SHA: ${head_sha:0:12}"
    echo "────────────────────────────────────────────────"
    echo ""
  fi

  # Run all gates (ALL BLOCKING)
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
  gate_results+=("$(run_gate_changelog)")
  gate_results+=("$(run_gate_version_tag)")
  gate_results+=("$(run_gate_open_prs)")
  gate_results+=("$(run_gate_ci_status)")
  gate_results+=("$(run_gate_qa_signoff)")

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

  # Determine overall gate status (ALL BLOCKING - no warnings allowed)
  local gate_status gate_summary exit_code
  # For production, warnings are treated as failures
  gate_status=$(gate_determine_status "$checks_json" true)

  # Custom summary for production gates
  if [[ "$gate_status" == "FAIL" ]]; then
    local fail_count
    fail_count=$(echo "$checks_json" | jq '[.[] | select(.status == "fail" or .status == "warn")] | length')
    gate_summary="$fail_count check(s) failed - production promotion is BLOCKED"
    exit_code=1
  else
    gate_summary="All production gates passed - promotion is cleared"
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
      promotion_type: "qa-to-main",
      strict_mode: true,
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
    gate_create_issues_from_report "pre-promote-main-gate" "$report" "$PR_NUMBER" "false"
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
