#!/usr/bin/env bash
set -euo pipefail
#
# Naming Convention Validator
# Validates file and directory names against repository conventions
# See: docs/standards/NAMING_CONVENTIONS.md
# size-ok: comprehensive naming validation across multiple file types and directory patterns
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
CHECK_TYPE=""
FIX_MODE=false

# Regex patterns
KEBAB_CASE_PATTERN='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
PASCAL_CASE_PATTERN='^[A-Z][a-zA-Z0-9]*$'
SCRIPT_PATTERN='^[a-z][a-z0-9]*(-[a-z0-9]+)*\.sh$'
MD_UPPERCASE_PATTERN='^[A-Z][A-Z0-9_]*\.md$'
MD_LOWERCASE_PATTERN='^[a-z][a-z0-9-]*\.md$'

# Skill naming patterns - category-action format
SKILL_PREFIXES=("repo" "pr" "sprint" "milestone" "issue" "worktree" "audit" "skill")
SKILL_ACTIONS=("audit" "review" "status" "update" "complete" "create" "close" "merge" "cleanup" "checkout" "release" "fix" "iterate" "triage" "list" "sync" "init" "work" "continue" "locks" "label" "promote")

# Prohibited generic names
PROHIBITED_NAMES=("utils.ts" "helpers.ts" "misc.ts" "common.ts" "util.ts" "helper.ts")

usage() {
  cat << EOF
Usage: $(basename "$0") [options]

Validate file and directory naming conventions.

Options:
  --path PATH       Validate only files/dirs under PATH (default: entire repo)
  --type TYPE       Validate only specific type:
                      scripts  - Shell scripts (.sh)
                      dirs     - Directory names
                      ts       - TypeScript files
                      skills   - Skill/command names
                      all      - Everything (default)
  --verbose         Show all checks, not just failures
  --fix             Show suggested fixes (does not auto-rename)
  -h, --help        Show this help message

Examples:
  ./scripts/validate-naming.sh                    # Validate everything
  ./scripts/validate-naming.sh --path src/        # Validate only src/
  ./scripts/validate-naming.sh --type scripts     # Validate only scripts
  ./scripts/validate-naming.sh --type skills      # Validate skill names
  ./scripts/validate-naming.sh --verbose          # Show all results

Exit codes:
  0 - All validations passed
  1 - Some validations failed
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
  if [ -n "$2" ] && [ "$FIX_MODE" = true ]; then
    echo -e "    ${BLUE}→${NC} Suggested: $2"
  fi
}

log_warn() {
  ((WARNINGS++)) || true
  echo -e "  ${YELLOW}⚠${NC} $1"
}

# Convert string to kebab-case
to_kebab_case() {
  echo "$1" | sed -E 's/([A-Z])/-\L\1/g' | sed 's/^-//' | sed 's/_/-/g' | tr '[:upper:]' '[:lower:]'
}

# Validate script files (.sh)
validate_scripts() {
  local search_path="${1:-$REPO_DIR/scripts}"

  echo -e "\n${BLUE}Validating script names...${NC}"

  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local filename=$(basename "$file")

    if [[ "$filename" =~ $SCRIPT_PATTERN ]]; then
      log_pass "$filename"
    else
      local suggested=$(to_kebab_case "${filename%.sh}").sh
      log_fail "$filename (should be kebab-case)" "$suggested"
    fi
  done < <(find "$search_path" -name "*.sh" -type f -print0 2>/dev/null)
}

# Validate directory names
validate_directories() {
  local search_path="${1:-$REPO_DIR}"

  echo -e "\n${BLUE}Validating directory names...${NC}"

  while IFS= read -r -d '' dir; do
    ((TOTAL++)) || true
    local dirname=$(basename "$dir")
    local relpath="${dir#$REPO_DIR/}"

    # Skip hidden directories and common exceptions
    if [[ "$dirname" == .* ]] || [[ "$dirname" == "node_modules" ]]; then
      continue
    fi

    # Allow GitHub special directories (ISSUE_TEMPLATE, PULL_REQUEST_TEMPLATE, etc.)
    if [[ "$relpath" == .github/* ]] && [[ "$dirname" =~ ^[A-Z_]+$ ]]; then
      log_pass "$relpath/ (GitHub convention directory)"
      continue
    fi

    # Allow PascalCase for component directories (check if has index file)
    if [[ "$dirname" =~ $PASCAL_CASE_PATTERN ]] && [ -f "$dir/index.tsx" -o -f "$dir/index.ts" ]; then
      log_pass "$relpath/ (PascalCase component directory)"
      continue
    fi

    if [[ "$dirname" =~ $KEBAB_CASE_PATTERN ]]; then
      log_pass "$relpath/"
    else
      local suggested=$(to_kebab_case "$dirname")
      log_fail "$relpath/ (should be kebab-case)" "$suggested/"
    fi
  done < <(find "$search_path" -type d -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.claude-sync/*' -print0 2>/dev/null)
}

# Validate TypeScript/JavaScript files
validate_typescript() {
  local search_path="${1:-$REPO_DIR}"

  echo -e "\n${BLUE}Validating TypeScript/JavaScript names...${NC}"

  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local filename=$(basename "$file")
    local relpath="${file#$REPO_DIR/}"
    local name_without_ext="${filename%.*}"
    local ext="${filename##*.}"

    # Check for prohibited generic names
    for prohibited in "${PROHIBITED_NAMES[@]}"; do
      if [[ "$filename" == "$prohibited" ]]; then
        log_fail "$relpath (prohibited generic name - be more specific)"
        continue 2
      fi
    done

    # React components (.tsx) should be PascalCase
    if [[ "$ext" == "tsx" ]]; then
      # Skip test files
      if [[ "$filename" =~ \.(test|spec|e2e)\.tsx$ ]]; then
        local base="${filename%.test.tsx}"
        base="${base%.spec.tsx}"
        base="${base%.e2e.tsx}"
        if [[ "$base" =~ $PASCAL_CASE_PATTERN ]] || [[ "$base" =~ $KEBAB_CASE_PATTERN ]]; then
          log_pass "$relpath"
        else
          log_fail "$relpath (test file base name should be PascalCase or kebab-case)"
        fi
        continue
      fi

      # Index files are allowed
      if [[ "$filename" == "index.tsx" ]]; then
        log_pass "$relpath"
        continue
      fi

      if [[ "$name_without_ext" =~ $PASCAL_CASE_PATTERN ]]; then
        log_pass "$relpath"
      else
        log_fail "$relpath (React component should be PascalCase)"
      fi
      continue
    fi

    # TypeScript services/utilities (.ts) should be kebab-case
    if [[ "$ext" == "ts" ]]; then
      # Skip test files
      if [[ "$filename" =~ \.(test|spec|e2e|integration)\.ts$ ]]; then
        log_pass "$relpath"
        continue
      fi

      # Index files and config files are allowed
      if [[ "$filename" == "index.ts" ]] || [[ "$filename" =~ \.config\.ts$ ]] || [[ "$filename" =~ \.d\.ts$ ]]; then
        log_pass "$relpath"
        continue
      fi

      # Models/Classes can be PascalCase
      if [[ "$name_without_ext" =~ $PASCAL_CASE_PATTERN ]]; then
        log_pass "$relpath (PascalCase - assuming model/class)"
        continue
      fi

      # Services/utilities should be kebab-case
      if [[ "$name_without_ext" =~ $KEBAB_CASE_PATTERN ]]; then
        log_pass "$relpath"
      else
        local suggested=$(to_kebab_case "$name_without_ext").$ext
        log_fail "$relpath (should be kebab-case for services/utilities)" "$suggested"
      fi
    fi
  done < <(find "$search_path" \( -name "*.ts" -o -name "*.tsx" \) -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/.next/*' -not -path '*/dist/*' -print0 2>/dev/null)
}

# Check if skill name follows convention
# Returns: 0 = compliant, 1 = reorder needed, 2 = non-standard
check_skill_convention() {
  local skill="$1"

  # Utility skills without prefix are allowed
  if [[ "$skill" == "capture" ]] || [[ "$skill" == "example" ]]; then
    return 0
  fi

  # Check for valid prefix-action pattern
  for prefix in "${SKILL_PREFIXES[@]}"; do
    if [[ "$skill" == "${prefix}-"* ]]; then
      # Has valid prefix
      local action="${skill#${prefix}-}"
      # Check if action part is valid (contains valid action or compound)
      for valid_action in "${SKILL_ACTIONS[@]}"; do
        if [[ "$action" == "$valid_action" ]] || [[ "$action" == *"-${valid_action}" ]] || [[ "$action" == "${valid_action}-"* ]]; then
          return 0
        fi
      done
      # Has prefix but unknown action - still compliant structure
      return 0
    fi
  done

  # Check if it's action-prefix (needs reorder)
  for action in "${SKILL_ACTIONS[@]}"; do
    if [[ "$skill" == "${action}-"* ]]; then
      # e.g., close-issue should be issue-close
      return 1
    fi
  done

  # Non-standard pattern
  return 2
}

# Suggest corrected skill name
suggest_skill_name() {
  local skill="$1"

  # Mapping of known non-compliant names
  case "$skill" in
    "close-issue") echo "issue-close" ;;
    "close-milestone") echo "milestone-close" ;;
    "label-issue") echo "issue-label" ;;
    "init-repo") echo "repo-init" ;;
    "sync-repo") echo "repo-sync" ;;
    "new-milestone") echo "milestone-create" ;;
    "issues-checkout") echo "issue-checkout" ;;
    "issues-locks") echo "issue-locks" ;;
    "issues-release") echo "issue-release" ;;
    "action-audit") echo "audit-actions" ;;
    "claude-model-review") echo "audit-model-configs" ;;
    "metrics-review") echo "audit-metrics" ;;
    "skill-analyzer") echo "audit-skills" ;;
    "deploy-review") echo "repo-deploy-review" ;;
    "create-release-branch") echo "repo-create-release" ;;
    "milestones") echo "milestone-list" ;;
    "pr-to-main") echo "pr-promote-main" ;;
    "pr-to-qa") echo "pr-promote-qa" ;;
    "repo-audit-complete") echo "repo-audit-full" ;;
    "pm-triage") echo "issue-triage-bulk" ;;
    "update-skills") echo "skill-sync" ;;
    "wise-men-debate") echo "issue-prioritize" ;;
    *) echo "" ;;  # No suggestion
  esac
}

# Check if file is a deprecated alias (backwards compatibility redirect)
is_deprecated_alias() {
  local file="$1"
  # Check if file contains the deprecated alias marker
  grep -q "Deprecated Alias" "$file" 2>/dev/null
}

# Validate skill/command names
validate_skills() {
  local search_path="${1:-$REPO_DIR/core/commands}"

  echo -e "\n${BLUE}Validating skill/command names...${NC}"
  echo -e "  ${YELLOW}Convention: category-action (e.g., pr-merge, issue-close)${NC}"
  echo -e "  ${YELLOW}Prefixes: ${SKILL_PREFIXES[*]}${NC}"
  echo ""

  # Track violations by type for summary
  local compliant=0
  local needs_reorder=0
  local non_standard=0
  local aliases_skipped=0

  while IFS= read -r -d '' file; do
    local filename=$(basename "$file" .md)

    # Skip deprecated alias files (backwards compatibility redirects)
    if is_deprecated_alias "$file"; then
      ((aliases_skipped++)) || true
      if [ "$VERBOSE" = true ]; then
        echo -e "  ${BLUE}↪${NC} $filename (deprecated alias - skipped)"
      fi
      continue
    fi

    ((TOTAL++)) || true

    local result=0
    check_skill_convention "$filename" || result=$?

    case $result in
      0)
        ((compliant++)) || true
        log_pass "$filename"
        ;;
      1)
        ((needs_reorder++)) || true
        local suggested=$(suggest_skill_name "$filename")
        if [ -n "$suggested" ]; then
          log_fail "$filename (needs reorder to category-action)" "$suggested"
        else
          log_fail "$filename (needs reorder to category-action)"
        fi
        ;;
      2)
        ((non_standard++)) || true
        local suggested=$(suggest_skill_name "$filename")
        if [ -n "$suggested" ]; then
          log_warn "$filename (non-standard pattern)"
          if [ "$FIX_MODE" = true ]; then
            echo -e "    ${BLUE}→${NC} Suggested: $suggested"
          fi
        else
          log_warn "$filename (non-standard pattern - review manually)"
        fi
        ;;
    esac
  done < <(find "$search_path" -name "*.md" -type f -print0 2>/dev/null)

  echo ""
  echo -e "  Skill Summary: ${GREEN}$compliant compliant${NC}, ${RED}$needs_reorder need reorder${NC}, ${YELLOW}$non_standard non-standard${NC}"
  if [ "$aliases_skipped" -gt 0 ]; then
    echo -e "  ${BLUE}Skipped:${NC} $aliases_skipped deprecated aliases"
  fi
}

# Validate markdown files
validate_markdown() {
  local search_path="${1:-$REPO_DIR}"

  echo -e "\n${BLUE}Validating markdown file names...${NC}"

  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local filename=$(basename "$file")
    local relpath="${file#$REPO_DIR/}"

    # Skip files in specific directories that may have different conventions
    if [[ "$relpath" == core/commands/* ]] || [[ "$relpath" == packs/*/* ]]; then
      log_pass "$relpath (command/pack file - convention may vary)"
      continue
    fi

    # Standard docs should be UPPERCASE or lowercase
    if [[ "$filename" =~ $MD_UPPERCASE_PATTERN ]] || [[ "$filename" =~ $MD_LOWERCASE_PATTERN ]]; then
      log_pass "$relpath"
    else
      log_warn "$relpath (should be UPPERCASE.md or lowercase.md)"
    fi
  done < <(find "$search_path" -name "*.md" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null)
}

# Check for prohibited patterns
check_prohibited_patterns() {
  local search_path="${1:-$REPO_DIR}"

  echo -e "\n${BLUE}Checking for prohibited patterns...${NC}"

  # Check for spaces in filenames
  while IFS= read -r -d '' file; do
    ((TOTAL++)) || true
    local filename=$(basename "$file")
    local relpath="${file#$REPO_DIR/}"
    log_fail "$relpath (contains spaces - use hyphens instead)"
  done < <(find "$search_path" -name "* *" -type f -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null)

  # Check for underscores in directories (except Python, hidden dirs)
  while IFS= read -r -d '' dir; do
    ((TOTAL++)) || true
    local dirname=$(basename "$dir")
    local relpath="${dir#$REPO_DIR/}"

    # Skip Python dunder directories and hidden directories
    if [[ "$dirname" == __* ]] || [[ "$dirname" == .* ]]; then
      continue
    fi

    if [[ "$dirname" == *_* ]]; then
      local suggested=$(echo "$dirname" | tr '_' '-')
      log_fail "$relpath/ (contains underscores - use hyphens)" "$suggested/"
    fi
  done < <(find "$search_path" -type d -name "*_*" -not -path '*/.git/*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -print0 2>/dev/null)
}

# Print summary
print_summary() {
  echo ""
  echo "═══════════════════════════════════════════════════"
  echo -e "${BLUE}Naming Convention Validation Summary${NC}"
  echo "═══════════════════════════════════════════════════"
  echo -e "Total checked:  $TOTAL"
  echo -e "Passed:         ${GREEN}$PASSED${NC}"
  echo -e "Failed:         ${RED}$FAILED${NC}"
  echo -e "Warnings:       ${YELLOW}$WARNINGS${NC}"
  echo "═══════════════════════════════════════════════════"

  if [ "$FAILED" -gt 0 ]; then
    echo -e "\n${RED}Some naming conventions were violated.${NC}"
    echo "See: docs/standards/NAMING_CONVENTIONS.md"
    return 1
  else
    echo -e "\n${GREEN}All naming conventions passed!${NC}"
    return 0
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --path)
      CHECK_PATH="$2"
      shift 2
      ;;
    --type)
      CHECK_TYPE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --fix)
      FIX_MODE=true
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

# Determine search path
SEARCH_PATH="${CHECK_PATH:-$REPO_DIR}"
if [ ! -d "$SEARCH_PATH" ]; then
  echo "Error: Path does not exist: $SEARCH_PATH"
  exit 1
fi

echo "═══════════════════════════════════════════════════"
echo -e "${BLUE}Naming Convention Validator${NC}"
echo "═══════════════════════════════════════════════════"
echo "Search path: $SEARCH_PATH"
echo "Check type:  ${CHECK_TYPE:-all}"
echo ""

# Run validations based on type
case "${CHECK_TYPE:-all}" in
  scripts)
    validate_scripts "$SEARCH_PATH"
    ;;
  dirs)
    validate_directories "$SEARCH_PATH"
    ;;
  ts)
    validate_typescript "$SEARCH_PATH"
    ;;
  md)
    validate_markdown "$SEARCH_PATH"
    ;;
  skills)
    validate_skills "$REPO_DIR/core/commands"
    ;;
  all)
    validate_scripts "$SEARCH_PATH"
    validate_directories "$SEARCH_PATH"
    validate_typescript "$SEARCH_PATH"
    validate_markdown "$SEARCH_PATH"
    validate_skills "$REPO_DIR/core/commands"
    check_prohibited_patterns "$SEARCH_PATH"
    ;;
  *)
    echo "Unknown type: $CHECK_TYPE"
    echo "Valid types: scripts, dirs, ts, md, skills, all"
    exit 1
    ;;
esac

# Print summary and exit with appropriate code
print_summary
