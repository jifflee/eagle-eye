#!/usr/bin/env bash
set -euo pipefail
#
# Agent Validation Script
# Validates agent definition files for correctness and consistency
# Supports pack-based architecture with core + packs + domains
# size-ok: multi-pack agent validation with format, field, and consistency checks
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

# Function to validate a single agent file
validate_agent() {
  local file="$1"
  local filename=$(basename "$file")
  local agent_name="${filename%.md}"
  local errors=0
  local warnings=0

  echo "  Validating: $filename"

  # Check 1: File must be .md
  if [[ ! "$filename" =~ \.md$ ]]; then
    echo -e "    ${RED}✗${NC} File must have .md extension"
    ((errors++)) || true
  fi

  # Check 2: Filename must be kebab-case
  if [[ ! "$agent_name" =~ ^[a-z]+(-[a-z]+)*$ ]]; then
    echo -e "    ${RED}✗${NC} Filename must be kebab-case (lowercase with hyphens)"
    ((errors++)) || true
  fi

  # Check 3: File must not be empty
  if [ ! -s "$file" ]; then
    echo -e "    ${RED}✗${NC} File is empty"
    ((errors++)) || true
    return $errors
  fi

  # Extract YAML frontmatter
  local frontmatter=$(sed -n '/^---$/,/^---$/p' "$file" | sed '1d;$d')

  # Check 4: Must have YAML frontmatter
  if [ -z "$frontmatter" ]; then
    echo -e "    ${RED}✗${NC} Missing YAML frontmatter (must start and end with ---)"
    ((errors++)) || true
    return $errors
  fi

  # Check 5: Must have 'name' field
  local yaml_name=$(echo "$frontmatter" | grep '^name:' | sed 's/name: *//' | tr -d '"' | tr -d "'" | xargs)
  if [ -z "$yaml_name" ]; then
    echo -e "    ${RED}✗${NC} Missing 'name' field in frontmatter"
    ((errors++)) || true
  elif [ "$yaml_name" != "$agent_name" ]; then
    echo -e "    ${RED}✗${NC} Name field '$yaml_name' doesn't match filename '$agent_name'"
    ((errors++)) || true
  fi

  # Check 6: Must have 'description' field
  local description=$(echo "$frontmatter" | grep '^description:' | sed 's/description: *//')
  if [ -z "$description" ]; then
    echo -e "    ${RED}✗${NC} Missing 'description' field in frontmatter"
    ((errors++)) || true
  else
    if [[ ! "$description" =~ ^Use\ this\ agent ]]; then
      echo -e "    ${YELLOW}⚠${NC} Description should start with 'Use this agent to...'"
      ((warnings++)) || true
    fi
  fi

  # Check 7: Must have 'model' field
  local model=$(echo "$frontmatter" | grep '^model:' | sed 's/model: *//' | tr -d '"' | tr -d "'" | xargs)
  if [ -z "$model" ]; then
    echo -e "    ${RED}✗${NC} Missing 'model' field in frontmatter"
    ((errors++)) || true
  elif [[ ! "$model" =~ ^(sonnet|opus|haiku)$ ]]; then
    echo -e "    ${YELLOW}⚠${NC} Model should be 'sonnet', 'opus', or 'haiku' (found: '$model')"
    ((warnings++)) || true
  fi

  # Extract content after frontmatter
  local content=$(awk '/^---$/{++n; next} n==2' "$file")

  # Check 8: Must have content after frontmatter
  if [ -z "$content" ] || [ "$(echo "$content" | tr -d '[:space:]')" = "" ]; then
    echo -e "    ${RED}✗${NC} Missing agent system prompt (content after frontmatter)"
    ((errors++)) || true
  fi

  # Check 9: Should have key sections
  local has_role=$(echo "$content" | grep -i "## ROLE" || true)
  local has_objectives=$(echo "$content" | grep -i "## PRIMARY OBJECTIVES\|## OBJECTIVES" || true)
  local has_boundaries=$(echo "$content" | grep -i "## BOUNDARIES" || true)

  if [ -z "$has_role" ]; then
    echo -e "    ${YELLOW}⚠${NC} Missing '## ROLE' section"
    ((warnings++)) || true
  fi

  if [ -z "$has_objectives" ]; then
    echo -e "    ${YELLOW}⚠${NC} Missing '## OBJECTIVES' section"
    ((warnings++)) || true
  fi

  if [ -z "$has_boundaries" ]; then
    echo -e "    ${YELLOW}⚠${NC} Missing '## BOUNDARIES' section"
    ((warnings++)) || true
  fi

  # Summary for this file
  if [ $errors -eq 0 ]; then
    if [ $warnings -eq 0 ]; then
      echo -e "    ${GREEN}✓${NC} Valid"
    else
      echo -e "    ${GREEN}✓${NC} Valid (with $warnings warning(s))"
    fi
    return 0
  else
    echo -e "    ${RED}✗${NC} Failed with $errors error(s)"
    return $errors
  fi
}

# Validate agents in a directory
validate_directory() {
  local dir="$1"
  local label="$2"

  if [ ! -d "$dir" ]; then
    return 0
  fi

  local agent_files=$(find "$dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)

  if [ -z "$agent_files" ]; then
    return 0
  fi

  echo ""
  echo -e "${BLUE}📁 $label${NC}"
  echo "   Path: $dir"
  echo ""

  while IFS= read -r file; do
    # Use || true to prevent set -e exit on zero result (bash 5.x behavior)
    ((TOTAL++)) || true

    if validate_agent "$file"; then
      ((PASSED++)) || true
    else
      ((FAILED++)) || true
    fi

    echo ""
  done <<< "$agent_files"
}

# Check for duplicate agent names
check_duplicates() {
  echo ""
  echo "🔍 Checking for duplicate agent names..."

  local ALL_AGENTS=""

  # Core
  if [ -d "$REPO_DIR/core/agents" ]; then
    for f in "$REPO_DIR"/core/agents/*.md; do
      [ -f "$f" ] && ALL_AGENTS+="$(basename "$f")|core"$'\n'
    done
  fi

  # Packs
  for pack_dir in "$REPO_DIR"/packs/*/agents; do
    if [ -d "$pack_dir" ]; then
      pack_name=$(basename "$(dirname "$pack_dir")")
      for f in "$pack_dir"/*.md; do
        [ -f "$f" ] && ALL_AGENTS+="$(basename "$f")|packs/$pack_name"$'\n'
      done
    fi
  done

  # Domains
  for domain_dir in "$REPO_DIR"/domains/*/agents; do
    if [ -d "$domain_dir" ]; then
      domain_name=$(basename "$(dirname "$domain_dir")")
      for f in "$domain_dir"/*.md; do
        [ -f "$f" ] && ALL_AGENTS+="$(basename "$f")|domains/$domain_name"$'\n'
      done
    fi
  done

  local duplicates=$(echo "$ALL_AGENTS" | cut -d'|' -f1 | sort | uniq -d)

  if [ -n "$duplicates" ]; then
    echo -e "${RED}❌ Found duplicate agent names:${NC}"
    while IFS= read -r dup; do
      [ -z "$dup" ] && continue
      echo "  - $dup found in:"
      echo "$ALL_AGENTS" | grep "^$dup|" | cut -d'|' -f2 | sed 's/^/      /'
    done <<< "$duplicates"
    ((FAILED++)) || true
  else
    echo -e "${GREEN}✓${NC} No duplicate agent names"
  fi
}

# Show help
show_help() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Validates agent definition files for correctness and consistency."
  echo ""
  echo "Options:"
  echo "  --all          Validate all agents (core + packs + domains)"
  echo "  --core         Validate core agents only"
  echo "  --pack X       Validate specific pack"
  echo "  --domain X     Validate specific domain"
  echo "  --help         Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --all                    # Validate everything"
  echo "  $0 --core                   # Validate core only"
  echo "  $0 --pack quality           # Validate quality pack"
  echo "  $0 --domain finance         # Validate finance domain"
}

# Main
main() {
  echo "🔍 Agent Validation Script"
  echo "   Repository: $REPO_DIR"

  case "${1:-}" in
    --all|"")
      # Validate all
      validate_directory "$REPO_DIR/core/agents" "Core Agents"

      for pack_dir in "$REPO_DIR"/packs/*/agents; do
        if [ -d "$pack_dir" ]; then
          pack_name=$(basename "$(dirname "$pack_dir")")
          validate_directory "$pack_dir" "Pack: $pack_name"
        fi
      done

      for domain_dir in "$REPO_DIR"/domains/*/agents; do
        if [ -d "$domain_dir" ]; then
          domain_name=$(basename "$(dirname "$domain_dir")")
          validate_directory "$domain_dir" "Domain: $domain_name"
        fi
      done

      check_duplicates
      ;;

    --core)
      validate_directory "$REPO_DIR/core/agents" "Core Agents"
      ;;

    --pack)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --pack requires a pack name${NC}"
        exit 1
      fi
      validate_directory "$REPO_DIR/packs/$2/agents" "Pack: $2"
      ;;

    --domain)
      if [ -z "${2:-}" ]; then
        echo -e "${RED}Error: --domain requires a domain name${NC}"
        exit 1
      fi
      validate_directory "$REPO_DIR/domains/$2/agents" "Domain: $2"
      ;;

    --help|-h)
      show_help
      exit 0
      ;;

    *)
      # Validate specific directory
      if [ -d "$1" ]; then
        validate_directory "$1" "Custom Directory"
      else
        echo -e "${RED}Error: Unknown option or directory '$1'${NC}"
        show_help
        exit 1
      fi
      ;;
  esac

  # Summary
  echo ""
  echo "═══════════════════════════════════════"
  echo "Summary:"
  echo "  Total agents: $TOTAL"
  echo -e "  ${GREEN}Passed: $PASSED${NC}"
  if [ $FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: $FAILED${NC}"
  fi
  if [ $WARNINGS -gt 0 ]; then
    echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
  fi
  echo "═══════════════════════════════════════"

  if [ $FAILED -gt 0 ]; then
    echo -e "${RED}❌ Validation failed${NC}"
    exit 1
  else
    echo -e "${GREEN}✅ All validations passed${NC}"
    exit 0
  fi
}

main "$@"
