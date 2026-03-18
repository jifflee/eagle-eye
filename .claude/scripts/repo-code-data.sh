#!/bin/bash
set -euo pipefail
# repo-code-data.sh
# Pre-process code quality metrics for /repo-code skill
# Returns JSON with file sizes, tech debt markers, coupling, and code smells
set -eu

# Exclusion options as arrays (safe, no eval needed)
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=venv --exclude-dir=.venv --exclude-dir=dist --exclude-dir=build)
FIND_EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/__pycache__/*' -not -path '*/venv/*' -not -path '*/.venv/*' -not -path '*/dist/*' -not -path '*/build/*')

# Detect project type
PROJECT_TYPE="unknown"
[[ -f "package.json" ]] && PROJECT_TYPE="nodejs"
[[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]] && PROJECT_TYPE="python"
[[ -f "Cargo.toml" ]] && PROJECT_TYPE="rust"
[[ -f "go.mod" ]] && PROJECT_TYPE="go"

# Source file extensions as find options (array-based)
FIND_EXT=()
case "$PROJECT_TYPE" in
  nodejs) FIND_EXT=(-name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx') ;;
  python) FIND_EXT=(-name '*.py') ;;
  rust) FIND_EXT=(-name '*.rs') ;;
  go) FIND_EXT=(-name '*.go') ;;
  *) FIND_EXT=(-name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.py' -o -name '*.sh') ;;
esac

# Total source files
SOURCE_FILES=$(find . "${FIND_EXCLUDE[@]}" \( "${FIND_EXT[@]}" \) 2>/dev/null | wc -l | tr -d ' ')

# Large files (>300 lines) - top 10, using -print0 for safe filename handling
LARGE_FILES=$(find . "${FIND_EXCLUDE[@]}" \( "${FIND_EXT[@]}" \) -print0 2>/dev/null | xargs -0 wc -l 2>/dev/null | sort -rn | grep -v "total" | head -10 | awk '{if ($1 > 300) printf "%s:%s,", $2, $1}' | sed 's/,$//')

# Very large files (>500 lines) count
VERY_LARGE=$(find . "${FIND_EXCLUDE[@]}" \( "${FIND_EXT[@]}" \) -print0 2>/dev/null | xargs -0 wc -l 2>/dev/null | sort -rn | grep -v "total" | awk '$1 > 500 {count++} END {print count+0}')

# Tech debt markers
TODO_COUNT=$(grep -rn "TODO" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.py" --include="*.js" --include="*.sh" . 2>/dev/null | wc -l | tr -d ' ')
FIXME_COUNT=$(grep -rn "FIXME" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.py" --include="*.js" --include="*.sh" . 2>/dev/null | wc -l | tr -d ' ')
HACK_COUNT=$(grep -rn "HACK" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.py" --include="*.js" --include="*.sh" . 2>/dev/null | wc -l | tr -d ' ')

# Debug statements
CONSOLE_LOG=$(grep -rn "console\.log" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" --include="*.tsx" --include="*.jsx" . 2>/dev/null | wc -l | tr -d ' ')
PRINT_STMT=$(grep -rn "^[[:space:]]*print(" "${GREP_EXCLUDE[@]}" --include="*.py" . 2>/dev/null | wc -l | tr -d ' ')
DEBUG_TOTAL=$((CONSOLE_LOG + PRINT_STMT))

# Import frequency (top coupled modules)
TOP_IMPORTS=$(grep -rh "^import\|^from" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.py" --include="*.js" . 2>/dev/null | sort | uniq -c | sort -rn | head -5 | awk '{printf "%s,", $1}' | sed 's/,$//')

# Highly imported files (coupling indicator)
HIGH_COUPLING=$(grep -rn "from\|import" "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.py" --include="*.js" . 2>/dev/null | sed "s/:.*//" | sort | uniq -c | sort -rn | head -5 | awk '$1 > 10 {count++} END {print count+0}')

# Calculate score
SCORE=100
# Large files penalty
[[ "$VERY_LARGE" -gt 0 ]] && SCORE=$((SCORE - VERY_LARGE * 10))
# Debug statements
[[ "$DEBUG_TOTAL" -gt 10 ]] && SCORE=$((SCORE - 10))
# Tech debt
DEBT_TOTAL=$((TODO_COUNT + FIXME_COUNT + HACK_COUNT))
[[ "$DEBT_TOTAL" -gt 20 ]] && SCORE=$((SCORE - 10))
[[ "$DEBT_TOTAL" -gt 50 ]] && SCORE=$((SCORE - 10))
# High coupling
[[ "$HIGH_COUPLING" -gt 0 ]] && SCORE=$((SCORE - HIGH_COUPLING * 10))
# Floor at 0
[[ $SCORE -lt 0 ]] && SCORE=0

# Determine status
if [[ $SCORE -ge 80 ]]; then STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
elif [[ $SCORE -ge 40 ]]; then STATUS="needs_work"
else STATUS="critical"
fi

# Output JSON
cat <<EOF
{
  "score": $SCORE,
  "status": "$STATUS",
  "project_type": "$PROJECT_TYPE",
  "source_files": $SOURCE_FILES,
  "large_files": "$LARGE_FILES",
  "very_large_count": $VERY_LARGE,
  "tech_debt": {
    "todo": $TODO_COUNT,
    "fixme": $FIXME_COUNT,
    "hack": $HACK_COUNT,
    "total": $DEBT_TOTAL
  },
  "debug_statements": {
    "console_log": $CONSOLE_LOG,
    "print": $PRINT_STMT,
    "total": $DEBUG_TOTAL
  },
  "coupling": {
    "high_coupling_files": $HIGH_COUPLING,
    "top_imports": "$TOP_IMPORTS"
  }
}
EOF
