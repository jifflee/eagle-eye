#!/usr/bin/env bash
# db-query-audit-data.sh
# Pre-process database query performance audit metrics for /performance:db-query skill
# Returns JSON with N+1 patterns, missing indexes, SELECT *, full table scans, and JOIN issues
#
# Usage: ./scripts/db-query-audit-data.sh
# Output: JSON object with DB query findings, scores, and metadata
#
# Supported: SQLAlchemy, Django ORM, Prisma, ActiveRecord, Sequelize, TypeORM, raw SQL
# Databases: PostgreSQL, MySQL, SQLite patterns
#
# size-ok: data-gathering script, not a skill file

set -euo pipefail

# ── Common exclusion patterns ─────────────────────────────────────────────────
GREP_EXCLUDE=(--exclude-dir=node_modules --exclude-dir=.git
              --exclude-dir=__pycache__ --exclude-dir=venv
              --exclude-dir=.venv --exclude-dir=dist
              --exclude-dir=build --exclude-dir=.next
              --exclude-dir=coverage --exclude-dir=.cache)

# Helper: grep that never fails due to no matches
safe_grep_count() {
  { grep "$@" 2>/dev/null || :; } | wc -l | tr -d ' '
}

safe_grep_lines() {
  { grep "$@" 2>/dev/null || :; } | head -10
}

# ── Detect project type ───────────────────────────────────────────────────────
PROJECT_TYPE="unknown"
[[ -f "package.json" ]]                                              && PROJECT_TYPE="nodejs"
[[ -f "requirements.txt" || -f "pyproject.toml" || -f "setup.py" ]] && PROJECT_TYPE="python"
[[ -f "Gemfile" ]]                                                   && PROJECT_TYPE="ruby"
[[ -f "go.mod" ]]                                                    && PROJECT_TYPE="go"
[[ -f "package.json" && ( -f "requirements.txt" || -f "pyproject.toml" ) ]] && PROJECT_TYPE="multi"

# ── ORM detection ─────────────────────────────────────────────────────────────
ORM="none"
HAS_SQLALCHEMY=false
HAS_DJANGO=false
HAS_PRISMA=false
HAS_ACTIVERECORD=false
HAS_SEQUELIZE=false
HAS_TYPEORM=false

# Python ORMs
if [[ "$PROJECT_TYPE" == "python" || "$PROJECT_TYPE" == "multi" ]]; then
  { grep -rq "from sqlalchemy\|import sqlalchemy\|SQLAlchemy" \
    "${GREP_EXCLUDE[@]}" --include="*.py" . 2>/dev/null && HAS_SQLALCHEMY=true; } || true
  { grep -rq "from django.db\|django.db.models\|models\.Model" \
    "${GREP_EXCLUDE[@]}" --include="*.py" . 2>/dev/null && HAS_DJANGO=true; } || true
fi

# Node/TS ORMs
if [[ "$PROJECT_TYPE" == "nodejs" || "$PROJECT_TYPE" == "multi" ]]; then
  { grep -rq "@prisma/client\|PrismaClient\|prisma\." \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" . 2>/dev/null && HAS_PRISMA=true; } || true
  { grep -rq "from 'sequelize'\|require('sequelize')\|DataTypes\." \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" . 2>/dev/null && HAS_SEQUELIZE=true; } || true
  { grep -rq "from 'typeorm'\|@Entity\(\|@Column\(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" . 2>/dev/null && HAS_TYPEORM=true; } || true
fi

# Ruby ORM
if [[ "$PROJECT_TYPE" == "ruby" ]]; then
  { grep -rq "ActiveRecord::Base\|ApplicationRecord\|has_many\|belongs_to" \
    "${GREP_EXCLUDE[@]}" --include="*.rb" . 2>/dev/null && HAS_ACTIVERECORD=true; } || true
fi

# Summarize ORM
if $HAS_SQLALCHEMY && $HAS_DJANGO; then ORM="sqlalchemy+django"
elif $HAS_SQLALCHEMY; then ORM="sqlalchemy"
elif $HAS_DJANGO;     then ORM="django"
elif $HAS_PRISMA;     then ORM="prisma"
elif $HAS_SEQUELIZE;  then ORM="sequelize"
elif $HAS_TYPEORM;    then ORM="typeorm"
elif $HAS_ACTIVERECORD; then ORM="activerecord"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# A. N+1 QUERY DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

N_PLUS_ONE_COUNT=0
N_PLUS_ONE_LOCATIONS=""
LAZY_LOAD_RISK=0

# ── Django: .objects.get / .objects.filter inside loop ────────────────────────
DJANGO_N1=0
if $HAS_DJANGO; then
  DJANGO_N1=$(safe_grep_count -rn \
    "\.objects\.get\|\.objects\.filter\|\.objects\.all\|\.objects\.first" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  # Flag lazy relationship access (accessing FK attribute in Python loop context)
  DJANGO_LAZY=$(safe_grep_count -rn \
    "for .*in .*:$" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  [[ $DJANGO_LAZY -gt 0 && $DJANGO_N1 -gt 0 ]] && LAZY_LOAD_RISK=1
fi

# ── SQLAlchemy: session.query / .get() calls ──────────────────────────────────
SQLALCHEMY_N1=0
if $HAS_SQLALCHEMY; then
  SQLALCHEMY_N1=$(safe_grep_count -rn \
    "session\.query\|session\.get\|session\.execute\|\.scalars(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi

# ── Prisma: findUnique/findFirst in map/forEach/for ──────────────────────────
PRISMA_N1=0
if $HAS_PRISMA; then
  PRISMA_N1=$(safe_grep_count -rn \
    "prisma\.\w*\.findUnique\|prisma\.\w*\.findFirst\|prisma\.\w*\.findMany" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
fi

# ── ActiveRecord: .find / .where inside each/map ─────────────────────────────
AR_N1=0
if $HAS_ACTIVERECORD; then
  AR_N1=$(safe_grep_count -rn \
    "\.find(\|\.where(\|\.find_by(\|\.first(" \
    "${GREP_EXCLUDE[@]}" --include="*.rb" .)
  AR_LOOPS=$(safe_grep_count -rn \
    "\.each\|\.map\|\.collect\|\.select" \
    "${GREP_EXCLUDE[@]}" --include="*.rb" .)
  [[ $AR_N1 -gt 0 && $AR_LOOPS -gt 0 ]] && LAZY_LOAD_RISK=1
fi

# ── Sequelize/TypeORM generic ─────────────────────────────────────────────────
SEQ_N1=0
if $HAS_SEQUELIZE || $HAS_TYPEORM; then
  SEQ_N1=$(safe_grep_count -rn \
    "\.findOne(\|\.findAll(\|\.findByPk(\|\.find(\|\.findAndCountAll(" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
fi

TOTAL_QUERY_CALLS=$(( DJANGO_N1 + SQLALCHEMY_N1 + PRISMA_N1 + AR_N1 + SEQ_N1 ))

# Loop context detection (heuristic): loops near query calls
LOOP_COUNT=$(safe_grep_count -rn \
  "for .*in \|for .*of \|\.forEach(\|\.map(\|\.each\b\|while (" \
  "${GREP_EXCLUDE[@]}" . )

# Estimate N+1 risk: query calls AND loops present
N_PLUS_ONE_RISK=0
[[ $TOTAL_QUERY_CALLS -gt 2 && $LOOP_COUNT -gt 2 ]] && N_PLUS_ONE_RISK=1

# Capture sample locations for Django (most verbose ORM)
if $HAS_DJANGO && [[ $DJANGO_N1 -gt 0 ]]; then
  N_PLUS_ONE_LOCATIONS=$( { grep -rn "\.objects\.get\|\.objects\.filter" \
    "${GREP_EXCLUDE[@]}" --include="*.py" . 2>/dev/null || :; } | head -5 | \
    awk -F: '{printf "%s:%s,", $1, $2}' | sed 's/,$//')
elif $HAS_PRISMA && [[ $PRISMA_N1 -gt 0 ]]; then
  N_PLUS_ONE_LOCATIONS=$( { grep -rn "prisma\.\w*\.findUnique\|prisma\.\w*\.findFirst" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" . 2>/dev/null || :; } | head -5 | \
    awk -F: '{printf "%s:%s,", $1, $2}' | sed 's/,$//')
fi
N_PLUS_ONE_LOCATIONS="${N_PLUS_ONE_LOCATIONS:-none}"

# ═══════════════════════════════════════════════════════════════════════════════
# B. MISSING INDEX DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

MISSING_INDEX_COUNT=0
MIGRATION_MISSING_INDEX=0
FK_WITHOUT_INDEX=0

# ── ActiveRecord migrations: add_column without add_index ────────────────────
MIGRATION_DIR=""
[[ -d "db/migrate" ]]         && MIGRATION_DIR="db/migrate"
[[ -d "database/migrations" ]] && MIGRATION_DIR="database/migrations"
[[ -d "migrations" ]]         && MIGRATION_DIR="migrations"

if [[ -n "$MIGRATION_DIR" ]]; then
  ADD_COLUMN_COUNT=$(safe_grep_count -rn \
    "add_column\|AddColumn\|add column" \
    "${GREP_EXCLUDE[@]}" "$MIGRATION_DIR")
  ADD_INDEX_COUNT=$(safe_grep_count -rn \
    "add_index\|AddIndex\|CREATE INDEX\|add_index\|addIndex" \
    "${GREP_EXCLUDE[@]}" "$MIGRATION_DIR")
  # Rough heuristic: more column additions than index additions indicates gaps
  if [[ $ADD_COLUMN_COUNT -gt 0 && $ADD_INDEX_COUNT -lt $ADD_COLUMN_COUNT ]]; then
    MIGRATION_MISSING_INDEX=$(( ADD_COLUMN_COUNT - ADD_INDEX_COUNT ))
  fi
fi

# ── Django: ForeignKey fields (should have db_index=True by default, but check) ─
DJANGO_FK_COUNT=0
DJANGO_FK_NO_INDEX=0
if $HAS_DJANGO; then
  DJANGO_FK_COUNT=$(safe_grep_count -rn \
    "ForeignKey(\|OneToOneField(\|ManyToManyField(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  DJANGO_FK_NO_INDEX=$(safe_grep_count -rn \
    "ForeignKey(.*db_index=False" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
fi

# ── Prisma: @relation without @@index ─────────────────────────────────────────
PRISMA_RELATION_COUNT=0
PRISMA_INDEX_COUNT=0
if $HAS_PRISMA; then
  PRISMA_RELATION_COUNT=$(safe_grep_count -rn "@relation(" \
    "${GREP_EXCLUDE[@]}" --include="*.prisma" .)
  PRISMA_INDEX_COUNT=$(safe_grep_count -rn "@@index\|@unique\|@@unique" \
    "${GREP_EXCLUDE[@]}" --include="*.prisma" .)
fi

# ── SQLAlchemy: Column with ForeignKey but no index=True ─────────────────────
SA_FK_COUNT=0
SA_FK_WITH_INDEX=0
SA_FK_WITHOUT_INDEX=0
if $HAS_SQLALCHEMY; then
  SA_FK_COUNT=$(safe_grep_count -rn "ForeignKey(" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  SA_FK_WITH_INDEX=$(safe_grep_count -rn "ForeignKey(.*index=True\|Column(.*index=True" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  if [[ $SA_FK_COUNT -gt 0 ]]; then
    SA_FK_WITHOUT_INDEX=$(( SA_FK_COUNT - SA_FK_WITH_INDEX ))
    [[ $SA_FK_WITHOUT_INDEX -lt 0 ]] && SA_FK_WITHOUT_INDEX=0
  fi
fi

FK_WITHOUT_INDEX=$(( DJANGO_FK_NO_INDEX + SA_FK_WITHOUT_INDEX ))
MISSING_INDEX_COUNT=$(( FK_WITHOUT_INDEX + MIGRATION_MISSING_INDEX ))

# Concurrent index check for Rails migrations
CONCURRENT_INDEX_MISSING=0
if [[ -n "$MIGRATION_DIR" ]] && [[ "$PROJECT_TYPE" == "ruby" ]]; then
  NON_CONCURRENT=$(safe_grep_count -rn "add_index" \
    "${GREP_EXCLUDE[@]}" "$MIGRATION_DIR")
  CONCURRENT=$(safe_grep_count -rn "algorithm: :concurrently\|CONCURRENTLY" \
    "${GREP_EXCLUDE[@]}" "$MIGRATION_DIR")
  if [[ $NON_CONCURRENT -gt 0 && $CONCURRENT -lt $NON_CONCURRENT ]]; then
    CONCURRENT_INDEX_MISSING=$(( NON_CONCURRENT - CONCURRENT ))
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# C. SELECT * DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

SELECT_STAR_COUNT=0
SELECT_STAR_LOCATIONS=""
ORM_ALL_COUNT=0

# Raw SQL SELECT *
SELECT_STAR_COUNT=$(safe_grep_count -rni \
  "SELECT \*\|select\(\*\)\|select_related\(\)" \
  "${GREP_EXCLUDE[@]}" .)

SELECT_STAR_LOCATIONS=$( { grep -rni "SELECT \*" \
  "${GREP_EXCLUDE[@]}" . 2>/dev/null || :; } | head -5 | \
  awk -F: '{printf "%s:%s,", $1, $2}' | sed 's/,$//')
SELECT_STAR_LOCATIONS="${SELECT_STAR_LOCATIONS:-none}"

# ORM: .all() without .only() / .values()
if $HAS_DJANGO; then
  DJANGO_ALL=$(safe_grep_count -rn "\.objects\.all()" \
    "${GREP_EXCLUDE[@]}" --include="*.py" .)
  ORM_ALL_COUNT=$(( ORM_ALL_COUNT + DJANGO_ALL ))
fi
if $HAS_ACTIVERECORD; then
  AR_ALL=$(safe_grep_count -rn "\.all\b\|\.find(:all)" \
    "${GREP_EXCLUDE[@]}" --include="*.rb" .)
  ORM_ALL_COUNT=$(( ORM_ALL_COUNT + AR_ALL ))
fi
if $HAS_PRISMA; then
  PRISMA_ALL=$(safe_grep_count -rn "findMany({}" \
    "${GREP_EXCLUDE[@]}" --include="*.ts" --include="*.js" .)
  ORM_ALL_COUNT=$(( ORM_ALL_COUNT + PRISMA_ALL ))
fi

TOTAL_SELECT_STAR=$(( SELECT_STAR_COUNT + ORM_ALL_COUNT ))

# ═══════════════════════════════════════════════════════════════════════════════
# D. FULL TABLE SCAN DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

NO_LIMIT_COUNT=0
LIKE_WILDCARD_COUNT=0
UNINDEXED_ORDER_COUNT=0

# Queries with no LIMIT clause (raw SQL)
NO_LIMIT_SQL=$(safe_grep_count -rni \
  "SELECT .* FROM " \
  "${GREP_EXCLUDE[@]}" .)
WITH_LIMIT=$(safe_grep_count -rni \
  "LIMIT \|\.limit(\|\.take(\|\.first\b\|\.paginate(" \
  "${GREP_EXCLUDE[@]}" .)
# Estimate queries missing LIMIT
if [[ $NO_LIMIT_SQL -gt $WITH_LIMIT ]]; then
  NO_LIMIT_COUNT=$(( NO_LIMIT_SQL - WITH_LIMIT ))
fi

# Leading wildcard LIKE (bypasses indexes)
LIKE_WILDCARD_COUNT=$(safe_grep_count -rni \
  "LIKE '%\|like '%\|ilike '%" \
  "${GREP_EXCLUDE[@]}" .)

# ORDER BY without obvious index (heuristic: ORDER BY on non-id columns)
UNINDEXED_ORDER_COUNT=$(safe_grep_count -rni \
  "ORDER BY [^)]*[^_]created_at\|ORDER BY [^)]*[^_]updated_at\|ORDER BY [^)]*name\b\|ORDER BY [^)]*email\b" \
  "${GREP_EXCLUDE[@]}" .)

TOTAL_SCAN_RISK=$(( NO_LIMIT_COUNT + LIKE_WILDCARD_COUNT ))

# ═══════════════════════════════════════════════════════════════════════════════
# E. SLOW JOIN DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

CARTESIAN_RISK=0
MULTI_JOIN_COUNT=0
JOIN_COUNT=0

JOIN_COUNT=$(safe_grep_count -rni \
  "\bJOIN\b\|\.join(\|joins(:" \
  "${GREP_EXCLUDE[@]}" .)

# Cartesian risk: FROM with multiple tables but no explicit JOIN condition
# Heuristic: comma-separated tables in FROM clause
CARTESIAN_RISK=$(safe_grep_count -rni \
  "FROM [a-z_]*, [a-z_]*\b" \
  "${GREP_EXCLUDE[@]}" .)

# Queries with many JOINs (>3 join keywords in same file section)
MULTI_JOIN_FILES=$( { grep -rni "JOIN" "${GREP_EXCLUDE[@]}" . 2>/dev/null || :; } | \
  awk -F: '{print $1}' | sort | uniq -c | sort -rn | \
  awk '$1 > 3 {print $2}' | wc -l | tr -d ' ')
MULTI_JOIN_COUNT=${MULTI_JOIN_FILES:-0}

# ═══════════════════════════════════════════════════════════════════════════════
# SCORING
# ═══════════════════════════════════════════════════════════════════════════════

SCORE=100

# N+1 risk: -15 (capped per confirmed pattern count, max -45)
if [[ $N_PLUS_ONE_RISK -eq 1 ]]; then
  N1_PENALTY=$(( TOTAL_QUERY_CALLS * 5 ))
  [[ $N1_PENALTY -gt 45 ]] && N1_PENALTY=45
  SCORE=$(( SCORE - N1_PENALTY ))
fi

# SELECT *: -8 each, max -24
SEL_PENALTY=$(( TOTAL_SELECT_STAR * 8 ))
[[ $SEL_PENALTY -gt 24 ]] && SEL_PENALTY=24
SCORE=$(( SCORE - SEL_PENALTY ))

# Missing indexes: -10 each, max -30
IDX_PENALTY=$(( MISSING_INDEX_COUNT * 10 ))
[[ $IDX_PENALTY -gt 30 ]] && IDX_PENALTY=30
SCORE=$(( SCORE - IDX_PENALTY ))

# No LIMIT: -8 each, max -24
LIM_PENALTY=$(( NO_LIMIT_COUNT * 8 ))
[[ $LIM_PENALTY -gt 24 ]] && LIM_PENALTY=24
SCORE=$(( SCORE - LIM_PENALTY ))

# Leading wildcard LIKE: -6 each, max -18
LIKE_PENALTY=$(( LIKE_WILDCARD_COUNT * 6 ))
[[ $LIKE_PENALTY -gt 18 ]] && LIKE_PENALTY=18
SCORE=$(( SCORE - LIKE_PENALTY ))

# Cartesian JOIN: -12 each, max -24
CART_PENALTY=$(( CARTESIAN_RISK * 12 ))
[[ $CART_PENALTY -gt 24 ]] && CART_PENALTY=24
SCORE=$(( SCORE - CART_PENALTY ))

# Missing concurrent index: -5 each, max -15
CONC_PENALTY=$(( CONCURRENT_INDEX_MISSING * 5 ))
[[ $CONC_PENALTY -gt 15 ]] && CONC_PENALTY=15
SCORE=$(( SCORE - CONC_PENALTY ))

# Floor at 0
[[ $SCORE -lt 0 ]] && SCORE=0

# Status thresholds
if [[ $SCORE -ge 80 ]];   then STATUS="good"
elif [[ $SCORE -ge 60 ]]; then STATUS="warning"
elif [[ $SCORE -ge 40 ]]; then STATUS="needs_work"
else                           STATUS="critical"
fi

# ── Emit JSON ─────────────────────────────────────────────────────────────────
cat <<EOF
{
  "score": $SCORE,
  "status": "$STATUS",
  "project_type": "$PROJECT_TYPE",
  "orm": "$ORM",
  "n_plus_one": {
    "risk": $N_PLUS_ONE_RISK,
    "total_query_calls": $TOTAL_QUERY_CALLS,
    "loop_count": $LOOP_COUNT,
    "lazy_load_risk": $LAZY_LOAD_RISK,
    "locations": "$N_PLUS_ONE_LOCATIONS",
    "by_orm": {
      "django": $DJANGO_N1,
      "sqlalchemy": $SQLALCHEMY_N1,
      "prisma": $PRISMA_N1,
      "activerecord": $AR_N1,
      "sequelize_typeorm": $SEQ_N1
    }
  },
  "indexes": {
    "missing_count": $MISSING_INDEX_COUNT,
    "fk_without_index": $FK_WITHOUT_INDEX,
    "migration_missing_index": $MIGRATION_MISSING_INDEX,
    "concurrent_index_missing": $CONCURRENT_INDEX_MISSING,
    "prisma_relations": $PRISMA_RELATION_COUNT,
    "prisma_indexes": $PRISMA_INDEX_COUNT
  },
  "select_star": {
    "raw_sql_count": $SELECT_STAR_COUNT,
    "orm_all_count": $ORM_ALL_COUNT,
    "total": $TOTAL_SELECT_STAR,
    "locations": "$SELECT_STAR_LOCATIONS"
  },
  "full_scans": {
    "no_limit_risk": $NO_LIMIT_COUNT,
    "like_leading_wildcard": $LIKE_WILDCARD_COUNT,
    "unindexed_order_by": $UNINDEXED_ORDER_COUNT,
    "total_risk": $TOTAL_SCAN_RISK
  },
  "joins": {
    "total_join_count": $JOIN_COUNT,
    "cartesian_risk": $CARTESIAN_RISK,
    "multi_join_files": $MULTI_JOIN_COUNT
  },
  "migrations": {
    "dir": "$MIGRATION_DIR",
    "add_column_count": ${ADD_COLUMN_COUNT:-0},
    "add_index_count": ${ADD_INDEX_COUNT:-0},
    "concurrent_missing": $CONCURRENT_INDEX_MISSING
  }
}
EOF
