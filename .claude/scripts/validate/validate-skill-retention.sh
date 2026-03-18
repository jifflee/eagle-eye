#!/usr/bin/env bash
#
# validate-skill-retention.sh - Validate skill retention and naming conventions
# Ensures all canonical skills in core/commands/ are properly deployed to .claude/commands/
# and validates colon naming convention compliance
#
# Usage:
#   ./scripts/validate-skill-retention.sh           # Run validation with summary
#   ./scripts/validate-skill-retention.sh --json    # Output JSON format for automation
#   ./scripts/validate-skill-retention.sh --verbose # Show detailed file-by-file comparison
#
# Exit codes:
#   0 - All checks passed
#   1 - Validation failures detected

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
OUTPUT_JSON=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) OUTPUT_JSON=true; shift ;;
    --verbose|-v) VERBOSE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--json] [--verbose]"
      echo ""
      echo "Options:"
      echo "  --json      Output results in JSON format"
      echo "  --verbose   Show detailed validation output"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Colors (disabled in JSON mode)
if [ "$OUTPUT_JSON" = false ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# Valid skill categories per naming convention
VALID_CATEGORIES=(
  "audit"
  "delivery"
  "issue"
  "local"
  "merge"
  "milestone"
  "ops"
  "pr"
  "release"
  "repo"
  "sprint"
  "tool"
  "validate"
)

# Validation state
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNINGS=0

# Detailed results
declare -a MISSING_SKILLS
declare -a ORPHANED_SKILLS
declare -a INVALID_NAMES
declare -a VALID_SKILLS

# Helper function to check if category is valid
is_valid_category() {
  local category="$1"
  for valid in "${VALID_CATEGORIES[@]}"; do
    if [ "$category" = "$valid" ]; then
      return 0
    fi
  done
  return 1
}

# Check 1: Validate colon naming convention in core/commands/
if [ "$OUTPUT_JSON" = false ]; then
  echo -e "${BLUE}=== Check 1: Colon Naming Convention ===${NC}"
fi

TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
NAMING_PASS=true

while IFS= read -r -d '' skill_file; do
  skill_name=$(basename "$skill_file" .md)

  # Check if name contains colon
  if [[ ! "$skill_name" =~ : ]]; then
    INVALID_NAMES+=("$skill_name (missing colon separator)")
    NAMING_PASS=false
    if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
      echo -e "  ${RED}FAIL${NC}: $skill_name - missing colon separator"
    fi
    continue
  fi

  # Extract category and action
  category="${skill_name%%:*}"
  action="${skill_name#*:}"

  # Validate category
  if ! is_valid_category "$category"; then
    INVALID_NAMES+=("$skill_name (invalid category: $category)")
    NAMING_PASS=false
    if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
      echo -e "  ${RED}FAIL${NC}: $skill_name - invalid category '$category'"
    fi
    continue
  fi

  # Validate action is not empty
  if [ -z "$action" ]; then
    INVALID_NAMES+=("$skill_name (empty action)")
    NAMING_PASS=false
    if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
      echo -e "  ${RED}FAIL${NC}: $skill_name - empty action name"
    fi
    continue
  fi

  VALID_SKILLS+=("$skill_name")
  if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${GREEN}PASS${NC}: $skill_name"
  fi
done < <(find "$REPO_DIR/core/commands" -type f -name "*.md" -print0 2>/dev/null || true)

if [ "$NAMING_PASS" = true ]; then
  PASSED_CHECKS=$((PASSED_CHECKS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${GREEN}✓ All skills use valid colon naming (${#VALID_SKILLS[@]} skills)${NC}"
  fi
else
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${RED}✗ Found ${#INVALID_NAMES[@]} skills with invalid naming${NC}"
  fi
fi

if [ "$OUTPUT_JSON" = false ]; then
  echo ""
fi

# Check 2: Validate deployment to .claude/commands/
if [ "$OUTPUT_JSON" = false ]; then
  echo -e "${BLUE}=== Check 2: Skill Deployment ===${NC}"
fi

TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
DEPLOYMENT_PASS=true

# Check each canonical skill is deployed
while IFS= read -r -d '' source_skill; do
  skill_name=$(basename "$source_skill" .md)
  target_skill="$REPO_DIR/.claude/commands/$skill_name.md"

  if [ ! -f "$target_skill" ]; then
    MISSING_SKILLS+=("$skill_name")
    DEPLOYMENT_PASS=false
    if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
      echo -e "  ${RED}MISSING${NC}: $skill_name"
    fi
  elif [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${GREEN}DEPLOYED${NC}: $skill_name"
  fi
done < <(find "$REPO_DIR/core/commands" -type f -name "*.md" -print0 2>/dev/null || true)

if [ "$DEPLOYMENT_PASS" = true ]; then
  PASSED_CHECKS=$((PASSED_CHECKS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${GREEN}✓ All canonical skills deployed to .claude/commands/${NC}"
  fi
else
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${RED}✗ Found ${#MISSING_SKILLS[@]} missing skills${NC}"
  fi
fi

if [ "$OUTPUT_JSON" = false ]; then
  echo ""
fi

# Check 3: Detect orphaned skills (in .claude/commands/ but not in core/commands/)
if [ "$OUTPUT_JSON" = false ]; then
  echo -e "${BLUE}=== Check 3: Orphaned Skills ===${NC}"
fi

TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
ORPHAN_CHECK_PASS=true

if [ -d "$REPO_DIR/.claude/commands" ]; then
  while IFS= read -r -d '' deployed_skill; do
    skill_name=$(basename "$deployed_skill" .md)
    source_skill="$REPO_DIR/core/commands/$skill_name.md"

    if [ ! -f "$source_skill" ]; then
      ORPHANED_SKILLS+=("$skill_name")
      ORPHAN_CHECK_PASS=false
      if [ "$VERBOSE" = true ] && [ "$OUTPUT_JSON" = false ]; then
        echo -e "  ${YELLOW}ORPHANED${NC}: $skill_name (no source in core/commands/)"
      fi
    fi
  done < <(find "$REPO_DIR/.claude/commands" -type f -name "*.md" -print0 2>/dev/null || true)
fi

if [ "$ORPHAN_CHECK_PASS" = true ]; then
  PASSED_CHECKS=$((PASSED_CHECKS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${GREEN}✓ No orphaned skills detected${NC}"
  fi
else
  WARNINGS=$((WARNINGS + 1))
  if [ "$OUTPUT_JSON" = false ]; then
    echo -e "  ${YELLOW}⚠ Found ${#ORPHANED_SKILLS[@]} orphaned skills${NC}"
  fi
fi

if [ "$OUTPUT_JSON" = false ]; then
  echo ""
fi

# Summary
if [ "$OUTPUT_JSON" = false ]; then
  echo -e "${BLUE}=== Summary ===${NC}"
  echo "  Total checks: $TOTAL_CHECKS"
  echo -e "  ${GREEN}Passed${NC}: $PASSED_CHECKS"
  echo -e "  ${RED}Failed${NC}: $FAILED_CHECKS"
  if [ "$WARNINGS" -gt 0 ]; then
    echo -e "  ${YELLOW}Warnings${NC}: $WARNINGS"
  fi
  echo ""
  # Count array elements safely
  set +u
  valid_count=${#VALID_SKILLS[@]}
  invalid_count=${#INVALID_NAMES[@]}
  missing_count=${#MISSING_SKILLS[@]}
  orphaned_count=${#ORPHANED_SKILLS[@]}
  set -u

  echo "  Valid skills: $valid_count"
  echo "  Invalid names: $invalid_count"
  echo "  Missing skills: $missing_count"
  echo "  Orphaned skills: $orphaned_count"
  echo ""

  if [ "$FAILED_CHECKS" -eq 0 ]; then
    echo -e "${GREEN}✓ ALL CHECKS PASSED${NC}"
  else
    echo -e "${RED}✗ VALIDATION FAILED${NC}"
    echo ""

    set +u
    if [ "${invalid_count}" -gt 0 ]; then
      echo -e "${RED}Invalid skill names:${NC}"
      for skill in "${INVALID_NAMES[@]}"; do
        echo "  - $skill"
      done
      echo ""
    fi

    if [ "${missing_count}" -gt 0 ]; then
      echo -e "${RED}Missing deployed skills:${NC}"
      for skill in "${MISSING_SKILLS[@]}"; do
        echo "  - $skill"
      done
      echo ""
    fi
    set -u
  fi

  set +u
  if [ "${orphaned_count}" -gt 0 ]; then
    echo -e "${YELLOW}Orphaned skills (deployed but no source):${NC}"
    for skill in "${ORPHANED_SKILLS[@]}"; do
      echo "  - $skill"
    done
    echo ""
  fi
  set -u
else
  # JSON output
  set +u
  valid_count=${#VALID_SKILLS[@]}
  invalid_count=${#INVALID_NAMES[@]}
  missing_count=${#MISSING_SKILLS[@]}
  orphaned_count=${#ORPHANED_SKILLS[@]}

  # Build JSON arrays safely
  valid_json="$(printf '%s\n' "${VALID_SKILLS[@]}" 2>/dev/null | jq -R . | jq -s . || echo '[]')"
  invalid_json="$(printf '%s\n' "${INVALID_NAMES[@]}" 2>/dev/null | jq -R . | jq -s . || echo '[]')"
  missing_json="$(printf '%s\n' "${MISSING_SKILLS[@]}" 2>/dev/null | jq -R . | jq -s . || echo '[]')"
  orphaned_json="$(printf '%s\n' "${ORPHANED_SKILLS[@]}" 2>/dev/null | jq -R . | jq -s . || echo '[]')"
  set -u

  jq -n \
    --arg status "$([ "$FAILED_CHECKS" -eq 0 ] && echo "PASS" || echo "FAIL")" \
    --argjson total "$TOTAL_CHECKS" \
    --argjson passed "$PASSED_CHECKS" \
    --argjson failed "$FAILED_CHECKS" \
    --argjson warnings "$WARNINGS" \
    --argjson valid_count "$valid_count" \
    --argjson invalid_count "$invalid_count" \
    --argjson missing_count "$missing_count" \
    --argjson orphaned_count "$orphaned_count" \
    --argjson valid_skills "$valid_json" \
    --argjson invalid_names "$invalid_json" \
    --argjson missing_skills "$missing_json" \
    --argjson orphaned_skills "$orphaned_json" \
    '{
      status: $status,
      checks: {
        total: $total,
        passed: $passed,
        failed: $failed,
        warnings: $warnings
      },
      skills: {
        valid_count: $valid_count,
        invalid_count: $invalid_count,
        missing_count: $missing_count,
        orphaned_count: $orphaned_count
      },
      details: {
        valid_skills: $valid_skills,
        invalid_names: $invalid_names,
        missing_skills: $missing_skills,
        orphaned_skills: $orphaned_skills
      }
    }'
fi

# Exit with appropriate code
if [ "$FAILED_CHECKS" -eq 0 ]; then
  exit 0
else
  exit 1
fi
