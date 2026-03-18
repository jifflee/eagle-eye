#!/usr/bin/env bash
# ============================================================
# Script: check-naming-conventions.sh
# Purpose: Validate naming conventions for scripts and files
# Usage: ./scripts/ci/check-naming-conventions.sh [--fix]
# Exit codes: 0 = pass, 1 = violations found
# ============================================================

set -euo pipefail

FIX_MODE="${1:-}"
VIOLATIONS=0

echo "# Naming Convention Check"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Check script naming (lowercase with hyphens)
echo "## Script Naming"
echo ""

while IFS= read -r script; do
  [ -f "$script" ] || continue

  basename=$(basename "$script")

  # Check for valid pattern: lowercase letters, numbers, hyphens, ending in .sh
  if [[ ! "$basename" =~ ^[a-z][a-z0-9-]*\.sh$ ]]; then
    echo "VIOLATION: $script"
    echo "  Expected: lowercase with hyphens (e.g., my-script.sh)"
    echo "  Found: $basename"
    ((VIOLATIONS++))

    if [ "$FIX_MODE" = "--fix" ]; then
      # Generate suggested name
      suggested=$(echo "$basename" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed 's/[^a-z0-9.-]/-/g')
      echo "  Suggested: $suggested"
    fi
    echo ""
  fi
done < <(find scripts -name "*.sh" -type f 2>/dev/null)

if [ "$VIOLATIONS" -eq 0 ]; then
  echo "All scripts follow naming conventions"
fi
echo ""

# Check for uppercase directories (should be lowercase)
echo "## Directory Naming"
echo ""

dir_violations=0
while IFS= read -r dir; do
  [ -d "$dir" ] || continue

  basename=$(basename "$dir")

  if [[ "$basename" =~ [A-Z] ]]; then
    echo "VIOLATION: $dir"
    echo "  Expected: lowercase"
    echo "  Found: $basename"
    ((dir_violations++))
  fi
done < <(find . -type d -name "*[A-Z]*" 2>/dev/null | grep -v node_modules | grep -v ".git")

if [ "$dir_violations" -eq 0 ]; then
  echo "All directories follow naming conventions"
else
  ((VIOLATIONS+=dir_violations))
fi
echo ""

# Check markdown files in docs/standards (should be UPPERCASE)
echo "## Standards Document Naming"
echo ""

std_violations=0
while IFS= read -r doc; do
  [ -f "$doc" ] || continue

  basename=$(basename "$doc" .md)

  # Standards should be UPPERCASE with underscores
  if [[ ! "$basename" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
    # Allow some exceptions
    if [[ "$basename" != "README" ]] && [[ "$basename" != "CHANGELOG" ]]; then
      echo "WARNING: $doc"
      echo "  Expected: UPPERCASE_WITH_UNDERSCORES.md"
      echo "  Found: $basename.md"
      ((std_violations++))
    fi
  fi
done < <(find docs/standards -name "*.md" -type f 2>/dev/null)

if [ "$std_violations" -eq 0 ]; then
  echo "All standards documents follow naming conventions"
fi
echo ""

# Check milestone naming convention
echo "## Milestone Naming"
echo ""

milestone_violations=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

if [ -x "$REPO_DIR/scripts/validate/validate-milestone-name.sh" ] && command -v gh &>/dev/null; then
  # Get all open milestones
  milestones=$(gh api repos/:owner/:repo/milestones --paginate 2>/dev/null | jq -r '.[].title' || echo "")

  if [ -n "$milestones" ]; then
    while IFS= read -r milestone; do
      [ -z "$milestone" ] && continue

      # Validate each milestone
      result=$("$REPO_DIR/scripts/validate/validate-milestone-name.sh" "$milestone" 2>/dev/null || echo '{"valid": false}')
      is_valid=$(echo "$result" | jq -r '.valid')

      if [ "$is_valid" = "false" ]; then
        reason=$(echo "$result" | jq -r '.reason // "Invalid format"')
        echo "VIOLATION: $milestone"
        echo "  Reason: $reason"
        echo "  Expected: sprint-MMYY-N format (e.g., sprint-0226-7)"
        echo "  Run: ./scripts/validate/validate-milestone-name.sh to get the correct next name"
        ((milestone_violations++))
        echo ""
      fi
    done <<< "$milestones"

    if [ "$milestone_violations" -eq 0 ]; then
      echo "All milestones follow naming convention (sprint-MMYY-N)"
    fi
  else
    echo "No milestones found or unable to fetch milestones"
  fi
else
  echo "SKIPPED: validate-milestone-name.sh not found or gh not available"
fi
echo ""

# Summary
echo "## Summary"
echo ""
echo "| Category | Violations |"
echo "|----------|------------|"
echo "| Script names | $VIOLATIONS |"
echo "| Directory names | $dir_violations |"
echo "| Standards docs | $std_violations |"
echo "| Milestone names | $milestone_violations |"
echo ""

total_violations=$((VIOLATIONS + std_violations + milestone_violations))

if [ "$total_violations" -gt 0 ]; then
  echo "FAILED: $total_violations naming violations found"
  exit 1
fi

echo "PASSED: All naming conventions followed"
exit 0
