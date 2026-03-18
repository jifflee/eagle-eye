#!/usr/bin/env bash
# claude-data-cleanup.sh
# Manages retention and cleanup of ~/.claude directory data

set -euo pipefail

# Default configuration
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
RETENTION_DAYS=30
DRY_RUN=false
ARCHIVE_MODE=false
DELETE_MODE=false
VERBOSE=false

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Manage retention and cleanup of ~/.claude directory data.

OPTIONS:
    --older-than DAYS       Delete/archive files older than DAYS days (default: 30)
    --dry-run               Show what would be deleted/archived without doing it
    --archive               Compress old files instead of deleting them
    --delete                Delete old files permanently
    --verbose               Show detailed output
    --claude-dir PATH       Override ~/.claude directory path
    -h, --help              Show this help message

EXAMPLES:
    # Preview what would be deleted (30+ days old)
    $(basename "$0") --older-than 30 --dry-run

    # Archive sessions older than 30 days
    $(basename "$0") --older-than 30 --archive

    # Delete sessions older than 90 days
    $(basename "$0") --older-than 90 --delete

    # Verbose dry-run for 60 days
    $(basename "$0") --older-than 60 --dry-run --verbose

RETENTION RECOMMENDATIONS:
    - Archive sessions after 30 days
    - Delete archived sessions after 90 days
    - Run weekly via cron for automatic maintenance
    - stats-cache.json is always preserved

EOF
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

verbose_log() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --older-than)
            RETENTION_DAYS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --archive)
            ARCHIVE_MODE=true
            shift
            ;;
        --delete)
            DELETE_MODE=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --claude-dir)
            CLAUDE_DIR="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [[ "$ARCHIVE_MODE" == true ]] && [[ "$DELETE_MODE" == true ]]; then
    log_error "Cannot use --archive and --delete together. Choose one."
    exit 1
fi

if [[ "$ARCHIVE_MODE" == false ]] && [[ "$DELETE_MODE" == false ]]; then
    log_error "Must specify either --archive or --delete mode."
    usage
fi

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    log_error "Invalid retention days: $RETENTION_DAYS"
    exit 1
fi

# Verify claude directory exists
if [[ ! -d "$CLAUDE_DIR" ]]; then
    log_error "Claude directory not found: $CLAUDE_DIR"
    exit 1
fi

# Display configuration
log "Claude Data Cleanup Configuration:"
echo "  Directory: $CLAUDE_DIR"
echo "  Retention: $RETENTION_DAYS days"
echo "  Mode: $(if [[ "$ARCHIVE_MODE" == true ]]; then echo "Archive"; else echo "Delete"; fi)"
echo "  Dry Run: $DRY_RUN"
echo ""

# Calculate cutoff date (files older than this will be processed)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS date command
    CUTOFF_DATE=$(date -v-${RETENTION_DAYS}d +%s)
else
    # Linux date command
    CUTOFF_DATE=$(date -d "$RETENTION_DAYS days ago" +%s)
fi

# Statistics
TOTAL_FILES=0
TOTAL_SIZE=0
PROCESSED_FILES=0
PROCESSED_SIZE=0
ARCHIVED_FILES=0
DELETED_FILES=0

# Format bytes to human readable
format_size() {
    local size=$1
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$size"
    else
        # Fallback for macOS
        if (( size < 1024 )); then
            echo "${size}B"
        elif (( size < 1048576 )); then
            echo "$((size / 1024))KB"
        elif (( size < 1073741824 )); then
            echo "$((size / 1048576))MB"
        else
            echo "$((size / 1073741824))GB"
        fi
    fi
}

# Get file modification time
get_file_mtime() {
    local file=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f %m "$file"
    else
        stat -c %Y "$file"
    fi
}

# Archive a file
archive_file() {
    local file=$1
    local archive_file="${file}.gz"

    if [[ "$DRY_RUN" == true ]]; then
        verbose_log "Would archive: $file"
        return 0
    fi

    if gzip -k "$file" 2>/dev/null; then
        rm "$file"
        verbose_log "Archived: $file -> $archive_file"
        return 0
    else
        log_warning "Failed to archive: $file"
        return 1
    fi
}

# Delete a file
delete_file() {
    local file=$1

    if [[ "$DRY_RUN" == true ]]; then
        verbose_log "Would delete: $file"
        return 0
    fi

    if rm "$file" 2>/dev/null; then
        verbose_log "Deleted: $file"
        return 0
    else
        log_warning "Failed to delete: $file"
        return 1
    fi
}

# Process files in a directory
process_directory() {
    local dir=$1
    local pattern=${2:-"*"}

    if [[ ! -d "$dir" ]]; then
        verbose_log "Directory not found: $dir"
        return
    fi

    log "Processing: $dir"

    # Find files matching pattern
    while IFS= read -r -d '' file; do
        # Skip if it's stats-cache.json (always preserve)
        if [[ "$(basename "$file")" == "stats-cache.json" ]]; then
            verbose_log "Skipping preserved file: $file"
            continue
        fi

        # Skip already compressed files if in archive mode
        if [[ "$ARCHIVE_MODE" == true ]] && [[ "$file" == *.gz ]]; then
            verbose_log "Skipping already archived: $file"
            continue
        fi

        # Get file stats
        local file_mtime=$(get_file_mtime "$file")
        local file_size=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null || echo 0)

        TOTAL_FILES=$((TOTAL_FILES + 1))
        TOTAL_SIZE=$((TOTAL_SIZE + file_size))

        # Check if file is older than retention period
        if (( file_mtime < CUTOFF_DATE )); then
            PROCESSED_FILES=$((PROCESSED_FILES + 1))
            PROCESSED_SIZE=$((PROCESSED_SIZE + file_size))

            if [[ "$ARCHIVE_MODE" == true ]]; then
                if archive_file "$file"; then
                    ARCHIVED_FILES=$((ARCHIVED_FILES + 1))
                fi
            else
                if delete_file "$file"; then
                    DELETED_FILES=$((DELETED_FILES + 1))
                fi
            fi
        else
            verbose_log "Skipping recent file: $file"
        fi
    done < <(find "$dir" -type f -name "$pattern" -print0 2>/dev/null)
}

# Clean up empty directories
cleanup_empty_dirs() {
    local dir=$1

    if [[ "$DRY_RUN" == true ]]; then
        log "Would remove empty directories in: $dir"
        find "$dir" -type d -empty 2>/dev/null | while read -r empty_dir; do
            verbose_log "Would remove empty dir: $empty_dir"
        done
    else
        log "Removing empty directories in: $dir"
        find "$dir" -type d -empty -delete 2>/dev/null || true
    fi
}

# Main processing
log "Starting cleanup process..."
echo ""

# Process projects directory (session transcripts)
if [[ -d "$CLAUDE_DIR/projects" ]]; then
    process_directory "$CLAUDE_DIR/projects" "*.json"
    cleanup_empty_dirs "$CLAUDE_DIR/projects"
fi

# Process todos directory
if [[ -d "$CLAUDE_DIR/todos" ]]; then
    process_directory "$CLAUDE_DIR/todos" "*.json"
    cleanup_empty_dirs "$CLAUDE_DIR/todos"
fi

# Process history.jsonl (only if delete mode and very old)
# Archive mode skips this since it's already line-delimited
if [[ "$DELETE_MODE" == true ]] && [[ -f "$CLAUDE_DIR/history.jsonl" ]]; then
    log "Processing history.jsonl..."
    local history_file="$CLAUDE_DIR/history.jsonl"
    local history_mtime=$(get_file_mtime "$history_file")

    # Only process if the entire file is older than retention
    if (( history_mtime < CUTOFF_DATE )); then
        local history_size=$(stat -f %z "$history_file" 2>/dev/null || stat -c %s "$history_file" 2>/dev/null || echo 0)

        if [[ "$DRY_RUN" == true ]]; then
            log_warning "Would delete old history.jsonl ($(format_size $history_size))"
        else
            log_warning "Deleting old history.jsonl ($(format_size $history_size))"
            delete_file "$history_file"
        fi
    fi
fi

# Display summary
echo ""
log_success "Cleanup Summary:"
echo "  Total files scanned: $TOTAL_FILES ($(format_size $TOTAL_SIZE))"
echo "  Files older than $RETENTION_DAYS days: $PROCESSED_FILES ($(format_size $PROCESSED_SIZE))"

if [[ "$ARCHIVE_MODE" == true ]]; then
    echo "  Files archived: $ARCHIVED_FILES"
else
    echo "  Files deleted: $DELETED_FILES"
fi

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    log_warning "DRY RUN MODE - No changes were made"
    log "Run without --dry-run to apply changes"
fi

echo ""
log_success "Cleanup complete!"
