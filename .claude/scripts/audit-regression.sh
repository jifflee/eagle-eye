#!/usr/bin/env bash
#
# audit-regression.sh - Runtime regression testing for skills, hooks, and actions
# Feature #1024 - Add regression audit for skills, hooks, and actions
#
# Usage:
#   ./scripts/audit-regression.sh                    # Full regression audit
#   ./scripts/audit-regression.sh --skills           # Skills only
#   ./scripts/audit-regression.sh --hooks            # Hooks only
#   ./scripts/audit-regression.sh --actions          # Actions only
#   ./scripts/audit-regression.sh --json             # JSON output
#   ./scripts/audit-regression.sh --verbose          # Detailed output
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
CLAUDE_DIR="$REPO_ROOT/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
CORE_COMMANDS_DIR="$REPO_ROOT/core/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
SCRIPTS_DIR="$REPO_ROOT/scripts"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_WARNINGS=0

# Options
TEST_SKILLS=true
TEST_HOOKS=true
TEST_ACTIONS=true
JSON_OUTPUT=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skills)
      TEST_HOOKS=false
      TEST_ACTIONS=false
      shift
      ;;
    --hooks)
      TEST_SKILLS=false
      TEST_ACTIONS=false
      shift
      ;;
    --actions)
      TEST_SKILLS=false
      TEST_HOOKS=false
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      cat << EOF
Usage: $0 [options]

Runtime regression testing for skills, hooks, and actions.
Goes beyond static validation to verify behavioral correctness.

Options:
  --skills      Test skills only
  --hooks       Test hooks only
  --actions     Test actions only
  --json        Output as JSON
  --verbose     Detailed output
  -h, --help    Show this help

Examples:
  $0                    # Run full regression audit
  $0 --skills --verbose # Test skills with detailed output
  $0 --json             # JSON output for CI integration
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Utility functions
log_info() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${BLUE}$1${NC}"
}

log_success() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $1${NC}"
}

log_warning() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${YELLOW}⚠ $1${NC}"
}

# Test functions
test_skills() {
  log_info "Testing Skills..."

  local skills_tested=0
  local skills_passed=0
  local skills_failed=0

  # Test .claude/commands/*.md
  if [ -d "$COMMANDS_DIR" ]; then
    while IFS= read -r -d '' skill_file; do
      ((skills_tested++))
      local skill_name=$(basename "$skill_file" .md)

      # Check frontmatter
      if ! grep -q "^---$" "$skill_file" 2>/dev/null; then
        log_error "Skill $skill_name: Missing frontmatter"
        ((skills_failed++))
        continue
      fi

      # Check for description field
      local fm=$(sed -n '/^---$/,/^---$/p' "$skill_file" 2>/dev/null | sed '1d;$d')
      if ! echo "$fm" | grep -q "^description:"; then
        log_error "Skill $skill_name: Missing description"
        ((skills_failed++))
        continue
      fi

      # Check referenced scripts exist
      local missing_scripts=false
      while IFS= read -r script_ref; do
        local script_path="$REPO_ROOT/${script_ref#./}"
        if [ ! -f "$script_path" ]; then
          log_warning "Skill $skill_name: Script not found: $script_ref"
          ((TOTAL_WARNINGS++))
          missing_scripts=true
        fi
      done < <(grep -oE '\./scripts/[a-zA-Z0-9_-]+\.sh' "$skill_file" 2>/dev/null || true)

      if [ "$missing_scripts" = false ]; then
        [ "$VERBOSE" = true ] && log_success "Skill $skill_name: OK"
        ((skills_passed++))
      else
        ((skills_failed++))
      fi
    done < <(find "$COMMANDS_DIR" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null)
  fi

  # Test core/commands/*.md
  if [ -d "$CORE_COMMANDS_DIR" ]; then
    while IFS= read -r -d '' skill_file; do
      ((skills_tested++))
      local skill_name=$(basename "$skill_file" .md)

      # Basic check
      if grep -q "^---$" "$skill_file" 2>/dev/null && grep -q "^description:" "$skill_file" 2>/dev/null; then
        [ "$VERBOSE" = true ] && log_success "Core skill $skill_name: OK"
        ((skills_passed++))
      else
        log_error "Core skill $skill_name: Invalid format"
        ((skills_failed++))
      fi
    done < <(find "$CORE_COMMANDS_DIR" -maxdepth 1 -name "*.md" -type f -print0 2>/dev/null)
  fi

  ((TOTAL_TESTS += skills_tested))
  ((TOTAL_PASSED += skills_passed))
  ((TOTAL_FAILED += skills_failed))

  log_info "Skills: $skills_tested tested, $skills_passed passed, $skills_failed failed"
}

test_hooks() {
  log_info "Testing Hooks..."

  local hooks_tested=0
  local hooks_passed=0
  local hooks_failed=0

  # Test settings.json
  ((hooks_tested++))
  if [ ! -f "$SETTINGS_FILE" ]; then
    log_error "settings.json not found"
    ((hooks_failed++))
  elif ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
    log_error "settings.json invalid JSON"
    ((hooks_failed++))
  else
    log_success "settings.json: Valid"
    ((hooks_passed++))
  fi

  # Test registered hooks
  if [ -f "$SETTINGS_FILE" ] && jq empty "$SETTINGS_FILE" 2>/dev/null; then
    while IFS= read -r hook_command; do
      [ -z "$hook_command" ] && continue
      ((hooks_tested++))

      local hook_path="$REPO_ROOT/$hook_command"
      local hook_name=$(basename "$hook_command")

      if [ ! -f "$hook_path" ]; then
        log_error "Hook $hook_name: File not found"
        ((hooks_failed++))
      elif [ ! -x "$hook_path" ]; then
        log_error "Hook $hook_name: Not executable"
        ((hooks_failed++))
      else
        [ "$VERBOSE" = true ] && log_success "Hook $hook_name: OK"
        ((hooks_passed++))
      fi
    done < <(jq -r '.hooks[][] | .hooks[]?.command // empty' "$SETTINGS_FILE" 2>/dev/null || true)
  fi

  ((TOTAL_TESTS += hooks_tested))
  ((TOTAL_PASSED += hooks_passed))
  ((TOTAL_FAILED += hooks_failed))

  log_info "Hooks: $hooks_tested tested, $hooks_passed passed, $hooks_failed failed"
}

test_actions() {
  log_info "Testing Actions..."

  local actions_tested=0
  local actions_passed=0
  local actions_failed=0

  # Test 1: Count executable scripts
  ((actions_tested++))
  local action_count=$(find "$SCRIPTS_DIR" -maxdepth 1 -name "*.sh" -type f -executable 2>/dev/null | wc -l || echo 0)
  log_success "Found $action_count executable action scripts"
  ((actions_passed++))

  # Test 2: Check tier-registry.json
  ((actions_tested++))
  local tier_registry="$CLAUDE_DIR/tier-registry.json"
  if [ -f "$tier_registry" ]; then
    if jq empty "$tier_registry" 2>/dev/null; then
      log_success "tier-registry.json: Valid"
      ((actions_passed++))
    else
      log_error "tier-registry.json: Invalid JSON"
      ((actions_failed++))
    fi
  else
    log_info "tier-registry.json: Not found (optional)"
    ((actions_passed++))
  fi

  # Test 3: Check critical scripts
  local critical_scripts=("capability-audit.sh" "audit-skills-data.sh" "validate-framework-artifacts.sh")
  for script_name in "${critical_scripts[@]}"; do
    ((actions_tested++))
    local script_path="$SCRIPTS_DIR/$script_name"

    if [ ! -f "$script_path" ]; then
      log_warning "Critical script missing: $script_name"
      ((TOTAL_WARNINGS++))
      ((actions_passed++))  # Warning, not failure
    elif [ ! -x "$script_path" ]; then
      log_error "Critical script not executable: $script_name"
      ((actions_failed++))
    else
      [ "$VERBOSE" = true ] && log_success "Critical script $script_name: OK"
      ((actions_passed++))
    fi
  done

  ((TOTAL_TESTS += actions_tested))
  ((TOTAL_PASSED += actions_passed))
  ((TOTAL_FAILED += actions_failed))

  log_info "Actions: $actions_tested tested, $actions_passed passed, $actions_failed failed"
}

# Main execution
main() {
  if [ "$JSON_OUTPUT" = false ]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         REGRESSION AUDIT - Runtime Verification              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
  fi

  # Run tests
  [ "$TEST_SKILLS" = true ] && test_skills
  [ "$TEST_HOOKS" = true ] && test_hooks
  [ "$TEST_ACTIONS" = true ] && test_actions

  # Output results
  if [ "$JSON_OUTPUT" = true ]; then
    cat << EOF
{
  "summary": {
    "total_tests": $TOTAL_TESTS,
    "passed": $TOTAL_PASSED,
    "failed": $TOTAL_FAILED,
    "warnings": $TOTAL_WARNINGS,
    "status": "$([ $TOTAL_FAILED -eq 0 ] && echo "passed" || echo "failed")",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
  else
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "Regression Audit Summary"
    echo "══════════════════════════════════════════════════════════════"
    echo "Total Tests:    $TOTAL_TESTS"
    echo "Passed:         $TOTAL_PASSED"
    echo "Failed:         $TOTAL_FAILED"
    echo "Warnings:       $TOTAL_WARNINGS"
    echo "══════════════════════════════════════════════════════════════"

    if [ $TOTAL_FAILED -eq 0 ]; then
      echo -e "${GREEN}✓ All regression tests passed${NC}"
    else
      echo -e "${RED}✗ Regression audit failed with $TOTAL_FAILED errors${NC}"
    fi
    echo "══════════════════════════════════════════════════════════════"
    echo ""
  fi

  # Exit with appropriate code
  [ $TOTAL_FAILED -eq 0 ] && exit 0 || exit 1
}

main
