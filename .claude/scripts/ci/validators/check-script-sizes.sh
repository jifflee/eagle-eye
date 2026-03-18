#!/usr/bin/env bash
# ============================================================
# Script: check-script-sizes.sh
# Purpose: Check scripts against size guidelines
# Usage: ./scripts/ci/check-script-sizes.sh [--strict]
# Exit codes: 0 = pass, 1 = hard limit exceeded, 2 = warnings (strict)
# ============================================================

set -euo pipefail

HARD_LIMIT=500
WARN_LIMIT=300
IDEAL_LIMIT=200
STRICT=""
FILES_MODE=""
FILE_LIST=()

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict) STRICT="--strict"; shift ;;
    --files) shift; while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do FILE_LIST+=("$1"); shift; done; FILES_MODE="true" ;;
    *) shift ;;
  esac
done

ERRORS=0
WARNINGS=0
SUPPRESSED=0

# Check if a script has a size-ok annotation in its first 30 lines
# Usage: has_size_ok_annotation <script_path>
# Returns 0 if annotation found, 1 otherwise
has_size_ok_annotation() {
  head -30 "$1" | grep -q '^# size-ok:' 2>/dev/null
}

echo "# Script Size Check"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "| Guideline | Threshold | Status |"
echo "|-----------|-----------|--------|"
echo "| Ideal | <= $IDEAL_LIMIT lines | OK |"
echo "| Warning | $IDEAL_LIMIT-$WARN_LIMIT lines | Review |"
echo "| Large | $WARN_LIMIT-$HARD_LIMIT lines | Document |"
echo "| Exceeded | > $HARD_LIMIT lines | Split |"
echo ""

if [ "$FILES_MODE" = "true" ]; then
  echo "**Mode:** PR-changed files only (${#FILE_LIST[@]} files)"
else
  echo "**Mode:** Full repository scan"
fi
echo ""

echo "## Script Analysis"
echo ""
echo "| Script | Lines | Status | Action |"
echo "|--------|-------|--------|--------|"

list_scripts() {
  if [ "$FILES_MODE" = "true" ]; then
    for f in "${FILE_LIST[@]}"; do
      echo "$f"
    done
  else
    find scripts -name "*.sh" -type f 2>/dev/null | sort
  fi
}

while IFS= read -r script; do
  [ -f "$script" ] || continue

  lines=$(wc -l < "$script" | tr -d ' ')

  if [ "$lines" -gt "$HARD_LIMIT" ]; then
    if has_size_ok_annotation "$script"; then
      status="OK (size-ok)"
      action="-"
      SUPPRESSED=$((SUPPRESSED + 1))
    else
      status="EXCEEDED"
      action="Consider splitting or add size-ok annotation"
      ERRORS=$((ERRORS + 1))
    fi
  elif [ "$lines" -gt "$WARN_LIMIT" ]; then
    if has_size_ok_annotation "$script"; then
      status="OK (size-ok)"
      action="-"
      SUPPRESSED=$((SUPPRESSED + 1))
    else
      status="Large"
      action="Review for splitting"
      WARNINGS=$((WARNINGS + 1))
    fi
  elif [ "$lines" -gt "$IDEAL_LIMIT" ]; then
    status="Warning"
    action="Consider refactoring"
  else
    status="OK"
    action="-"
  fi

  # Truncate path for display
  display_path=$(echo "$script" | sed 's|scripts/||')
  echo "| $display_path | $lines | $status | $action |"
done < <(list_scripts)

echo ""

# Summary statistics
total_scripts=$(find scripts -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
total_lines=$(find scripts -name "*.sh" -type f -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}')
avg_lines=$((total_lines / (total_scripts > 0 ? total_scripts : 1)))

echo "## Summary"
echo ""
echo "| Metric | Value |"
echo "|--------|-------|"
echo "| Total scripts | $total_scripts |"
echo "| Total lines | $total_lines |"
echo "| Average lines | $avg_lines |"
echo "| Exceeds hard limit | $ERRORS |"
echo "| Exceeds warning limit | $WARNINGS |"
echo "| Suppressed (size-ok) | $SUPPRESSED |"
echo ""

# Detailed breakdown for large scripts
if [ "$ERRORS" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then
  echo "## Large Scripts Detail"
  echo ""

  while IFS= read -r script; do
    [ -f "$script" ] || continue

    lines=$(wc -l < "$script" | tr -d ' ')

    if [ "$lines" -gt "$WARN_LIMIT" ] && ! has_size_ok_annotation "$script"; then
      echo "### $(basename "$script") ($lines lines)"
      echo ""
      echo "**Path:** $script"
      echo ""

      # Count functions
      func_count=$(grep -c "^[a-z_]*() {" "$script" 2>/dev/null || echo 0)
      echo "**Functions:** $func_count"
      echo ""

      # Show function list
      if [ "$func_count" -gt 0 ]; then
        echo "**Function list:**"
        grep "^[a-z_]*() {" "$script" 2>/dev/null | sed 's/() {.*//' | while read -r func; do
          echo "- \`$func\`"
        done
        echo ""
      fi

      # Suggestions
      echo "**Recommendations:**"
      if [ "$func_count" -gt 8 ]; then
        echo "- Extract shared functions to \`scripts/lib/\`"
      fi
      if [ "$lines" -gt "$HARD_LIMIT" ]; then
        echo "- Split into smaller, focused scripts"
        echo "- Or document why large size is necessary"
      fi
      echo ""
    fi
  done < <(list_scripts)
fi

# Exit codes
if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS scripts exceed hard limit ($HARD_LIMIT lines)"
  exit 1
fi

if [ "$STRICT" = "--strict" ] && [ "$WARNINGS" -gt 0 ]; then
  echo "FAILED (strict): $WARNINGS scripts exceed warning limit ($WARN_LIMIT lines)"
  exit 2
fi

echo "PASSED: All scripts within acceptable limits"
exit 0
