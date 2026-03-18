#!/usr/bin/env bash
set -euo pipefail
#
# README Validation Script
# Validates README.md files for required sections and completeness
# Based on docs/templates/README_TEMPLATE.md requirements
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
TOTAL_CHECKS=0
PASSED=0
FAILED=0
WARNINGS=0

# Default settings
VERBOSE=false
TARGET_FILE=""
CHECK_ENV=true

print_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [README_PATH]

Validates README.md files for required sections and completeness.

Arguments:
  README_PATH         Path to README.md file (default: ./README.md)

Options:
  -v, --verbose       Show detailed output
  -q, --quiet         Only show errors
  --no-env-check      Skip .env.example requirement check
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Validate ./README.md
  $(basename "$0") path/to/README.md  # Validate specific file
  $(basename "$0") -v                 # Verbose validation
EOF
}

# Check for a required section
check_section() {
  local file="$1"
  local section="$2"
  local required="${3:-true}"

  ((TOTAL_CHECKS++)) || true

  if grep -qiE "^#+\s*$section" "$file" 2>/dev/null; then
    if [ "$VERBOSE" = true ]; then
      echo -e "  ${GREEN}✓${NC} Section: $section"
    fi
    ((PASSED++)) || true
    return 0
  else
    if [ "$required" = true ]; then
      echo -e "  ${RED}✗${NC} Missing required section: $section"
      ((FAILED++)) || true
      return 1
    else
      if [ "$VERBOSE" = true ]; then
        echo -e "  ${YELLOW}⚠${NC} Optional section missing: $section"
      fi
      ((WARNINGS++)) || true
      return 0
    fi
  fi
}

# Check for code blocks in a section
check_section_has_code() {
  local file="$1"
  local section="$2"

  # Extract content between section heading and next same-or-higher-level heading
  local content
  content=$(awk -v section="$section" '
    BEGIN { found=0; level=0; IGNORECASE=1 }
    /^#+/ {
      # Count heading level
      match($0, /^#+/)
      new_level = RLENGTH

      if (found && new_level <= level) exit

      # Check if this line matches the section pattern
      line = $0
      gsub(/^#+\s*/, "", line)
      if (match(line, section)) {
        found = 1
        level = new_level
      }
      next
    }
    found { print }
  ' "$file")

  if echo "$content" | grep -q '```'; then
    return 0
  else
    return 1
  fi
}

# Main validation function
validate_readme() {
  local file="$1"
  local dir
  dir=$(dirname "$file")

  echo -e "\n${BLUE}Validating:${NC} $file"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Check file exists
  if [ ! -f "$file" ]; then
    echo -e "${RED}ERROR:${NC} File not found: $file"
    return 1
  fi

  # Check file is not empty
  if [ ! -s "$file" ]; then
    echo -e "${RED}ERROR:${NC} File is empty: $file"
    return 1
  fi

  # Check minimum line count
  local line_count
  line_count=$(wc -l < "$file" | tr -d ' ')
  ((TOTAL_CHECKS++)) || true

  if [ "$line_count" -ge 50 ]; then
    if [ "$VERBOSE" = true ]; then
      echo -e "  ${GREEN}✓${NC} README has sufficient content ($line_count lines)"
    fi
    ((PASSED++)) || true
  else
    echo -e "  ${YELLOW}⚠${NC} README is minimal ($line_count lines, recommended: 50+)"
    ((WARNINGS++)) || true
  fi

  # Required sections per template
  echo -e "\n${BLUE}Required Sections:${NC}"
  check_section "$file" "Quick Start" true
  check_section "$file" "Testing|Tests|Running Tests" true

  # Check Environment Variables section (required if .env.example exists)
  if [ "$CHECK_ENV" = true ]; then
    if [ -f "$dir/.env.example" ] || [ -f "$REPO_DIR/.env.example" ]; then
      check_section "$file" "Environment Variables|Configuration" true
    else
      check_section "$file" "Environment Variables|Configuration" false
    fi
  fi

  # Recommended sections
  echo -e "\n${BLUE}Recommended Sections:${NC}"
  check_section "$file" "Project Structure|Repository Structure|Structure" false
  check_section "$file" "Installation|Setup|Getting Started" false
  check_section "$file" "Usage|How to Use|Examples" false
  check_section "$file" "Contributing" false
  check_section "$file" "License" false
  check_section "$file" "API|Endpoints" false

  # Check Quick Start has code examples
  ((TOTAL_CHECKS++)) || true
  if check_section_has_code "$file" "Quick Start"; then
    if [ "$VERBOSE" = true ]; then
      echo -e "  ${GREEN}✓${NC} Quick Start contains code examples"
    fi
    ((PASSED++)) || true
  else
    echo -e "  ${YELLOW}⚠${NC} Quick Start should contain code examples"
    ((WARNINGS++)) || true
  fi

  # Check Testing section has code examples
  ((TOTAL_CHECKS++)) || true
  if check_section_has_code "$file" "Testing\|Tests\|Running Tests"; then
    if [ "$VERBOSE" = true ]; then
      echo -e "  ${GREEN}✓${NC} Testing section contains code examples"
    fi
    ((PASSED++)) || true
  else
    echo -e "  ${YELLOW}⚠${NC} Testing section should contain code examples"
    ((WARNINGS++)) || true
  fi

  # Summary
  echo -e "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${BLUE}Summary:${NC}"
  echo -e "  Total checks: $TOTAL_CHECKS"
  echo -e "  ${GREEN}Passed:${NC} $PASSED"
  echo -e "  ${RED}Failed:${NC} $FAILED"
  echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"

  if [ "$FAILED" -gt 0 ]; then
    echo -e "\n${RED}Validation FAILED${NC}"
    return 1
  elif [ "$WARNINGS" -gt 0 ]; then
    echo -e "\n${YELLOW}Validation PASSED with warnings${NC}"
    return 0
  else
    echo -e "\n${GREEN}Validation PASSED${NC}"
    return 0
  fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -q|--quiet)
      VERBOSE=false
      shift
      ;;
    --no-env-check)
      CHECK_ENV=false
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
    *)
      TARGET_FILE="$1"
      shift
      ;;
  esac
done

# Set default target if not specified
if [ -z "$TARGET_FILE" ]; then
  TARGET_FILE="$REPO_DIR/README.md"
fi

# Run validation
validate_readme "$TARGET_FILE"
exit_code=$?

exit $exit_code
