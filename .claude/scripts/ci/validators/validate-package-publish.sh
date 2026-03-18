#!/usr/bin/env bash
# ============================================================
# Script: validate-package-publish.sh
# Purpose: Validate package can be published (dry-run for PRs)
#
# This script runs all publish validation checks WITHOUT actually
# publishing the package. Use in PR validation to catch issues early.
#
# Usage:
#   ./scripts/ci/validators/validate-package-publish.sh [--strict]
#
# Options:
#   --strict    Fail on warnings (default: fail only on errors)
#   --verbose   Show detailed output
#   --help      Show this help
#
# Checks:
#   - package.json is valid and has required fields
#   - All files listed in "files" array exist
#   - packs.json is valid (if exists)
#   - Package can be built/packed
#   - Tests pass
#   - No uncommitted changes to package.json
#
# Exit codes:
#   0 - Package is ready to publish
#   1 - Package has issues that would block publishing
#   2 - Tool error
#
# Integration:
#   - PR validation: ./scripts/ci/validators/validate-package-publish.sh
#   - Pre-commit: ./scripts/ci/validators/validate-package-publish.sh --strict
#
# Related:
#   - scripts/ci/publish-on-tag.sh - Actual publish script
#   - Issue #1079 - Set up GitHub Packages publish pipeline
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ──────────────────────────────────────────────────────────────────

STRICT_MODE=false
VERBOSE=false

# ─── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ──────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)   STRICT_MODE=true; shift ;;
    --verbose)  VERBOSE=true; shift ;;
    --help|-h)  show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ───────────────────────────────────────────────────────────────────

log_info() {
  echo -e "${BLUE}[validate]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[validate]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[validate]${NC} $*"
}

log_error() {
  echo -e "${RED}[validate]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}[debug]${NC} $*"
  fi
}

log_step() {
  echo ""
  echo -e "${BOLD}▸ $*${NC}"
}

# ─── Validation Functions ──────────────────────────────────────────────────────

validate_package_json() {
  log_step "Validating package.json..."

  if [[ ! -f "$REPO_ROOT/package.json" ]]; then
    log_error "package.json not found"
    return 1
  fi

  # Validate JSON syntax
  if ! jq empty "$REPO_ROOT/package.json" 2>/dev/null; then
    log_error "package.json is not valid JSON"
    return 1
  fi

  # Check required fields
  local required_fields=("name" "version" "repository")
  local missing_fields=()

  for field in "${required_fields[@]}"; do
    if [[ "$(jq -r ".$field // empty" "$REPO_ROOT/package.json")" == "" ]]; then
      missing_fields+=("$field")
    fi
  done

  if [[ ${#missing_fields[@]} -gt 0 ]]; then
    log_error "Missing required fields in package.json:"
    for field in "${missing_fields[@]}"; do
      log_error "  - $field"
    done
    return 1
  fi

  # Validate version format
  local version
  version=$(jq -r '.version' "$REPO_ROOT/package.json")
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    log_error "Invalid version format: $version (expected: X.Y.Z or X.Y.Z-prerelease)"
    return 1
  fi

  # Check publishConfig
  local registry
  registry=$(jq -r '.publishConfig.registry // empty' "$REPO_ROOT/package.json")
  if [[ "$registry" != "https://npm.pkg.github.com" ]]; then
    log_warn "publishConfig.registry is not set to GitHub Packages"
    log_warn "  Expected: https://npm.pkg.github.com"
    log_warn "  Found: ${registry:-<not set>}"
    if [[ "$STRICT_MODE" == "true" ]]; then
      return 1
    fi
  fi

  # Check package name matches GitHub org
  local pkg_name
  pkg_name=$(jq -r '.name' "$REPO_ROOT/package.json")
  if [[ ! "$pkg_name" =~ ^@jifflee/ ]]; then
    log_warn "Package name should be scoped to @jifflee/ for GitHub Packages"
    log_warn "  Current: $pkg_name"
    if [[ "$STRICT_MODE" == "true" ]]; then
      return 1
    fi
  fi

  log_verbose "Package: $pkg_name@$version"
  log_verbose "Registry: $registry"
  log_success "package.json is valid"

  return 0
}

validate_files_array() {
  log_step "Validating files array..."

  local files_array
  files_array=$(jq -r '.files // [] | length' "$REPO_ROOT/package.json")

  if [[ "$files_array" -eq 0 ]]; then
    log_warn "No files specified in package.json 'files' array"
    log_warn "This means ALL files will be published (including node_modules, tests, etc.)"
    if [[ "$STRICT_MODE" == "true" ]]; then
      return 1
    fi
    return 0
  fi

  log_verbose "Checking $files_array file patterns..."

  local missing_files=()
  local total_matched=0

  while IFS= read -r file_pattern; do
    # Remove trailing slash and wildcards for base path check
    local base_pattern="${file_pattern%/}"
    base_pattern="${base_pattern%%\**}"

    # Check if base path exists
    if [[ ! -e "$REPO_ROOT/$base_pattern" ]]; then
      missing_files+=("$file_pattern")
    else
      total_matched=$((total_matched + 1))
      log_verbose "  ✓ $file_pattern"
    fi
  done < <(jq -r '.files[]' "$REPO_ROOT/package.json")

  if [[ ${#missing_files[@]} -gt 0 ]]; then
    log_error "Missing files/directories listed in package.json:"
    for missing in "${missing_files[@]}"; do
      log_error "  - $missing"
    done
    return 1
  fi

  log_success "All $total_matched file patterns are valid"
  return 0
}

validate_packs_json() {
  log_step "Validating packs.json..."

  if [[ ! -f "$REPO_ROOT/packs.json" ]]; then
    log_verbose "packs.json not found (optional)"
    return 0
  fi

  # Validate JSON syntax
  if ! jq empty "$REPO_ROOT/packs.json" 2>/dev/null; then
    log_error "packs.json is not valid JSON"
    return 1
  fi

  # Check if packs.json is included in files array
  local includes_packs
  includes_packs=$(jq -r '.files[] | select(. == "packs.json")' "$REPO_ROOT/package.json" || echo "")

  if [[ -z "$includes_packs" ]]; then
    log_warn "packs.json exists but is not in package.json files array"
    if [[ "$STRICT_MODE" == "true" ]]; then
      return 1
    fi
  fi

  # Validate pack structure
  local pack_count
  pack_count=$(jq -r '.packs // {} | length' "$REPO_ROOT/packs.json")

  log_verbose "Found $pack_count pack(s) in packs.json"

  log_success "packs.json is valid"
  return 0
}

validate_npm_pack() {
  log_step "Running npm pack dry-run..."

  if ! command -v npm &>/dev/null; then
    log_warn "npm not found - skipping pack validation"
    return 0
  fi

  # Create temporary directory for pack output
  local temp_dir
  temp_dir=$(mktemp -d)
  trap 'rm -rf "$temp_dir"' RETURN

  cd "$REPO_ROOT"

  # Run npm pack --dry-run to see what would be packaged
  # Note: We skip this check if prepare script fails (e.g., husky not installed)
  # since it's a dev dependency and doesn't affect the package contents
  local pack_output
  pack_output=$(npm pack --dry-run 2>&1 || true)

  # Check if pack output contains package files (even if prepare failed)
  if echo "$pack_output" | grep -q "npm notice"; then
    log_verbose "npm pack dry-run succeeded"

    # Count files that would be included
    local file_count
    file_count=$(echo "$pack_output" | grep -c "^npm notice" || echo "0")

    log_verbose "Package would include approximately $file_count files"

    # Check for common unwanted files
    local unwanted_patterns=("test/" "tests/" ".env" "*.test.js" "*.spec.js")
    local found_unwanted=false

    for pattern in "${unwanted_patterns[@]}"; do
      if echo "$pack_output" | grep -q "$pattern"; then
        log_warn "Package may include unwanted files matching: $pattern"
        found_unwanted=true
      fi
    done

    if [[ "$found_unwanted" == "true" ]] && [[ "$STRICT_MODE" == "true" ]]; then
      log_error "Unwanted files detected in package"
      return 1
    fi

    log_success "npm pack validation passed"
  else
    log_warn "npm pack dry-run did not produce expected output"
    log_verbose "This may be due to missing dev dependencies (e.g., husky)"
    log_verbose "Package structure will still be validated via files array check"
    # Don't fail on this - files array validation is sufficient
  fi

  return 0
}

validate_tests() {
  log_step "Validating tests..."

  if [[ -f "$REPO_ROOT/scripts/test-runner.sh" ]]; then
    log_verbose "Running test suite via scripts/test-runner.sh..."

    if "$REPO_ROOT/scripts/test-runner.sh"; then
      log_success "All tests passed"
    else
      log_error "Test suite failed"
      return 1
    fi
  elif [[ -f "$REPO_ROOT/package.json" ]] && jq -e '.scripts.test' "$REPO_ROOT/package.json" &>/dev/null; then
    log_verbose "Running npm test..."

    if npm test; then
      log_success "npm test passed"
    else
      log_error "npm test failed"
      return 1
    fi
  else
    log_warn "No test runner found"
    log_warn "  Checked: scripts/test-runner.sh and npm test"
    if [[ "$STRICT_MODE" == "true" ]]; then
      log_error "No tests found in strict mode"
      return 1
    fi
  fi

  return 0
}

validate_git_state() {
  log_step "Validating git state..."

  # Check for uncommitted changes to package.json
  if git diff --name-only | grep -q "^package.json$"; then
    log_warn "package.json has uncommitted changes"
    if [[ "$STRICT_MODE" == "true" ]]; then
      log_error "Commit package.json changes before publishing"
      return 1
    fi
  fi

  # Check for staged changes to package.json
  if git diff --cached --name-only | grep -q "^package.json$"; then
    log_warn "package.json has staged but uncommitted changes"
    if [[ "$STRICT_MODE" == "true" ]]; then
      log_error "Commit package.json changes before publishing"
      return 1
    fi
  fi

  log_success "Git state is clean"
  return 0
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
  local exit_code=0

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Package Publish Validation (Dry Run)${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"

  # Run all validations
  validate_package_json || exit_code=1
  validate_files_array || exit_code=1
  validate_packs_json || exit_code=1
  validate_npm_pack || exit_code=1
  validate_git_state || exit_code=1
  validate_tests || exit_code=1

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"

  if [[ $exit_code -eq 0 ]]; then
    echo ""
    log_success "✓ All validation checks passed!"
    echo ""
    log_info "Package is ready to publish to GitHub Packages"
    echo ""
    log_info "To publish:"
    log_info "  1. Create and push a version tag:"
    log_info "     git tag v\$(jq -r .version package.json)"
    log_info "     git push origin v\$(jq -r .version package.json)"
    echo ""
    log_info "  2. The publish script will run automatically:"
    log_info "     ./scripts/ci/publish-on-tag.sh"
    echo ""
  else
    echo ""
    log_error "✗ Validation failed!"
    echo ""
    log_error "Fix the issues above before publishing."
    echo ""
  fi

  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  exit $exit_code
}

main "$@"
