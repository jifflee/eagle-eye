#!/bin/bash
# skill-sync.sh - Declarative skill and config sync
# Feature #688: Declarative skill and config sync
#
# Usage:
#   ./scripts/skill-sync.sh [level] [options]
#
# Levels:
#   framework  - Sync from framework repo release tag
#   project    - Sync from project config/manifest
#   user       - Sync user personal overrides
#
# Options:
#   --dry-run       Preview changes without applying
#   --no-backup     Skip backup creation
#   --restore DATE  Restore from backup
#   --list-backups  List available backups
#
# Examples:
#   ./scripts/skill-sync.sh framework --dry-run
#   ./scripts/skill-sync.sh project
#   ./scripts/skill-sync.sh --restore 2026-02-09
#   ./scripts/skill-sync.sh --list-backups

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_DIR="${HOME}/.claude"
BACKUP_DIR="${CLAUDE_DIR}/.skill-backup"
MANIFEST_DIR="${CLAUDE_DIR}/.manifests"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
LEVEL="${1:-}"
DRY_RUN=false
NO_BACKUP=false
RESTORE_DATE=""
LIST_BACKUPS=false

shift || true
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-backup)
      NO_BACKUP=true
      shift
      ;;
    --restore)
      RESTORE_DATE="$2"
      shift 2
      ;;
    --list-backups)
      LIST_BACKUPS=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Create required directories
mkdir -p "$BACKUP_DIR" "$MANIFEST_DIR"

#######################################
# List available backups
#######################################
list_backups() {
  local level="${1:-}"

  echo -e "${BLUE}Available Backups:${NC}"
  echo ""

  if [[ ! -d "$BACKUP_DIR" ]] || [[ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]]; then
    echo "  No backups found"
    return 0
  fi

  local count=0
  for backup_dir in "$BACKUP_DIR"/*; do
    [[ -d "$backup_dir" ]] || continue

    local backup_name
    backup_name=$(basename "$backup_dir")

    # Filter by level if specified
    if [[ -n "$level" ]] && [[ ! "$backup_name" =~ ^${level}- ]]; then
      continue
    fi

    if [[ -f "$backup_dir/metadata.json" ]]; then
      local timestamp assets_count backup_level
      timestamp=$(jq -r '.timestamp' "$backup_dir/metadata.json" 2>/dev/null || echo "unknown")
      assets_count=$(jq -r '.assetsCount' "$backup_dir/metadata.json" 2>/dev/null || echo "?")
      backup_level=$(jq -r '.level' "$backup_dir/metadata.json" 2>/dev/null || echo "?")

      echo -e "  ${GREEN}$timestamp${NC} [$backup_level] - $assets_count assets"
      count=$((count + 1))
    fi
  done

  if [[ $count -eq 0 ]]; then
    echo "  No backups found"
  fi

  echo ""
}

#######################################
# Restore from backup
#######################################
restore_backup() {
  local level="$1"
  local timestamp="$2"

  local backup_dir="$BACKUP_DIR/${level}-${timestamp}"

  if [[ ! -d "$backup_dir" ]]; then
    echo -e "${RED}Error: Backup not found: ${level}-${timestamp}${NC}" >&2
    exit 1
  fi

  echo -e "${BLUE}Restoring from backup: ${level}-${timestamp}${NC}"
  echo ""

  if [[ ! -f "$backup_dir/metadata.json" ]]; then
    echo -e "${RED}Error: Backup metadata not found${NC}" >&2
    exit 1
  fi

  local assets_count
  assets_count=$(jq -r '.assetsCount' "$backup_dir/metadata.json")

  echo "  Assets to restore: $assets_count"
  echo ""

  read -p "Restore this backup? [y/N] " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Restore cancelled"
    exit 0
  fi

  # Restore files
  local restored=0
  for asset_type in skills agents hooks configs manifests; do
    local type_dir="$backup_dir/$asset_type"
    [[ -d "$type_dir" ]] || continue

    local target_dir="$CLAUDE_DIR/$asset_type"
    mkdir -p "$target_dir"

    for file in "$type_dir"/*; do
      [[ -f "$file" ]] || continue

      local filename
      filename=$(basename "$file")
      cp "$file" "$target_dir/$filename"
      restored=$((restored + 1))
    done
  done

  echo ""
  echo -e "${GREEN}✓ Restored $restored assets${NC}"
}

#######################################
# Create backup
#######################################
create_backup() {
  local level="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H-%M-%S")

  local backup_dir="$BACKUP_DIR/${level}-${timestamp}"
  mkdir -p "$backup_dir"

  echo -e "${BLUE}Creating backup: ${level}-${timestamp}${NC}"

  local assets_count=0

  # Backup each asset type
  for asset_type in skills agents hooks configs manifests; do
    local source_dir="$CLAUDE_DIR/$asset_type"
    [[ -d "$source_dir" ]] || continue

    local target_dir="$backup_dir/$asset_type"
    mkdir -p "$target_dir"

    for file in "$source_dir"/*; do
      [[ -f "$file" ]] || continue

      local filename
      filename=$(basename "$file")
      cp "$file" "$target_dir/$filename"
      assets_count=$((assets_count + 1))
    done
  done

  # Create metadata
  cat > "$backup_dir/metadata.json" <<EOF
{
  "timestamp": "$timestamp",
  "level": "$level",
  "assetsCount": $assets_count,
  "manifest": {
    "version": "1.0.0",
    "level": "$level",
    "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "assets": {}
  }
}
EOF

  echo -e "  Backed up: $assets_count assets"

  # Cleanup old backups (keep last 5)
  cleanup_old_backups "$level"

  echo "$backup_dir"
}

#######################################
# Cleanup old backups
#######################################
cleanup_old_backups() {
  local level="$1"
  local max_backups=5

  local backups=()
  for backup_dir in "$BACKUP_DIR/${level}-"*; do
    [[ -d "$backup_dir" ]] || continue
    backups+=("$backup_dir")
  done

  local count=${#backups[@]}
  if [[ $count -le $max_backups ]]; then
    return 0
  fi

  # Sort by name (timestamp) and remove oldest
  IFS=$'\n' sorted=($(sort <<<"${backups[*]}"))
  unset IFS

  local to_remove=$((count - max_backups))
  for ((i=0; i<to_remove; i++)); do
    rm -rf "${sorted[$i]}"
    echo -e "  ${YELLOW}Removed old backup: $(basename "${sorted[$i]}")${NC}"
  done
}

#######################################
# Perform sync
#######################################
perform_sync() {
  local level="$1"

  echo -e "${BLUE}Skill Sync Report ($level level)${NC}"
  echo ""

  # Determine source and target paths
  local source_path target_path

  case "$level" in
    framework)
      source_path="$REPO_ROOT"
      target_path="$CLAUDE_DIR"
      ;;
    project)
      source_path="$REPO_ROOT"
      target_path="$CLAUDE_DIR"
      ;;
    user)
      source_path="$CLAUDE_DIR/user-overrides"
      target_path="$CLAUDE_DIR"
      ;;
    *)
      echo -e "${RED}Error: Invalid level: $level${NC}" >&2
      echo "Valid levels: framework, project, user"
      exit 1
      ;;
  esac

  # Load current manifest
  local manifest_file="$MANIFEST_DIR/.sync-manifest-${level}.json"
  local current_assets=()

  if [[ -f "$manifest_file" ]]; then
    # Extract asset names from manifest
    mapfile -t current_assets < <(jq -r '.assets | to_entries[] | .value[] | .name' "$manifest_file" 2>/dev/null || echo "")
  fi

  # Scan source for desired assets
  local desired_assets=()
  for asset_type in skills agents hooks configs manifests; do
    local type_dir="$source_path/$asset_type"
    [[ -d "$type_dir" ]] || continue

    for file in "$type_dir"/*; do
      [[ -f "$file" ]] || continue
      desired_assets+=("$(basename "$file")")
    done
  done

  # Compute diff
  local added=()
  local updated=()
  local removed=()

  # Find added and updated
  for asset in "${desired_assets[@]}"; do
    if [[ ! " ${current_assets[*]} " =~ " ${asset} " ]]; then
      added+=("$asset")
    else
      # Check if file changed (simple check - could be hash-based)
      updated+=("$asset")
    fi
  done

  # Find removed (stale assets)
  for asset in "${current_assets[@]}"; do
    if [[ ! " ${desired_assets[*]} " =~ " ${asset} " ]]; then
      removed+=("$asset")
    fi
  done

  # Display diff
  echo -e "  ${GREEN}Added:   ${#added[@]}${NC}"
  if [[ ${#added[@]} -gt 0 ]]; then
    for asset in "${added[@]}"; do
      echo "    + $asset"
    done
  fi

  echo ""
  echo -e "  ${YELLOW}Updated: ${#updated[@]}${NC}"
  if [[ ${#updated[@]} -gt 0 ]] && [[ ${#updated[@]} -le 10 ]]; then
    for asset in "${updated[@]}"; do
      echo "    ~ $asset"
    done
  fi

  echo ""
  echo -e "  ${RED}Removed: ${#removed[@]}${NC}"
  if [[ ${#removed[@]} -gt 0 ]]; then
    for asset in "${removed[@]}"; do
      echo "    - $asset (PURGED - not in desired state)"
    done
  fi

  local total_changes=$((${#added[@]} + ${#updated[@]} + ${#removed[@]}))

  if [[ $total_changes -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}✓ No changes needed - state matches desired${NC}"
    return 0
  fi

  # Create backup if removing files
  local backup_path=""
  if [[ ${#removed[@]} -gt 0 ]] && [[ "$NO_BACKUP" != true ]] && [[ "$DRY_RUN" != true ]]; then
    echo ""
    backup_path=$(create_backup "$level")
    echo -e "  ${GREEN}Backup: $backup_path${NC}"
  fi

  echo ""

  # Dry run or apply
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY RUN] No changes applied${NC}"
    return 0
  fi

  read -p "Apply changes? [y/N] " -n 1 -r
  echo

  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Sync cancelled"
    return 0
  fi

  # Apply changes
  local applied=0
  local failed=0

  # Add new files
  for asset in "${added[@]}"; do
    for asset_type in skills agents hooks configs manifests; do
      local source_file="$source_path/$asset_type/$asset"
      if [[ -f "$source_file" ]]; then
        local target_dir="$target_path/$asset_type"
        mkdir -p "$target_dir"
        if cp "$source_file" "$target_dir/$asset"; then
          applied=$((applied + 1))
        else
          failed=$((failed + 1))
        fi
        break
      fi
    done
  done

  # Update existing files
  for asset in "${updated[@]}"; do
    for asset_type in skills agents hooks configs manifests; do
      local source_file="$source_path/$asset_type/$asset"
      if [[ -f "$source_file" ]]; then
        local target_dir="$target_path/$asset_type"
        if cp "$source_file" "$target_dir/$asset"; then
          applied=$((applied + 1))
        else
          failed=$((failed + 1))
        fi
        break
      fi
    done
  done

  # Remove stale files
  for asset in "${removed[@]}"; do
    for asset_type in skills agents hooks configs manifests; do
      local target_file="$target_path/$asset_type/$asset"
      if [[ -f "$target_file" ]]; then
        if rm "$target_file"; then
          applied=$((applied + 1))
        else
          failed=$((failed + 1))
        fi
        break
      fi
    done
  done

  # Update manifest
  cat > "$manifest_file" <<EOF
{
  "version": "1.0.0",
  "level": "$level",
  "generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "assets": {
    "skills": [],
    "agents": [],
    "hooks": [],
    "configs": [],
    "manifests": []
  }
}
EOF

  echo ""
  echo -e "${GREEN}✓ Sync complete${NC}"
  echo "  Applied: $applied"
  if [[ $failed -gt 0 ]]; then
    echo -e "  ${RED}Failed: $failed${NC}"
  fi

  if [[ -n "$backup_path" ]]; then
    echo ""
    echo -e "  Backup saved: $backup_path"
    echo -e "  Restore with: ./scripts/skill-sync.sh --restore $(basename "$backup_path" | sed "s/^${level}-//")"
  fi
}

#######################################
# Main
#######################################
main() {
  # List backups
  if [[ "$LIST_BACKUPS" == true ]]; then
    list_backups "$LEVEL"
    exit 0
  fi

  # Restore from backup
  if [[ -n "$RESTORE_DATE" ]]; then
    if [[ -z "$LEVEL" ]]; then
      echo -e "${RED}Error: Level required for restore${NC}" >&2
      echo "Usage: $0 <level> --restore <date>"
      exit 1
    fi
    restore_backup "$LEVEL" "$RESTORE_DATE"
    exit 0
  fi

  # Sync
  if [[ -z "$LEVEL" ]]; then
    echo "Usage: $0 <level> [options]"
    echo ""
    echo "Levels:"
    echo "  framework  - Sync from framework repo release tag"
    echo "  project    - Sync from project config/manifest"
    echo "  user       - Sync user personal overrides"
    echo ""
    echo "Options:"
    echo "  --dry-run       Preview changes without applying"
    echo "  --no-backup     Skip backup creation"
    echo "  --restore DATE  Restore from backup"
    echo "  --list-backups  List available backups"
    exit 1
  fi

  perform_sync "$LEVEL"
}

main
