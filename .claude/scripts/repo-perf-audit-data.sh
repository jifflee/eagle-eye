#!/usr/bin/env bash
# repo-perf-audit-data.sh
# Pre-process performance audit metrics for /performance:repo-audit skill
# Returns JSON with dependency weight, anti-patterns, build config, and caching opportunities
#
# Usage: ./scripts/repo-perf-audit-data.sh
# Output: JSON object with performance findings, scores, and metadata
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Common exclusion patterns ─────────────────────────────────────────────────
FIND_EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/.git/*'
              -not -path '*/__pycache__/*' -not -path '*/venv/*'
              -not -path '*/.venv/*' -not -path '*/dist/*'
              -not -path '*/build/*' -not -path '*/.next/*'
              -not -path '*/coverage/*')
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git
              --exclude-dir=__pycache__ --exclude-dir=venv
              --exclude-dir=.venv --exclude-dir=dist
              --exclude-dir=build --exclude-dir=.next
              --exclude-dir=coverage)

# Helper: grep that never fails due to no matches (grep exits 1 on no match)
# Usage: safe_grep_count <grep args...>
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

# ── Detect project type ───────────────────────────────────────────────────────
PROJECT_TYPE="unknown"
[[ -f "package.json" ]]                                              && PROJECT_TYPE="nodejs"
[[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]] && PROJECT_TYPE="python"
[[ -f "Cargo.toml" ]]                                               && PROJECT_TYPE="rust"
[[ -f "go.mod" ]]                                                   && PROJECT_TYPE="go"
# Multi-type: Node wins if both exist (monorepo with python scripts)
[[ -f "package.json" && ( -f "requirements.txt" || -f "pyproject.toml" ) ]] && PROJECT_TYPE="multi"

# ── Source file extensions ────────────────────────────────────────────────────
case "$PROJECT_TYPE" in
  nodejs) SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.jsx" "*.mjs" "*.cjs") ;;
  python) SRC_EXTS=("*.py") ;;
  rust)   SRC_EXTS=("*.rs") ;;
  go)     SRC_EXTS=("*.go") ;;
  *)      SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.py" "*.sh") ;;
esac

# Build find -name arguments
SRC_FIND_ARGS=()
for ext in "${SRC_EXTS[@]}"; do
  [[ ${#SRC_FIND_ARGS[@]} -gt 0 ]] && SRC_FIND_ARGS+=(-o)
  SRC_FIND_ARGS+=(-name "$ext")
done

# Build grep --include flags
GREP_INCLUDE=()
for ext in "${SRC_EXTS[@]}"; do
  GREP_INCLUDE+=(--include="$ext")
done

# ── Total source files ────────────────────────────────────────────────────────
SOURCE_FILES=$(find . "${FIND_EXCLUDE[@]}" \( "${SRC_FIND_ARGS[@]}" \) 2>/dev/null | wc -l | tr -d ' ')

# ═══════════════════════════════════════════════════════════════════════════════
# A. HEAVY DEPENDENCY ANALYSIS
# ═══════════════════════════════════════════════════════════════════════════════

HEAVY_DEPS="[]"
HEAVY_DEP_COUNT=0

# ── Node.js: known heavy packages used for trivial tasks ─────────────────────
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]] && [[ -f "package.json" ]]; then
  # lodash: check if used for just 1-2 functions (should use native ES)
  LODASH_PRESENT=$( (grep -q '"lodash"' package.json 2>/dev/null || grep -q '"lodash-es"' package.json 2>/dev/null) && echo "true" || echo "false")
  LODASH_USAGE=0
  if [[ "$LODASH_PRESENT" == "true" ]]; then
    LODASH_USAGE=$(safe_grep_count -rn "from 'lodash\|require('lodash\|from \"lodash\|require(\"lodash" \
      "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  fi

  # moment: heavy date library (use date-fns or dayjs)
  MOMENT_PRESENT=$(grep -q '"moment"' package.json 2>/dev/null && echo "true" || echo "false")

  # axios in browser (fetch is native)
  AXIOS_PRESENT=$(grep -q '"axios"' package.json 2>/dev/null && echo "true" || echo "false")
  AXIOS_IN_BROWSER=$(safe_grep_count -rn "import axios\|require('axios\|require(\"axios" \
    "${GREP_EXCLUDE[@]}" --include="*.tsx" --include="*.jsx" .)

  # request: deprecated (use got/node-fetch/axios)
  REQUEST_PRESENT=$(grep -q '"request"' package.json 2>/dev/null && echo "true" || echo "false")

  # uuid: crypto.randomUUID() is native in Node 14.17+
  UUID_PRESENT=$(grep -q '"uuid"' package.json 2>/dev/null && echo "true" || echo "false")

  HEAVY_DEPS=$(jq -n \
    --argjson lodash "$LODASH_PRESENT" \
    --argjson lodash_usage "$LODASH_USAGE" \
    --argjson moment "$MOMENT_PRESENT" \
    --argjson axios "$AXIOS_PRESENT" \
    --argjson axios_browser "$AXIOS_IN_BROWSER" \
    --argjson request "$REQUEST_PRESENT" \
    --argjson uuid "$UUID_PRESENT" \
    '[
      if $lodash and $lodash_usage < 5 then {
        package: "lodash", severity: "high",
        reason: ("Used " + ($lodash_usage|tostring) + " import(s) — replace with native ES methods"),
        alternative: "native ES6+"
      } else empty end,
      if $lodash and $lodash_usage >= 5 then {
        package: "lodash", severity: "medium",
        reason: "Consider lodash-es for tree-shaking or migrate to native methods",
        alternative: "lodash-es or native ES6+"
      } else empty end,
      if $moment then {
        package: "moment", severity: "high",
        reason: "moment.js is 67KB minified; no tree-shaking support",
        alternative: "date-fns (tree-shakable) or dayjs (2KB)"
      } else empty end,
      if $axios and $axios_browser > 0 then {
        package: "axios (browser)", severity: "medium",
        reason: "Browser already has native fetch(); axios adds ~13KB",
        alternative: "fetch() or ky (3KB)"
      } else empty end,
      if $request then {
        package: "request", severity: "high",
        reason: "Deprecated since 2020; no native Promise support",
        alternative: "got, node-fetch, or axios"
      } else empty end,
      if $uuid then {
        package: "uuid", severity: "low",
        reason: "Node 14.17+ and modern browsers have crypto.randomUUID()",
        alternative: "crypto.randomUUID() (native)"
      } else empty end
    ]')

  HEAVY_DEP_COUNT=$(echo "$HEAVY_DEPS" | jq 'length')
fi

# ── Python: known heavy packages for simple tasks ─────────────────────────────
PYTHON_HEAVY_DEPS="[]"
PYTHON_HEAVY_COUNT=0

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  REQ_FILE=""
  [[ -f "requirements.txt" ]] && REQ_FILE="requirements.txt"
  [[ -f "pyproject.toml" ]]   && REQ_FILE="pyproject.toml"

  if [[ -n "$REQ_FILE" ]]; then
    # pandas for simple CSV reading (use csv module)
    PANDAS_PRESENT=$(grep -qi "pandas" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    PANDAS_CSV_ONLY=0
    if [[ "$PANDAS_PRESENT" == "true" ]]; then
      PANDAS_READ_CSV=$(safe_grep_count -rn "\.read_csv\|\.read_excel\|\.read_json" \
        "${GREP_EXCLUDE[@]}" --include="*.py" .)
      PANDAS_DF_OPS=$(safe_grep_count -rn "\.groupby\|\.merge\|\.pivot\|\.resample\|\.rolling" \
        "${GREP_EXCLUDE[@]}" --include="*.py" .)
      if [[ $PANDAS_READ_CSV -gt 0 && $PANDAS_DF_OPS -eq 0 ]]; then
        PANDAS_CSV_ONLY=1
      fi
    fi

    # requests when httpx (async) would be better
    REQUESTS_PRESENT=$(grep -qi "^requests" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    IS_ASYNC_PROJECT=$(safe_grep_count -rn "async def\|await " "${GREP_EXCLUDE[@]}" --include="*.py" .)

    # SQLAlchemy when raw queries suffice (small apps)
    SQLALCHEMY_PRESENT=$(grep -qi "sqlalchemy" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")

    # Jinja2 when f-strings suffice
    JINJA_PRESENT=$(grep -qi "jinja2\|jinja" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    JINJA_USAGE=$(safe_grep_count -rn "from jinja2\|import jinja2\|Environment(" \
      "${GREP_EXCLUDE[@]}" --include="*.py" .)

    PYTHON_HEAVY_DEPS=$(jq -n \
      --argjson pandas "$PANDAS_PRESENT" \
      --argjson pandas_csv_only "$PANDAS_CSV_ONLY" \
      --argjson requests "$REQUESTS_PRESENT" \
      --argjson is_async "$IS_ASYNC_PROJECT" \
      --argjson sqlalchemy "$SQLALCHEMY_PRESENT" \
      --argjson jinja "$JINJA_PRESENT" \
      --argjson jinja_usage "$JINJA_USAGE" \
      '[
        if $pandas and ($pandas_csv_only == 1) then {
          package: "pandas", severity: "medium",
          reason: "Only used for CSV reading — pandas is ~30MB installed",
          alternative: "csv module (stdlib) or polars for performance"
        } else empty end,
        if $requests and ($is_async > 10) then {
          package: "requests", severity: "medium",
          reason: "Sync requests in async codebase blocks event loop",
          alternative: "httpx (async-native) or aiohttp"
        } else empty end,
        if $jinja and ($jinja_usage < 3) then {
          package: "Jinja2", severity: "low",
          reason: ("Used " + ($jinja_usage|tostring) + " time(s) — f-strings may suffice"),
          alternative: "Python f-strings or string.Template (stdlib)"
        } else empty end
      ]')
    PYTHON_HEAVY_COUNT=$(echo "$PYTHON_HEAVY_DEPS" | jq 'length')
  fi
fi

ALL_HEAVY_DEPS=$(jq -n --argjson n "$HEAVY_DEPS" --argjson p "$PYTHON_HEAVY_DEPS" '$n + $p')
TOTAL_HEAVY=$(( HEAVY_DEP_COUNT + PYTHON_HEAVY_COUNT ))

# ═══════════════════════════════════════════════════════════════════════════════
# B. PERFORMANCE ANTI-PATTERNS
# ═══════════════════════════════════════════════════════════════════════════════

# ── Sync I/O in async contexts (Node.js) ─────────────────────────────────────
SYNC_IO_COUNT=0
SYNC_IO_LOCATIONS=""
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  SYNC_IO_COUNT=$(safe_grep_count -rn \
    "readFileSync\|writeFileSync\|execSync\|spawnSync\|mkdirSync\|readdirSync\|statSync\|existsSync" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  SYNC_IO_LOCATIONS=$({ grep -rn "readFileSync\|writeFileSync\|execSync\|spawnSync" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" . 2>/dev/null || :; } | head -5 | \
    awk -F: '{printf "%s:%s,", $1, $2}' | sed 's/,$//')
fi

# ── Sync I/O in async contexts (Python) ──────────────────────────────────────
PYTHON_SYNC_IO_COUNT=0
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  # open() calls not wrapped in aiofiles / async with
  PYTHON_SYNC_IO_COUNT=$(safe_grep_count -rn "open(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" . )
fi

TOTAL_SYNC_IO=$(( SYNC_IO_COUNT + PYTHON_SYNC_IO_COUNT ))

# ── N+1 query patterns ────────────────────────────────────────────────────────
# Heuristic: query method calls in codebase + loop count → risk flag
N_PLUS_ONE_COUNT=$(safe_grep_count -rn "for\s\|while\s" "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
QUERY_IN_LOOP=$(safe_grep_count -rn "\.find\|\.findOne\|\.query\|\.execute\|\.fetchone\|\.get(" \
  "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
N_PLUS_ONE_RISK=$( [[ $QUERY_IN_LOOP -gt 0 && $N_PLUS_ONE_COUNT -gt 0 ]] && echo 1 || echo 0 )

# ── Missing memoization ───────────────────────────────────────────────────────
REPEATED_CALLS=$(safe_grep_count -rn \
  "JSON\.parse\|JSON\.stringify\|\.split(\|\.replace(\|\.map(\|\.filter(" \
  "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
HAS_MEMOIZE=$(safe_grep_count -rn \
  "memoize\|lru_cache\|functools\.cache\|useMemo\|useCallback\|\.memoize" \
  "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
MISSING_MEMO_RISK=$( [[ $REPEATED_CALLS -gt 20 && $HAS_MEMOIZE -eq 0 ]] && echo 1 || echo 0 )

# ── Wildcard / barrel imports ─────────────────────────────────────────────────
WILDCARD_IMPORTS=0
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  WILDCARD_IMPORTS=$(safe_grep_count -rn "import \* as\|export \* from" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
fi
WILDCARD_PY=0
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  WILDCARD_PY=$(safe_grep_count -rn "^from .* import \*" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi
TOTAL_WILDCARD=$(( WILDCARD_IMPORTS + WILDCARD_PY ))

# ═══════════════════════════════════════════════════════════════════════════════
# C. BUILD & BUNDLE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

NO_TREESHAKING=false
DUPLICATE_DEPS=0
HAS_BUNDLE_ANALYZER=false

if [[ -f "tsconfig.json" ]]; then
  # Use grep (not jq) because tsconfig.json may be JSONC with comments
  if grep -qi '"module"\s*:\s*"commonjs"' tsconfig.json 2>/dev/null; then
    NO_TREESHAKING=true
  fi
fi

if [[ -f "package.json" ]]; then
  HAS_BUNDLE_ANALYZER=$(grep -q "bundle-analyzer\|bundlesize\|source-map-explorer" package.json 2>/dev/null \
    && echo "true" || echo "false")
  if [[ -f "package-lock.json" ]]; then
    DUPLICATE_DEPS=$(jq '[.packages // {} | to_entries[] | .key] | group_by(split("/")[-1]) | map(select(length > 1)) | length' \
      package-lock.json 2>/dev/null || echo "0")
    DUPLICATE_DEPS=${DUPLICATE_DEPS:-0}
  fi
fi

# ── Bundler detection ─────────────────────────────────────────────────────────
HAS_MINIFICATION=false
BUNDLER="none"
[[ -f "webpack.config.js" || -f "webpack.config.ts" ]] && BUNDLER="webpack"
[[ -f "vite.config.js" || -f "vite.config.ts" ]]       && BUNDLER="vite"
[[ -f "esbuild.config.js" ]]                            && BUNDLER="esbuild"
[[ -f "rollup.config.js" ]]                             && BUNDLER="rollup"

if [[ "$BUNDLER" == "webpack" ]]; then
  { grep -q "minimize\|UglifyJsPlugin\|TerserPlugin" webpack.config.* 2>/dev/null && HAS_MINIFICATION=true; } || true
elif [[ "$BUNDLER" == "vite" ]]; then
  HAS_MINIFICATION=true  # vite minifies by default
fi

# ═══════════════════════════════════════════════════════════════════════════════
# D. STARTUP PERFORMANCE
# ═══════════════════════════════════════════════════════════════════════════════

# Expensive sync work at module top level
TOP_LEVEL_SYNC=0
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  TOP_LEVEL_SYNC=$(safe_grep_count -rn \
    "^const.*=.*readFileSync\|^let.*=.*readFileSync\|^var.*=.*readFileSync" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
fi

# Python: heavy ML/data imports at module level (slow startup)
PYTHON_HEAVY_INIT=0
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  PYTHON_HEAVY_INIT=$(safe_grep_count -rn \
    "^import numpy\|^import pandas\|^import tensorflow\|^import torch\|^import scipy" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi

TOTAL_HEAVY_INIT=$(( TOP_LEVEL_SYNC + PYTHON_HEAVY_INIT ))

# ── Dynamic imports / lazy loading ───────────────────────────────────────────
HAS_LAZY_LOADING=false
LAZY_COUNT=0
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  LAZY_COUNT=$(safe_grep_count -rn "import(\|React\.lazy\|lazy(() =>" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  [[ $LAZY_COUNT -gt 0 ]] && HAS_LAZY_LOADING=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E. CACHING OPPORTUNITIES
# ═══════════════════════════════════════════════════════════════════════════════

ENV_READS_IN_LOOP=$(safe_grep_count -rn "process\.env\.\|os\.environ\[" \
  "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)

FILE_READS_COUNT=0
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  FILE_READS_COUNT=$(safe_grep_count -rn "readFile\|readFileSync" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════════════════════════════════

SCORE=100

# Heavy deps: -8 each, max -24
HEAVY_PENALTY=$(( TOTAL_HEAVY * 8 ))
[[ $HEAVY_PENALTY -gt 24 ]] && HEAVY_PENALTY=24
SCORE=$(( SCORE - HEAVY_PENALTY ))

# Sync I/O in async: -12 per occurrence, cap at 3
SYNC_CAPPED=$TOTAL_SYNC_IO
[[ $SYNC_CAPPED -gt 3 ]] && SYNC_CAPPED=3
SCORE=$(( SCORE - SYNC_CAPPED * 12 ))

# N+1 risk: -10
[[ $N_PLUS_ONE_RISK -eq 1 ]] && SCORE=$(( SCORE - 10 ))

# Missing memoization: -6
[[ $MISSING_MEMO_RISK -eq 1 ]] && SCORE=$(( SCORE - 6 ))

# No tree-shaking: -8
$NO_TREESHAKING && SCORE=$(( SCORE - 8 ))

# Duplicate deps: -5 each, max -15
DUP_PENALTY=$(( DUPLICATE_DEPS * 5 ))
[[ $DUP_PENALTY -gt 15 ]] && DUP_PENALTY=15
SCORE=$(( SCORE - DUP_PENALTY ))

# Heavy startup init: -5 each, max -15
INIT_CAPPED=$TOTAL_HEAVY_INIT
[[ $INIT_CAPPED -gt 3 ]] && INIT_CAPPED=3
SCORE=$(( SCORE - INIT_CAPPED * 5 ))

# Wildcard imports: -3 each, max -9
WILD_CAPPED=$TOTAL_WILDCARD
[[ $WILD_CAPPED -gt 3 ]] && WILD_CAPPED=3
SCORE=$(( SCORE - WILD_CAPPED * 3 ))

# Floor at 0
[[ $SCORE -lt 0 ]] && SCORE=0

# Status thresholds
if [[ $SCORE -ge 80 ]]; then   STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
elif [[ $SCORE -ge 40 ]]; then STATUS="needs_work"
else                            STATUS="critical"
fi

# ── Emit JSON ─────────────────────────────────────────────────────────────────
cat <<EOF
{
  "score": $SCORE,
  "status": "$STATUS",
  "project_type": "$PROJECT_TYPE",
  "source_files": $SOURCE_FILES,
  "deps": {
    "heavy": $ALL_HEAVY_DEPS,
    "heavy_count": $TOTAL_HEAVY
  },
  "patterns": {
    "sync_in_async": {
      "count": $TOTAL_SYNC_IO,
      "nodejs_count": $SYNC_IO_COUNT,
      "python_count": $PYTHON_SYNC_IO_COUNT,
      "locations": "$SYNC_IO_LOCATIONS"
    },
    "n_plus_one_risk": $N_PLUS_ONE_RISK,
    "query_count": $QUERY_IN_LOOP,
    "loop_count": $N_PLUS_ONE_COUNT,
    "missing_memoize_risk": $MISSING_MEMO_RISK,
    "memoize_usage": $HAS_MEMOIZE,
    "wildcard_imports": $TOTAL_WILDCARD
  },
  "build": {
    "bundler": "$BUNDLER",
    "no_treeshaking": $NO_TREESHAKING,
    "has_minification": $HAS_MINIFICATION,
    "has_bundle_analyzer": $HAS_BUNDLE_ANALYZER,
    "duplicate_deps": $DUPLICATE_DEPS
  },
  "startup": {
    "top_level_sync_reads": $TOP_LEVEL_SYNC,
    "heavy_module_imports": $PYTHON_HEAVY_INIT,
    "total_heavy_init": $TOTAL_HEAVY_INIT,
    "has_lazy_loading": $HAS_LAZY_LOADING,
    "lazy_import_count": $LAZY_COUNT
  },
  "cache": {
    "env_reads": $ENV_READS_IN_LOOP,
    "file_reads": $FILE_READS_COUNT,
    "has_memoize": $HAS_MEMOIZE
  }
}
EOF
