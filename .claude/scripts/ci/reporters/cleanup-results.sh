#!/usr/bin/env bash
# cleanup-results.sh
# Cleans up old CI result files from .ci/history/
#
# Usage:
#   ./scripts/ci/cleanup-results.sh [OPTIONS]
#
# Options:
#   --days N        Keep results newer than N days (default: 30)
#   --keep N        Keep at least N history entries per mode (default: 10)
#   --ci-dir DIR    Override .ci/ directory (default: .ci/)
#   --dry-run       Show what would be deleted without deleting
#   --quiet         Suppress non-essential output
#   --help          Show this help
#
# Behavior:
#   - Deletes history entries older than --days (default 30)
#   - Always keeps at least --keep entries per mode (even if older)
#   - Never touches .ci/latest/ entries
#
# Exit codes:
#   0  Success
#   1  Error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

KEEP_DAYS=30
KEEP_MIN=10
CI_DIR="$REPO_ROOT/.ci"
DRY_RUN=false
QUIET=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─── Parse Args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)     KEEP_DAYS="$2"; shift 2 ;;
    --keep)     KEEP_MIN="$2"; shift 2 ;;
    --ci-dir)   CI_DIR="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --quiet)    QUIET=true; shift ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[cleanup]${NC} $*"
  fi
}

log_warn() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${YELLOW}[cleanup]${NC} $*" >&2
  fi
}

log_dry() {
  echo -e "${YELLOW}[DRY RUN]${NC} Would delete: $*"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local history_dir="$CI_DIR/history"

  if [[ ! -d "$history_dir" ]]; then
    log_info "No history directory found at: $history_dir"
    exit 0
  fi

  local deleted_count=0
  local kept_count=0
  local cutoff_epoch
  cutoff_epoch=$(date -u -d "$KEEP_DAYS days ago" +%s 2>/dev/null || \
                 date -u -v-"${KEEP_DAYS}"d +%s 2>/dev/null || \
                 echo $(($(date +%s) - KEEP_DAYS * 86400)))

  # Group history files by mode for minimum-keep enforcement
  declare -A mode_files
  while IFS= read -r -d '' file; do
    local basename
    basename=$(basename "$file")
    # Extract mode from filename: {mode}-{timestamp}.json
    # Mode may contain hyphens (e.g., pre-commit), timestamp is like 20260218T120000Z
    local mode
    mode=$(echo "$basename" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z\.json$//')
    mode_files["$mode"]+="$file"$'\n'
  done < <(find "$history_dir" -name "*.json" -type f -print0 | sort -z)

  # Process each mode
  for mode in "${!mode_files[@]}"; do
    local files_str="${mode_files[$mode]}"
    local -a files=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$f")
    done <<< "$files_str"

    local total_files=${#files[@]}
    log_info "Mode '$mode': $total_files history entries"

    # Sort files by modification time (oldest first)
    local -a sorted_files=()
    while IFS= read -r -d '' f; do
      sorted_files+=("$f")
    done < <(printf '%s\0' "${files[@]}" | xargs -0 ls -t --time=ctime -r 2>/dev/null | tr '\n' '\0' || \
             printf '%s\0' "${files[@]}" | sort -z)

    local keep_boundary=$((total_files - KEEP_MIN))
    local file_idx=0

    for file in "${sorted_files[@]}"; do
      file_idx=$((file_idx + 1))

      # Always keep the minimum recent entries
      if [[ $file_idx -gt $keep_boundary ]]; then
        kept_count=$((kept_count + 1))
        continue
      fi

      # Check age
      local file_mtime
      file_mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)

      if [[ "$file_mtime" -lt "$cutoff_epoch" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
          log_dry "$file"
        else
          rm -f "$file"
          log_info "Deleted: $file"
        fi
        deleted_count=$((deleted_count + 1))
      else
        kept_count=$((kept_count + 1))
      fi
    done
  done

  # Remove empty date directories
  if [[ "$DRY_RUN" != "true" ]]; then
    find "$history_dir" -type d -empty -delete 2>/dev/null || true
  fi

  echo ""
  log_info "Cleanup complete: deleted=$deleted_count, kept=$kept_count"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "DRY RUN mode - no files were actually deleted"
  fi
}

main "$@"
