#!/usr/bin/env bash
# ============================================================
# Script: ci-validate-fixtures.sh
# Purpose: Validate fixtures in CI with stricter requirements
# Usage: ./scripts/ci/validators/ci-validate-fixtures.sh
# Dependencies: jq, validate-all-fixtures.sh
# Renamed from validate-fixtures.sh to distinguish from scripts/maintenance/validate-fixtures.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}CI Fixture Validation${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Environment: CI"
echo "Mode: Strict"
echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

ERRORS=0

# Check if fixture directory exists
if [ ! -d "$FIXTURE_DIR" ]; then
  echo -e "${YELLOW}⚠ No fixtures directory found${NC}"
  echo "Location checked: $FIXTURE_DIR"
  echo ""
  echo "This is acceptable if fixtures haven't been created yet."
  exit 0
fi

# Count fixtures
FIXTURE_COUNT=$(find "$FIXTURE_DIR" -name "*.json" -o -name "*.sql" 2>/dev/null | wc -l | tr -d ' ')

if [ "$FIXTURE_COUNT" -eq 0 ]; then
  echo -e "${YELLOW}⚠ No fixture files found${NC}"
  echo ""
  echo "This is acceptable if fixtures haven't been created yet."
  exit 0
fi

echo "Found $FIXTURE_COUNT fixture file(s)"
echo ""

# Run comprehensive validation in strict mode
echo "## Running Comprehensive Validation"
echo ""

if "$REPO_ROOT/scripts/maintenance/validate-all-fixtures.sh" --strict; then
  echo -e "${GREEN}✓ Comprehensive validation passed${NC}"
else
  echo -e "${RED}✗ Comprehensive validation failed${NC}"
  ((ERRORS++))
fi

echo ""

# CI-specific checks
echo "## CI-Specific Checks"
echo ""

# Check 1: Fixtures older than 90 days
echo "### Checking fixture age..."
OLD_FIXTURES=$(find "$FIXTURE_DIR" -name "*.json" -type f -mtime +90 2>/dev/null | wc -l | tr -d ' ')

if [ "$OLD_FIXTURES" -gt 0 ]; then
  echo -e "${YELLOW}WARNING: $OLD_FIXTURES fixture(s) older than 90 days${NC}"
  echo ""
  echo "Old fixtures found:"
  find "$FIXTURE_DIR" -name "*.json" -type f -mtime +90 -exec echo "  - {}" \; 2>/dev/null
  echo ""
  echo "Consider updating these fixtures to ensure they match current schemas."
  echo ""

  # In CI, this is a warning, not an error
  # Uncomment to make this an error:
  # ((ERRORS++))
else
  echo -e "${GREEN}✓ All fixtures are recent (< 90 days)${NC}"
fi

echo ""

# Check 2: All fixtures have metadata
echo "### Checking fixture metadata..."
MISSING_META=0

while IFS= read -r file; do
  [ -f "$file" ] || continue

  # Skip generated fixtures (they have different metadata requirements)
  if [[ "$file" == *"/generated/"* ]]; then
    continue
  fi

  if ! jq -e '._metadata' "$file" >/dev/null 2>&1; then
    if [ "$MISSING_META" -eq 0 ]; then
      echo -e "${RED}ERROR: Fixtures missing metadata:${NC}"
    fi
    echo "  - $file"
    ((MISSING_META++))
  fi
done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

if [ "$MISSING_META" -gt 0 ]; then
  echo ""
  echo "All fixtures should include _metadata. See: docs/standards/FIXTURE_CAPTURE.md"
  ((ERRORS++))
else
  echo -e "${GREEN}✓ All fixtures have metadata${NC}"
fi

echo ""

# Check 3: Check for potential secrets/PII
echo "### Checking for sensitive data patterns..."
SENSITIVE_FOUND=0

# Check for real email domains
REAL_EMAILS=$(grep -rE '@(gmail|yahoo|hotmail|outlook|live|aol|icloud)\.' "$FIXTURE_DIR" --include="*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REAL_EMAILS" -gt 0 ]; then
  echo -e "${RED}ERROR: Potential real email addresses found in fixtures${NC}"
  grep -rE '@(gmail|yahoo|hotmail|outlook|live|aol|icloud)\.' "$FIXTURE_DIR" --include="*.json" 2>/dev/null | head -5 | sed 's/^/  /'
  echo ""
  ((SENSITIVE_FOUND++))
  ((ERRORS++))
fi

# Check for API key patterns
API_KEYS=$(grep -rE '(sk_live|pk_live|api_key.*[a-zA-Z0-9]{32,}|secret.*[a-zA-Z0-9]{32,})' "$FIXTURE_DIR" --include="*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$API_KEYS" -gt 0 ]; then
  echo -e "${RED}ERROR: Potential API keys found in fixtures${NC}"
  grep -rE '(sk_live|pk_live|api_key.*[a-zA-Z0-9]{32,}|secret.*[a-zA-Z0-9]{32,})' "$FIXTURE_DIR" --include="*.json" 2>/dev/null | head -5 | sed 's/^/  /'
  echo ""
  ((SENSITIVE_FOUND++))
  ((ERRORS++))
fi

# Check for credit card patterns (simple check)
CC_PATTERNS=$(grep -rE '[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}[- ]?[0-9]{4}' "$FIXTURE_DIR" --include="*.json" 2>/dev/null | wc -l | tr -d ' ')
if [ "$CC_PATTERNS" -gt 0 ]; then
  echo -e "${YELLOW}WARNING: Potential credit card patterns found${NC}"
  echo "Verify these are test numbers, not real cards"
  echo ""
  # This is a warning, not an error (test cards are expected)
fi

if [ "$SENSITIVE_FOUND" -eq 0 ]; then
  echo -e "${GREEN}✓ No sensitive data patterns detected${NC}"
fi

echo ""

# Check 4: Verify fixture files are properly formatted
echo "### Checking JSON formatting..."
BADLY_FORMATTED=0

while IFS= read -r file; do
  [ -f "$file" ] || continue

  # Check if file ends with newline
  if [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
    if [ "$BADLY_FORMATTED" -eq 0 ]; then
      echo -e "${YELLOW}WARNING: Files without trailing newline:${NC}"
    fi
    echo "  - $file"
    ((BADLY_FORMATTED++))
  fi

  # Check for tabs (should use spaces)
  if grep -q $'\t' "$file" 2>/dev/null; then
    echo -e "${YELLOW}WARNING: File contains tabs (should use spaces): $file${NC}"
    ((BADLY_FORMATTED++))
  fi
done < <(find "$FIXTURE_DIR" -name "*.json" -type f 2>/dev/null)

if [ "$BADLY_FORMATTED" -eq 0 ]; then
  echo -e "${GREEN}✓ All fixtures properly formatted${NC}"
fi

echo ""

# Check 5: Check for fixture schema references
echo "### Checking for schema validation..."

# Check if schemas directory exists
if [ -d "$REPO_ROOT/schemas" ]; then
  echo "Schema directory found: $REPO_ROOT/schemas"
  SCHEMA_COUNT=$(find "$REPO_ROOT/schemas" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  echo "Available schemas: $SCHEMA_COUNT"

  # This is informational - actual schema validation would require ajv or similar
  echo ""
  echo "Note: Actual schema validation requires ajv (not yet implemented)"
  echo "To add schema validation:"
  echo "  npm install --save-dev ajv"
  echo "  Update validate-all-fixtures.sh to include schema checks"
else
  echo -e "${BLUE}ℹ No schemas directory found${NC}"
  echo "Schema validation not available"
fi

echo ""

# Summary
echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}CI Validation Summary${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "| Metric | Count |"
echo "|--------|-------|"
echo "| Fixtures checked | $FIXTURE_COUNT |"
echo "| Errors | $ERRORS |"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo -e "${RED}✗ FAILED: $ERRORS error(s) found${NC}"
  echo ""
  echo "Fix the errors above and re-run validation."
  echo ""
  echo "Common fixes:"
  echo "  • Remove real email addresses from fixtures"
  echo "  • Remove API keys and secrets"
  echo "  • Add _metadata to all fixtures"
  echo "  • Ensure files end with newline"
  echo ""
  exit 1
fi

echo -e "${GREEN}✓ PASSED: All CI fixture validation checks passed${NC}"
echo ""

if [ "$OLD_FIXTURES" -gt 0 ]; then
  echo -e "${YELLOW}Note: $OLD_FIXTURES fixture(s) are older than 90 days${NC}"
  echo "Consider updating them to ensure they match current schemas."
  echo ""
fi

exit 0
