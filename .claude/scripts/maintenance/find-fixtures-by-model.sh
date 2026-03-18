#!/usr/bin/env bash
# ============================================================
# Script: find-fixtures-by-model.sh
# Purpose: Find all fixture files related to a specific model
# Usage: ./scripts/maintenance/find-fixtures-by-model.sh <ModelName> [--verbose]
# Dependencies: none
# ============================================================

set -euo pipefail

# Configuration
FIXTURE_DIR="tests/fixtures"
MODEL_NAME="${1:-}"
VERBOSE="${2:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $0 <ModelName> [--verbose]

Find all fixture files related to a specific model.

Arguments:
  ModelName    Name of the model to search for (e.g., User, Product, Order)

Options:
  --verbose    Show detailed information about matches

Examples:
  $0 User
  $0 Product --verbose
  $0 Order

Search Strategy:
  1. Files in model-specific directories (e.g., users/ for User model)
  2. JSON files containing probable model field names
  3. References to the model name in _metadata
  4. SQL seed files with table references

EOF
  exit 1
}

# Validate arguments
if [ -z "$MODEL_NAME" ]; then
  echo -e "${RED}Error: Model name is required${NC}"
  echo ""
  usage
fi

# Check if fixture directory exists
if [ ! -d "$FIXTURE_DIR" ]; then
  echo -e "${YELLOW}Warning: Fixture directory not found: $FIXTURE_DIR${NC}"
  exit 0
fi

echo -e "${BLUE}Searching for fixtures related to model: $MODEL_NAME${NC}"
echo ""

FOUND_COUNT=0
declare -a FOUND_FILES=()

# Convert model name to different formats for searching
MODEL_LOWER=$(echo "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')
MODEL_PLURAL="${MODEL_LOWER}s"
MODEL_SNAKE=$(echo "$MODEL_NAME" | sed 's/\([A-Z]\)/_\1/g' | tr '[:upper:]' '[:lower:]' | sed 's/^_//')

# Search strategy 1: Model-specific directories
echo "## Strategy 1: Directory-based search"
while IFS= read -r dir; do
  [ -d "$dir" ] || continue

  # Find JSON and SQL files in this directory
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    FOUND_FILES+=("$file")
    echo -e "${GREEN}Found in${NC} $file (directory match)"
    ((FOUND_COUNT++))

    if [ "$VERBOSE" = "--verbose" ]; then
      echo "  Reason: Located in model-specific directory"
      if [[ "$file" == *.json ]]; then
        echo "  Preview: $(jq -r 'keys | .[0:3] | join(", ")' "$file" 2>/dev/null || echo "N/A")"
      fi
      echo ""
    fi
  done < <(find "$dir" -maxdepth 1 -type f \( -name "*.json" -o -name "*.sql" \) 2>/dev/null)
done < <(find "$FIXTURE_DIR" -type d -name "$MODEL_LOWER" -o -name "$MODEL_PLURAL" 2>/dev/null)

if [ "$FOUND_COUNT" -eq 0 ]; then
  echo "No fixtures found in model-specific directories"
fi
echo ""

# Search strategy 2: Metadata references
echo "## Strategy 2: Metadata reference search"
METADATA_COUNT=0

while IFS= read -r file; do
  [ -f "$file" ] || continue

  # Skip if already found
  if [[ " ${FOUND_FILES[*]} " =~ " ${file} " ]]; then
    continue
  fi

  # Check if model name appears in metadata
  if jq -e "._metadata | tostring | test(\"$MODEL_NAME\"; \"i\")" "$file" >/dev/null 2>&1; then
    FOUND_FILES+=("$file")
    echo -e "${GREEN}Found in${NC} $file (metadata reference)"
    ((FOUND_COUNT++))
    ((METADATA_COUNT++))

    if [ "$VERBOSE" = "--verbose" ]; then
      echo "  Reason: Model referenced in _metadata"
      METADATA_SOURCE=$(jq -r '._metadata.source // "N/A"' "$file" 2>/dev/null)
      echo "  Source: $METADATA_SOURCE"
      echo ""
    fi
  fi
done < <(find "$FIXTURE_DIR" -type f -name "*.json" 2>/dev/null)

if [ "$METADATA_COUNT" -eq 0 ]; then
  echo "No fixtures found with metadata references"
fi
echo ""

# Search strategy 3: Field name patterns
echo "## Strategy 3: Field pattern search"
FIELD_COUNT=0

# Common field patterns based on model name
FIELD_PATTERNS=(
  "${MODEL_LOWER}Id"
  "${MODEL_LOWER}_id"
  "${MODEL_SNAKE}_id"
)

for pattern in "${FIELD_PATTERNS[@]}"; do
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip if already found
    if [[ " ${FOUND_FILES[*]} " =~ " ${file} " ]]; then
      continue
    fi

    # Check if pattern exists in JSON
    if jq -e ".. | objects | has(\"$pattern\")" "$file" >/dev/null 2>&1; then
      FOUND_FILES+=("$file")
      echo -e "${GREEN}Found in${NC} $file (field: $pattern)"
      ((FOUND_COUNT++))
      ((FIELD_COUNT++))

      if [ "$VERBOSE" = "--verbose" ]; then
        echo "  Reason: Contains field '$pattern'"
        SAMPLE_VALUE=$(jq -r ".. | objects | select(has(\"$pattern\")) | .\"$pattern\" | select(type == \"string\")" "$file" 2>/dev/null | head -1)
        if [ -n "$SAMPLE_VALUE" ]; then
          echo "  Sample value: $SAMPLE_VALUE"
        fi
        echo ""
      fi

      break  # Only report once per file
    fi
  done < <(find "$FIXTURE_DIR" -type f -name "*.json" 2>/dev/null)
done

if [ "$FIELD_COUNT" -eq 0 ]; then
  echo "No fixtures found with field patterns"
fi
echo ""

# Search strategy 4: SQL seed files
echo "## Strategy 4: SQL seed file search"
SQL_COUNT=0

# Look for table references in SQL files
while IFS= read -r file; do
  [ -f "$file" ] || continue

  # Skip if already found
  if [[ " ${FOUND_FILES[*]} " =~ " ${file} " ]]; then
    continue
  fi

  # Check for table name patterns (case insensitive)
  if grep -qiE "(FROM|INTO|UPDATE|JOIN)\s+${MODEL_LOWER}s?\s" "$file" 2>/dev/null; then
    FOUND_FILES+=("$file")
    echo -e "${GREEN}Found in${NC} $file (SQL table reference)"
    ((FOUND_COUNT++))
    ((SQL_COUNT++))

    if [ "$VERBOSE" = "--verbose" ]; then
      echo "  Reason: References table '$MODEL_LOWER' or '${MODEL_PLURAL}'"
      TABLE_OPS=$(grep -iE "(FROM|INTO|UPDATE|JOIN)\s+${MODEL_LOWER}s?\s" "$file" | head -3 | sed 's/^/    /')
      echo "  Operations:"
      echo "$TABLE_OPS"
      echo ""
    fi
  fi
done < <(find "$FIXTURE_DIR" -type f -name "*.sql" 2>/dev/null)

if [ "$SQL_COUNT" -eq 0 ]; then
  echo "No SQL seed files found"
fi
echo ""

# Summary
echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}Summary${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [ "$FOUND_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}No fixtures found for model: $MODEL_NAME${NC}"
  echo ""
  echo "Suggestions:"
  echo "  • Check if the model name is correct"
  echo "  • Verify fixtures exist in $FIXTURE_DIR"
  echo "  • Try searching with --verbose for more details"
  echo "  • Consider creating fixtures for this model"
  exit 0
else
  echo -e "${GREEN}Total: $FOUND_COUNT fixture file(s) may need updates${NC}"
  echo ""

  if [ "$VERBOSE" != "--verbose" ]; then
    echo "Tip: Run with --verbose for detailed information about each match"
    echo ""
  fi

  echo "Next steps:"
  echo "  1. Review the listed fixtures for necessary updates"
  echo "  2. Update fixtures manually or regenerate with:"
  echo "     npx ts-node scripts/maintenance/regenerate-fixtures.ts --model $MODEL_NAME"
  echo "  3. Validate fixtures: npm run fixtures:validate"
  echo "  4. Run tests: npm test"
fi

echo ""
exit 0
