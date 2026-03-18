#!/usr/bin/env bash
# ============================================================
# Script: check-seed-migrations.sh
# Purpose: Check if database migrations affect seed files
# Usage: ./scripts/maintenance/check-seed-migrations.sh <migration-file>
# Dependencies: none
# ============================================================

set -euo pipefail

MIGRATION_FILE="${1:-}"
SEED_DIR="tests/seeds"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $0 <migration-file>

Check if a database migration affects seed files and identify which seeds need updates.

Arguments:
  migration-file    Path to the migration file to check

Examples:
  $0 migrations/20260215_add_user_preferences.sql
  $0 migrations/20260215_add_user_preferences.js

Output:
  - Lists tables affected by the migration
  - Identifies seed files that reference those tables
  - Provides recommendations for updating seeds

Exit Codes:
  0 - No seed updates needed
  1 - Seed updates may be required (warning)
  2 - Error (invalid arguments, file not found)

EOF
  exit 2
}

# Validate arguments
if [ -z "$MIGRATION_FILE" ]; then
  echo -e "${RED}Error: Migration file is required${NC}"
  echo ""
  usage
fi

if [ ! -f "$MIGRATION_FILE" ]; then
  echo -e "${RED}Error: Migration file not found: $MIGRATION_FILE${NC}"
  exit 2
fi

# Check if seed directory exists
if [ ! -d "$SEED_DIR" ]; then
  echo -e "${YELLOW}Warning: Seed directory not found: $SEED_DIR${NC}"
  echo "No seed files to check"
  exit 0
fi

echo "═══════════════════════════════════════════════════════════"
echo -e "${BLUE}Migration-Seed Impact Analysis${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Migration: $MIGRATION_FILE"
echo "Seed directory: $SEED_DIR"
echo ""

# ============================================================
# Extract affected tables from migration
# ============================================================

echo "## Analyzing Migration"
echo ""

declare -a AFFECTED_TABLES=()
declare -A TABLE_OPERATIONS=()

# Detect migration type
MIGRATION_EXT="${MIGRATION_FILE##*.}"

case "$MIGRATION_EXT" in
  sql)
    # Parse SQL migration
    echo "Migration type: SQL"
    echo ""

    # Extract CREATE TABLE statements
    while IFS= read -r line; do
      if [[ "$line" =~ CREATE[[:space:]]+TABLE[[:space:]]+([a-zA-Z0-9_]+) ]]; then
        TABLE_NAME="${BASH_REMATCH[1]}"
        AFFECTED_TABLES+=("$TABLE_NAME")
        TABLE_OPERATIONS["$TABLE_NAME"]="CREATE TABLE"
      fi
    done < "$MIGRATION_FILE"

    # Extract ALTER TABLE statements
    while IFS= read -r line; do
      if [[ "$line" =~ ALTER[[:space:]]+TABLE[[:space:]]+([a-zA-Z0-9_]+) ]]; then
        TABLE_NAME="${BASH_REMATCH[1]}"
        if [[ ! " ${AFFECTED_TABLES[*]} " =~ " ${TABLE_NAME} " ]]; then
          AFFECTED_TABLES+=("$TABLE_NAME")
        fi
        TABLE_OPERATIONS["$TABLE_NAME"]="${TABLE_OPERATIONS[$TABLE_NAME]:-}, ALTER TABLE"
      fi
    done < "$MIGRATION_FILE"

    # Extract DROP TABLE statements
    while IFS= read -r line; do
      if [[ "$line" =~ DROP[[:space:]]+TABLE[[:space:]]+([a-zA-Z0-9_]+) ]]; then
        TABLE_NAME="${BASH_REMATCH[1]}"
        if [[ ! " ${AFFECTED_TABLES[*]} " =~ " ${TABLE_NAME} " ]]; then
          AFFECTED_TABLES+=("$TABLE_NAME")
        fi
        TABLE_OPERATIONS["$TABLE_NAME"]="${TABLE_OPERATIONS[$TABLE_NAME]:-}, DROP TABLE"
      fi
    done < "$MIGRATION_FILE"
    ;;

  js|ts)
    # Parse JavaScript/TypeScript migration (Knex, Sequelize, etc.)
    echo "Migration type: JavaScript/TypeScript"
    echo ""

    # Extract table references from common migration methods
    # createTable, alterTable, dropTable, schema.table(), etc.

    while IFS= read -r line; do
      # Match: createTable('table_name') or createTable("table_name")
      if [[ "$line" =~ createTable\([\'\"]([ a-zA-Z0-9_]+)[\'\"] ]]; then
        TABLE_NAME="${BASH_REMATCH[1]}"
        AFFECTED_TABLES+=("$TABLE_NAME")
        TABLE_OPERATIONS["$TABLE_NAME"]="CREATE TABLE"
      fi

      # Match: alterTable('table_name') or table('table_name')
      if [[ "$line" =~ (alterTable|table)\([\'\"]([ a-zA-Z0-9_]+)[\'\"] ]]; then
        TABLE_NAME="${BASH_REMATCH[2]}"
        if [[ ! " ${AFFECTED_TABLES[*]} " =~ " ${TABLE_NAME} " ]]; then
          AFFECTED_TABLES+=("$TABLE_NAME")
        fi
        TABLE_OPERATIONS["$TABLE_NAME"]="${TABLE_OPERATIONS[$TABLE_NAME]:-}, ALTER TABLE"
      fi

      # Match: dropTable('table_name')
      if [[ "$line" =~ dropTable\([\'\"]([ a-zA-Z0-9_]+)[\'\"] ]]; then
        TABLE_NAME="${BASH_REMATCH[1]}"
        if [[ ! " ${AFFECTED_TABLES[*]} " =~ " ${TABLE_NAME} " ]]; then
          AFFECTED_TABLES+=("$TABLE_NAME")
        fi
        TABLE_OPERATIONS["$TABLE_NAME"]="${TABLE_OPERATIONS[$TABLE_NAME]:-}, DROP TABLE"
      fi
    done < "$MIGRATION_FILE"
    ;;

  *)
    echo -e "${YELLOW}Warning: Unknown migration file type: $MIGRATION_EXT${NC}"
    echo "Supported types: .sql, .js, .ts"
    echo ""
    echo "Attempting generic table detection..."
    echo ""

    # Generic pattern matching
    while IFS= read -r line; do
      if [[ "$line" =~ (CREATE|ALTER|DROP)[[:space:]]+TABLE[[:space:]]+([a-zA-Z0-9_]+) ]]; then
        TABLE_NAME="${BASH_REMATCH[2]}"
        if [[ ! " ${AFFECTED_TABLES[*]} " =~ " ${TABLE_NAME} " ]]; then
          AFFECTED_TABLES+=("$TABLE_NAME")
        fi
      fi
    done < "$MIGRATION_FILE"
    ;;
esac

# Display affected tables
if [ ${#AFFECTED_TABLES[@]} -eq 0 ]; then
  echo -e "${GREEN}✓ No table modifications detected${NC}"
  echo ""
  echo "This migration appears to be data-only or doesn't affect tables."
  echo "Seed files likely don't need updates."
  exit 0
fi

echo "Tables affected by migration:"
for table in "${AFFECTED_TABLES[@]}"; do
  ops="${TABLE_OPERATIONS[$table]:-UNKNOWN}"
  echo -e "  ${BLUE}•${NC} $table (${ops})"
done
echo ""

# ============================================================
# Find affected seed files
# ============================================================

echo "## Checking Seed Files"
echo ""

declare -a AFFECTED_SEEDS=()
declare -A SEED_REFERENCES=()

for table in "${AFFECTED_TABLES[@]}"; do
  # Search for table references in seed files
  # Common patterns: INSERT INTO table, UPDATE table, FROM table, JOIN table, etc.

  while IFS= read -r seed_file; do
    [ -f "$seed_file" ] || continue

    # Skip if already in affected list
    if [[ " ${AFFECTED_SEEDS[*]} " =~ " ${seed_file} " ]]; then
      continue
    fi

    # Check for table references (case insensitive)
    if grep -qiE "(FROM|INTO|UPDATE|JOIN|TABLE)[[:space:]]+${table}s?" "$seed_file" 2>/dev/null; then
      AFFECTED_SEEDS+=("$seed_file")
      SEED_REFERENCES["$seed_file"]="${SEED_REFERENCES[$seed_file]:-}$table, "
    fi
  done < <(find "$SEED_DIR" -type f \( -name "*.sql" -o -name "*.js" -o -name "*.ts" \) 2>/dev/null)
done

if [ ${#AFFECTED_SEEDS[@]} -eq 0 ]; then
  echo -e "${GREEN}✓ No seed files reference affected tables${NC}"
  echo ""
  echo "Seed files don't need updates for this migration."
  exit 0
fi

echo "Seed files that reference affected tables:"
for seed in "${AFFECTED_SEEDS[@]}"; do
  tables="${SEED_REFERENCES[$seed]%, }"
  echo -e "  ${YELLOW}•${NC} $seed"
  echo "    Tables: $tables"
done
echo ""

# ============================================================
# Provide recommendations
# ============================================================

echo "═══════════════════════════════════════════════════════════"
echo -e "${YELLOW}⚠️  WARNING: Migration affects ${#AFFECTED_SEEDS[@]} seed file(s)${NC}"
echo "═══════════════════════════════════════════════════════════"
echo ""

echo "## Recommended Actions"
echo ""

STEP=1

# Check operation types for specific recommendations
HAS_CREATE=false
HAS_ALTER=false
HAS_DROP=false

for table in "${AFFECTED_TABLES[@]}"; do
  ops="${TABLE_OPERATIONS[$table]:-}"
  if [[ "$ops" == *"CREATE"* ]]; then HAS_CREATE=true; fi
  if [[ "$ops" == *"ALTER"* ]]; then HAS_ALTER=true; fi
  if [[ "$ops" == *"DROP"* ]]; then HAS_DROP=true; fi
done

if [ "$HAS_CREATE" = true ]; then
  echo "${STEP}. New tables created - Consider adding seed data for:"
  for table in "${AFFECTED_TABLES[@]}"; do
    if [[ "${TABLE_OPERATIONS[$table]}" == *"CREATE"* ]]; then
      echo "   - $table"
    fi
  done
  echo ""
  ((STEP++))
fi

if [ "$HAS_ALTER" = true ]; then
  echo "${STEP}. Tables altered - Review and update affected seeds:"
  for seed in "${AFFECTED_SEEDS[@]}"; do
    echo "   - Check: $seed"
  done
  echo ""
  echo "   Common updates needed:"
  echo "   - Add new columns to INSERT statements"
  echo "   - Remove dropped columns"
  echo "   - Update default values"
  echo "   - Adjust data types if changed"
  echo ""
  ((STEP++))
fi

if [ "$HAS_DROP" = true ]; then
  echo "${STEP}. Tables dropped - Remove references from seeds:"
  for table in "${AFFECTED_TABLES[@]}"; do
    if [[ "${TABLE_OPERATIONS[$table]}" == *"DROP"* ]]; then
      echo "   - Remove $table references from seeds"
    fi
  done
  echo ""
  ((STEP++))
fi

echo "${STEP}. Test the migration and seeds:"
echo "   $ npm run db:reset           # Reset database"
echo "   $ npm run db:seed:full       # Load all seeds"
echo "   $ npm test                   # Run tests"
echo ""
((STEP++))

echo "${STEP}. If seeds load successfully and tests pass:"
echo "   $ git add tests/seeds/"
echo "   $ git commit -m \"test: update seeds for migration $(basename "$MIGRATION_FILE")\""
echo ""

# ============================================================
# Additional checks
# ============================================================

echo "## Additional Checks"
echo ""

# Check for common migration patterns that often need seed updates
CRITICAL_PATTERNS=(
  "NOT NULL"
  "FOREIGN KEY"
  "UNIQUE"
  "PRIMARY KEY"
  "DEFAULT"
)

FOUND_PATTERNS=()

for pattern in "${CRITICAL_PATTERNS[@]}"; do
  if grep -qi "$pattern" "$MIGRATION_FILE"; then
    FOUND_PATTERNS+=("$pattern")
  fi
done

if [ ${#FOUND_PATTERNS[@]} -gt 0 ]; then
  echo -e "${YELLOW}⚠️  Critical patterns found in migration:${NC}"
  for pattern in "${FOUND_PATTERNS[@]}"; do
    echo "   - $pattern"
  done
  echo ""
  echo "These constraints may require seed data adjustments:"
  echo "   - NOT NULL: Ensure all seed records provide values"
  echo "   - FOREIGN KEY: Verify referenced records exist in seeds"
  echo "   - UNIQUE: Check for duplicate values in seed data"
  echo "   - DEFAULT: Consider if seed data should use defaults"
  echo ""
fi

# Check if full.sql exists and imports affected seeds
if [ -f "$SEED_DIR/full.sql" ]; then
  FULL_NEEDS_UPDATE=false

  for seed in "${AFFECTED_SEEDS[@]}"; do
    seed_basename=$(basename "$seed")
    if grep -q "$seed_basename" "$SEED_DIR/full.sql"; then
      FULL_NEEDS_UPDATE=true
      break
    fi
  done

  if [ "$FULL_NEEDS_UPDATE" = true ]; then
    echo -e "${BLUE}Note:${NC} full.sql imports affected seeds - verify execution order is correct"
    echo ""
  fi
fi

echo "═══════════════════════════════════════════════════════════"
echo ""

# Exit with warning code
exit 1
