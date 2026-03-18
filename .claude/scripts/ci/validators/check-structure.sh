#!/usr/bin/env bash
# ============================================================
# Script: check-structure.sh
# Purpose: Validate required repository directory structure
# Usage: ./scripts/ci/check-structure.sh
# Exit codes: 0 = pass, 1 = missing required structure
# ============================================================

set -euo pipefail

ERRORS=0

echo "# Repository Structure Check"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Required directories for this repository
REQUIRED_DIRS=(
  "scripts"
  "docs"
  "tests"
  "core"
  ".github/workflows"
)

# Recommended directories (warn if missing)
RECOMMENDED_DIRS=(
  "scripts/ci"
  "scripts/audit"
  "docs/standards"
  "tests/unit"
)

echo "## Required Directories"
echo ""
echo "| Directory | Status |"
echo "|-----------|--------|"

for dir in "${REQUIRED_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "| $dir | PASS |"
  else
    echo "| $dir | MISSING |"
    ERRORS=$((ERRORS + 1))
  fi
done
echo ""

echo "## Recommended Directories"
echo ""
echo "| Directory | Status |"
echo "|-----------|--------|"

WARNINGS=0
for dir in "${RECOMMENDED_DIRS[@]}"; do
  if [ -d "$dir" ]; then
    echo "| $dir | PASS |"
  else
    echo "| $dir | MISSING (recommended) |"
    WARNINGS=$((WARNINGS + 1))
  fi
done
echo ""

# Check for required root files
echo "## Required Files"
echo ""
echo "| File | Status |"
echo "|------|--------|"

REQUIRED_FILES=(
  ".gitignore"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [ -f "$file" ]; then
    echo "| $file | PASS |"
  else
    echo "| $file | MISSING |"
    ERRORS=$((ERRORS + 1))
  fi
done
echo ""

# Summary
echo "## Summary"
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS required items missing"
  echo ""
  echo "**How to fix:** Create the missing directories/files listed above."
  echo "See: docs/standards/REPO_STRUCTURE.md"
  exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
  echo "PASSED with $WARNINGS recommendations"
else
  echo "PASSED: All required structure present"
fi
exit 0
