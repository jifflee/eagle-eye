#!/usr/bin/env bash
# ============================================================
# Script: find-duplicates.sh
# Purpose: Find duplicate functions and code patterns across scripts
# Usage: ./scripts/maintenance/find-duplicates.sh
# Dependencies: grep, awk, sort
# ============================================================

set -euo pipefail

echo "# Duplicate Code Analysis"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Find duplicate function names
echo "## Duplicate Function Names"
echo ""
echo "Functions defined in multiple files:"
echo ""

grep -rh "^[a-z_]*() {" scripts/ 2>/dev/null | \
  sed 's/() {.*//' | \
  sort | \
  uniq -c | \
  sort -rn | \
  while read -r count name; do
    if [ "$count" -gt 1 ]; then
      echo "### \`$name\` (defined $count times)"
      echo ""
      grep -rn "^${name}() {" scripts/ 2>/dev/null | while read -r location; do
        echo "- $location"
      done
      echo ""
    fi
  done

# Find similar code blocks (simple pattern matching)
echo "## Similar Code Patterns"
echo ""
echo "Common patterns that might indicate duplication:"
echo ""

# Look for repeated error handling patterns
echo "### Error Handling Patterns"
echo ""
echo "Files with similar error handling:"
grep -rln 'echo.*ERROR\|log_error' scripts/ 2>/dev/null | head -10 | while read -r file; do
  echo "- $file"
done
echo ""

# Look for repeated argument parsing
echo "### Argument Parsing Patterns"
echo ""
echo "Files with argument parsing (potential for shared utility):"
grep -rln 'while.*getopts\|shift\|"$1"\|${1:-}' scripts/ 2>/dev/null | head -10 | while read -r file; do
  echo "- $file"
done
echo ""

# Look for repeated jq patterns
echo "### JSON Processing Patterns"
echo ""
echo "Files using jq (potential for shared JSON utilities):"
grep -rln 'jq ' scripts/ 2>/dev/null | head -10 | while read -r file; do
  count=$(grep -c 'jq ' "$file" 2>/dev/null || echo 0)
  echo "- $file ($count jq calls)"
done
echo ""

# Look for repeated curl/API calls
echo "### API Call Patterns"
echo ""
echo "Files with API calls:"
grep -rln 'curl\|gh api' scripts/ 2>/dev/null | head -10 | while read -r file; do
  echo "- $file"
done
echo ""

# Summary
echo "## Summary"
echo ""
echo "| Category | Count |"
echo "|----------|-------|"
echo "| Scripts with error handling | $(grep -rl 'echo.*ERROR\|log_error' scripts/ 2>/dev/null | wc -l | tr -d ' ') |"
echo "| Scripts with arg parsing | $(grep -rl 'while.*getopts\|shift' scripts/ 2>/dev/null | wc -l | tr -d ' ') |"
echo "| Scripts using jq | $(grep -rl 'jq ' scripts/ 2>/dev/null | wc -l | tr -d ' ') |"
echo "| Scripts with API calls | $(grep -rl 'curl\|gh api' scripts/ 2>/dev/null | wc -l | tr -d ' ') |"
echo ""

echo "## Recommendations"
echo ""
echo "1. **Consolidate common functions** to \`scripts/lib/common.sh\`"
echo "2. **Extract JSON utilities** if multiple scripts have similar jq patterns"
echo "3. **Create API helper** if many scripts make similar API calls"
echo "4. **Standardize error handling** using shared log functions"
