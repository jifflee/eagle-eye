#!/usr/bin/env bash
#
# sync-configs.sh
# Sync configuration changes from repository to local deployment
# size-ok: sync engine with create/update/delete operations, backup/rollback support
#
# Usage:
#   ./sync-configs.sh                    # Standard sync
#   ./sync-configs.sh --dry-run          # Preview changes without applying
#   ./sync-configs.sh --initial          # Initial sync (apply all files)
#   ./sync-configs.sh --allow-delete     # Allow file deletions
#   ./sync-configs.sh --force FILE       # Force sync of specific file(s)
#   ./sync-configs.sh --rollback [FILE]  # Rollback to previous sync
#   ./sync-configs.sh --reset-override FILE  # Remove override and restore repo version
#   ./sync-configs.sh --auto             # Non-interactive mode
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Invalid arguments
#   3 - Missing dependencies
#   4 - Not initialized
#   5 - Manifest not found
#   6 - Rollback failed
#

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    # Minimal fallback if common.sh not available
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
    log_debug() { [ -n "${DEBUG:-}" ] && echo "[DEBUG] $*" >&2 || true; }
    die() { log_error "$*"; exit 1; }
fi

# Configuration
CLAUDE_AGENTS_DIR="${HOME}/.claude-tastic"
SYNC_STATE_FILE="${CLAUDE_AGENTS_DIR}/.sync-state.json"
BACKUP_DIR="${CLAUDE_AGENTS_DIR}/.backup"
OVERRIDE_DIR="${CLAUDE_AGENTS_DIR}/overrides"
CONFIGS_DIR="${REPO_DIR}/configs"
REPO_MANIFEST="${REPO_DIR}/.sync-manifest.json"
CLAUDE_DIR="${HOME}/.claude"

# Version tracking
readonly SCRIPT_VERSION="1.0.0"

# Target path mappings (relative config path -> absolute target directory)
declare -A TARGET_DIRS=(
    ["agents"]="${CLAUDE_DIR}/agents"
    ["commands"]="${CLAUDE_DIR}/commands"
    ["n8n-workflows"]="${CLAUDE_AGENTS_DIR}/n8n-workflows"
    ["container-defs"]="${CLAUDE_AGENTS_DIR}/container-defs"
    ["base"]="${CLAUDE_AGENTS_DIR}/base"
    ["mcp"]="${CLAUDE_DIR}"
)

# Parse arguments
DRY_RUN=false
INITIAL_SYNC=false
ALLOW_DELETE=false
AUTO_MODE=false
ROLLBACK_MODE=false
RESET_OVERRIDE_MODE=false
FORCE_FILES=()
ROLLBACK_FILE=""
RESET_OVERRIDE_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --initial)
            INITIAL_SYNC=true
            shift
            ;;
        --allow-delete)
            ALLOW_DELETE=true
            shift
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --force)
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                FORCE_FILES+=("$1")
                shift
            else
                die "Error: --force requires a file argument"
            fi
            ;;
        --rollback)
            ROLLBACK_MODE=true
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                ROLLBACK_FILE="$1"
                shift
            fi
            ;;
        --reset-override)
            RESET_OVERRIDE_MODE=true
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                RESET_OVERRIDE_FILE="$1"
                shift
            else
                die "Error: --reset-override requires a file argument"
            fi
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [FILES...]"
            echo ""
            echo "Sync configuration changes from repository to local deployment."
            echo ""
            echo "Options:"
            echo "  --dry-run       Show what would be done without making changes"
            echo "  --initial       Initial sync (apply all files)"
            echo "  --allow-delete  Allow file deletions"
            echo "  --auto          Non-interactive mode"
            echo "  --force FILE    Force sync of specific file(s), ignoring overrides"
            echo "  --rollback      Rollback to previous sync (optionally specify file)"
            echo "  --reset-override FILE  Remove override and restore repo version"
            echo "  --help          Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                            # Standard sync"
            echo "  $0 --dry-run                  # Preview changes"
            echo "  $0 --force agents/architect.md"
            echo "  $0 --rollback"
            echo "  $0 --reset-override agents/backend-developer.md"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 2
            ;;
    esac
done

# ============================================================
# Utility Functions
# ============================================================

# Calculate SHA256 hash of a file
calculate_hash() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print "sha256:" $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print "sha256:" $1}'
    else
        echo "sha256:unknown"
    fi
}

# Get target path for a config file
get_target_path() {
    local rel_path="$1"
    local category="${rel_path%%/*}"
    local file_path="${rel_path#*/}"

    local target_dir="${TARGET_DIRS[$category]:-}"
    if [ -z "$target_dir" ]; then
        # Default: put in claude-tastic directory
        target_dir="${CLAUDE_AGENTS_DIR}/${category}"
    fi

    # Handle special case for mcp configs
    if [ "$category" = "mcp" ]; then
        echo "${target_dir}/${file_path}"
    else
        echo "${target_dir}/${file_path}"
    fi
}

# Check if user has override for a file
has_user_override() {
    local rel_path="$1"
    local override_path="${CLAUDE_AGENTS_DIR}/overrides/${rel_path}"
    [[ -f "$override_path" ]]
}

# Check if a file is in the force list
is_force_file() {
    local rel_path="$1"
    for force_file in "${FORCE_FILES[@]}"; do
        if [[ "$rel_path" == "$force_file" ]]; then
            return 0
        fi
    done
    return 1
}

# Get manifest hash for a file
get_manifest_hash() {
    local rel_path="$1"
    jq -r ".files[\"$rel_path\"].hash // empty" "$REPO_MANIFEST"
}

# Get sync mode for a file
get_sync_mode() {
    local rel_path="$1"
    jq -r ".files[\"$rel_path\"].sync_mode // \"overwrite\"" "$REPO_MANIFEST"
}

# Get current timestamp
get_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ============================================================
# Backup Functions
# ============================================================

# Create backup of a file before modification
backup_file() {
    local target_path="$1"
    local rel_path="$2"

    if [ ! -f "$target_path" ]; then
        return 0
    fi

    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_subdir="${BACKUP_DIR}/${backup_timestamp}"
    local backup_path="${backup_subdir}/${rel_path}"

    mkdir -p "$(dirname "$backup_path")"
    cp "$target_path" "$backup_path"

    # Record backup in state
    echo "$backup_path"
}

# Get the most recent backup directory
get_latest_backup() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 1
    fi

    # Find most recent backup directory
    local latest
    latest=$(ls -1t "$BACKUP_DIR" 2>/dev/null | head -1)

    if [ -n "$latest" ]; then
        echo "${BACKUP_DIR}/${latest}"
        return 0
    fi

    return 1
}

# ============================================================
# Sync State Management
# ============================================================

# Read current sync state
read_sync_state() {
    if [ -f "$SYNC_STATE_FILE" ]; then
        cat "$SYNC_STATE_FILE"
    else
        echo '{}'
    fi
}

# Get applied hash for a file from sync state
get_applied_hash() {
    local rel_path="$1"
    local state
    state=$(read_sync_state)
    echo "$state" | jq -r ".applied_files[\"$rel_path\"].hash // empty"
}

# Update sync state after operations
update_sync_state() {
    local applied_files="$1"
    local skipped_files="$2"
    local deleted_files="$3"

    local timestamp
    timestamp=$(get_timestamp)

    local git_commit="unknown"
    if [ -d "${REPO_DIR}/.git" ]; then
        git_commit=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    fi

    # Read existing state
    local current_state
    current_state=$(read_sync_state)

    # Merge applied files
    local merged_applied
    merged_applied=$(echo "$current_state" | jq -r '.applied_files // {}')
    if [ "$applied_files" != "{}" ] && [ -n "$applied_files" ]; then
        merged_applied=$(echo "$merged_applied" "$applied_files" | jq -s '.[0] * .[1]')
    fi

    # Remove deleted files from applied
    if [ "$deleted_files" != "[]" ] && [ -n "$deleted_files" ]; then
        for deleted in $(echo "$deleted_files" | jq -r '.[]'); do
            merged_applied=$(echo "$merged_applied" | jq "del(.[\"$deleted\"])")
        done
    fi

    # Build new state
    cat > "$SYNC_STATE_FILE" << EOF
{
  "schema_version": "1.0",
  "last_sync": "$timestamp",
  "repo_commit": "$git_commit",
  "manifest_version": "$(jq -r '.version // "1.0.0"' "$REPO_MANIFEST" 2>/dev/null || echo "1.0.0")",
  "sync_script_version": "$SCRIPT_VERSION",
  "applied_files": $(echo "$merged_applied" | jq -c .),
  "skipped_files": $(echo "$skipped_files" | jq -c .)
}
EOF
}

# ============================================================
# Diff Generation
# ============================================================

# Generate diff between manifest and local state
generate_diff() {
    local creates=()
    local updates=()
    local deletes=()

    # Get all files from manifest
    local manifest_files
    manifest_files=$(jq -r '.files | keys[]' "$REPO_MANIFEST" 2>/dev/null)

    for rel_path in $manifest_files; do
        local target_path
        target_path=$(get_target_path "$rel_path")
        local manifest_hash
        manifest_hash=$(get_manifest_hash "$rel_path")

        if [ ! -f "$target_path" ]; then
            # File doesn't exist locally - CREATE
            creates+=("$rel_path")
        else
            # File exists - check if different
            local applied_hash
            applied_hash=$(get_applied_hash "$rel_path")

            if [ "$manifest_hash" != "$applied_hash" ]; then
                # Hash differs - UPDATE
                updates+=("$rel_path")
            fi
        fi
    done

    # Check for deletions (files in local state but not in manifest)
    local deleted_in_manifest
    deleted_in_manifest=$(jq -r '.deleted[]? // empty' "$REPO_MANIFEST" 2>/dev/null)

    for rel_path in $deleted_in_manifest; do
        local target_path
        target_path=$(get_target_path "$rel_path")
        if [ -f "$target_path" ]; then
            deletes+=("$rel_path")
        fi
    done

    # Also check applied files that are no longer in manifest
    local applied_files
    applied_files=$(read_sync_state | jq -r '.applied_files // {} | keys[]' 2>/dev/null || true)

    for rel_path in $applied_files; do
        if ! jq -e ".files[\"$rel_path\"]" "$REPO_MANIFEST" >/dev/null 2>&1; then
            local target_path
            target_path=$(get_target_path "$rel_path")
            if [ -f "$target_path" ]; then
                # Check if not already in deletes
                local already_deleted=false
                for d in "${deletes[@]:-}"; do
                    if [ "$d" = "$rel_path" ]; then
                        already_deleted=true
                        break
                    fi
                done
                if ! $already_deleted; then
                    deletes+=("$rel_path")
                fi
            fi
        fi
    done

    # Output JSON diff
    local creates_json="[]"
    local updates_json="[]"
    local deletes_json="[]"

    if [ ${#creates[@]} -gt 0 ]; then
        creates_json=$(printf '%s\n' "${creates[@]}" | jq -R . | jq -s .)
    fi

    if [ ${#updates[@]} -gt 0 ]; then
        updates_json=$(printf '%s\n' "${updates[@]}" | jq -R . | jq -s .)
    fi

    if [ ${#deletes[@]} -gt 0 ]; then
        deletes_json=$(printf '%s\n' "${deletes[@]}" | jq -R . | jq -s .)
    fi

    jq -n \
        --argjson creates "$creates_json" \
        --argjson updates "$updates_json" \
        --argjson deletes "$deletes_json" \
        '{creates: $creates, updates: $updates, deletes: $deletes}'
}

# ============================================================
# n8n Workflow Sync
# ============================================================

# Sync n8n workflows via API
sync_n8n_workflows() {
    local rel_path="$1"

    # Check if n8n sync is available
    if [ ! -f "${SCRIPT_DIR}/sync-n8n-workflows.sh" ]; then
        log_warn "sync-n8n-workflows.sh not found, skipping n8n sync"
        return 0
    fi

    # Check if n8n is available
    if ! "${SCRIPT_DIR}/n8n-health.sh" --quiet 2>/dev/null; then
        log_debug "n8n not available, skipping workflow sync"
        return 0
    fi

    local workflow_file="${CONFIGS_DIR}/${rel_path}"

    log_info "Syncing n8n workflow: $rel_path"
    if "${SCRIPT_DIR}/sync-n8n-workflows.sh" "$workflow_file"; then
        log_success "n8n workflow synced: $rel_path"
        return 0
    else
        log_warn "Failed to sync n8n workflow: $rel_path"
        return 1
    fi
}

# ============================================================
# Sync Operations
# ============================================================

# Apply a single file (create or update)
apply_file() {
    local rel_path="$1"
    local operation="$2"
    local source_path="${CONFIGS_DIR}/${rel_path}"
    local target_path
    target_path=$(get_target_path "$rel_path")

    if [ ! -f "$source_path" ]; then
        log_error "Source file not found: $source_path"
        return 1
    fi

    # Create target directory if needed
    local target_dir
    target_dir=$(dirname "$target_path")

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would $operation: $rel_path -> $target_path"
        return 0
    fi

    # Backup existing file before update
    if [ "$operation" = "update" ] && [ -f "$target_path" ]; then
        local backup_path
        backup_path=$(backup_file "$target_path" "$rel_path")
        if [ -n "$backup_path" ]; then
            log_debug "Backed up to: $backup_path"
        fi
    fi

    # Create directory and copy file
    mkdir -p "$target_dir"
    cp "$source_path" "$target_path"

    log_success "${operation^}: $rel_path"

    # Special handling for n8n workflows
    if [[ "$rel_path" == n8n-workflows/* ]] && [[ "$rel_path" == *.json ]]; then
        sync_n8n_workflows "$rel_path" || log_debug "n8n sync failed or skipped"
    fi

    # Return the hash for state tracking
    calculate_hash "$source_path"
}

# Delete a file
delete_file() {
    local rel_path="$1"
    local target_path
    target_path=$(get_target_path "$rel_path")

    if [ ! -f "$target_path" ]; then
        log_debug "File already deleted: $target_path"
        return 0
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would delete: $target_path"
        return 0
    fi

    # Backup before delete
    local backup_path
    backup_path=$(backup_file "$target_path" "$rel_path")
    if [ -n "$backup_path" ]; then
        log_debug "Backed up to: $backup_path"
    fi

    rm "$target_path"
    log_success "Deleted: $rel_path"
}

# Skip a file with reason
skip_file() {
    local rel_path="$1"
    local reason="$2"

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would skip: $rel_path ($reason)"
    else
        log_warn "Skipped: $rel_path ($reason)"
    fi
}

# ============================================================
# Override Management
# ============================================================

# Reset override for a file (remove override and restore repo version)
reset_override() {
    local rel_path="$1"
    local override_path="${OVERRIDE_DIR}/${rel_path}"
    local source_path="${CONFIGS_DIR}/${rel_path}"
    local target_path
    target_path=$(get_target_path "$rel_path")

    # Check if override exists
    if [ ! -f "$override_path" ]; then
        log_warn "No override exists for: $rel_path"
        return 1
    fi

    # Check if source file exists in repo
    if [ ! -f "$source_path" ]; then
        log_error "Source file not found in repo: $source_path"
        return 1
    fi

    if $DRY_RUN; then
        log_info "[DRY-RUN] Would remove override: $override_path"
        log_info "[DRY-RUN] Would restore repo version to: $target_path"
        return 0
    fi

    # Backup the override before removing (in case user wants it back)
    local backup_timestamp
    backup_timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_subdir="${BACKUP_DIR}/${backup_timestamp}"
    local backup_path="${backup_subdir}/overrides/${rel_path}"

    mkdir -p "$(dirname "$backup_path")"
    cp "$override_path" "$backup_path"
    log_debug "Backed up override to: $backup_path"

    # Remove the override
    rm "$override_path"
    log_success "Removed override: $override_path"

    # Remove empty parent directories in override tree
    local override_parent
    override_parent=$(dirname "$override_path")
    while [ "$override_parent" != "$OVERRIDE_DIR" ] && [ -d "$override_parent" ]; do
        rmdir "$override_parent" 2>/dev/null || break
        override_parent=$(dirname "$override_parent")
    done

    # Backup target file if it exists
    if [ -f "$target_path" ]; then
        backup_file "$target_path" "$rel_path"
    fi

    # Copy repo version to target
    local target_dir
    target_dir=$(dirname "$target_path")
    mkdir -p "$target_dir"
    cp "$source_path" "$target_path"
    log_success "Restored repo version: $rel_path"

    # Update sync state
    local hash
    hash=$(calculate_hash "$source_path")
    local timestamp
    timestamp=$(get_timestamp)

    local current_state
    current_state=$(read_sync_state)

    # Update applied_files
    local updated_applied
    updated_applied=$(echo "$current_state" | jq \
        --arg path "$rel_path" \
        --arg hash "$hash" \
        --arg ts "$timestamp" \
        '.applied_files[$path] = {hash: $hash, applied_at: $ts}')

    # Remove from skipped_files if present
    updated_applied=$(echo "$updated_applied" | jq --arg path "$rel_path" 'del(.skipped_files[$path])')

    echo "$updated_applied" > "$SYNC_STATE_FILE"
    log_success "Override reset complete for: $rel_path"
}

# Merge YAML files (base + override)
merge_yaml_files() {
    local base_file="$1"
    local override_file="$2"

    # Check if yq is available for YAML merging
    if ! command -v yq &>/dev/null; then
        log_warn "yq not found - YAML merging not available"
        log_warn "Install yq for deep merge support: https://github.com/mikefarah/yq"
        return 1
    fi

    # Merge YAML with override taking precedence
    yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$base_file" "$override_file"
}

# ============================================================
# Rollback Operations
# ============================================================

# Rollback to previous backup
do_rollback() {
    local specific_file="${1:-}"

    local backup_dir
    if ! backup_dir=$(get_latest_backup); then
        log_error "No backup found to rollback"
        exit 6
    fi

    log_info "Rolling back from: $backup_dir"

    if [ -n "$specific_file" ]; then
        # Rollback specific file
        local backup_file="${backup_dir}/${specific_file}"
        if [ ! -f "$backup_file" ]; then
            log_error "Backup not found for: $specific_file"
            exit 6
        fi

        local target_path
        target_path=$(get_target_path "$specific_file")

        if $DRY_RUN; then
            log_info "[DRY-RUN] Would restore: $specific_file"
        else
            cp "$backup_file" "$target_path"
            log_success "Restored: $specific_file"
        fi
    else
        # Rollback all files in backup
        local count=0
        while IFS= read -r -d '' backup_file; do
            local rel_path="${backup_file#$backup_dir/}"
            local target_path
            target_path=$(get_target_path "$rel_path")

            if $DRY_RUN; then
                log_info "[DRY-RUN] Would restore: $rel_path"
            else
                mkdir -p "$(dirname "$target_path")"
                cp "$backup_file" "$target_path"
                log_success "Restored: $rel_path"
            fi
            ((count++))
        done < <(find "$backup_dir" -type f -print0)

        if [ $count -eq 0 ]; then
            log_warn "No files found in backup"
        else
            log_success "Rollback complete: $count file(s) restored"
        fi
    fi
}

# ============================================================
# Main Sync Logic
# ============================================================

main() {
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        die "Required command not found: jq"
    fi

    # Check if deployment is initialized
    if [ ! -d "$CLAUDE_AGENTS_DIR" ] || [ ! -f "$SYNC_STATE_FILE" ]; then
        log_error "Deployment not initialized. Run init-deployment.sh first."
        exit 4
    fi

    # Ensure override directory exists
    mkdir -p "$OVERRIDE_DIR"

    # Handle reset-override mode
    if $RESET_OVERRIDE_MODE; then
        reset_override "$RESET_OVERRIDE_FILE"
        exit $?
    fi

    # Handle rollback mode
    if $ROLLBACK_MODE; then
        do_rollback "$ROLLBACK_FILE"
        exit 0
    fi

    # Check if manifest exists
    if [ ! -f "$REPO_MANIFEST" ]; then
        log_error "Sync manifest not found: $REPO_MANIFEST"
        log_info "Run generate-manifest.sh to create it."
        exit 5
    fi

    # Generate diff
    log_info "Analyzing configuration changes..."
    local diff
    diff=$(generate_diff)

    local creates
    local updates
    local deletes
    creates=$(echo "$diff" | jq -r '.creates[]')
    updates=$(echo "$diff" | jq -r '.updates[]')
    deletes=$(echo "$diff" | jq -r '.deletes[]')

    local create_count
    local update_count
    local delete_count
    create_count=$(echo "$diff" | jq '.creates | length')
    update_count=$(echo "$diff" | jq '.updates | length')
    delete_count=$(echo "$diff" | jq '.deletes | length')

    # Report summary
    log_info "Found: $create_count create(s), $update_count update(s), $delete_count delete(s)"

    if [ "$create_count" -eq 0 ] && [ "$update_count" -eq 0 ] && [ "$delete_count" -eq 0 ]; then
        log_success "Already up to date"
        exit 0
    fi

    # Track applied, skipped, and deleted files
    local applied_files="{}"
    local skipped_files="{}"
    local deleted_files="[]"
    local timestamp
    timestamp=$(get_timestamp)

    # Process creates
    for rel_path in $creates; do
        [ -z "$rel_path" ] && continue

        local hash
        hash=$(apply_file "$rel_path" "create")

        if ! $DRY_RUN && [ -n "$hash" ]; then
            applied_files=$(echo "$applied_files" | jq \
                --arg path "$rel_path" \
                --arg hash "$hash" \
                --arg ts "$timestamp" \
                '. + {($path): {hash: $hash, applied_at: $ts}}')
        fi
    done

    # Process updates
    for rel_path in $updates; do
        [ -z "$rel_path" ] && continue

        # Check for user override (unless forced)
        if has_user_override "$rel_path" && ! is_force_file "$rel_path"; then
            skip_file "$rel_path" "user_override_exists"

            if ! $DRY_RUN; then
                local override_path="${CLAUDE_AGENTS_DIR}/overrides/${rel_path}"
                skipped_files=$(echo "$skipped_files" | jq \
                    --arg path "$rel_path" \
                    --arg reason "user_override_exists" \
                    --arg override "$override_path" \
                    '. + {($path): {reason: $reason, override_path: $override}}')
            fi
            continue
        fi

        local hash
        hash=$(apply_file "$rel_path" "update")

        if ! $DRY_RUN && [ -n "$hash" ]; then
            applied_files=$(echo "$applied_files" | jq \
                --arg path "$rel_path" \
                --arg hash "$hash" \
                --arg ts "$timestamp" \
                '. + {($path): {hash: $hash, applied_at: $ts}}')
        fi
    done

    # Process deletes
    if [ "$delete_count" -gt 0 ]; then
        if $ALLOW_DELETE; then
            for rel_path in $deletes; do
                [ -z "$rel_path" ] && continue
                delete_file "$rel_path"

                if ! $DRY_RUN; then
                    deleted_files=$(echo "$deleted_files" | jq --arg path "$rel_path" '. + [$path]')
                fi
            done
        else
            log_warn "Pending deletions (use --allow-delete to apply):"
            for rel_path in $deletes; do
                [ -z "$rel_path" ] && continue
                echo "  - $rel_path"
            done
        fi
    fi

    # Update sync state
    if ! $DRY_RUN; then
        update_sync_state "$applied_files" "$skipped_files" "$deleted_files"
        log_success "Sync complete. State updated."
    else
        log_info "Dry run complete. No changes made."
    fi
}

# Run main
main
