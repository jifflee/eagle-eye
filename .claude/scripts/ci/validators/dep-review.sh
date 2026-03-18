#!/usr/bin/env bash
# ============================================================
# Script: dep-review.sh
# Purpose: PR-level dependency review - detect new vulnerabilities introduced by PR
#
# Compares dependency audit results between PR branch and base branch
# to identify NEW vulnerabilities introduced by the PR. Blocks PR merge
# if new critical/high vulnerabilities are added.
#
# Usage:
#   ./scripts/ci/dep-review.sh [OPTIONS]
#
# Options:
#   --base BRANCH       Base branch to compare against (default: dev)
#   --head BRANCH       Head branch to review (default: current branch)
#   --blocking-level    Severity level to block on: critical|high|medium|low (default: high)
#   --output FILE       Write JSON diff report to FILE (default: .dep-audit/dep-review.json)
#   --verbose           Show detailed output
#   --help              Show this help
#
# Exit codes:
#   0 - No new critical/high vulnerabilities introduced
#   1 - New critical/high vulnerabilities found (blocking)
#   2 - Tool error (missing dependencies, scan failed)
#
# How it works:
#   1. Stash current changes (if any)
#   2. Run dep-audit.sh on base branch → base-report.json
#   3. Checkout head/PR branch
#   4. Run dep-audit.sh on head branch → head-report.json
#   5. Diff the two reports to find NEW vulnerabilities
#   6. Block if new critical/high vulnerabilities found
#   7. Restore original branch
#
# Integration:
#   - Called by pr-validation-gate.sh for PR merge blocking
#   - Results written to .dep-audit/dep-review.json
#
# Related:
#   - scripts/ci/dep-audit.sh - Base dependency scanner
#   - scripts/pr/pr-validation-gate.sh - PR validation gate
#   - Issue #968 - Add local CI dependency scanning
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEP_AUDIT_SCRIPT="$SCRIPT_DIR/dep-audit.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

BASE_BRANCH="dev"
HEAD_BRANCH=""
BLOCKING_LEVEL="high"
OUTPUT_FILE="$REPO_ROOT/.dep-audit/dep-review.json"
VERBOSE=false

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
    --base)            BASE_BRANCH="$2"; shift 2 ;;
    --head)            HEAD_BRANCH="$2"; shift 2 ;;
    --blocking-level)  BLOCKING_LEVEL="$2"; shift 2 ;;
    --output)          OUTPUT_FILE="$2"; shift 2 ;;
    --verbose)         VERBOSE=true; shift ;;
    --help|-h)         show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_step() {
  echo -e "${BLUE}[STEP]${NC} $*"
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_prerequisites() {
  if [[ ! -f "$DEP_AUDIT_SCRIPT" ]]; then
    log_error "dep-audit.sh not found at: $DEP_AUDIT_SCRIPT"
    exit 2
  fi

  if [[ ! -x "$DEP_AUDIT_SCRIPT" ]]; then
    log_error "dep-audit.sh is not executable: $DEP_AUDIT_SCRIPT"
    exit 2
  fi

  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 2
  fi

  if ! command -v git &>/dev/null; then
    log_error "git is required but not installed"
    exit 2
  fi
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────

get_current_branch() {
  git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD"
}

branch_exists() {
  local branch="$1"
  git rev-parse --verify "$branch" &>/dev/null
}

# ─── Dependency Diff ──────────────────────────────────────────────────────────

extract_vulnerabilities() {
  local report_file="$1"
  local output_file="$2"

  if [[ ! -f "$report_file" ]]; then
    echo '[]' > "$output_file"
    return
  fi

  # Extract vulnerabilities from npm-audit.json
  local npm_vulns='[]'
  if [[ -f "$REPO_ROOT/.dep-audit/npm-audit.json" ]]; then
    npm_vulns=$(jq '[.vulnerabilities | to_entries | .[] | {package: .key, severity: .value.severity, cve: (.value.via[0].cve // .value.via[0].title // "Unknown"), source: "npm"}]' "$REPO_ROOT/.dep-audit/npm-audit.json" 2>/dev/null || echo '[]')
  fi

  # Extract vulnerabilities from pip-audit.json
  local pip_vulns='[]'
  if [[ -f "$REPO_ROOT/.dep-audit/pip-audit.json" ]]; then
    pip_vulns=$(jq '[.dependencies[]? | .vulnerabilities[]? | {package: .package, severity: .severity, cve: .id, source: "pip-audit"}]' "$REPO_ROOT/.dep-audit/pip-audit.json" 2>/dev/null || echo '[]')
  fi

  # Extract vulnerabilities from safety.json
  local safety_vulns='[]'
  if [[ -f "$REPO_ROOT/.dep-audit/safety.json" ]]; then
    safety_vulns=$(jq '[.[]? | {package: .package, severity: "high", cve: .advisory, source: "safety"}]' "$REPO_ROOT/.dep-audit/safety.json" 2>/dev/null || echo '[]')
  fi

  # Combine all vulnerabilities
  jq -n --argjson npm "$npm_vulns" --argjson pip "$pip_vulns" --argjson safety "$safety_vulns" \
    '$npm + $pip + $safety' > "$output_file"
}

compare_vulnerabilities() {
  local base_vulns="$1"
  local head_vulns="$2"
  local new_vulns="$3"

  # Find vulnerabilities in head that are not in base
  jq -n \
    --slurpfile base "$base_vulns" \
    --slurpfile head "$head_vulns" \
    '($head[0] // []) - ($base[0] // [])' > "$new_vulns"
}

count_severity() {
  local vulns_file="$1"
  local severity="$2"

  jq --arg sev "$severity" '[.[] | select(.severity | ascii_downcase == ($sev | ascii_downcase))] | length' "$vulns_file" 2>/dev/null || echo "0"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites

  # Detect head branch if not specified
  if [[ -z "$HEAD_BRANCH" ]]; then
    HEAD_BRANCH=$(get_current_branch)
  fi

  log_info "Dependency Review: $BASE_BRANCH → $HEAD_BRANCH (blocking: $BLOCKING_LEVEL+)"

  # Verify branches exist
  if ! branch_exists "$BASE_BRANCH"; then
    log_error "Base branch not found: $BASE_BRANCH"
    exit 2
  fi

  cd "$REPO_ROOT"

  # Save current branch
  local original_branch
  original_branch=$(get_current_branch)
  local original_commit
  original_commit=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  log_verbose "Original branch: $original_branch at $original_commit"

  # Temporary files
  local base_report; base_report=$(mktemp)
  local head_report; head_report=$(mktemp)
  local new_vulns; new_vulns=$(mktemp)

  # Cleanup function
  cleanup() {
    log_verbose "Cleaning up temporary files..."
    rm -f "$base_report" "$head_report" "$new_vulns"

    # Restore original branch if we moved
    if [[ "$(get_current_branch)" != "$original_branch" ]]; then
      log_verbose "Restoring original branch: $original_branch"
      git checkout "$original_branch" 2>/dev/null || git checkout "$original_commit" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  # Step 1: Scan base branch
  log_step "Scanning base branch: $BASE_BRANCH"
  git checkout "$BASE_BRANCH" &>/dev/null

  # Run dep-audit on base branch (ignore exit code, we just want the reports)
  "$DEP_AUDIT_SCRIPT" --full --format json &>/dev/null || true

  # Extract vulnerabilities from base
  extract_vulnerabilities "$REPO_ROOT/.dep-audit/npm-audit.json" "$base_report"
  local base_count
  base_count=$(jq 'length' "$base_report")
  log_verbose "Base branch vulnerabilities: $base_count"

  # Step 2: Scan head branch
  log_step "Scanning head branch: $HEAD_BRANCH"
  git checkout "$HEAD_BRANCH" &>/dev/null

  # Run dep-audit on head branch (ignore exit code, we just want the reports)
  "$DEP_AUDIT_SCRIPT" --full --format json &>/dev/null || true

  # Extract vulnerabilities from head
  extract_vulnerabilities "$REPO_ROOT/.dep-audit/npm-audit.json" "$head_report"
  local head_count
  head_count=$(jq 'length' "$head_report")
  log_verbose "Head branch vulnerabilities: $head_count"

  # Step 3: Compare and find new vulnerabilities
  log_step "Comparing vulnerability reports..."
  compare_vulnerabilities "$base_report" "$head_report" "$new_vulns"

  local new_count
  new_count=$(jq 'length' "$new_vulns")

  # Step 4: Count by severity
  local new_critical new_high new_medium new_low
  new_critical=$(count_severity "$new_vulns" "critical")
  new_high=$(count_severity "$new_vulns" "high")
  new_medium=$(count_severity "$new_vulns" "medium")
  new_low=$(count_severity "$new_vulns" "low")

  log_verbose "New vulnerabilities: critical=$new_critical, high=$new_high, medium=$new_medium, low=$new_low"

  # Step 5: Generate report
  mkdir -p "$(dirname "$OUTPUT_FILE")"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -n \
    --arg base "$BASE_BRANCH" \
    --arg head "$HEAD_BRANCH" \
    --arg timestamp "$timestamp" \
    --argjson base_count "$base_count" \
    --argjson head_count "$head_count" \
    --argjson new_count "$new_count" \
    --argjson new_critical "$new_critical" \
    --argjson new_high "$new_high" \
    --argjson new_medium "$new_medium" \
    --argjson new_low "$new_low" \
    --slurpfile new_vulns "$new_vulns" \
    '{
      timestamp: $timestamp,
      base_branch: $base,
      head_branch: $head,
      base_vulnerabilities: $base_count,
      head_vulnerabilities: $head_count,
      new_vulnerabilities: {
        total: $new_count,
        critical: $new_critical,
        high: $new_high,
        medium: $new_medium,
        low: $new_low
      },
      new_vulnerabilities_list: $new_vulns[0]
    }' > "$OUTPUT_FILE"

  # Step 6: Print summary
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Dependency Review Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Base branch:  $BASE_BRANCH ($base_count vulnerabilities)"
  echo "  Head branch:  $HEAD_BRANCH ($head_count vulnerabilities)"
  echo ""
  echo "  New vulnerabilities introduced by this PR:"
  printf "    %-12s: %d\n" "Critical" "$new_critical"
  printf "    %-12s: %d\n" "High" "$new_high"
  printf "    %-12s: %d\n" "Medium" "$new_medium"
  printf "    %-12s: %d\n" "Low" "$new_low"
  echo ""

  # Print new vulnerabilities if any
  if [[ $new_count -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}New Vulnerabilities:${NC}"
    echo ""
    jq -r '.[] | "  • \(.package) (\(.severity)): \(.cve) [source: \(.source)]"' "$new_vulns" | head -10
    echo ""
    if [[ $new_count -gt 10 ]]; then
      echo "  (showing first 10 of $new_count new vulnerabilities)"
      echo ""
    fi
  fi

  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Step 7: Determine exit code based on blocking level
  local should_block=false

  case "$BLOCKING_LEVEL" in
    critical)
      [[ $new_critical -gt 0 ]] && should_block=true
      ;;
    high)
      [[ $new_critical -gt 0 || $new_high -gt 0 ]] && should_block=true
      ;;
    medium)
      [[ $new_critical -gt 0 || $new_high -gt 0 || $new_medium -gt 0 ]] && should_block=true
      ;;
    low)
      [[ $new_count -gt 0 ]] && should_block=true
      ;;
  esac

  if [[ "$should_block" == "true" ]]; then
    log_error "PR introduces new $BLOCKING_LEVEL+ vulnerabilities - BLOCKING merge"
    log_error "Review report: $OUTPUT_FILE"
    exit 1
  else
    log_info "No new $BLOCKING_LEVEL+ vulnerabilities introduced - PASS"
    log_info "Report saved: $OUTPUT_FILE"
    exit 0
  fi
}

main "$@"
