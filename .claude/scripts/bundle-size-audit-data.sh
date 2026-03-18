#!/usr/bin/env bash
# bundle-size-audit-data.sh
# Pre-process bundle size audit metrics for /performance:bundle-size skill
# Returns JSON with dependency weight, duplicate deps, tree-shaking gaps, and devDep leakage
#
# Usage: ./scripts/bundle-size-audit-data.sh
# Output: JSON object with bundle size findings, scores, and metadata
#
# Supports: npm (package.json/package-lock.json/yarn.lock/pnpm-lock.yaml), pip (requirements.txt/pyproject.toml)
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Common exclusion patterns ─────────────────────────────────────────────────
FIND_EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/.git/*'
              -not -path '*/__pycache__/*' -not -path '*/venv/*'
              -not -path '*/.venv/*' -not -path '*/dist/*'
              -not -path '*/build/*' -not -path '*/.next/*'
              -not -path '*/coverage/*' -not -path '*/.cache/*')
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git
              --exclude-dir=__pycache__ --exclude-dir=venv
              --exclude-dir=.venv --exclude-dir=dist
              --exclude-dir=build --exclude-dir=.next
              --exclude-dir=coverage --exclude-dir=.cache)

# Helper: grep that never fails due to no matches (grep exits 1 on no match)
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

safe_grep_lines() {
  { grep "$@" 2>/dev/null || :; } | head -5
}

# ── Detect project type ───────────────────────────────────────────────────────
PROJECT_TYPE="unknown"
[[ -f "package.json" ]]                                              && PROJECT_TYPE="nodejs"
[[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]] && PROJECT_TYPE="python"
[[ -f "package.json" && ( -f "requirements.txt" || -f "pyproject.toml" ) ]] && PROJECT_TYPE="multi"

# ── Package manager detection ─────────────────────────────────────────────────
PKG_MANAGER="none"
if [[ -f "package.json" ]]; then
  [[ -f "package-lock.json" ]] && PKG_MANAGER="npm"
  [[ -f "yarn.lock" ]]         && PKG_MANAGER="yarn"
  [[ -f "pnpm-lock.yaml" ]]    && PKG_MANAGER="pnpm"
  [[ "$PKG_MANAGER" == "none" ]] && PKG_MANAGER="npm"  # default if package.json present
fi
if [[ "$PROJECT_TYPE" == "python" && "$PKG_MANAGER" == "none" ]]; then
  PKG_MANAGER="pip"
fi

# ── Source file extensions ────────────────────────────────────────────────────
case "$PROJECT_TYPE" in
  nodejs) SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.jsx" "*.mjs" "*.cjs") ;;
  python) SRC_EXTS=("*.py") ;;
  *)      SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.jsx" "*.py") ;;
esac

GREP_INCLUDE=()
for ext in "${SRC_EXTS[@]}"; do
  GREP_INCLUDE+=(--include="$ext")
done

# Non-test source files (exclude test/spec files and __tests__ directories)
GREP_INCLUDE_SRC=()
for ext in "${SRC_EXTS[@]}"; do
  GREP_INCLUDE_SRC+=(--include="$ext")
done
GREP_EXCLUDE_TESTS=(--exclude-dir=__tests__ --exclude-dir=test --exclude-dir=tests
                    --exclude-dir=spec --exclude="*.test.*" --exclude="*.spec.*")

# ═══════════════════════════════════════════════════════════════════════════════
# A. HEAVYWEIGHT DEPENDENCIES WITH LIGHTER ALTERNATIVES
# ═══════════════════════════════════════════════════════════════════════════════

HEAVY_DEPS="[]"
HEAVY_DEP_COUNT=0

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]] && [[ -f "package.json" ]]; then

  # ── moment: 67KB minified, no tree-shaking ────────────────────────────────
  MOMENT_PRESENT=$(grep -q '"moment"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── lodash: 70KB, should use native ES6+ or lodash-es ────────────────────
  LODASH_PRESENT=$( { grep -q '"lodash"' package.json 2>/dev/null || \
    grep -q '"lodash-es"' package.json 2>/dev/null; } && echo "true" || echo "false" )
  LODASH_USAGE=0
  LODASH_ES_PRESENT=$(grep -q '"lodash-es"' package.json 2>/dev/null && echo "true" || echo "false")
  if [[ "$LODASH_PRESENT" == "true" ]]; then
    LODASH_USAGE=$(safe_grep_count -rn \
      "from 'lodash\|require('lodash\|from \"lodash\|require(\"lodash" \
      "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  fi

  # ── jQuery: rarely needed in modern apps ──────────────────────────────────
  JQUERY_PRESENT=$(grep -q '"jquery"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── underscore: superseded by lodash / native ─────────────────────────────
  UNDERSCORE_PRESENT=$(grep -q '"underscore"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── request: deprecated ───────────────────────────────────────────────────
  REQUEST_PRESENT=$(grep -q '"request"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── bluebird: native Promise is sufficient in Node 12+ ────────────────────
  BLUEBIRD_PRESENT=$(grep -q '"bluebird"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── uuid: crypto.randomUUID() native in Node 14.17+ ──────────────────────
  UUID_PRESENT=$(grep -q '"uuid"' package.json 2>/dev/null && echo "true" || echo "false")

  # ── validator: many checks are one-liners in native JS ────────────────────
  VALIDATOR_PRESENT=$(grep -q '"validator"' package.json 2>/dev/null && echo "true" || echo "false")
  VALIDATOR_USAGE=$(safe_grep_count -rn \
    "from 'validator\|require('validator\|from \"validator" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)

  HEAVY_DEPS=$(jq -n \
    --argjson moment "$MOMENT_PRESENT" \
    --argjson lodash "$LODASH_PRESENT" \
    --argjson lodash_usage "$LODASH_USAGE" \
    --argjson lodash_es "$LODASH_ES_PRESENT" \
    --argjson jquery "$JQUERY_PRESENT" \
    --argjson underscore "$UNDERSCORE_PRESENT" \
    --argjson request "$REQUEST_PRESENT" \
    --argjson bluebird "$BLUEBIRD_PRESENT" \
    --argjson uuid "$UUID_PRESENT" \
    --argjson validator "$VALIDATOR_PRESENT" \
    --argjson validator_usage "$VALIDATOR_USAGE" \
    '[
      if $moment then {
        package: "moment", size_kb: 67, severity: "high",
        reason: "moment.js is 67KB minified+gzipped with no tree-shaking support",
        alternative: "date-fns (tree-shakable, pay-per-function) or dayjs (2KB)"
      } else empty end,
      if $lodash and ($lodash_es | not) and $lodash_usage < 5 then {
        package: "lodash", size_kb: 70, severity: "high",
        reason: ("Used " + ($lodash_usage|tostring) + " import(s) — lodash is 70KB and not tree-shakable"),
        alternative: "native ES6+ methods or lodash-es (tree-shakable)"
      } else empty end,
      if $lodash and ($lodash_es | not) and $lodash_usage >= 5 then {
        package: "lodash", size_kb: 70, severity: "medium",
        reason: "lodash is not tree-shakable — all 70KB included even for partial use",
        alternative: "lodash-es for tree-shaking, or migrate hot functions to native ES6+"
      } else empty end,
      if $jquery then {
        package: "jquery", size_kb: 30, severity: "medium",
        reason: "jQuery rarely needed in modern frameworks (React/Vue/Angular handle DOM)",
        alternative: "vanilla JS DOM APIs (querySelector, fetch, addEventListener)"
      } else empty end,
      if $underscore then {
        package: "underscore", size_kb: 17, severity: "medium",
        reason: "underscore is superseded by lodash and native ES6+ methods",
        alternative: "native ES6+ or lodash-es (if lodash functions needed)"
      } else empty end,
      if $request then {
        package: "request", size_kb: 50, severity: "high",
        reason: "request is deprecated since 2020 with no Promise support",
        alternative: "got, node-fetch, axios, or native fetch (Node 18+)"
      } else empty end,
      if $bluebird then {
        package: "bluebird", size_kb: 18, severity: "low",
        reason: "native Promise is sufficient in Node 12+ and all modern browsers",
        alternative: "native Promise / async-await"
      } else empty end,
      if $uuid then {
        package: "uuid", size_kb: 8, severity: "low",
        reason: "crypto.randomUUID() is native in Node 14.17+ and modern browsers",
        alternative: "crypto.randomUUID() (native — zero dependencies)"
      } else empty end,
      if $validator and $validator_usage < 4 then {
        package: "validator", size_kb: 20, severity: "low",
        reason: ("Used " + ($validator_usage|tostring) + " time(s) — most checks are one-liners"),
        alternative: "native regex or zod/yup for schema validation"
      } else empty end
    ]')

  HEAVY_DEP_COUNT=$(echo "$HEAVY_DEPS" | jq 'length')
fi

# ── Python: heavyweight packages with lighter alternatives ────────────────────
PYTHON_HEAVY_DEPS="[]"
PYTHON_HEAVY_COUNT=0

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  REQ_FILE=""
  [[ -f "requirements.txt" ]] && REQ_FILE="requirements.txt"
  [[ -f "pyproject.toml" ]]   && REQ_FILE="pyproject.toml"

  if [[ -n "$REQ_FILE" ]]; then
    PANDAS_PRESENT=$(grep -qi "^pandas\|\"pandas\"\|'pandas'" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    PANDAS_CSV_ONLY=0
    if [[ "$PANDAS_PRESENT" == "true" ]]; then
      PANDAS_READ_CSV=$(safe_grep_count -rn "\.read_csv\|\.read_excel\|\.read_json" \
        "${GREP_EXCLUDE[@]}" --include="*.py" .)
      PANDAS_DF_OPS=$(safe_grep_count -rn "\.groupby\|\.merge\|\.pivot\|\.resample\|\.rolling\|\.apply\|\.agg" \
        "${GREP_EXCLUDE[@]}" --include="*.py" .)
      [[ $PANDAS_READ_CSV -gt 0 && $PANDAS_DF_OPS -eq 0 ]] && PANDAS_CSV_ONLY=1
    fi

    REQUESTS_PRESENT=$(grep -qi "^requests\b\|\"requests\"\|'requests'" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    IS_ASYNC_PROJECT=$(safe_grep_count -rn "async def\|await " "${GREP_EXCLUDE[@]}" --include="*.py" .)

    PYYAML_PRESENT=$(grep -qi "pyyaml\|^yaml\b" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    PYYAML_USAGE=$(safe_grep_count -rn "import yaml\|from yaml" "${GREP_EXCLUDE[@]}" --include="*.py" .)

    PILLOW_PRESENT=$(grep -qi "pillow\|^PIL\b" "$REQ_FILE" 2>/dev/null && echo "true" || echo "false")
    PILLOW_USAGE=$(safe_grep_count -rn "from PIL\|import PIL\|Image\.open\|Image\.new" \
      "${GREP_EXCLUDE[@]}" --include="*.py" .)

    PYTHON_HEAVY_DEPS=$(jq -n \
      --argjson pandas "$PANDAS_PRESENT" \
      --argjson pandas_csv_only "$PANDAS_CSV_ONLY" \
      --argjson requests "$REQUESTS_PRESENT" \
      --argjson is_async "$IS_ASYNC_PROJECT" \
      --argjson pyyaml "$PYYAML_PRESENT" \
      --argjson pyyaml_usage "$PYYAML_USAGE" \
      --argjson pillow "$PILLOW_PRESENT" \
      --argjson pillow_usage "$PILLOW_USAGE" \
      '[
        if $pandas and ($pandas_csv_only == 1) then {
          package: "pandas", size_kb: 30720, severity: "medium",
          reason: "Only CSV I/O detected — pandas is ~30MB installed for just read_csv()",
          alternative: "csv module (stdlib) or polars (~3MB) for performance"
        } else empty end,
        if $requests and ($is_async > 10) then {
          package: "requests", size_kb: 400, severity: "medium",
          reason: "Sync requests in async codebase blocks the event loop",
          alternative: "httpx (async-native) or aiohttp"
        } else empty end,
        if $pyyaml and ($pyyaml_usage < 3) then {
          package: "PyYAML", size_kb: 200, severity: "low",
          reason: ("Used " + ($pyyaml_usage|tostring) + " time(s) — consider json or tomllib (stdlib)"),
          alternative: "json module (stdlib) or tomllib (Python 3.11+)"
        } else empty end,
        if $pillow and ($pillow_usage < 3) then {
          package: "Pillow", size_kb: 10240, severity: "low",
          reason: ("Used " + ($pillow_usage|tostring) + " time(s) — Pillow is ~10MB installed"),
          alternative: "imghdr (stdlib) for detection, or a smaller focused library"
        } else empty end
      ]')
    PYTHON_HEAVY_COUNT=$(echo "$PYTHON_HEAVY_DEPS" | jq 'length')
  fi
fi

ALL_HEAVY_DEPS=$(jq -n --argjson n "$HEAVY_DEPS" --argjson p "$PYTHON_HEAVY_DEPS" '$n + $p')
TOTAL_HEAVY=$(( HEAVY_DEP_COUNT + PYTHON_HEAVY_COUNT ))

# ═══════════════════════════════════════════════════════════════════════════════
# B. DUPLICATE DEPENDENCIES IN LOCK FILE
# ═══════════════════════════════════════════════════════════════════════════════

DUPLICATE_DEPS="[]"
DUPLICATE_COUNT=0
DUPLICATE_RAW=0

if [[ -f "package-lock.json" ]]; then
  # Count packages appearing at multiple versions (nested deduplication failures)
  DUPLICATE_RAW=$(jq '
    [.packages // {} | to_entries[]
      | select(.key | startswith("node_modules/"))
      | { name: (.key | ltrimstr("node_modules/") | split("/node_modules/")[-1]), version: .value.version }
    ]
    | group_by(.name)
    | map(select(length > 1))
    | length
  ' package-lock.json 2>/dev/null || echo "0")
  DUPLICATE_RAW=${DUPLICATE_RAW:-0}
  DUPLICATE_COUNT=$DUPLICATE_RAW

  # Build top duplicates list (first 5)
  DUPLICATE_DEPS=$(jq '
    [.packages // {} | to_entries[]
      | select(.key | startswith("node_modules/"))
      | { name: (.key | ltrimstr("node_modules/") | split("/node_modules/")[-1]), version: .value.version }
    ]
    | group_by(.name)
    | map(select(length > 1))
    | sort_by(-length)
    | .[0:5]
    | map({
        package: .[0].name,
        versions: [.[].version] | unique,
        copy_count: length,
        severity: "medium"
      })
  ' package-lock.json 2>/dev/null || echo "[]")
elif [[ -f "yarn.lock" ]]; then
  # Count duplicate package name blocks in yarn.lock
  DUPLICATE_RAW=$(grep -c '^"' yarn.lock 2>/dev/null || echo "0")
  # Yarn.lock duplicates: same package at different version constraints
  UNIQUE_PKGS=$(grep '^"' yarn.lock 2>/dev/null | sed 's/@[^@"]*".*$//' | sort -u | wc -l | tr -d ' ')
  TOTAL_PKGS=$(grep -c '^"' yarn.lock 2>/dev/null || echo "0")
  DUPLICATE_COUNT=$(( TOTAL_PKGS - UNIQUE_PKGS ))
  [[ $DUPLICATE_COUNT -lt 0 ]] && DUPLICATE_COUNT=0
  DUPLICATE_DEPS="[]"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# C. TREE-SHAKING OPPORTUNITIES
# ═══════════════════════════════════════════════════════════════════════════════

NO_TREESHAKING=false
TREESHAKING_REASON=""
WILDCARD_IMPORTS=0
BARREL_IMPORT_COUNT=0

if [[ -f "tsconfig.json" ]]; then
  if grep -qi '"module"\s*:\s*"commonjs"' tsconfig.json 2>/dev/null; then
    NO_TREESHAKING=true
    TREESHAKING_REASON="tsconfig.json uses CommonJS module format — prevents tree-shaking"
  fi
fi

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  WILDCARD_IMPORTS=$(safe_grep_count -rn "import \* as\|export \* from" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  # Barrel imports: importing many named exports from a large library
  BARREL_IMPORT_COUNT=$(safe_grep_count -rn \
    "^import {[^}]\{50,\}} from\|^import {[^}]*,[^}]*,[^}]*,[^}]*,[^}]*} from" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
fi

WILDCARD_PY=0
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  WILDCARD_PY=$(safe_grep_count -rn "^from .* import \*" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi

TOTAL_WILDCARD=$(( WILDCARD_IMPORTS + WILDCARD_PY ))

# ── Bundler / tree-shaking config ─────────────────────────────────────────────
BUNDLER="none"
HAS_BUNDLE_ANALYZER=false
[[ -f "webpack.config.js" || -f "webpack.config.ts" ]] && BUNDLER="webpack"
[[ -f "vite.config.js" || -f "vite.config.ts" ]]       && BUNDLER="vite"
[[ -f "esbuild.config.js" ]]                            && BUNDLER="esbuild"
[[ -f "rollup.config.js" || -f "rollup.config.ts" ]]   && BUNDLER="rollup"
[[ -f "next.config.js" || -f "next.config.ts" ]]       && BUNDLER="next"

if [[ -f "package.json" ]]; then
  HAS_BUNDLE_ANALYZER=$(grep -q \
    "bundle-analyzer\|bundlesize\|source-map-explorer\|bundle-visualizer\|rollup-plugin-visualizer" \
    package.json 2>/dev/null && echo "true" || echo "false")
fi

# ═══════════════════════════════════════════════════════════════════════════════
# D. DYNAMIC VS STATIC IMPORT OPPORTUNITIES
# ═══════════════════════════════════════════════════════════════════════════════

HAS_LAZY_LOADING=false
LAZY_COUNT=0
STATIC_LARGE_IMPORTS=0

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  LAZY_COUNT=$(safe_grep_count -rn "import(\|React\.lazy\|lazy(() =>" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
  [[ $LAZY_COUNT -gt 0 ]] && HAS_LAZY_LOADING=true

  # Heuristic: large component/page files that are statically imported (could be lazy)
  STATIC_LARGE_IMPORTS=$(safe_grep_count -rn \
    "^import.*from.*[Pp]age\|^import.*from.*[Dd]ashboard\|^import.*from.*[Mm]odal\|^import.*from.*[Cc]hart" \
    "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE[@]}" .)
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E. DEVDEPENDENCY LEAKAGE INTO PRODUCTION CODE
# ═══════════════════════════════════════════════════════════════════════════════

DEVDEP_LEAKAGE="[]"
DEVDEP_LEAKAGE_COUNT=0

if [[ -f "package.json" ]] && command -v jq >/dev/null 2>&1; then
  # Extract devDependency names
  DEV_DEPS_LIST=$(jq -r '.devDependencies // {} | keys[]' package.json 2>/dev/null || echo "")

  if [[ -n "$DEV_DEPS_LIST" ]]; then
    # Common devDeps that should never appear in production source
    LEAK_PATTERNS=("@types/" "jest" "mocha" "chai" "sinon" "eslint" "prettier"
                   "webpack" "rollup" "esbuild" "vite" "babel" "ts-node" "nodemon"
                   "husky" "lint-staged" "vitest")

    LEAKED_PKGS="[]"
    for pattern in "${LEAK_PATTERNS[@]}"; do
      # Check if any matching devDep is imported in non-test source
      MATCHES=$(echo "$DEV_DEPS_LIST" | grep "$pattern" 2>/dev/null || true)
      for pkg in $MATCHES; do
        IMPORT_COUNT=$(safe_grep_count -rn \
          "from '${pkg}'\|require('${pkg}')\|from \"${pkg}\"\|require(\"${pkg}\")" \
          "${GREP_EXCLUDE[@]}" "${GREP_INCLUDE_SRC[@]}" "${GREP_EXCLUDE_TESTS[@]}" .)
        if [[ $IMPORT_COUNT -gt 0 ]]; then
          LEAKED_PKGS=$(echo "$LEAKED_PKGS" | jq \
            --arg pkg "$pkg" --argjson count "$IMPORT_COUNT" \
            '. + [{"package": $pkg, "import_count": $count, "severity": "critical"}]')
          DEVDEP_LEAKAGE_COUNT=$(( DEVDEP_LEAKAGE_COUNT + 1 ))
        fi
      done
    done
    DEVDEP_LEAKAGE="$LEAKED_PKGS"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════════════════════════════════

SCORE=100

# Heavyweight deps: -10 each for high severity, -5 for medium, max -30
HIGH_HEAVY=$(echo "$ALL_HEAVY_DEPS" | jq '[.[] | select(.severity == "high")] | length')
MED_HEAVY=$(echo "$ALL_HEAVY_DEPS" | jq '[.[] | select(.severity == "medium")] | length')
HEAVY_PENALTY=$(( HIGH_HEAVY * 10 + MED_HEAVY * 5 ))
[[ $HEAVY_PENALTY -gt 30 ]] && HEAVY_PENALTY=30
SCORE=$(( SCORE - HEAVY_PENALTY ))

# Duplicate deps: -5 each, max -20
DUP_PENALTY=$(( DUPLICATE_COUNT * 5 ))
[[ $DUP_PENALTY -gt 20 ]] && DUP_PENALTY=20
SCORE=$(( SCORE - DUP_PENALTY ))

# No tree-shaking: -8
$NO_TREESHAKING && SCORE=$(( SCORE - 8 ))

# DevDep leakage: -10 each, max -20
LEAK_PENALTY=$(( DEVDEP_LEAKAGE_COUNT * 10 ))
[[ $LEAK_PENALTY -gt 20 ]] && LEAK_PENALTY=20
SCORE=$(( SCORE - LEAK_PENALTY ))

# No dynamic imports (large app without code splitting): -5
if [[ "$BUNDLER" != "none" && "$HAS_LAZY_LOADING" == "false" && $STATIC_LARGE_IMPORTS -gt 3 ]]; then
  SCORE=$(( SCORE - 5 ))
fi

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
  "pkg_manager": "$PKG_MANAGER",
  "bundler": "$BUNDLER",
  "has_bundle_analyzer": $HAS_BUNDLE_ANALYZER,
  "heavy_deps": $ALL_HEAVY_DEPS,
  "heavy_dep_count": $TOTAL_HEAVY,
  "duplicates": $DUPLICATE_DEPS,
  "duplicate_count": $DUPLICATE_COUNT,
  "treeshaking": {
    "no_esm": $NO_TREESHAKING,
    "reason": "$TREESHAKING_REASON",
    "wildcard_imports": $TOTAL_WILDCARD,
    "barrel_imports": $BARREL_IMPORT_COUNT
  },
  "code_splitting": {
    "has_lazy_loading": $HAS_LAZY_LOADING,
    "lazy_count": $LAZY_COUNT,
    "static_large_imports": $STATIC_LARGE_IMPORTS
  },
  "devdep_leakage": $DEVDEP_LEAKAGE,
  "devdep_leakage_count": $DEVDEP_LEAKAGE_COUNT
}
EOF
