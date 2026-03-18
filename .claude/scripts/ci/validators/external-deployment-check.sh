#!/usr/bin/env bash
# ============================================================
# Script: external-deployment-check.sh
# Purpose: External deployment readiness check for public repos
#
# Validates that a public repository is safe for external release by checking:
#   1. No sensitive data leakage (secrets, credentials, internal URLs)
#   2. Public-readiness (README, LICENSE, CONTRIBUTING.md)
#   3. Dependency safety (no private registries)
#   4. Code safety (no debug artifacts, test fixtures with real data)
#
# This gate is ONLY run for public repos during qa → main promotion.
# Private repos skip this check entirely.
#
# Usage:
#   ./scripts/ci/validators/external-deployment-check.sh [OPTIONS]
#
# Options:
#   --repo-profile FILE  Path to repo-profile.yaml (default: config/repo-profile.yaml)
#   --output FILE        Write findings JSON to FILE
#   --dry-run            Show what would be checked
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  All checks passed (ready for external deployment)
#   1  One or more checks failed (blocks qa → main promotion)
#   2  Error (missing config, invalid options, repo is private)
#
# Integration:
#   - Called by /release:promote-main for public repos only
#   - Called by /release:validate-qa for public repos only
#   - Configured in config/repo-profile.yaml
#
# Related: Issue #1129 (unified SDLC for public/private repos)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO_PROFILE="${REPO_PROFILE:-config/repo-profile.yaml}"
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-profile) REPO_PROFILE="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --help|-h)      show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq is required for YAML parsing" >&2
  echo "  Install: brew install yq (macOS) or snap install yq (Linux)" >&2
  exit 2
fi

if [[ ! -f "$REPO_ROOT/$REPO_PROFILE" ]]; then
  echo -e "${RED}[ERROR]${NC} Repo profile not found: $REPO_PROFILE" >&2
  echo "  Run /repo-init to create repo profile" >&2
  exit 2
fi

# Check if repo is configured as public (external)
VISIBILITY=$(yq eval '.visibility.type' "$REPO_ROOT/$REPO_PROFILE" 2>/dev/null || echo "unknown")

if [[ "$VISIBILITY" != "public" ]]; then
  echo -e "${BLUE}[INFO]${NC} External deployment check skipped (repo is not public)"
  echo "  Visibility: $VISIBILITY"
  echo "  Only external repos require external deployment validation"
  exit 0
fi

# ─── Check Functions ──────────────────────────────────────────────────────────

CHECKS_PASSED=0
CHECKS_FAILED=0
FINDINGS_FILE=$(mktemp)

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $*"
  CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $*"
  echo "$*" >> "$FINDINGS_FILE"
  CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

# ─── Category 1: Sensitive Data Leakage ──────────────────────────────────────

check_sensitive_data() {
  log_info "Category 1: Checking for sensitive data leakage..."
  echo ""

  local category_failures=0

  # Use existing sensitivity-scan.sh script
  if [[ -f "$SCRIPT_DIR/sensitivity-scan.sh" ]]; then
    if "$SCRIPT_DIR/sensitivity-scan.sh" --repo-profile "$REPO_PROFILE" >/dev/null 2>&1; then
      log_pass "No hardcoded secrets, API keys, or credentials detected"
      log_pass "No internal URLs, IPs, or infrastructure references found"
      log_pass "No private registry references or internal package names"
    else
      log_fail "Sensitive data detected (run: ./scripts/ci/validators/sensitivity-scan.sh)"
      category_failures=1
    fi
  else
    log_warn "sensitivity-scan.sh not found, skipping detailed scan"
  fi

  # Check for .env files (not examples/templates)
  local env_files
  env_files=$(find "$REPO_ROOT" -name ".env" -o -name ".env.local" -o -name ".env.production" 2>/dev/null | grep -v "example\|template\|sample" || true)

  if [[ -n "$env_files" ]]; then
    log_fail "Real .env files found (should use .env.example only):"
    echo "$env_files" | while read -r file; do
      echo "    - ${file#$REPO_ROOT/}"
    done >> "$FINDINGS_FILE"
    category_failures=1
  else
    log_pass "No real .env files committed"
  fi

  echo ""
  return $category_failures
}

# ─── Category 2: Public-Readiness ────────────────────────────────────────────

check_public_readiness() {
  log_info "Category 2: Checking public-readiness..."
  echo ""

  local category_failures=0

  # Check README.md exists and is meaningful
  if [[ ! -f "$REPO_ROOT/README.md" ]]; then
    log_fail "README.md is missing"
    category_failures=1
  else
    # Check if README is not just a stub (more than 100 characters)
    local readme_size
    readme_size=$(wc -c < "$REPO_ROOT/README.md")
    if [[ "$readme_size" -lt 100 ]]; then
      log_fail "README.md exists but appears to be a stub (less than 100 characters)"
      category_failures=1
    else
      log_pass "README.md exists and is meaningful"
    fi
  fi

  # Check LICENSE file exists
  if [[ ! -f "$REPO_ROOT/LICENSE" ]]; then
    log_fail "LICENSE file is missing"
    category_failures=1
  else
    log_pass "LICENSE file exists"
  fi

  # Check CONTRIBUTING.md (warning if missing for public repos)
  if [[ ! -f "$REPO_ROOT/CONTRIBUTING.md" ]]; then
    log_warn "CONTRIBUTING.md is missing (recommended for public repos)"
    # Not a failure, just a warning
  else
    log_pass "CONTRIBUTING.md exists"
  fi

  # Check for internal-only documentation references
  local internal_refs
  internal_refs=$(git grep -l "internal\\.confluence\\.\\|internal\\.jira\\.\\|source-.*github\\.com" -- "*.md" 2>/dev/null || true)

  if [[ -n "$internal_refs" ]]; then
    log_fail "Internal-only documentation references found in:"
    echo "$internal_refs" | while read -r file; do
      echo "    - $file"
    done >> "$FINDINGS_FILE"
    category_failures=1
  else
    log_pass "No internal-only documentation references"
  fi

  # Check for references to private repos
  local private_repo_refs
  private_repo_refs=$(git grep -l "github\\.com/[^/]*/source-" -- "*.md" "*.json" "*.yaml" 2>/dev/null || true)

  if [[ -n "$private_repo_refs" ]]; then
    log_fail "References to private repos (source-*) found in:"
    echo "$private_repo_refs" | while read -r file; do
      echo "    - $file"
    done >> "$FINDINGS_FILE"
    category_failures=1
  else
    log_pass "No references to private repos"
  fi

  echo ""
  return $category_failures
}

# ─── Category 3: Dependency Safety ───────────────────────────────────────────

check_dependency_safety() {
  log_info "Category 3: Checking dependency safety..."
  echo ""

  local category_failures=0

  # Check package.json for private registries (if exists)
  if [[ -f "$REPO_ROOT/package.json" ]]; then
    if grep -q "registry.*internal\|registry.*private" "$REPO_ROOT/package.json" 2>/dev/null; then
      log_fail "Private/internal registry references found in package.json"
      category_failures=1
    else
      log_pass "No private registry references in package.json"
    fi

    # Check for scoped packages pointing to private registries
    if grep -qE "@[^/]+/.*:registry.*internal\|@[^/]+/.*:registry.*private" "$REPO_ROOT/package.json" 2>/dev/null; then
      log_fail "Scoped packages with private registry found in package.json"
      category_failures=1
    fi
  fi

  # Check requirements.txt for private registries (if exists)
  if [[ -f "$REPO_ROOT/requirements.txt" ]]; then
    if grep -q "extra-index-url.*internal\|extra-index-url.*private" "$REPO_ROOT/requirements.txt" 2>/dev/null; then
      log_fail "Private registry references found in requirements.txt"
      category_failures=1
    else
      log_pass "No private registry references in requirements.txt"
    fi
  fi

  # Check .npmrc for private registries (if exists)
  if [[ -f "$REPO_ROOT/.npmrc" ]]; then
    if grep -q "registry.*internal\|registry.*private" "$REPO_ROOT/.npmrc" 2>/dev/null; then
      log_fail "Private registry configuration found in .npmrc"
      category_failures=1
    fi
  fi

  # Check go.mod for private module references (if exists)
  if [[ -f "$REPO_ROOT/go.mod" ]]; then
    if grep -qE "require.*internal/\|replace.*internal/" "$REPO_ROOT/go.mod" 2>/dev/null; then
      log_fail "Private/internal module references found in go.mod"
      category_failures=1
    fi
  fi

  if [[ $category_failures -eq 0 ]]; then
    log_pass "All dependencies appear to be publicly available"
  fi

  echo ""
  return $category_failures
}

# ─── Category 4: Code Safety ─────────────────────────────────────────────────

check_code_safety() {
  log_info "Category 4: Checking code safety..."
  echo ""

  local category_failures=0

  # Check for excessive debug artifacts (console.log, print statements)
  local debug_count
  debug_count=$(git grep -c "console\\.log\|print(" -- "*.js" "*.ts" "*.py" 2>/dev/null | awk -F: '{sum+=$2} END {print sum}' || echo "0")

  if [[ "$debug_count" -gt 20 ]]; then
    log_warn "High number of debug statements found ($debug_count). Consider removing before release."
    # Not a failure, just a warning
  else
    log_pass "Reasonable number of debug statements ($debug_count)"
  fi

  # Check for TODO hacks
  local todo_hacks
  todo_hacks=$(git grep -n "TODO.*hack\|FIXME.*hack\|XXX.*hack" -- "*.js" "*.ts" "*.py" "*.sh" 2>/dev/null || true)

  if [[ -n "$todo_hacks" ]]; then
    log_fail "TODO hacks found in code:"
    echo "$todo_hacks" | head -10 | while read -r line; do
      echo "    - $line"
    done >> "$FINDINGS_FILE"
    category_failures=1
  else
    log_pass "No TODO hacks found"
  fi

  # Check for test fixtures with real data
  local test_fixtures
  test_fixtures=$(find "$REPO_ROOT" -path "*/test/*" -o -path "*/tests/*" | xargs grep -l "@.*\\.com\|api[_-]key.*=.*[A-Za-z0-9]\{20,\}" 2>/dev/null || true)

  if [[ -n "$test_fixtures" ]]; then
    log_fail "Test fixtures with potentially real data found:"
    echo "$test_fixtures" | while read -r file; do
      echo "    - ${file#$REPO_ROOT/}"
    done >> "$FINDINGS_FILE"
    category_failures=1
  else
    log_pass "No test fixtures with real data detected"
  fi

  # Check for large commented-out code blocks
  local commented_blocks
  commented_blocks=$(git grep -c "^[[:space:]]*#.*\|^[[:space:]]*//" -- "*.js" "*.ts" "*.py" "*.sh" 2>/dev/null | awk -F: '$2 > 50 {print $1": "$2" lines"}' || true)

  if [[ -n "$commented_blocks" ]]; then
    log_warn "Files with large commented-out code blocks:"
    echo "$commented_blocks" | while read -r file; do
      echo "    - $file"
    done
    # Not a failure, just a warning
  else
    log_pass "No excessive commented-out code blocks"
  fi

  echo ""
  return $category_failures
}

# ─── Main Execution ───────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        External Deployment Readiness Check                ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "Repository:   ${YELLOW}$(basename "$REPO_ROOT")${NC}"
  echo -e "Visibility:   ${YELLOW}$VISIBILITY${NC}"
  echo -e "Profile:      $REPO_PROFILE"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would check for external deployment readiness:"
    echo "  1. Sensitive data leakage (secrets, credentials, internal URLs)"
    echo "  2. Public-readiness (README, LICENSE, documentation)"
    echo "  3. Dependency safety (no private registries)"
    echo "  4. Code safety (no debug artifacts, test fixtures)"
    exit 0
  fi

  # Run all checks
  local total_failures=0

  check_sensitive_data || total_failures=$((total_failures + $?))
  check_public_readiness || total_failures=$((total_failures + $?))
  check_dependency_safety || total_failures=$((total_failures + $?))
  check_code_safety || total_failures=$((total_failures + $?))

  echo "────────────────────────────────────────────────────────────"
  echo ""

  # Report results
  if [[ "$total_failures" -eq 0 ]]; then
    echo -e "${GREEN}✓ External deployment check PASSED${NC}"
    echo ""
    echo "  Summary:"
    echo "    - Checks passed: $CHECKS_PASSED"
    echo "    - Checks failed: $CHECKS_FAILED"
    echo ""
    echo "  Repository is ready for external deployment (qa → main promotion)"
    echo ""
    exit 0
  else
    echo -e "${RED}✗ External deployment check FAILED${NC}"
    echo ""
    echo "  Summary:"
    echo "    - Checks passed: $CHECKS_PASSED"
    echo "    - Checks failed: $CHECKS_FAILED"
    echo ""
    echo -e "${RED}Action required:${NC}"
    echo "  1. Review the failures listed above"
    echo "  2. Remove sensitive data, fix missing documentation, resolve dependency issues"
    echo "  3. Re-run this check to verify: ./scripts/ci/validators/external-deployment-check.sh"
    echo ""
    echo "  qa → main promotion is BLOCKED until all checks pass."
    echo ""

    # Save detailed findings if output file specified
    if [[ -n "$OUTPUT_FILE" ]]; then
      {
        echo "External Deployment Check Failures:"
        echo ""
        cat "$FINDINGS_FILE"
      } > "$OUTPUT_FILE"
      echo "  Detailed findings saved to: $OUTPUT_FILE"
      echo ""
    fi

    rm -f "$FINDINGS_FILE"
    exit 1
  fi
}

trap 'rm -f "$FINDINGS_FILE"' EXIT

main "$@"
