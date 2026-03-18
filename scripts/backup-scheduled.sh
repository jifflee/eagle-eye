#!/usr/bin/env bash
set -euo pipefail

# Scheduled backup — run via cron or launchd
# Keeps last N backups and cleans up old ones
#
# Usage:
#   ./scripts/backup-scheduled.sh              # Run backup, keep last 10
#   ./scripts/backup-scheduled.sh --keep 30    # Keep last 30 backups
#   ./scripts/backup-scheduled.sh --setup      # Install cron job (every 6 hours)
#
# Cron setup (manual):
#   crontab -e
#   0 */6 * * * cd /path/to/eagle-eye && ./scripts/backup-scheduled.sh >> backups/cron.log 2>&1

KEEP=${2:-10}
BACKUP_ROOT="backups"

case "${1:-run}" in
  --setup)
    REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    CRON_CMD="0 */6 * * * cd $REPO_DIR && ./scripts/backup-scheduled.sh >> backups/cron.log 2>&1"

    # Check if already installed
    if crontab -l 2>/dev/null | grep -q "backup-scheduled.sh"; then
      echo "Cron job already installed:"
      crontab -l | grep "backup-scheduled"
    else
      (crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
      echo "Cron job installed: backup every 6 hours"
      echo "  $CRON_CMD"
      echo ""
      echo "To change interval, edit with: crontab -e"
      echo "To remove: crontab -l | grep -v backup-scheduled | crontab -"
    fi
    exit 0
    ;;

  --keep)
    KEEP="$2"
    ;;
esac

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting scheduled backup..."

# Check if containers are running
if ! docker compose ps 2>/dev/null | grep -q "running"; then
  echo "  No containers running — skipping backup"
  exit 0
fi

# Run the backup
bash "$(dirname "$0")/backup.sh"

# Clean up old backups (keep last N)
BACKUP_COUNT=$(ls -d "$BACKUP_ROOT"/20* 2>/dev/null | wc -l | tr -d ' ')
if [ "$BACKUP_COUNT" -gt "$KEEP" ]; then
  REMOVE_COUNT=$((BACKUP_COUNT - KEEP))
  echo ""
  echo "  Cleaning up $REMOVE_COUNT old backup(s) (keeping last $KEEP)..."
  ls -d "$BACKUP_ROOT"/20* | head -n "$REMOVE_COUNT" | while read -r dir; do
    rm -rf "$dir"
    echo "    Removed: $dir"
  done
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete"
