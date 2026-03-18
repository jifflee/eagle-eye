#!/bin/bash
set -euo pipefail
# validate-environment-tier.sh
# Validates that promoted code complies with environment tier restrictions
#
# Usage:
#   ./scripts/ci/validate-environment-tier.sh <tier>
#   ./scripts/ci/validate-environment-tier.sh qa
#   ./scripts/ci/validate-environment-tier.sh prod
#   ./scripts/ci/validate-environment-tier.sh --dry-run qa
#
# Exit codes:
#   0 - Tier validation passed
#   1 - Tier violations found (blocking)
#   2 - Warnings found (non-blocking)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Default configuration
DRY_RUN=false
TARGET_TIER=""
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    qa|prod|dev)
      TARGET_TIER="$1"
      shift
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--dry-run] [--verbose] <tier>"
      echo "  tier: qa, prod, or dev"
      exit 1
      ;;
  esac
done

# Validate tier argument
if [ -z "$TARGET_TIER" ]; then
  echo "Error: Target tier required (qa or prod)"
  echo "Usage: $0 [--dry-run] <tier>"
  exit 1
fi

# Define tier restrictions
# Format: pattern|tier|violation_type|message
declare -a TIER_RULES=(
  # Development-only tools (not allowed in qa or prod)
  "scripts/dev-tools/*|qa,prod|error|Development tools not allowed in qa/prod"
  "scripts/scaffold-*|qa,prod|error|Scaffolding scripts not allowed in qa/prod"
  ".claude/agents/*refactor*|qa,prod|warning|Refactoring agents typically not needed in qa/prod"

  # Testing tools (not allowed in prod)
  "scripts/test-*|prod|error|Test scripts not allowed in prod"
  ".claude/commands/test-*|prod|error|Test commands not allowed in prod"
  "scripts/ci/test-*|prod|warning|CI test scripts typically not needed in prod"

  # QA-only tools (not allowed in prod)
  ".claude/agents/test-qa*|prod|error|QA-specific agents not allowed in prod"
  "scripts/qa-*|prod|error|QA scripts not allowed in prod"

  # Development agents (not allowed in prod, warning in qa)
  ".claude/agents/backend-developer.md|prod|error|Development agents not allowed in prod"
  ".claude/agents/frontend-developer.md|prod|error|Development agents not allowed in prod"
  ".claude/agents/backend-developer.md|qa|warning|Development agents typically not needed in qa"
  ".claude/agents/frontend-developer.md|qa|warning|Development agents typically not needed in qa"
)

# Tracking
ERRORS=0
WARNINGS=0
declare -a ERROR_MESSAGES=()
declare -a WARNING_MESSAGES=()

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    echo "$@"
  fi
}

# Check if file matches pattern and tier
check_file_against_rules() {
  local file="$1"
  local relative_path="${file#$REPO_ROOT/}"

  log_verbose "Checking: $relative_path"

  for rule in "${TIER_RULES[@]}"; do
    IFS='|' read -r pattern tiers violation_type message <<< "$rule"

    # Check if this rule applies to target tier
    if [[ ",$tiers," != *",$TARGET_TIER,"* ]]; then
      continue
    fi

    # Check if file matches pattern
    if [[ "$relative_path" == $pattern ]]; then
      if [ "$violation_type" = "error" ]; then
        ERRORS=$((ERRORS + 1))
        ERROR_MESSAGES+=("❌ $relative_path: $message")
      else
        WARNINGS=$((WARNINGS + 1))
        WARNING_MESSAGES+=("⚠️  $relative_path: $message")
      fi
      log_verbose "  → Violation: $violation_type - $message"
    fi
  done
}

# Main validation
echo "==================================================================="
echo "Environment Tier Validation"
echo "==================================================================="
echo ""
echo "Target Tier: $TARGET_TIER"
echo "Repository: $REPO_ROOT"
if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN (no enforcement)"
fi
echo ""

# Find all files in repository (excluding .git)
log_verbose "Scanning repository files..."

while IFS= read -r -d '' file; do
  check_file_against_rules "$file"
done < <(find "$REPO_ROOT" -type f -not -path "*/\.git/*" -print0)

# Report results
echo "==================================================================="
echo "Validation Results"
echo "==================================================================="
echo ""

if [ ${#ERROR_MESSAGES[@]} -gt 0 ]; then
  echo -e "${RED}ERRORS (${#ERROR_MESSAGES[@]}):${NC}"
  printf '%s\n' "${ERROR_MESSAGES[@]}"
  echo ""
fi

if [ ${#WARNING_MESSAGES[@]} -gt 0 ]; then
  echo -e "${YELLOW}WARNINGS (${#WARNING_MESSAGES[@]}):${NC}"
  printf '%s\n' "${WARNING_MESSAGES[@]}"
  echo ""
fi

# Summary
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
  echo -e "${GREEN}✅ Tier validation passed${NC}"
  echo "No violations found for tier: $TARGET_TIER"
  exit 0
elif [ $ERRORS -eq 0 ]; then
  echo -e "${YELLOW}⚠️  Tier validation passed with warnings${NC}"
  echo "Errors: $ERRORS"
  echo "Warnings: $WARNINGS"
  echo ""
  echo "Warnings are non-blocking but should be reviewed."

  if [ "$DRY_RUN" = true ]; then
    exit 0
  else
    exit 2  # Non-blocking warnings
  fi
else
  echo -e "${RED}❌ Tier validation FAILED${NC}"
  echo "Errors: $ERRORS (blocking)"
  echo "Warnings: $WARNINGS"
  echo ""
  echo "Fix errors before promoting to $TARGET_TIER."

  if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "(Dry run mode - would fail in enforcement mode)"
    exit 0
  else
    exit 1  # Blocking errors
  fi
fi
