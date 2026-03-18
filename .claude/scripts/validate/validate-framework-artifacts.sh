#!/usr/bin/env bash
#
# validate-framework-artifacts.sh - Enforce standards for skills, hooks, and actions
# Feature #1021 - Add enforcement guardrails for skills, hooks, and actions
#
# Usage:
#   ./scripts/validate-framework-artifacts.sh              # Validate all artifacts
#   ./scripts/validate-framework-artifacts.sh --skills     # Validate skills only
#   ./scripts/validate-framework-artifacts.sh --hooks      # Validate hooks only
#   ./scripts/validate-framework-artifacts.sh --actions    # Validate actions only
#   ./scripts/validate-framework-artifacts.sh --json       # JSON output
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation errors found
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
CLAUDE_DIR="$REPO_ROOT/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
TIER_REGISTRY="$CLAUDE_DIR/tier-registry.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
TOTAL_CHECKED=0

# Options
VALIDATE_SKILLS=true
VALIDATE_HOOKS=true
VALIDATE_ACTIONS=true
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skills)
      VALIDATE_HOOKS=false
      VALIDATE_ACTIONS=false
      shift
      ;;
    --hooks)
      VALIDATE_SKILLS=false
      VALIDATE_ACTIONS=false
      shift
      ;;
    --actions)
      VALIDATE_SKILLS=false
      VALIDATE_HOOKS=false
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --skills      Validate skills only"
      echo "  --hooks       Validate hooks only"
      echo "  --actions     Validate actions only"
      echo "  --json        Output as JSON"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ===========================
# SKILL VALIDATION
# ===========================

validate_skills() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${BLUE}Validating Skills...${NC}"

  [ ! -d "$COMMANDS_DIR" ] && return

  for skill_file in "$COMMANDS_DIR"/*.md; do
    [ -f "$skill_file" ] || continue
    ((TOTAL_CHECKED++))

    local skill_name=$(basename "$skill_file" .md)
    local has_error=false

    # Check 1: YAML frontmatter
    local fm_count=$(grep -c "^---$" "$skill_file" 2>/dev/null || echo 0)
    if [ "$fm_count" -lt 2 ]; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $skill_name: Missing YAML frontmatter${NC}"
      ((TOTAL_ERRORS++))
      has_error=true
      continue
    fi

    # Check 2: Required field - description
    local fm=$(sed -n '/^---$/,/^---$/p' "$skill_file" | sed '1d;$d')
    if ! echo "$fm" | grep -q "^description:"; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $skill_name: Missing 'description' field${NC}"
      ((TOTAL_ERRORS++))
      has_error=true
    fi

    # Check 3: Kebab-case naming
    if [[ ! "$skill_name" =~ ^[a-z]+(-[a-z0-9]+)*$ ]]; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $skill_name: Must be kebab-case${NC}"
      ((TOTAL_ERRORS++))
      has_error=true
    fi

    # Check 4: Content after frontmatter
    local content=$(awk '/^---$/{++n; next} n==2' "$skill_file")
    if [ -z "$content" ] || [ "$(echo "$content" | tr -d '[:space:]')" = "" ]; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $skill_name: Missing content${NC}"
      ((TOTAL_ERRORS++))
      has_error=true
    fi

    # Success
    if [ "$has_error" = false ] && [ "$JSON_OUTPUT" = false ]; then
      echo -e "${GREEN}✓ $skill_name${NC}"
    fi
  done
}

# ===========================
# HOOK VALIDATION
# ===========================

validate_hooks() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${BLUE}Validating Hooks...${NC}"

  # Check settings.json
  if [ ! -f "$SETTINGS_FILE" ]; then
    [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ settings.json not found${NC}"
    ((TOTAL_ERRORS++))
    return
  fi

  if ! jq empty "$SETTINGS_FILE" 2>/dev/null; then
    [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ settings.json invalid JSON${NC}"
    ((TOTAL_ERRORS++))
    return
  fi

  ((TOTAL_CHECKED++))

  # Extract all hook commands to a temp file to avoid subshell issues
  local tmpfile=$(mktemp)
  jq -r '.hooks | .. | .command? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u > "$tmpfile"

  while IFS= read -r hook_cmd; do
    [ -z "$hook_cmd" ] && continue
    ((TOTAL_CHECKED++))

    local hook_file="$REPO_ROOT/$hook_cmd"
    local hook_name=$(basename "$hook_cmd")

    if [ ! -f "$hook_file" ]; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $hook_name: File not found${NC}"
      ((TOTAL_ERRORS++))
    elif [ ! -x "$hook_file" ]; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $hook_name: Not executable${NC}"
      ((TOTAL_ERRORS++))
    elif ! head -1 "$hook_file" | grep -q '^#!'; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${YELLOW}⚠ $hook_name: Missing shebang${NC}"
      ((TOTAL_WARNINGS++))
    else
      [ "$JSON_OUTPUT" = false ] && echo -e "${GREEN}✓ $hook_name${NC}"
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"

  # Check orphaned hooks
  if [ -d "$HOOKS_DIR" ]; then
    local registered=$(jq -r '.hooks | .. | .command? // empty' "$SETTINGS_FILE" 2>/dev/null | sort -u)

    for hook_file in "$HOOKS_DIR"/*; do
      [ -f "$hook_file" ] || continue

      local hook_path=".claude/hooks/$(basename "$hook_file")"

      if ! echo "$registered" | grep -Fxq "$hook_path"; then
        [ "$JSON_OUTPUT" = false ] && echo -e "${YELLOW}⚠ Orphaned: $(basename "$hook_file")${NC}"
        ((TOTAL_WARNINGS++))
      fi
    done
  fi
}

# ===========================
# ACTION VALIDATION
# ===========================

validate_actions() {
  [ "$JSON_OUTPUT" = false ] && echo -e "${BLUE}Validating Actions...${NC}"

  if [ ! -f "$TIER_REGISTRY" ]; then
    [ "$JSON_OUTPUT" = false ] && echo -e "${YELLOW}⚠ tier-registry.json not found${NC}"
    return
  fi

  if ! jq empty "$TIER_REGISTRY" 2>/dev/null; then
    [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ tier-registry.json invalid JSON${NC}"
    ((TOTAL_ERRORS++))
    return
  fi

  ((TOTAL_CHECKED++))

  local valid_tiers="T0 T1 T2 T3"
  local has_error=false

  # Extract all tier assignments to temp file
  local tmpfile=$(mktemp)
  jq -r '.categories | to_entries[] | .key as $cat | .value | to_entries[] | "\($cat).\(.key)=\(.value)"' "$TIER_REGISTRY" 2>/dev/null > "$tmpfile"

  while IFS='=' read -r operation tier; do
    [ -z "$operation" ] && continue
    ((TOTAL_CHECKED++))

    if ! echo "$valid_tiers" | grep -q "\<$tier\>"; then
      [ "$JSON_OUTPUT" = false ] && echo -e "${RED}✗ $operation: Invalid tier $tier${NC}"
      ((TOTAL_ERRORS++))
      has_error=true
    else
      [ "$JSON_OUTPUT" = false ] && echo -e "${GREEN}✓ $operation ($tier)${NC}"
    fi
  done < "$tmpfile"

  rm -f "$tmpfile"
}

# ===========================
# MAIN EXECUTION
# ===========================

main() {
  [ "$VALIDATE_SKILLS" = true ] && validate_skills
  [ "$VALIDATE_HOOKS" = true ] && validate_hooks
  [ "$VALIDATE_ACTIONS" = true ] && validate_actions

  if [ "$JSON_OUTPUT" = true ]; then
    cat <<EOF
{
  "summary": {
    "total_checked": $TOTAL_CHECKED,
    "total_errors": $TOTAL_ERRORS,
    "total_warnings": $TOTAL_WARNINGS,
    "status": "$([ $TOTAL_ERRORS -eq 0 ] && echo "passed" || echo "failed")",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  }
}
EOF
  else
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "Framework Artifacts Validation Summary"
    echo "═══════════════════════════════════════════════════════════"
    echo "Total Checked:  $TOTAL_CHECKED"
    echo -e "Errors:         ${RED}$TOTAL_ERRORS${NC}"
    echo -e "Warnings:       ${YELLOW}$TOTAL_WARNINGS${NC}"
    echo "═══════════════════════════════════════════════════════════"

    if [ $TOTAL_ERRORS -eq 0 ]; then
      echo -e "${GREEN}✓ All validations passed${NC}"
    else
      echo -e "${RED}✗ Validation failed with $TOTAL_ERRORS errors${NC}"
    fi
    echo "═══════════════════════════════════════════════════════════"
  fi

  [ $TOTAL_ERRORS -gt 0 ] && exit 1 || exit 0
}

main
