#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="backups/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "  Backing up to $BACKUP_DIR/"

# === PostgreSQL ===
echo "  [1/3] PostgreSQL..."
if docker compose ps postgres 2>/dev/null | grep -q "running"; then
  docker compose exec -T postgres pg_dump -U eagle_eye eagle_eye > "$BACKUP_DIR/postgres.sql" 2>/dev/null
  echo "    Saved: $BACKUP_DIR/postgres.sql ($(wc -c < "$BACKUP_DIR/postgres.sql" | tr -d ' ') bytes)"
else
  echo "    Skipped (not running)"
fi

# === Neo4j ===
echo "  [2/3] Neo4j..."
if docker compose ps neo4j 2>/dev/null | grep -q "running"; then
  # Export all nodes and relationships as Cypher statements
  docker compose exec -T neo4j cypher-shell -u neo4j -p eagle-eye-dev \
    "CALL apoc.export.cypher.all(null, {format: 'plain', stream: true}) YIELD cypherStatements RETURN cypherStatements" \
    2>/dev/null > "$BACKUP_DIR/neo4j.cypher" || \
  docker compose exec -T neo4j cypher-shell -u neo4j -p eagle-eye-dev \
    "MATCH (n) RETURN count(n) AS nodes" 2>/dev/null > "$BACKUP_DIR/neo4j-count.txt"

  if [ -f "$BACKUP_DIR/neo4j.cypher" ] && [ -s "$BACKUP_DIR/neo4j.cypher" ]; then
    echo "    Saved: $BACKUP_DIR/neo4j.cypher ($(wc -c < "$BACKUP_DIR/neo4j.cypher" | tr -d ' ') bytes)"
  else
    # Fallback: export as JSON via cypher-shell
    docker compose exec -T neo4j cypher-shell -u neo4j -p eagle-eye-dev --format plain \
      "MATCH (n) RETURN labels(n) AS labels, properties(n) AS props LIMIT 10000" \
      2>/dev/null > "$BACKUP_DIR/neo4j-nodes.txt" || true
    echo "    Saved: $BACKUP_DIR/neo4j-nodes.txt (partial export)"
  fi
else
  echo "    Skipped (not running)"
fi

# === Redis ===
echo "  [3/3] Redis..."
if docker compose ps redis 2>/dev/null | grep -q "running"; then
  docker compose exec -T redis redis-cli BGSAVE 2>/dev/null || true
  sleep 1
  docker compose cp redis:/data/dump.rdb "$BACKUP_DIR/redis.rdb" 2>/dev/null || true
  if [ -f "$BACKUP_DIR/redis.rdb" ]; then
    echo "    Saved: $BACKUP_DIR/redis.rdb ($(wc -c < "$BACKUP_DIR/redis.rdb" | tr -d ' ') bytes)"
  else
    echo "    Skipped (no dump file)"
  fi
else
  echo "    Skipped (not running)"
fi

echo ""
echo "  Backup complete: $BACKUP_DIR/"
ls -lh "$BACKUP_DIR/" 2>/dev/null | tail -n +2 | sed 's/^/    /'
