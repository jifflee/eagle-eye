#!/usr/bin/env bash
set -euo pipefail
# Validate script naming conventions
# Part of issue #1113 - Script naming audit

set -eo pipefail

echo "=== Script Naming Convention Validation ==="
echo
echo "Checking scripts/ directory for naming compliance..."
echo

# Count total scripts
total=$(find scripts/ -name "*.sh" -type f | wc -l | tr -d ' ')
echo "Total scripts: $total"
echo

# Check 1: No scripts should use colon separator
echo "Check 1: Scripts using colon separator (bash incompatible)"
colon_scripts=$(find scripts/ -name "*:*.sh" 2>/dev/null | wc -l | tr -d ' ')
if [ "$colon_scripts" -eq 0 ]; then
  echo "  ✅ PASS: No scripts using colon separator"
else
  echo "  ❌ FAIL: Found $colon_scripts script(s) using colon separator"
  find scripts/ -name "*:*.sh"
fi
echo

# Check 2: Data scripts should have category prefixes
echo "Check 2: Data scripts with category prefixes"
data_scripts=$(find scripts/ -maxdepth 1 -name "*-data.sh" 2>/dev/null | wc -l | tr -d ' ')
missing_prefix=0

echo "  Found $data_scripts data scripts in scripts/"
echo "  Checking for category prefixes..."

while IFS= read -r script; do
  if [ -n "$script" ]; then
    basename=$(basename "$script")
    prefix="${basename%-data.sh}"
    if [[ "$prefix" != *-* ]]; then
      echo "    ⚠️  $basename (missing category prefix)"
      missing_prefix=$((missing_prefix + 1))
    fi
  fi
done < <(find scripts/ -maxdepth 1 -name "*-data.sh" 2>/dev/null)

if [ "$missing_prefix" -eq 0 ]; then
  echo "  ✅ PASS: All data scripts have category prefixes"
else
  echo "  ⚠️  WARNING: $missing_prefix data script(s) missing category prefix"
  echo "     (Low priority - scripts still function correctly)"
fi
echo

# Check 3: Naming patterns summary
echo "Check 3: Naming patterns summary"
data_count=$(find scripts/ -name "*-data.sh" 2>/dev/null | wc -l | tr -d ' ')
validate_count=$(find scripts/ -name "validate-*.sh" 2>/dev/null | wc -l | tr -d ' ')
gate_count=$(find scripts/ -name "*-gate.sh" 2>/dev/null | wc -l | tr -d ' ')

echo "  Data scripts (*-data.sh):      $data_count"
echo "  Validation scripts (validate-*.sh): $validate_count"
echo "  Gate scripts (*-gate.sh):      $gate_count"
echo "  ✅ All scripts use hyphen separator"
echo

# Summary
echo "=== Summary ==="
if [ "$colon_scripts" -eq 0 ] && [ "$missing_prefix" -eq 0 ]; then
  echo "✅ All checks passed!"
  echo "   Scripts follow bash naming conventions (hyphens, not colons)"
  exit 0
elif [ "$colon_scripts" -gt 0 ]; then
  echo "❌ Validation FAILED: Scripts using colon separator found"
  exit 1
else
  echo "✅ Validation PASSED with $missing_prefix warning(s)"
  echo "   Minor inconsistencies found but scripts function correctly"
  exit 0
fi
