#!/usr/bin/env bash
set -euo pipefail
#
# Test Existence Validator
# Validates that source files have corresponding test files
# See: docs/standards/TEST_REQUIREMENTS.md
#

set -e

# Get repo root (parent of scripts/)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Counters
TOTAL=0
PASSED=0
FAILED=0
WARNINGS=0

# Options
VERBOSE=false
CHECK_PATH=""

usage() {
  cat << EOF
Usage: $(basename "$0") [options]

Validate that source files have corresponding test files per TEST_REQUIREMENTS.md.

Options:
  --path PATH       Validate only files under PATH (default: src/)
  --verbose         Show all checks, not just failures
  -h, --help        Show this help message

Existence Rules:
  src/services/*.ts     -> tests/unit/services/*.test.ts
  src/models/*.ts       -> tests/unit/models/*.test.ts
  src/routes/api/**/*.ts -> tests/integration/routes/**/*.test.ts
  src/utils/*.ts        -> tests/unit/utils/*.test.ts

Exit codes:
  0 - All validations passed
  1 - Some validations failed (missing test files)
EOF
}

log_pass() {
  ((PASSED++)) || true
  if [ "$VERBOSE" = true ]; then
    echo -e "  ${GREEN}✓${NC} $1"
  fi
}

log_fail() {
  ((FAILED++)) || true
  echo -e "  ${RED}✗${NC} $1"
}

log_warn() {
  ((WARNINGS++)) || true
  echo -e "  ${YELLOW}!${NC} $1"
}

log_info() {
  echo -e "  ${BLUE}i${NC} $1"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      CHECK_PATH="$2"
      shift 2
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

# Default check path
if [ -z "$CHECK_PATH" ]; then
  CHECK_PATH="src"
fi

echo -e "${BLUE}Test Existence Validator${NC}"
echo -e "${BLUE}========================${NC}"
echo ""

# Check if src/ directory exists
if [ ! -d "$REPO_DIR/$CHECK_PATH" ]; then
  echo -e "${YELLOW}No $CHECK_PATH/ directory found. Nothing to validate.${NC}"
  exit 0
fi

# Map source path to expected test path
get_test_path() {
  local src_file="$1"
  local basename
  basename=$(basename "$src_file" .ts)

  case "$src_file" in
    src/services/*)
      echo "tests/unit/services/${basename}.test.ts"
      ;;
    src/models/*)
      echo "tests/unit/models/${basename}.test.ts"
      ;;
    src/routes/api/*)
      # Strip src/routes/api/ prefix and add tests/integration/routes/
      local route_path="${src_file#src/routes/api/}"
      local route_dir
      route_dir=$(dirname "$route_path")
      echo "tests/integration/routes/${route_dir}/${basename}.test.ts"
      ;;
    src/utils/*)
      echo "tests/unit/utils/${basename}.test.ts"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Validate services
echo -e "${BLUE}Checking: src/services/${NC}"
if [ -d "$REPO_DIR/src/services" ]; then
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local_path="${file#$REPO_DIR/}"
    test_path=$(get_test_path "$local_path")
    if [ -n "$test_path" ] && [ -f "$REPO_DIR/$test_path" ]; then
      log_pass "$local_path -> $test_path"
    elif [ -n "$test_path" ]; then
      log_fail "Missing: $test_path (for $local_path)"
    fi
  done < <(find "$REPO_DIR/src/services" -name "*.ts" -not -name "*.test.ts" -not -name "*.d.ts" -not -name "index.ts" -print0 2>/dev/null)
else
  log_info "No src/services/ directory"
fi

# Validate models
echo ""
echo -e "${BLUE}Checking: src/models/${NC}"
if [ -d "$REPO_DIR/src/models" ]; then
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local_path="${file#$REPO_DIR/}"
    test_path=$(get_test_path "$local_path")
    if [ -n "$test_path" ] && [ -f "$REPO_DIR/$test_path" ]; then
      log_pass "$local_path -> $test_path"
    elif [ -n "$test_path" ]; then
      log_fail "Missing: $test_path (for $local_path)"
    fi
  done < <(find "$REPO_DIR/src/models" -name "*.ts" -not -name "*.test.ts" -not -name "*.d.ts" -not -name "index.ts" -print0 2>/dev/null)
else
  log_info "No src/models/ directory"
fi

# Validate routes
echo ""
echo -e "${BLUE}Checking: src/routes/api/${NC}"
if [ -d "$REPO_DIR/src/routes/api" ]; then
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local_path="${file#$REPO_DIR/}"
    test_path=$(get_test_path "$local_path")
    if [ -n "$test_path" ] && [ -f "$REPO_DIR/$test_path" ]; then
      log_pass "$local_path -> $test_path"
    elif [ -n "$test_path" ]; then
      log_fail "Missing: $test_path (for $local_path)"
    fi
  done < <(find "$REPO_DIR/src/routes/api" -name "*.ts" -not -name "*.test.ts" -not -name "*.d.ts" -not -name "index.ts" -print0 2>/dev/null)
else
  log_info "No src/routes/api/ directory"
fi

# Validate utils
echo ""
echo -e "${BLUE}Checking: src/utils/${NC}"
if [ -d "$REPO_DIR/src/utils" ]; then
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local_path="${file#$REPO_DIR/}"
    test_path=$(get_test_path "$local_path")
    if [ -n "$test_path" ] && [ -f "$REPO_DIR/$test_path" ]; then
      log_pass "$local_path -> $test_path"
    elif [ -n "$test_path" ]; then
      log_fail "Missing: $test_path (for $local_path)"
    fi
  done < <(find "$REPO_DIR/src/utils" -name "*.ts" -not -name "*.test.ts" -not -name "*.d.ts" -not -name "index.ts" -print0 2>/dev/null)
else
  log_info "No src/utils/ directory"
fi

# Check test file naming conventions
echo ""
echo -e "${BLUE}Checking: Test file naming conventions${NC}"
if [ -d "$REPO_DIR/tests" ]; then
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local_path="${file#$REPO_DIR/}"
    basename_file=$(basename "$file")
    case "$basename_file" in
      *.test.ts|*.integration.test.ts|*.e2e.test.ts)
        log_pass "$local_path (valid naming)"
        ;;
      *)
        log_warn "$local_path (non-standard naming, expected *.test.ts, *.integration.test.ts, or *.e2e.test.ts)"
        ;;
    esac
  done < <(find "$REPO_DIR/tests" -name "*.ts" -not -name "*.d.ts" -print0 2>/dev/null)
else
  log_info "No tests/ directory"
fi

# Summary
echo ""
echo -e "${BLUE}========================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "  Total checks: $TOTAL"
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"

if [ "$FAILED" -gt 0 ]; then
  echo ""
  echo -e "${RED}Validation failed: $FAILED missing test file(s)${NC}"
  exit 1
elif [ "$TOTAL" -eq 0 ]; then
  echo ""
  echo -e "${YELLOW}No source files found to validate.${NC}"
  exit 0
else
  echo ""
  echo -e "${GREEN}All test existence checks passed.${NC}"
  exit 0
fi
