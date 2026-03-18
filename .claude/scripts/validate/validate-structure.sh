#!/usr/bin/env bash
set -euo pipefail
#
# Repository Structure Validator
# Validates repository directory structure against standards
# See: docs/standards/REPOSITORY_STRUCTURE.md
# size-ok: multi-category structure validation across directories, files, and conventions
#

set -e

# Get repo root (parent of scripts/)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# Options
VERBOSE=false
CHECK_PATH=""
FRAMEWORK_MODE=false

usage() {
  cat << EOF
Usage: $(basename "$0") [options]

Validate repository directory structure against standards.

Options:
  --path PATH       Validate structure at PATH (default: repo root)
  --framework       Enable framework-mode checks (core/, .claude/, etc.)
  --verbose         Show all checks, not just failures
  -h, --help        Show this help message

Examples:
  $(basename "$0")                    # Validate current repo
  $(basename "$0") --framework        # Include framework-specific checks
  $(basename "$0") --verbose          # Show all check results
  $(basename "$0") --path /some/repo  # Validate another repo

Exit codes:
  0  All checks pass
  1  One or more violations found
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      CHECK_PATH="$2"
      shift 2
      ;;
    --framework)
      FRAMEWORK_MODE=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# Set target directory
TARGET_DIR="${CHECK_PATH:-$REPO_DIR}"

if [ ! -d "$TARGET_DIR" ]; then
  echo -e "${RED}[ERROR]${NC} Directory not found: $TARGET_DIR"
  exit 1
fi

# Auto-detect framework mode
if [ -d "$TARGET_DIR/core" ] && [ -d "$TARGET_DIR/.claude" ]; then
  FRAMEWORK_MODE=true
fi

# ============================================================
# Check Functions
# ============================================================

check_pass() {
  local msg="$1"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
  if [ "$VERBOSE" = true ]; then
    echo -e "  ${GREEN}[PASS]${NC} $msg"
  fi
}

check_fail() {
  local msg="$1"
  TOTAL=$((TOTAL + 1))
  FAILED=$((FAILED + 1))
  echo -e "  ${RED}[FAIL]${NC} $msg"
}

check_warn() {
  local msg="$1"
  TOTAL=$((TOTAL + 1))
  WARNINGS=$((WARNINGS + 1))
  echo -e "  ${YELLOW}[WARN]${NC} $msg"
}

# ============================================================
# Required Structure Checks
# ============================================================

echo -e "${BLUE}=== Repository Structure Validation ===${NC}"
echo -e "${BLUE}Target: ${NC}$TARGET_DIR"
echo ""

echo -e "${BLUE}--- Required Structure ---${NC}"

# Check README.md
if [ -f "$TARGET_DIR/README.md" ]; then
  check_pass "README.md exists"
else
  check_fail "README.md missing in root"
fi

# Check required directories
REQUIRED_DIRS=("docs" "scripts" "tests" ".github")
for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$TARGET_DIR/$dir" ]; then
    check_pass "$dir/ directory exists"
  else
    check_fail "$dir/ directory missing"
  fi
done

# Check config directory (or root config files)
if [ -d "$TARGET_DIR/config" ]; then
  check_pass "config/ directory exists"
else
  # Check for root config files as alternative
  config_files=$(find "$TARGET_DIR" -maxdepth 1 \( -name "*.json" -o -name "*.yml" -o -name "*.yaml" -o -name "*.toml" \) -not -name "package-lock.json" 2>/dev/null | head -1)
  if [ -n "$config_files" ]; then
    check_warn "config/ directory missing (root config files found)"
  else
    check_fail "config/ directory missing (no configuration found)"
  fi
fi

# Check src directory (or equivalents)
if [ -d "$TARGET_DIR/src" ]; then
  check_pass "src/ directory exists"
elif [ -d "$TARGET_DIR/app" ]; then
  check_pass "app/ directory exists (src/ equivalent)"
elif [ -d "$TARGET_DIR/lib" ]; then
  check_pass "lib/ directory exists (src/ equivalent)"
elif [ -d "$TARGET_DIR/backend" ]; then
  check_pass "backend/ directory exists (src/ equivalent)"
elif [ "$FRAMEWORK_MODE" = true ]; then
  check_warn "src/ not required for framework repos (core/ used instead)"
else
  check_fail "src/ directory missing (or equivalent: app/, lib/, backend/)"
fi

# ============================================================
# Framework-Specific Checks
# ============================================================

if [ "$FRAMEWORK_MODE" = true ]; then
  echo ""
  echo -e "${BLUE}--- Framework Structure ---${NC}"

  FRAMEWORK_DIRS=("core" ".claude")
  for dir in "${FRAMEWORK_DIRS[@]}"; do
    if [ -d "$TARGET_DIR/$dir" ]; then
      check_pass "$dir/ directory exists"
    else
      check_fail "$dir/ directory missing (required for framework repos)"
    fi
  done
fi

# ============================================================
# Root Cleanliness Checks
# ============================================================

echo ""
echo -e "${BLUE}--- Root Cleanliness ---${NC}"

# Check for source code in root
SOURCE_EXTENSIONS=("py" "ts" "js" "go" "rs" "java" "rb" "php")
root_source_files=""
for ext in "${SOURCE_EXTENSIONS[@]}"; do
  found=$(find "$TARGET_DIR" -maxdepth 1 -name "*.$ext" 2>/dev/null)
  if [ -n "$found" ]; then
    root_source_files="$root_source_files $found"
  fi
done

if [ -z "$root_source_files" ]; then
  check_pass "No source code files in root"
else
  for f in $root_source_files; do
    check_fail "Source code in root: $(basename "$f")"
  done
fi

# Check for test files in root
root_test_files=$(find "$TARGET_DIR" -maxdepth 1 \( -name "test_*" -o -name "*_test.*" -o -name "*.test.*" -o -name "*.spec.*" \) 2>/dev/null)
if [ -z "$root_test_files" ]; then
  check_pass "No test files in root"
else
  for f in $root_test_files; do
    check_fail "Test file in root: $(basename "$f")"
  done
fi

# Check for standalone scripts in root (excluding Makefile)
root_scripts=$(find "$TARGET_DIR" -maxdepth 1 -name "*.sh" 2>/dev/null)
if [ -z "$root_scripts" ]; then
  check_pass "No standalone scripts in root"
else
  for f in $root_scripts; do
    check_fail "Script in root: $(basename "$f") (move to scripts/)"
  done
fi

# ============================================================
# Test Organization Checks
# ============================================================

echo ""
echo -e "${BLUE}--- Test Organization ---${NC}"

if [ -d "$TARGET_DIR/tests" ]; then
  # Check for test subdirectories
  if [ -d "$TARGET_DIR/tests/unit" ] || [ -d "$TARGET_DIR/tests/integration" ] || [ -d "$TARGET_DIR/tests/e2e" ]; then
    check_pass "Tests organized by type (unit/integration/e2e)"
  else
    # Check if there are test files at all
    test_files=$(find "$TARGET_DIR/tests" -name "*.test.*" -o -name "test_*" -o -name "*_test.*" 2>/dev/null | head -1)
    if [ -n "$test_files" ]; then
      check_warn "Test files exist but not organized into unit/integration/e2e"
    else
      check_warn "tests/ directory exists but no test files found"
    fi
  fi

  # Check for fixtures directory
  if [ -d "$TARGET_DIR/tests/fixtures" ]; then
    check_pass "tests/fixtures/ directory exists"
  else
    check_warn "tests/fixtures/ directory not found"
  fi
else
  check_warn "tests/ directory missing (skipping test organization checks)"
fi

# ============================================================
# Scripts Organization Checks
# ============================================================

echo ""
echo -e "${BLUE}--- Scripts Organization ---${NC}"

if [ -d "$TARGET_DIR/scripts" ]; then
  # Check for lib directory
  if [ -d "$TARGET_DIR/scripts/lib" ]; then
    check_pass "scripts/lib/ directory exists"
  else
    check_warn "scripts/lib/ directory not found (recommended for shared utilities)"
  fi

  # Count scripts in root of scripts/
  root_script_count=$(find "$TARGET_DIR/scripts" -maxdepth 1 -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$root_script_count" -gt 30 ]; then
    check_warn "scripts/ has $root_script_count scripts in root (consider organizing into subdirectories)"
  else
    check_pass "scripts/ organization is reasonable ($root_script_count scripts in root)"
  fi
else
  check_warn "scripts/ directory missing (skipping script organization checks)"
fi

# ============================================================
# Documentation Organization Checks
# ============================================================

echo ""
echo -e "${BLUE}--- Documentation Organization ---${NC}"

if [ -d "$TARGET_DIR/docs" ]; then
  # Check for standards directory
  if [ -d "$TARGET_DIR/docs/standards" ]; then
    check_pass "docs/standards/ directory exists"
  else
    check_warn "docs/standards/ directory not found"
  fi

  # Count docs in root of docs/
  root_doc_count=$(find "$TARGET_DIR/docs" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$root_doc_count" -gt 20 ]; then
    check_warn "docs/ has $root_doc_count files in root (consider organizing into subdirectories)"
  else
    check_pass "docs/ organization is reasonable ($root_doc_count files in root)"
  fi
else
  check_warn "docs/ directory missing (skipping documentation checks)"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "  Total checks: $TOTAL"
echo -e "  ${GREEN}Passed: $PASSED${NC}"
if [ "$FAILED" -gt 0 ]; then
  echo -e "  ${RED}Failed: $FAILED${NC}"
fi
if [ "$WARNINGS" -gt 0 ]; then
  echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
fi

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo -e "${RED}Structure validation FAILED${NC}"
  echo "See docs/standards/REPOSITORY_STRUCTURE.md for the full standard."
  exit 1
else
  echo ""
  echo -e "${GREEN}Structure validation PASSED${NC}"
  exit 0
fi
