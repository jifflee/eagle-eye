#!/bin/bash
set -euo pipefail
# repo-structure-data.sh
# Pre-process repository structure metrics for /repo-structure skill
# Returns JSON with directory analysis, naming conventions, and findings
set -eu

# Exclusion options as array (safe, no eval needed)
EXCLUDE_OPTS=(-not -path '*/.*' -not -path '*/node_modules/*' -not -path '*/__pycache__/*' -not -path '*/venv/*' -not -path '*/.venv/*')

# Directory count
DIR_COUNT=$(find . -type d "${EXCLUDE_OPTS[@]}" 2>/dev/null | wc -l | tr -d ' ')

# File count
FILE_COUNT=$(find . -type f "${EXCLUDE_OPTS[@]}" 2>/dev/null | wc -l | tr -d ' ')

# Max depth
MAX_DEPTH=$(find . -type d "${EXCLUDE_OPTS[@]}" 2>/dev/null | awk -F/ '{print NF-1}' | sort -rn | head -1)
MAX_DEPTH=${MAX_DEPTH:-0}

# Standard directories check
HAS_SRC=$([[ -d "src" || -d "lib" ]] && echo "true" || echo "false")
HAS_TESTS=$([[ -d "tests" || -d "test" || -d "__tests__" ]] && echo "true" || echo "false")
HAS_DOCS=$([[ -d "docs" || -d "doc" ]] && echo "true" || echo "false")
HAS_SCRIPTS=$([[ -d "scripts" || -d "bin" ]] && echo "true" || echo "false")
HAS_CONFIG=$([[ -d "config" || -d ".config" ]] && echo "true" || echo "false")
HAS_GITHUB=$([[ -d ".github" ]] && echo "true" || echo "false")

# Top-level directories (for structure overview)
TOP_DIRS=$(ls -d */ 2>/dev/null | head -20 | tr '\n' ',' | sed 's/,$//')

# File types distribution (top 10)
FILE_TYPES=$(find . -type f "${EXCLUDE_OPTS[@]}" 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -10 | awk '{printf "%s:%s,", $2, $1}' | sed 's/,$//')

# Naming convention analysis (using find -print0 and xargs -0 for safe filename handling)
KEBAB_COUNT=$(find . -type f "${EXCLUDE_OPTS[@]}" -print0 2>/dev/null | xargs -0 -I{} basename {} | grep -c '^[a-z][a-z0-9]*\(-[a-z0-9]*\)*\.' || true)
KEBAB_COUNT=${KEBAB_COUNT:-0}
CAMEL_COUNT=$(find . -type f "${EXCLUDE_OPTS[@]}" -print0 2>/dev/null | xargs -0 -I{} basename {} | grep -c '^[a-z][a-zA-Z0-9]*\.' || true)
CAMEL_COUNT=${CAMEL_COUNT:-0}
SNAKE_COUNT=$(find . -type f "${EXCLUDE_OPTS[@]}" -print0 2>/dev/null | xargs -0 -I{} basename {} | grep -c '^[a-z][a-z0-9]*\(_[a-z0-9]*\)*\.' || true)
SNAKE_COUNT=${SNAKE_COUNT:-0}

# Files per top-level directory (top 10)
FILES_PER_DIR=$(find . -type f "${EXCLUDE_OPTS[@]}" 2>/dev/null | cut -d/ -f2 | sort | uniq -c | sort -rn | head -10 | awk '{printf "%s:%s,", $2, $1}' | sed 's/,$//')

# Required files check
HAS_README=$([[ -f "README.md" ]] && echo "true" || echo "false")
HAS_GITIGNORE=$([[ -f ".gitignore" ]] && echo "true" || echo "false")
HAS_ENV_EXAMPLE=$([[ -f ".env.example" ]] && echo "true" || echo "false")

# Config files in root
ROOT_CONFIGS=$(ls *.json *.yml *.yaml *.toml *.cfg *.ini 2>/dev/null | wc -l | tr -d ' ')

# Calculate score
SCORE=100
# Non-standard structure
[[ "$HAS_SRC" == "false" && "$DIR_COUNT" -gt 5 ]] && SCORE=$((SCORE - 10))
[[ "$HAS_TESTS" == "false" ]] && SCORE=$((SCORE - 10))
[[ "$HAS_DOCS" == "false" ]] && SCORE=$((SCORE - 5))
# Excessive depth
[[ "$MAX_DEPTH" -gt 5 ]] && SCORE=$((SCORE - 15))
# No README
[[ "$HAS_README" == "false" ]] && SCORE=$((SCORE - 15))
# Too many root configs
[[ "$ROOT_CONFIGS" -gt 10 ]] && SCORE=$((SCORE - 5))

# Determine status
if [[ $SCORE -ge 80 ]]; then STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
else STATUS="needs_work"
fi

# Output JSON
cat <<EOF
{
  "score": $SCORE,
  "status": "$STATUS",
  "directories": $DIR_COUNT,
  "files": $FILE_COUNT,
  "max_depth": $MAX_DEPTH,
  "top_dirs": "$TOP_DIRS",
  "file_types": "$FILE_TYPES",
  "files_per_dir": "$FILES_PER_DIR",
  "standard_dirs": {
    "src_or_lib": $HAS_SRC,
    "tests": $HAS_TESTS,
    "docs": $HAS_DOCS,
    "scripts": $HAS_SCRIPTS,
    "config": $HAS_CONFIG,
    "github": $HAS_GITHUB
  },
  "required_files": {
    "readme": $HAS_README,
    "gitignore": $HAS_GITIGNORE,
    "env_example": $HAS_ENV_EXAMPLE
  },
  "naming": {
    "kebab_case": $KEBAB_COUNT,
    "camel_case": $CAMEL_COUNT,
    "snake_case": $SNAKE_COUNT
  },
  "root_configs": $ROOT_CONFIGS
}
EOF
