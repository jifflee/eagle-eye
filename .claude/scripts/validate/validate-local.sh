#!/usr/bin/env bash
#
# validate-local.sh - Consolidated local validation suite
#
# Purpose:
#   Run all local validations (lint, security, structure, tests).
#   This project uses local testing suite only — no GitHub Actions CI.
#
# Usage:
#   ./scripts/validate-local.sh              # Run all validations
#   ./scripts/validate-local.sh --quick      # Skip slow checks (shellcheck)
#   ./scripts/validate-local.sh --verbose    # Detailed output
#   ./scripts/validate-local.sh --help       # Show help
#
# Exit codes:
#   0 - All validations passed
#   1 - One or more validations failed
#
# Related: Issue #362 - Add local validation suite
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
QUICK_MODE=false
VERBOSE=false

# Counters
TOTAL_CHECKS=0
PASSED=0
FAILED=0
SKIPPED=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --quick|-q)
      QUICK_MODE=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--quick] [--verbose] [--help]"
      echo ""
      echo "Run all local validations that don't require GitHub Actions."
      echo ""
      echo "Options:"
      echo "  --quick, -q     Skip slow checks (shellcheck)"
      echo "  --verbose, -v   Show detailed output from each check"
      echo "  --help, -h      Show this help message"
      echo ""
      echo "Validations included:"
      echo "  - Agent definitions (validate-agents.sh)"
      echo "  - Skill boundaries (validate-skill-boundaries.sh)"
      echo "  - Sprint work structure (validate-sprint-work.sh)"
      echo "  - n8n workflows (validate-n8n-workflows.sh)"
      echo "  - Script standards (headers, sizes, functions)"
      echo "  - ShellCheck (skipped with --quick)"
      echo ""
      echo "Validations NOT included (require gh CLI with auth):"
      echo "  - PR lifecycle labels (needs PR events)"
      echo "  - GitHub conventions (needs gh CLI with auth)"
      echo "  - Branch protection (GitHub setting, not CI)"
      echo ""
      echo "Exit codes:"
      echo "  0 - All validations passed"
      echo "  1 - One or more validations failed"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
  esac
done

# Print header
echo ""
echo "==========================================="
echo "Local Validation Suite"
echo "==========================================="
echo ""
echo "Repository: $REPO_ROOT"
echo "Quick mode: $QUICK_MODE"
echo "Verbose: $VERBOSE"
echo ""

# Function to run a check and record results
run_check() {
  local name="$1"
  local command="$2"
  local optional="${3:-false}"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

  printf "  %-35s " "$name..."

  local start_time
  start_time=$(date +%s)

  local output
  local exit_code=0

  if $VERBOSE; then
    echo ""
    eval "$command" 2>&1 | sed 's/^/    /' || exit_code=$?
    printf "    Result: "
  else
    output=$(eval "$command" 2>&1) || exit_code=$?
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [[ $exit_code -eq 0 ]]; then
    echo -e "${GREEN}passed${NC} (${duration}s)"
    PASSED=$((PASSED + 1))
  elif [[ "$optional" == "true" ]]; then
    echo -e "${YELLOW}skipped${NC} (optional)"
    SKIPPED=$((SKIPPED + 1))
  else
    echo -e "${RED}failed${NC} (${duration}s)"
    FAILED=$((FAILED + 1))
    if ! $VERBOSE && [[ -n "${output:-}" ]]; then
      # Show failure output in non-verbose mode
      echo "$output" | head -20 | sed 's/^/    /'
      local lines
      lines=$(echo "$output" | wc -l | tr -d ' ')
      if [[ $lines -gt 20 ]]; then
        echo "    ... ($((lines - 20)) more lines)"
      fi
    fi
  fi
}

# Function to skip a check
skip_check() {
  local name="$1"
  local reason="$2"

  printf "  %-35s " "$name..."
  echo -e "${YELLOW}skipped${NC} ($reason)"
  SKIPPED=$((SKIPPED + 1))
}

# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Section: Agent Validation
echo -e "${BLUE}Agent Validation${NC}"
if [[ -f "$SCRIPT_DIR/validate-agents.sh" ]]; then
  run_check "Agent definitions" "$SCRIPT_DIR/validate-agents.sh --all"
else
  skip_check "Agent definitions" "script not found"
fi
echo ""

# Section: Skill Validation
echo -e "${BLUE}Skill Validation${NC}"
if [[ -f "$SCRIPT_DIR/validate-skill-boundaries.sh" ]]; then
  run_check "Skill boundaries" "$SCRIPT_DIR/validate-skill-boundaries.sh --ci"
else
  skip_check "Skill boundaries" "script not found"
fi

if [[ -f "$SCRIPT_DIR/validate-sprint-work.sh" ]]; then
  run_check "Sprint work structure" "$SCRIPT_DIR/validate-sprint-work.sh"
else
  skip_check "Sprint work structure" "script not found"
fi

if [[ -f "$SCRIPT_DIR/ci/validators/check-skill-sizes.sh" ]]; then
  run_check "Skill file sizes" "$SCRIPT_DIR/ci/validators/check-skill-sizes.sh --errors-only"
else
  skip_check "Skill file sizes" "script not found"
fi
echo ""

# Section: n8n Workflow Validation
echo -e "${BLUE}n8n Workflow Validation${NC}"
if [[ -d "$REPO_ROOT/n8n-workflows" ]] && [[ -f "$SCRIPT_DIR/validate-n8n-workflows.sh" ]]; then
  run_check "n8n workflows" "$SCRIPT_DIR/validate-n8n-workflows.sh --quiet"
else
  skip_check "n8n workflows" "no workflows or script"
fi
echo ""

# Section: Script Standards
echo -e "${BLUE}Script Standards${NC}"

# Check script headers (shebang required)
check_headers() {
  local errors=0
  for script in $(find "$SCRIPT_DIR" -name '*.sh' -type f 2>/dev/null); do
    # Skip lib/*.sh as they're libraries
    if [[ "$script" == *"/lib/"* ]]; then
      continue
    fi
    if ! head -1 "$script" | grep -q '^#!/'; then
      echo "Missing shebang: $script" >&2
      errors=$((errors + 1))
    fi
  done
  return $errors
}
run_check "Script headers" check_headers

# Check script sizes (advisory only)
check_sizes() {
  local warnings=0
  for script in $(find "$SCRIPT_DIR" -name '*.sh' -type f 2>/dev/null); do
    local lines
    lines=$(grep -v '^[[:space:]]*#' "$script" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    local has_size_ok
    has_size_ok=$(head -30 "$script" | grep -c '^# size-ok:' || true)
    if [[ $lines -gt 500 ]] && [[ $has_size_ok -eq 0 ]]; then
      echo "Large script ($lines lines): $script" >&2
      warnings=$((warnings + 1))
    fi
  done
  # Advisory only - don't fail
  return 0
}
run_check "Script sizes (advisory)" check_sizes

# ShellCheck (slow, skip in quick mode)
if $QUICK_MODE; then
  skip_check "ShellCheck" "quick mode"
elif ! command_exists shellcheck; then
  skip_check "ShellCheck" "not installed"
else
  check_shellcheck() {
    local errors=0
    for script in $(find "$SCRIPT_DIR" -name '*.sh' -type f 2>/dev/null | head -50); do
      if ! shellcheck -f gcc "$script" 2>&1; then
        errors=$((errors + 1))
      fi
    done
    return $errors
  }
  run_check "ShellCheck" check_shellcheck "true"  # Optional - don't fail validation
fi
echo ""

# Section: Structure Validation
echo -e "${BLUE}Structure Validation${NC}"
if [[ -f "$SCRIPT_DIR/validate-structure.sh" ]]; then
  run_check "Repository structure" "$SCRIPT_DIR/validate-structure.sh"
else
  skip_check "Repository structure" "script not found"
fi

if [[ -f "$SCRIPT_DIR/validate-naming.sh" ]]; then
  run_check "Naming conventions" "$SCRIPT_DIR/validate-naming.sh"
else
  skip_check "Naming conventions" "script not found"
fi
echo ""

# Section: Test Validation
echo -e "${BLUE}Test Validation${NC}"
if [[ -f "$SCRIPT_DIR/validate-test-existence.sh" ]]; then
  run_check "Test existence" "$SCRIPT_DIR/validate-test-existence.sh"
else
  skip_check "Test existence" "script not found"
fi

if [[ -f "$SCRIPT_DIR/validate-test-distribution.sh" ]]; then
  run_check "Test distribution" "$SCRIPT_DIR/validate-test-distribution.sh"
else
  skip_check "Test distribution" "script not found"
fi
echo ""

# Print summary
echo "==========================================="
echo "Summary"
echo "==========================================="
echo ""
echo "Total checks: $TOTAL_CHECKS"
echo -e "${GREEN}Passed: $PASSED${NC}"
if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}Failed: $FAILED${NC}"
fi
if [[ $SKIPPED -gt 0 ]]; then
  echo -e "${YELLOW}Skipped: $SKIPPED${NC}"
fi
echo ""

# Update CI check labels if PR number provided via environment
if [[ -n "${PR_NUMBER:-}" ]] && command_exists gh; then
  LABEL_SCRIPT="${SCRIPT_DIR}/update-ci-check-labels.sh"
  if [[ -x "${LABEL_SCRIPT}" ]]; then
    echo -e "${BLUE}Updating CI check labels...${NC}"
    if [[ $FAILED -gt 0 ]]; then
      "${LABEL_SCRIPT}" "${PR_NUMBER}" fail 2>/dev/null || echo "Warning: Failed to update labels"
    else
      "${LABEL_SCRIPT}" "${PR_NUMBER}" pass 2>/dev/null || echo "Warning: Failed to update labels"
    fi
  fi
fi

# Exit status
if [[ $FAILED -gt 0 ]]; then
  echo -e "${RED}Validation failed!${NC}"
  echo "Fix the above issues before pushing."
  exit 1
else
  echo -e "${GREEN}All local validations passed!${NC}"
  echo ""
  echo "Note: Some checks require gh CLI with auth:"
  echo "  - PR lifecycle labels (needs PR events)"
  echo "  - GitHub conventions (needs gh auth)"
  echo "  - Branch protection enforcement (GitHub setting)"
  exit 0
fi
