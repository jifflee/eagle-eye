#!/usr/bin/env bash
# ============================================================
# Script: validate-all-fixtures.sh
# Purpose: Comprehensive fixture validation wrapper
# Usage: ./scripts/maintenance/validate-all-fixtures.sh [--strict]
# Dependencies: jq, validate-fixtures.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRICT="${1:-}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}Fixture Validation Suite${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Mode: $([ "$STRICT" = "--strict" ] && echo "STRICT" || echo "NORMAL")"
echo ""

TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# Run base fixture validation
echo "## Running Base Validation"
echo ""

if "$SCRIPT_DIR/validate-fixtures.sh" "$STRICT"; then
  echo -e "${GREEN}✓ Base validation passed${NC}"
else
  echo -e "${RED}✗ Base validation failed${NC}"
  ((TOTAL_ERRORS++))
fi

echo ""

# Additional validation: Check for common issues
echo "## Running Extended Validation"
echo ""

FIXTURE_DIR="tests/fixtures"

if [ ! -d "$FIXTURE_DIR" ]; then
  echo -e "${YELLOW}⚠ Fixture directory not found: $FIXTURE_DIR${NC}"
  echo "Skipping extended validation"
  echo ""
else
  # Check 1: Duplicate fixture detection
  echo "### Checking for duplicate fixtures..."
  DUPLICATES=0

  # Find potential duplicates by comparing file hashes
  declare -A file_hashes
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Get hash of file content (ignoring metadata)
    CONTENT_HASH=$(jq -S 'del(._metadata)' "$file" 2>/dev/null | md5sum | cut -d' ' -f1 2>/dev/null || echo "")

    if [ -n "$CONTENT_HASH" ]; then
      if [ -n "${file_hashes[$CONTENT_HASH]:-}" ]; then
        echo -e "${YELLOW}WARNING: Possible duplicate fixtures:${NC}"
        echo "  - ${file_hashes[$CONTENT_HASH]}"
        echo "  - $file"
        ((DUPLICATES++))
        ((TOTAL_WARNINGS++))
      else
        file_hashes[$CONTENT_HASH]="$file"
      fi
    fi
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  if [ "$DUPLICATES" -eq 0 ]; then
    echo -e "${GREEN}✓ No duplicate fixtures found${NC}"
  fi
  echo ""

  # Check 2: Orphaned fixture references
  echo "### Checking for orphaned references..."
  ORPHANED=0

  # Check if referenced fixtures exist
  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Look for references to other fixtures in metadata
    REFS=$(jq -r '._metadata.references[]? // empty' "$file" 2>/dev/null || echo "")

    if [ -n "$REFS" ]; then
      while IFS= read -r ref; do
        [ -n "$ref" ] || continue

        # Check if referenced file exists
        REF_FILE="$FIXTURE_DIR/$ref"
        if [ ! -f "$REF_FILE" ]; then
          echo -e "${YELLOW}WARNING: Orphaned reference in $file:${NC}"
          echo "  Referenced fixture not found: $ref"
          ((ORPHANED++))
          ((TOTAL_WARNINGS++))
        fi
      done <<< "$REFS"
    fi
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  if [ "$ORPHANED" -eq 0 ]; then
    echo -e "${GREEN}✓ No orphaned references found${NC}"
  fi
  echo ""

  # Check 3: Fixture size warnings
  echo "### Checking fixture sizes..."
  LARGE_FIXTURES=0
  SIZE_THRESHOLD=102400  # 100KB

  while IFS= read -r file; do
    [ -f "$file" ] || continue

    FILE_SIZE=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")

    if [ "$FILE_SIZE" -gt "$SIZE_THRESHOLD" ]; then
      SIZE_KB=$((FILE_SIZE / 1024))
      echo -e "${YELLOW}WARNING: Large fixture file ($SIZE_KB KB):${NC}"
      echo "  $file"
      echo "  Consider splitting or reducing fixture size"
      ((LARGE_FIXTURES++))
      ((TOTAL_WARNINGS++))
    fi
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  if [ "$LARGE_FIXTURES" -eq 0 ]; then
    echo -e "${GREEN}✓ All fixtures within size limits${NC}"
  fi
  echo ""

  # Check 4: Metadata completeness
  echo "### Checking metadata completeness..."
  INCOMPLETE_META=0

  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip generated fixtures directory (they may have different metadata)
    if [[ "$file" == *"/generated/"* ]]; then
      continue
    fi

    HAS_SOURCE=$(jq -e '._metadata.source' "$file" >/dev/null 2>&1 && echo "yes" || echo "no")
    HAS_CAPTURED=$(jq -e '._metadata.capturedAt' "$file" >/dev/null 2>&1 && echo "yes" || echo "no")

    # For captured fixtures, both fields should be present
    if [ "$HAS_CAPTURED" = "yes" ] && [ "$HAS_SOURCE" = "no" ]; then
      echo -e "${YELLOW}WARNING: Incomplete metadata in $file:${NC}"
      echo "  Has capturedAt but missing source field"
      ((INCOMPLETE_META++))
      ((TOTAL_WARNINGS++))
    fi
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  if [ "$INCOMPLETE_META" -eq 0 ]; then
    echo -e "${GREEN}✓ All fixture metadata is complete${NC}"
  fi
  echo ""

  # Check 5: Consistency checks for IDs
  echo "### Checking ID consistency..."
  INCONSISTENT_IDS=0

  # Collect all IDs from fixtures
  declare -A user_ids
  declare -A product_ids

  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Extract user IDs
    while IFS= read -r uid; do
      [ -n "$uid" ] || continue
      user_ids["$uid"]="${user_ids[$uid]:-0}+1"
    done < <(jq -r '.. | .userId? // .user_id? // empty' "$file" 2>/dev/null)

    # Extract product IDs
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      product_ids["$pid"]="${product_ids[$pid]:-0}+1"
    done < <(jq -r '.. | .productId? // .product_id? // empty' "$file" 2>/dev/null)
  done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

  # Check if user fixtures exist for referenced user IDs
  for uid in "${!user_ids[@]}"; do
    USER_FOUND=false

    while IFS= read -r file; do
      [ -f "$file" ] || continue

      if jq -e ".id == \"$uid\" or .userId == \"$uid\" or .user_id == \"$uid\"" "$file" >/dev/null 2>&1; then
        USER_FOUND=true
        break
      fi
    done < <(find "$FIXTURE_DIR" -type f -name "*.json" \( -path "*/users/*" -o -path "*/user/*" \) 2>/dev/null)

    if [ "$USER_FOUND" = false ]; then
      # Only warn if this looks like a test ID (not a real UUID)
      if [[ "$uid" =~ ^(user-|test-|usr-) ]]; then
        echo -e "${YELLOW}WARNING: Referenced user ID not found in fixtures: $uid${NC}"
        ((INCONSISTENT_IDS++))
        ((TOTAL_WARNINGS++))
      fi
    fi
  done

  if [ "$INCONSISTENT_IDS" -eq 0 ]; then
    echo -e "${GREEN}✓ ID references are consistent${NC}"
  fi
  echo ""
fi

# Final summary
echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}Validation Summary${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "| Metric   | Count |"
echo "|----------|-------|"
echo "| Errors   | $TOTAL_ERRORS |"
echo "| Warnings | $TOTAL_WARNINGS |"
echo ""

if [ "$TOTAL_ERRORS" -gt 0 ]; then
  echo -e "${RED}FAILED: $TOTAL_ERRORS error(s) found${NC}"
  echo ""
  echo "Fix errors and run validation again."
  exit 1
fi

if [ "$STRICT" = "--strict" ] && [ "$TOTAL_WARNINGS" -gt 0 ]; then
  echo -e "${YELLOW}FAILED (strict mode): $TOTAL_WARNINGS warning(s) found${NC}"
  echo ""
  echo "Address warnings or run without --strict flag."
  exit 1
fi

echo -e "${GREEN}✓ PASSED: All fixtures valid${NC}"
echo ""

if [ "$TOTAL_WARNINGS" -gt 0 ]; then
  echo -e "${YELLOW}Note: $TOTAL_WARNINGS warning(s) found but validation passed${NC}"
  echo "Consider addressing warnings to improve fixture quality."
  echo ""
fi

exit 0
