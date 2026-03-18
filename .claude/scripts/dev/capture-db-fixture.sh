#!/usr/bin/env bash
# ============================================================
# Script: capture-db-fixture.sh
# Purpose: Capture database state as test fixtures
# Usage: ./scripts/dev/capture-db-fixture.sh <table> <output-file>
# Dependencies: psql or mysql, jq
# ============================================================

set -euo pipefail

TABLE="${1:-}"
OUTPUT_FILE="${2:-}"
DATABASE_URL="${DATABASE_URL:-}"
DB_TYPE="${DB_TYPE:-postgres}"
LIMIT="${LIMIT:-100}"

if [ -z "$TABLE" ] || [ -z "$OUTPUT_FILE" ]; then
  echo "Usage: $0 <table> <output-file>"
  echo ""
  echo "Example:"
  echo "  DATABASE_URL=postgres://user:pass@host/db $0 users tests/fixtures/db/users.json"
  echo ""
  echo "Environment variables:"
  echo "  DATABASE_URL - Database connection string (required)"
  echo "  DB_TYPE - Database type: postgres or mysql (default: postgres)"
  echo "  LIMIT - Maximum rows to capture (default: 100)"
  exit 2
fi

if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: DATABASE_URL environment variable is required"
  exit 2
fi

# Create output directory if needed
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Capturing: $TABLE (limit $LIMIT)"

case "$DB_TYPE" in
  postgres)
    RESPONSE=$(psql "$DATABASE_URL" -t -c "
      SELECT json_agg(row_to_json(t))
      FROM (SELECT * FROM $TABLE LIMIT $LIMIT) t
    " 2>/dev/null)
    ;;
  mysql)
    RESPONSE=$(mysql "$DATABASE_URL" -N -e "
      SELECT JSON_ARRAYAGG(JSON_OBJECT(*))
      FROM (SELECT * FROM $TABLE LIMIT $LIMIT) t
    " 2>/dev/null)
    ;;
  *)
    echo "ERROR: Unsupported database type: $DB_TYPE"
    exit 2
    ;;
esac

# Handle null/empty response
if [ -z "$RESPONSE" ] || [ "$RESPONSE" = "null" ]; then
  RESPONSE="[]"
fi

# Validate JSON
if ! echo "$RESPONSE" | jq empty 2>/dev/null; then
  echo "ERROR: Response is not valid JSON"
  echo "$RESPONSE"
  exit 1
fi

# Add metadata and save
jq -n \
  --arg captured "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg table "$TABLE" \
  --arg db_type "$DB_TYPE" \
  --argjson limit "$LIMIT" \
  --argjson data "$RESPONSE" \
  '{
    _metadata: {
      capturedAt: $captured,
      source: ("table:" + $table),
      dbType: $db_type,
      limit: $limit,
      sanitized: false,
      notes: "Raw capture - needs sanitization before commit"
    },
    data: $data
  }' > "$OUTPUT_FILE"

echo "Saved to: $OUTPUT_FILE"
echo ""
echo "IMPORTANT: Run sanitization before committing:"
echo "  ./scripts/dev/sanitize-fixture.sh $OUTPUT_FILE > sanitized.json"
echo "  mv sanitized.json $OUTPUT_FILE"
