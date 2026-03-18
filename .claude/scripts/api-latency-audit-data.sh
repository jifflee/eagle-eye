#!/usr/bin/env bash
# api-latency-audit-data.sh
# Pre-process API latency audit metrics for /performance:api-latency skill
# Returns JSON with framework detection, blocking calls, pagination gaps,
# caching headers, compression, middleware, and serialization findings.
#
# Usage: ./scripts/api-latency-audit-data.sh [--payload-threshold KB]
# Output: JSON object with API latency findings, scores, and metadata
#
# Supported frameworks: Express, FastAPI, Flask, Next.js API routes
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
PAYLOAD_THRESHOLD=50   # KB; flag serialization without projection above this
while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload-threshold) PAYLOAD_THRESHOLD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Common exclusion patterns ─────────────────────────────────────────────────
FIND_EXCLUDE=(-not -path '*/node_modules/*' -not -path '*/.git/*'
              -not -path '*/__pycache__/*' -not -path '*/venv/*'
              -not -path '*/.venv/*' -not -path '*/dist/*'
              -not -path '*/build/*' -not -path '*/.next/*'
              -not -path '*/coverage/*' -not -path '*/test*'
              -not -path '*/__tests__/*' -not -path '*/spec*')
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git
              --exclude-dir=__pycache__ --exclude-dir=venv
              --exclude-dir=.venv --exclude-dir=dist
              --exclude-dir=build --exclude-dir=.next
              --exclude-dir=coverage)

# Helper: grep that never fails on no matches
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

# Helper: grep lines (first N), never fails
safe_grep_lines() {
  local n="$1"; shift
  { grep "$@" 2>/dev/null || :; } | head -"$n"
}

# ═══════════════════════════════════════════════════════════════════════════════
# A. FRAMEWORK DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

FRAMEWORK="unknown"
PROJECT_TYPE="unknown"

# Node.js frameworks
if [[ -f "package.json" ]]; then
  PROJECT_TYPE="nodejs"
  if grep -q '"express"' package.json 2>/dev/null; then
    FRAMEWORK="express"
  elif grep -q '"next"' package.json 2>/dev/null; then
    FRAMEWORK="nextjs"
  elif grep -q '"fastify"' package.json 2>/dev/null; then
    FRAMEWORK="fastify"
  elif grep -q '"koa"' package.json 2>/dev/null; then
    FRAMEWORK="koa"
  else
    FRAMEWORK="nodejs-other"
  fi
fi

# Python frameworks
if [[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]]; then
  PROJECT_TYPE="python"
  REQ_FILE=""
  [[ -f "requirements.txt" ]] && REQ_FILE="requirements.txt"
  [[ -f "pyproject.toml" ]]   && REQ_FILE="pyproject.toml"

  if [[ -n "$REQ_FILE" ]]; then
    if grep -qi "fastapi" "$REQ_FILE" 2>/dev/null; then
      FRAMEWORK="fastapi"
    elif grep -qi "flask" "$REQ_FILE" 2>/dev/null; then
      FRAMEWORK="flask"
    elif grep -qi "django" "$REQ_FILE" 2>/dev/null; then
      FRAMEWORK="django"
    elif grep -qi "starlette" "$REQ_FILE" 2>/dev/null; then
      FRAMEWORK="starlette"
    else
      FRAMEWORK="python-other"
    fi
  fi
fi

# Multi-type: package.json wins (monorepo)
if [[ -f "package.json" && ( -f "requirements.txt" || -f "pyproject.toml" ) ]]; then
  PROJECT_TYPE="multi"
fi

# ── Source file extensions per framework ──────────────────────────────────────
case "$PROJECT_TYPE" in
  nodejs) SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.jsx" "*.mjs") ;;
  python) SRC_EXTS=("*.py") ;;
  multi)  SRC_EXTS=("*.ts" "*.tsx" "*.js" "*.jsx" "*.py") ;;
  *)      SRC_EXTS=("*.ts" "*.js" "*.py") ;;
esac

GREP_INCLUDE=()
for ext in "${SRC_EXTS[@]}"; do
  GREP_INCLUDE+=(--include="$ext")
done

# ── Route count heuristic ─────────────────────────────────────────────────────
ROUTE_COUNT=0
case "$FRAMEWORK" in
  express|fastify|koa|nodejs-other)
    ROUTE_COUNT=$(safe_grep_count -rn \
      "\.get(\|\.post(\|\.put(\|\.patch(\|\.delete(\|\.all(\|router\." \
      "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .) ;;
  nextjs)
    # pages/api/** or app/**/route.ts
    ROUTE_COUNT=$(find . "${FIND_EXCLUDE[@]}" \
      \( -path "*/pages/api/*" -o -path "*/app/*/route.ts" -o -path "*/app/*/route.js" \) \
      2>/dev/null | wc -l | tr -d ' ') ;;
  fastapi|starlette)
    ROUTE_COUNT=$(safe_grep_count -rn \
      "@app\.\(get\|post\|put\|patch\|delete\)\|@router\.\(get\|post\|put\|patch\|delete\)" \
      "${GREP_EXCLUDE[@]}" --include="*.py" .) ;;
  flask)
    ROUTE_COUNT=$(safe_grep_count -rn \
      "@app\.route\|@blueprint\.route\|@bp\.route" \
      "${GREP_EXCLUDE[@]}" --include="*.py" .) ;;
  django)
    ROUTE_COUNT=$(safe_grep_count -rn \
      "path(\|re_path(\|url(" \
      "${GREP_EXCLUDE[@]}" --include="*.py" .) ;;
esac

# ═══════════════════════════════════════════════════════════════════════════════
# B. BLOCKING CALLS IN ASYNC HANDLERS
# ═══════════════════════════════════════════════════════════════════════════════

SYNC_CALL_COUNT=0
SYNC_CALL_LOCATIONS="[]"

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  SYNC_CALL_COUNT=$(safe_grep_count -rn \
    "readFileSync\|writeFileSync\|execSync\|spawnSync\|mkdirSync\|readdirSync\|statSync\|existsSync\|appendFileSync" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # Collect up to 5 locations
  SYNC_CALL_RAW=$({ grep -rn \
    "readFileSync\|writeFileSync\|execSync\|spawnSync\|mkdirSync" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" . 2>/dev/null || :; } | head -5)

  if [[ -n "$SYNC_CALL_RAW" ]]; then
    SYNC_CALL_LOCATIONS=$(echo "$SYNC_CALL_RAW" | awk -F: '{
      # Strip leading "./"
      f=$1; sub(/^\.\//, "", f)
      line=$2
      # Extract call name from remainder
      call=$0; gsub(/.*readFileSync/, "readFileSync", call); gsub(/.*execSync/, "execSync", call); gsub(/.*writeFileSync/, "writeFileSync", call); gsub(/.*spawnSync/, "spawnSync", call)
      printf "{\"file\":\"%s\",\"line\":%s}\n", f, line
    }' | jq -s '.')
  fi
fi

PYTHON_SYNC_CALL_COUNT=0
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  # Sync requests inside async def handlers
  PYTHON_SYNC_CALL_COUNT=$(safe_grep_count -rn \
    "requests\.get\|requests\.post\|requests\.put\|requests\.patch\|requests\.delete\|requests\.request" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi

TOTAL_SYNC_CALLS=$(( SYNC_CALL_COUNT + PYTHON_SYNC_CALL_COUNT ))

# ═══════════════════════════════════════════════════════════════════════════════
# C. PAGINATION ON LIST ENDPOINTS
# ═══════════════════════════════════════════════════════════════════════════════

# Detect list-style routes (plural nouns, /list, /all, /search)
UNPAGINATED_COUNT=0
HAS_PAGINATION_MIDDLEWARE=false

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  # Routes that look like list endpoints
  LIST_ROUTES=$(safe_grep_count -rn \
    "\.get(['\"][^'\"]*\(s\|list\|all\|search\|items\|results\)['\"]" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # Pagination guard patterns (limit, offset, page, per_page, cursor)
  PAGINATION_GUARDS=$(safe_grep_count -rn \
    "limit\|offset\|page\|per_page\|cursor\|pageSize\|take\|skip" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # If list routes exist but pagination guards are sparse, flag it
  if [[ $LIST_ROUTES -gt 0 && $PAGINATION_GUARDS -lt $LIST_ROUTES ]]; then
    UNPAGINATED_COUNT=$(( LIST_ROUTES - PAGINATION_GUARDS ))
    [[ $UNPAGINATED_COUNT -lt 0 ]] && UNPAGINATED_COUNT=0
  fi

  # Check for pagination middleware/helper
  PAG_MIDDLEWARE=$(safe_grep_count -rn \
    "paginate\|pagination\|express-paginate\|koa-paginate" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  [[ $PAG_MIDDLEWARE -gt 0 ]] && HAS_PAGINATION_MIDDLEWARE=true
fi

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  PY_LIST_ROUTES=$(safe_grep_count -rn \
    "def (list|get_all|get_list|search|index)" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  PY_PAG_GUARDS=$(safe_grep_count -rn \
    "limit\|offset\|page\|per_page\|cursor\|skip\|Paginator" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  if [[ $PY_LIST_ROUTES -gt 0 && $PY_PAG_GUARDS -lt $PY_LIST_ROUTES ]]; then
    PY_UNPAGINATED=$(( PY_LIST_ROUTES - PY_PAG_GUARDS ))
    [[ $PY_UNPAGINATED -lt 0 ]] && PY_UNPAGINATED=0
    UNPAGINATED_COUNT=$(( UNPAGINATED_COUNT + PY_UNPAGINATED ))
  fi
  PY_PAG_MIDDLEWARE=$(safe_grep_count -rn \
    "fastapi_pagination\|django\.core\.paginator\|flask_paginate" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  [[ $PY_PAG_MIDDLEWARE -gt 0 ]] && HAS_PAGINATION_MIDDLEWARE=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# D. CACHING HEADERS
# ═══════════════════════════════════════════════════════════════════════════════

MISSING_CACHE_CONTROL=0
MISSING_ETAG=false
HAS_CACHE_MIDDLEWARE=false

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  # Count GET handlers
  GET_HANDLERS=$(safe_grep_count -rn \
    "\.get(['\"]" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # Count Cache-Control header sets
  CACHE_CONTROL_SETS=$(safe_grep_count -rn \
    "Cache-Control\|cache-control\|cacheControl\|cache_control" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  if [[ $GET_HANDLERS -gt 0 && $CACHE_CONTROL_SETS -lt $GET_HANDLERS ]]; then
    MISSING_CACHE_CONTROL=$(( GET_HANDLERS - CACHE_CONTROL_SETS ))
    [[ $MISSING_CACHE_CONTROL -lt 0 ]] && MISSING_CACHE_CONTROL=0
  fi

  # ETag
  ETAG_USAGE=$(safe_grep_count -rn \
    "etag\|ETag\|e-tag" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  [[ $ETAG_USAGE -eq 0 ]] && MISSING_ETAG=true

  # Cache middleware
  CACHE_MW=$(safe_grep_count -rn \
    "apicache\|express-cache\|node-cache\|redis\|memcached\|cache-manager" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  [[ $CACHE_MW -gt 0 ]] && HAS_CACHE_MIDDLEWARE=true
fi

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  PY_CACHE_SETS=$(safe_grep_count -rn \
    "Cache-Control\|cache_control\|add_header.*Cache\|make_response" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  PY_CACHE_MW=$(safe_grep_count -rn \
    "flask_caching\|fastapi_cache\|django\.views\.decorators\.cache\|aioredis\|redis" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  [[ $PY_CACHE_MW -gt 0 ]] && HAS_CACHE_MIDDLEWARE=true

  PY_ETAG=$(safe_grep_count -rn \
    "etag\|ETag\|e-tag\|conditional_etag" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  if [[ $PY_ETAG -eq 0 && $ETAG_USAGE -eq 0 ]]; then
    MISSING_ETAG=true
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# E. COMPRESSION
# ═══════════════════════════════════════════════════════════════════════════════

HAS_COMPRESSION=false
COMPRESSION_MIDDLEWARE=""

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  COMP_COUNT=$(safe_grep_count -rn \
    "compression(\|compressible\|shrink-ray\|brotli\|zlib\|gzip" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  if [[ $COMP_COUNT -gt 0 ]]; then
    HAS_COMPRESSION=true
    COMPRESSION_MIDDLEWARE="compression"
  fi
fi

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  PY_COMP=$(safe_grep_count -rn \
    "GZipMiddleware\|flask.compress\|flask_compress\|brotli\|gzip\|deflate" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  if [[ $PY_COMP -gt 0 ]]; then
    HAS_COMPRESSION=true
    COMPRESSION_MIDDLEWARE="${COMPRESSION_MIDDLEWARE:+$COMPRESSION_MIDDLEWARE,}gzip"
  fi
fi

[[ -z "$COMPRESSION_MIDDLEWARE" ]] && COMPRESSION_MIDDLEWARE="none"

# ═══════════════════════════════════════════════════════════════════════════════
# F. REDUNDANT MIDDLEWARE / DUPLICATE PROCESSING
# ═══════════════════════════════════════════════════════════════════════════════

MIDDLEWARE_COUNT=0
DUPLICATE_AUTH_CHECKS=0
BODY_PARSED_TWICE=false

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  # Total middleware registrations
  MIDDLEWARE_COUNT=$(safe_grep_count -rn \
    "app\.use(\|router\.use(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # Auth middleware called multiple times
  AUTH_MW=$(safe_grep_count -rn \
    "authenticate\|authorize\|verifyToken\|checkAuth\|requireAuth\|isAuthenticated\|passport\." \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  # Heuristic: if auth appears more than route count, flag duplicates
  [[ $AUTH_MW -gt $(( ROUTE_COUNT + 2 )) ]] && DUPLICATE_AUTH_CHECKS=$(( AUTH_MW - ROUTE_COUNT ))

  # Body parser used more than once
  BODY_PARSE_COUNT=$(safe_grep_count -rn \
    "bodyParser\|express\.json(\|express\.urlencoded(\|body-parser" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  [[ $BODY_PARSE_COUNT -gt 2 ]] && BODY_PARSED_TWICE=true
fi

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  PY_MW=$(safe_grep_count -rn \
    "app\.add_middleware\|@app\.middleware\|Middleware(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  MIDDLEWARE_COUNT=$(( MIDDLEWARE_COUNT + PY_MW ))
fi

# ═══════════════════════════════════════════════════════════════════════════════
# G. INEFFICIENT SERIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

FULL_MODEL_DUMPS=0
NESTED_SERIALIZATION_LOOPS=0
HAS_SERIALIZER_LIBRARY=false

if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  # Full dumps: res.json(records) without projection
  FULL_MODEL_DUMPS=$(safe_grep_count -rn \
    "res\.json(\|res\.send(\|JSON\.stringify(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  # Field projection usage
  PROJECTION_USAGE=$(safe_grep_count -rn \
    "\.select(\|\.project(\|\.pick(\|\.omit(\|fields=" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)

  if [[ $FULL_MODEL_DUMPS -gt 0 && $PROJECTION_USAGE -lt $FULL_MODEL_DUMPS ]]; then
    FULL_MODEL_DUMPS=$(( FULL_MODEL_DUMPS - PROJECTION_USAGE ))
    [[ $FULL_MODEL_DUMPS -lt 0 ]] && FULL_MODEL_DUMPS=0
  else
    FULL_MODEL_DUMPS=0
  fi

  # Serializer library
  SER_LIB=$(safe_grep_count -rn \
    "class-transformer\|class-validator\|superjson\|zod\|yup\|io-ts" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  [[ $SER_LIB -gt 0 ]] && HAS_SERIALIZER_LIBRARY=true
fi

if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  # ORM full dumps
  PY_FULL_DUMPS=$(safe_grep_count -rn \
    "\.all()\|\.find()\|\.objects\.all\|\.fetchall(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  PY_PROJECTION=$(safe_grep_count -rn \
    "\.values(\|\.values_list(\|\.only(\|\.defer(\|\.filter(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)

  if [[ $PY_FULL_DUMPS -gt 0 && $PY_PROJECTION -lt $PY_FULL_DUMPS ]]; then
    PY_UNOPTIMIZED=$(( PY_FULL_DUMPS - PY_PROJECTION ))
    [[ $PY_UNOPTIMIZED -lt 0 ]] && PY_UNOPTIMIZED=0
    FULL_MODEL_DUMPS=$(( FULL_MODEL_DUMPS + PY_UNOPTIMIZED ))
  fi

  # Pydantic / marshmallow / dataclasses
  PY_SER=$(safe_grep_count -rn \
    "BaseModel\|marshmallow\|dataclass\|Schema(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  [[ $PY_SER -gt 0 ]] && HAS_SERIALIZER_LIBRARY=true
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════════════════════════════════

SCORE=100

# Sync blocking calls: -12 each, max -36
SYNC_CAPPED=$TOTAL_SYNC_CALLS
[[ $SYNC_CAPPED -gt 3 ]] && SYNC_CAPPED=3
SCORE=$(( SCORE - SYNC_CAPPED * 12 ))

# Unpaginated list endpoints: -8 each, max -32
PAGINAT_CAPPED=$UNPAGINATED_COUNT
[[ $PAGINAT_CAPPED -gt 4 ]] && PAGINAT_CAPPED=4
SCORE=$(( SCORE - PAGINAT_CAPPED * 8 ))

# No compression: -10
$HAS_COMPRESSION || SCORE=$(( SCORE - 10 ))

# Full model dumps without projection: -6 each, max -18
DUMP_CAPPED=$FULL_MODEL_DUMPS
[[ $DUMP_CAPPED -gt 3 ]] && DUMP_CAPPED=3
SCORE=$(( SCORE - DUMP_CAPPED * 6 ))

# Missing Cache-Control on GET handlers: -5 each, max -20
CACHE_CAPPED=$MISSING_CACHE_CONTROL
[[ $CACHE_CAPPED -gt 4 ]] && CACHE_CAPPED=4
SCORE=$(( SCORE - CACHE_CAPPED * 5 ))

# Duplicate auth middleware: -8 each, max -16
AUTH_CAPPED=$DUPLICATE_AUTH_CHECKS
[[ $AUTH_CAPPED -gt 2 ]] && AUTH_CAPPED=2
SCORE=$(( SCORE - AUTH_CAPPED * 8 ))

# Missing ETag: -5
$MISSING_ETAG && SCORE=$(( SCORE - 5 ))

# Middleware count > 15: -5
[[ $MIDDLEWARE_COUNT -gt 15 ]] && SCORE=$(( SCORE - 5 ))

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
  "framework": "$FRAMEWORK",
  "project_type": "$PROJECT_TYPE",
  "route_count": $ROUTE_COUNT,
  "payload_threshold_kb": $PAYLOAD_THRESHOLD,
  "blocking": {
    "sync_call_count": $TOTAL_SYNC_CALLS,
    "nodejs_sync_calls": $SYNC_CALL_COUNT,
    "python_sync_requests": $PYTHON_SYNC_CALL_COUNT,
    "locations": $SYNC_CALL_LOCATIONS
  },
  "pagination": {
    "unpaginated_count": $UNPAGINATED_COUNT,
    "has_pagination_middleware": $HAS_PAGINATION_MIDDLEWARE
  },
  "caching": {
    "missing_cache_control_count": $MISSING_CACHE_CONTROL,
    "missing_etag": $MISSING_ETAG,
    "has_cache_middleware": $HAS_CACHE_MIDDLEWARE
  },
  "compression": {
    "has_compression": $HAS_COMPRESSION,
    "middleware": "$COMPRESSION_MIDDLEWARE"
  },
  "middleware": {
    "middleware_count": $MIDDLEWARE_COUNT,
    "duplicate_auth_checks": $DUPLICATE_AUTH_CHECKS,
    "body_parsed_twice": $BODY_PARSED_TWICE
  },
  "serialization": {
    "full_model_dumps": $FULL_MODEL_DUMPS,
    "nested_serialization_loops": $NESTED_SERIALIZATION_LOOPS,
    "has_serializer_library": $HAS_SERIALIZER_LIBRARY
  }
}
EOF
