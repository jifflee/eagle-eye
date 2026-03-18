#!/bin/bash
# sprint-work-preflight.sh
# Mandatory pre-flight check for sprint-work command
# MUST be run before any sprint-work actions
# size-ok: multi-phase orchestration with worktree detection, state caching, and epic support
#
# Exit codes:
#   0 = Success (check JSON "action" field for next step)
#   2 = Error occurred
#
# JSON action values (all exit 0):
#   "continue"       = Proceed with sprint-work
#   "switch"         = Worktree exists, user must switch terminals
#   "created"        = Worktree created, user must switch terminals
#   "container_mode" = Container mode requested (with --read-only, reports without launching)
#
# Usage:
#   ./scripts/sprint-work-preflight.sh              # Auto-detect issue from worktree name (*-issue-{N})
#   ./scripts/sprint-work-preflight.sh 26           # Issue 26 specified (overrides auto-detect)
#   ./scripts/sprint-work-preflight.sh 26 --force   # Skip worktree (for meta-fixes only)
#   ./scripts/sprint-work-preflight.sh 26 --read-only  # Read-only op, safe in main repo
#   ./scripts/sprint-work-preflight.sh 26 --auto-launch  # Auto-launch terminal (default on)
#   ./scripts/sprint-work-preflight.sh 26 --no-auto-launch  # Print instructions only
#   ./scripts/sprint-work-preflight.sh 26 --base release/1.x  # Use specific base branch
#   ./scripts/sprint-work-preflight.sh 26 --worktree  # Opt into worktree mode (container is default)
#   ./scripts/sprint-work-preflight.sh 26 --container  # [DEPRECATED] Container is now default
#   ./scripts/sprint-work-preflight.sh 26 --image myimage:tag  # Use custom container image
#   ./scripts/sprint-work-preflight.sh 26 --fire-and-forget  # Run in background (detached)
#   ./scripts/sprint-work-preflight.sh 26 --ignore-cloud-sync  # Bypass cloud-sync warnings (not recommended)
#
# Auto-detection:
#   When no issue number is provided, the script attempts to detect it from the
#   current directory name. If the directory matches pattern "*-issue-{N}",
#   the script uses issue #{N} automatically. This allows running `/sprint-work`
#   in a worktree without specifying `--issue N` explicitly.

set -euo pipefail

# Get script directory for log-capture integration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_CAPTURE="$SCRIPT_DIR/log-capture.sh"

# ─── Cleanup Handler ──────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  # Clean up any temporary files or resources
  if [[ -n "${TEMP_FILES:-}" ]]; then
    rm -f $TEMP_FILES 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT INT TERM

# ─── Error Handling Functions ─────────────────────────────────────────────────

log_error() {
  echo "[sprint-work-preflight:ERROR] $*" >&2
}

die() {
  log_error "$@"
  echo "{\"action\": \"error\", \"reason\": \"fatal_error\", \"message\": \"$*\"}" >&2
  exit 2
}

# Error handler for unexpected failures
handle_error() {
  local line_number=$1
  local error_code=$2
  log_error "Script failed at line $line_number with exit code $error_code"
  exit $error_code
}

trap 'handle_error ${LINENO} $?' ERR

# Initialize session logging if available
if [[ -x "$LOG_CAPTURE" ]]; then
    "$LOG_CAPTURE" init 2>/dev/null || true
fi

# Parse all arguments - issue number can be first positional arg or anywhere
ISSUE_NUMBER=""
FORCE_FLAG=""
READ_ONLY_FLAG=""
CONTAINER_FLAG=""   # Explicit container mode request (deprecated, use default)
WORKTREE_FLAG=""    # Explicit worktree mode request (opt-in)
CONTAINER_IMAGE=""  # Custom container image
AUTO_LAUNCH="true"  # Default: auto-launch enabled
BASE_BRANCH=""      # Default: use dev
FIRE_AND_FORGET=""  # Fire-and-forget mode (detached container)
IGNORE_CLOUD_SYNC=""  # Bypass cloud-sync warnings

while [ $# -gt 0 ]; do
  case "$1" in
    --ignore-cloud-sync)
      IGNORE_CLOUD_SYNC="true"
      shift
      ;;
    --force)
      FORCE_FLAG="--force"
      shift
      ;;
    --read-only)
      READ_ONLY_FLAG="--read-only"
      shift
      ;;
    --no-auto-launch)
      AUTO_LAUNCH="false"
      shift
      ;;
    --auto-launch)
      AUTO_LAUNCH="true"
      shift
      ;;
    --base)
      if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
        echo '{"action": "error", "reason": "missing_base_branch", "message": "--base requires a branch name"}' >&2
        exit 2
      fi
      BASE_BRANCH="$2"
      shift 2
      ;;
    --container)
      CONTAINER_FLAG="true"
      echo "WARNING: --container flag is deprecated. Container mode is now the default." >&2
      echo "         Use --worktree to opt into worktree mode instead." >&2
      shift
      ;;
    --worktree)
      WORKTREE_FLAG="true"
      shift
      ;;
    --fire-and-forget)
      CONTAINER_FLAG="true"  # Fire-and-forget implies container mode
      FIRE_AND_FORGET="true"
      shift
      ;;
    --image)
      if [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
        echo '{"action": "error", "reason": "missing_image", "message": "--image requires an image name"}' >&2
        exit 2
      fi
      CONTAINER_IMAGE="$2"
      shift 2
      ;;
    -*)
      # Unknown flag, skip
      shift
      ;;
    *)
      # Positional argument - treat as issue number if numeric
      if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$ISSUE_NUMBER" ]; then
        ISSUE_NUMBER="$1"
      fi
      shift
      ;;
  esac
done

# Set default base branch if not specified
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH="dev"
fi

# ============================================================================
# CLOUD-SYNC DETECTION (P0)
# ============================================================================
# Check if repository is in cloud-synced directory (can cause corruption)
check_cloud_sync() {
  local repo_path="$1"

  # Check path patterns
  if [[ "$repo_path" == *"Mobile Documents"* ]] || \
     [[ "$repo_path" == *"/iCloud"* ]] || \
     [[ "$repo_path" == *"Dropbox"* ]] || \
     [[ "$repo_path" == *"OneDrive"* ]] || \
     [[ "$repo_path" == *"Google Drive"* ]]; then
    return 0  # Cloud sync detected
  fi

  # Check extended attributes (macOS iCloud)
  if command -v xattr >/dev/null 2>&1; then
    if xattr -l "$repo_path" 2>/dev/null | grep -q "fileprovider"; then
      return 0  # iCloud sync detected
    fi
  fi

  return 1  # No cloud sync
}

# Get repository root path for cloud-sync check
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -n "$REPO_ROOT" ] && [ "$IGNORE_CLOUD_SYNC" != "true" ]; then
  if check_cloud_sync "$REPO_ROOT"; then
    # Log cloud-sync detection
    if [[ -x "$LOG_CAPTURE" ]]; then
        "$LOG_CAPTURE" log-event "cloud_sync_detected" "{\"path\":\"$REPO_ROOT\"}" 2>/dev/null || true
        "$LOG_CAPTURE" capture-snapshot 2>/dev/null || true
    fi

    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  ⚠️  CLOUD-SYNCED REPOSITORY DETECTED                         ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Your repository appears to be in a cloud-synced folder:      ║" >&2
    echo "║  $REPO_ROOT" | fold -w 60 -s | sed 's/^/║  /' >&2
    echo "║                                                               ║" >&2
    echo "║  ⚠️  RISK: Cloud sync can corrupt Git repositories!          ║" >&2
    echo "║                                                               ║" >&2
    echo "║  Symptoms:                                                    ║" >&2
    echo "║  • Files appear deleted (100+ uncommitted changes)            ║" >&2
    echo "║  • Conflict directories (\" 2\" suffix, e.g., \"scripts 2/\")   ║" >&2
    echo "║  • Corrupted git index                                        ║" >&2
    echo "║  • Branch/directory name mismatches                           ║" >&2
    echo "║                                                               ║" >&2
    echo "║  RECOMMENDED ACTION:                                          ║" >&2
    echo "║  1. Move repository to a local folder (~/projects)            ║" >&2
    echo "║  2. Disable cloud sync for that folder                        ║" >&2
    echo "║  3. Use Git for version control instead                       ║" >&2
    echo "║                                                               ║" >&2
    echo "║  If you understand the risks and want to proceed anyway:      ║" >&2
    echo "║  Re-run with: --ignore-cloud-sync                             ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
    echo "{\"action\": \"error\", \"reason\": \"cloud_sync_detected\", \"path\": \"$REPO_ROOT\", \"message\": \"Repository in cloud-synced folder. Use --ignore-cloud-sync to bypass.\"}" >&2
    exit 2
  fi
fi

# ============================================================================
# WORKTREE HEALTH CHECKS (P1)
# ============================================================================
check_worktree_health() {
  local worktree_path="$1"
  local issue_number="$2"
  local current_branch="$3"

  local health_warnings=()
  local health_errors=()

  # Check for iCloud conflict directories (" 2" suffix)
  if ls -d "$worktree_path"/*\ 2 2>/dev/null | grep -q .; then
    health_errors+=("iCloud conflict directories detected (\" 2\" suffix)")
    health_errors+=("Example: $(ls -d "$worktree_path"/*\ 2 2>/dev/null | head -1)")
  fi

  # Verify worktree directory name matches expected pattern
  local worktree_dir=$(basename "$worktree_path")
  local expected_pattern=".*-issue-${issue_number}$"
  if ! [[ "$worktree_dir" =~ $expected_pattern ]]; then
    health_warnings+=("Worktree directory name doesn't match pattern: expected '*-issue-${issue_number}', got '$worktree_dir'")
  fi

  # Validate current branch matches issue number
  if [ -n "$current_branch" ] && [ -n "$issue_number" ]; then
    if ! [[ "$current_branch" =~ issue-${issue_number}($|[^0-9]) ]]; then
      health_warnings+=("Branch name '$current_branch' doesn't match issue #${issue_number}")
    fi
  fi

  # Check git index integrity
  if ! git -C "$worktree_path" fsck --quick --no-progress >/dev/null 2>&1; then
    health_errors+=("Git index integrity check failed (git fsck)")
  fi

  # Detect excessive uncommitted changes (>50 files = likely corruption)
  local modified_count=$(git -C "$worktree_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  if [ "$modified_count" -gt 50 ]; then
    health_errors+=("Excessive uncommitted changes detected: $modified_count files (likely corruption)")
  fi

  # Report errors
  if [ ${#health_errors[@]} -gt 0 ]; then
    # Log worktree health failure
    if [[ -x "$SCRIPT_DIR/log-capture.sh" ]]; then
      local errors_json=$(printf '%s\n' "${health_errors[@]}" | jq -R . | jq -s .)
      "$SCRIPT_DIR/log-capture.sh" log-event "worktree_health_failed" "{\"issue\":\"$issue_number\",\"errors\":$errors_json}" 2>/dev/null || true
      "$SCRIPT_DIR/log-capture.sh" capture-snapshot 2>/dev/null || true
    fi

    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  ❌ WORKTREE HEALTH CHECK FAILED                              ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Critical issues detected in worktree:                        ║" >&2
    for error in "${health_errors[@]}"; do
      echo "║  • $error" | fold -w 60 -s | sed 's/^/║    /' >&2
    done
    echo "║                                                               ║" >&2
    echo "║  RECOMMENDED ACTION:                                          ║" >&2
    echo "║  1. Delete corrupted worktree:                                ║" >&2
    echo "║     rm -rf $worktree_path" | fold -w 60 -s | sed 's/^/║     /' >&2
    echo "║  2. Clean up git worktree registry:                           ║" >&2
    echo "║     git worktree prune                                        ║" >&2
    echo "║  3. Re-create worktree with /sprint-work                      ║" >&2
    echo "║                                                               ║" >&2
    echo "║  If repository is in cloud-synced folder, move it first!      ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2

    local errors_json=$(printf '%s\n' "${health_errors[@]}" | jq -R . | jq -s .)
    echo "{\"action\": \"error\", \"reason\": \"worktree_health_check_failed\", \"errors\": $errors_json}" >&2
    exit 2
  fi

  # Report warnings (non-blocking)
  if [ ${#health_warnings[@]} -gt 0 ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  ⚠️  WORKTREE HEALTH WARNINGS                                 ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    for warning in "${health_warnings[@]}"; do
      echo "║  • $warning" | fold -w 60 -s | sed 's/^/║    /' >&2
    done
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  fi
}

# ============================================================================
# n8n AUTO-START CHECK
# ============================================================================
# Check and auto-start n8n-github (n8n-local) container if needed
# This is required for PR merge automation and GitHub webhook handling (#715, #716)
check_and_start_n8n() {
  local n8n_health_script="$SCRIPT_DIR/n8n-health.sh"
  local n8n_start_script="$SCRIPT_DIR/n8n-start.sh"

  # Skip if n8n-health.sh doesn't exist (n8n not set up yet)
  if [ ! -x "$n8n_health_script" ]; then
    return 0
  fi

  # Check if n8n is healthy
  if "$n8n_health_script" --quiet 2>/dev/null; then
    return 0
  fi

  # n8n is not running or unhealthy, attempt to start it
  echo "" >&2
  echo "╔═══════════════════════════════════════════════════════════════╗" >&2
  echo "║  n8n CONTAINER NOT ACTIVE                                     ║" >&2
  echo "╠═══════════════════════════════════════════════════════════════╣" >&2
  echo "║  The n8n-github container is required for:                    ║" >&2
  echo "║    - PR merge automation (#715)                               ║" >&2
  echo "║    - Container monitoring                                     ║" >&2
  echo "║    - GitHub webhook handling                                  ║" >&2
  echo "║                                                               ║" >&2
  echo "║  Attempting to auto-start n8n...                              ║" >&2
  echo "╚═══════════════════════════════════════════════════════════════╝" >&2

  # Attempt to start n8n
  if [ -x "$n8n_start_script" ]; then
    if "$n8n_start_script" --wait >/dev/null 2>&1; then
      echo "" >&2
      echo "✓ n8n started successfully" >&2
      echo "" >&2
      return 0
    else
      # Start failed, show warning but continue
      echo "" >&2
      echo "╔═══════════════════════════════════════════════════════════════╗" >&2
      echo "║  WARNING: n8n AUTO-START FAILED                               ║" >&2
      echo "╠═══════════════════════════════════════════════════════════════╣" >&2
      echo "║  Could not start n8n container automatically.                 ║" >&2
      echo "║  Some automation features may not be available.               ║" >&2
      echo "║                                                               ║" >&2
      echo "║  To start manually: ./scripts/n8n-start.sh                    ║" >&2
      echo "║                                                               ║" >&2
      echo "║  Continuing with sprint-work...                               ║" >&2
      echo "╚═══════════════════════════════════════════════════════════════╝" >&2
      echo "" >&2
      return 0
    fi
  else
    # n8n-start.sh not found, show warning but continue
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  WARNING: n8n START SCRIPT NOT FOUND                          ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Could not find n8n-start.sh script.                          ║" >&2
    echo "║  Some automation features may not be available.               ║" >&2
    echo "║                                                               ║" >&2
    echo "║  Continuing with sprint-work...                               ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    return 0
  fi
}

# Run n8n health check and auto-start if needed
check_and_start_n8n

# Log preflight start
if [[ -x "$LOG_CAPTURE" ]]; then
    "$LOG_CAPTURE" log-event "preflight_start" "{\"issue\":\"${ISSUE_NUMBER:-none}\"}" 2>/dev/null || true
fi

# Get worktree status
WORKTREE_JSON=$("$SCRIPT_DIR/detect-worktree.sh" 2>/dev/null || echo '{"is_worktree": false, "detection_error": true}')

# Extract values with null checking
IS_WORKTREE=$(echo "$WORKTREE_JSON" | jq -r '.is_worktree // false')
DETECTION_ERROR=$(echo "$WORKTREE_JSON" | jq -r '.detection_error // false')
REPO_NAME=$(echo "$WORKTREE_JSON" | jq -r '.repo_name // empty')
PARENT_DIR=$(echo "$WORKTREE_JSON" | jq -r '.parent_dir // empty')
CURRENT_BRANCH=$(echo "$WORKTREE_JSON" | jq -r '.branch // empty')

# Check for detection errors (null values or missing fields)
if [ "$DETECTION_ERROR" = "true" ] || [ -z "$REPO_NAME" ] || [ -z "$PARENT_DIR" ]; then
  # Try to recover with git commands
  REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")
  PARENT_DIR=$(dirname "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || echo "")

  if [ -z "$REPO_NAME" ] || [ -z "$PARENT_DIR" ]; then
    echo '{"action": "error", "reason": "detection_failed", "message": "Could not detect repository information"}' >&2
    exit 2
  fi
fi

# Check and auto-start n8n container if needed
# This ensures n8n-github container is running before sprint-work execution
check_n8n_container() {
  # Skip n8n checks in read-only mode or container mode
  if [ "$READ_ONLY_FLAG" = "--read-only" ] || [ "$CONTAINER_FLAG" = "true" ]; then
    return 0
  fi

  echo "Checking n8n container status..." >&2

  # Check if Docker is available
  if ! command -v docker &>/dev/null; then
    echo "Docker not available - running in worktree mode (n8n checks skipped)" >&2
    return 0
  fi

  if ! docker info &>/dev/null 2>&1; then
    echo "Docker daemon not running - running in worktree mode (n8n checks skipped)" >&2
    return 0
  fi

  # Check if n8n container exists and is running
  local n8n_container_name="n8n-local"
  local container_status=""

  # Check if container exists (running or stopped)
  if docker ps -a --format '{{.Names}}' | grep -q "^${n8n_container_name}$"; then
    container_status=$(docker inspect --format='{{.State.Status}}' "$n8n_container_name" 2>/dev/null || echo "not found")

    if [ "$container_status" = "running" ]; then
      # Container is running, check health
      if [ -x "$SCRIPT_DIR/n8n-health.sh" ]; then
        if "$SCRIPT_DIR/n8n-health.sh" --quiet 2>/dev/null; then
          echo "n8n container is healthy" >&2
          return 0
        else
          echo "n8n container is running but not healthy - attempting restart..." >&2
          docker restart "$n8n_container_name" >/dev/null 2>&1 || true
          # Wait briefly for health check
          sleep 3
          if "$SCRIPT_DIR/n8n-health.sh" --quiet 2>/dev/null; then
            echo "n8n container is now healthy" >&2
            return 0
          fi
        fi
      else
        # No health check script, assume running is good enough
        echo "n8n container is running" >&2
        return 0
      fi
    else
      # Container exists but not running - start it
      echo "n8n container exists but is not running - starting..." >&2
      docker start "$n8n_container_name" >/dev/null 2>&1 || {
        echo "Failed to start existing n8n container" >&2
        return 1
      }

      # Wait for health check
      if [ -x "$SCRIPT_DIR/n8n-health.sh" ]; then
        local retries=0
        local max_retries=15
        while [ $retries -lt $max_retries ]; do
          if "$SCRIPT_DIR/n8n-health.sh" --quiet 2>/dev/null; then
            echo "n8n container started and is healthy" >&2
            return 0
          fi
          sleep 2
          retries=$((retries + 1))
        done
        echo "Warning: n8n container started but health check failed" >&2
        return 0  # Continue anyway
      else
        echo "n8n container started" >&2
        return 0
      fi
    fi
  else
    # Container doesn't exist - create and start it
    echo "n8n container not found - creating and starting..." >&2

    if [ -x "$SCRIPT_DIR/n8n-start.sh" ]; then
      if "$SCRIPT_DIR/n8n-start.sh" --wait >/dev/null 2>&1; then
        echo "n8n container created and started successfully" >&2
        return 0
      else
        echo "Warning: Failed to start n8n container (continuing in worktree mode)" >&2
        return 0  # Don't fail sprint-work if n8n can't start
      fi
    else
      echo "Warning: n8n-start.sh not found (continuing in worktree mode)" >&2
      return 0
    fi
  fi
}

# Run n8n container check
check_n8n_container

# If no issue specified, try to auto-detect from worktree directory name
if [ -z "$ISSUE_NUMBER" ]; then
  # Get current directory name
  CURRENT_DIR=$(basename "$(pwd)")

  # Check if it matches the worktree naming pattern: *-issue-{N}
  if [[ "$CURRENT_DIR" =~ -issue-([0-9]+)$ ]]; then
    ISSUE_NUMBER="${BASH_REMATCH[1]}"
    AUTO_DETECTED="true"
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  AUTO-DETECTED ISSUE FROM WORKTREE CONTEXT                    ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Working on issue #$ISSUE_NUMBER (from worktree context)      " >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  else
    # No issue specified and not in a worktree with issue context
    echo "{\"action\": \"continue\", \"reason\": \"no_issue_specified\", \"base_branch\": \"$BASE_BRANCH\"}"
    exit 0
  fi
fi

# Note: Issue number is already validated as numeric during argument parsing

# Validate issue exists on GitHub
ISSUE_STATE=$(gh issue view "$ISSUE_NUMBER" --json number,state --jq '.state' 2>/dev/null || echo "NOT_FOUND")
if [ "$ISSUE_STATE" = "NOT_FOUND" ]; then
  echo "{\"action\": \"error\", \"reason\": \"issue_not_found\", \"message\": \"Issue #$ISSUE_NUMBER does not exist\"}" >&2
  exit 2
fi

# If issue is already closed, nothing to do
if [ "$ISSUE_STATE" = "CLOSED" ]; then
  echo "{\"action\": \"skip\", \"reason\": \"issue_closed\", \"issue\": \"$ISSUE_NUMBER\", \"message\": \"Issue #$ISSUE_NUMBER is already closed\"}"
  exit 0
fi

# Check if a merged PR exists for this issue (orphaned issue detection)
# This prevents creating worktrees for issues that are effectively complete
MERGED_PR=$(gh pr list --state merged --search "$ISSUE_NUMBER in:body" --json number,body,mergedAt --jq '
  [.[] |
    select((.body // "") | test("(?i)(fixes|closes|resolves) #'"$ISSUE_NUMBER"'\\b")) |
    {pr_number: .number, merged_at: .mergedAt}
  ] | .[0] // empty' 2>/dev/null || echo "")

if [ -n "$MERGED_PR" ]; then
  MERGED_PR_NUM=$(echo "$MERGED_PR" | jq -r '.pr_number')
  MERGED_AT=$(echo "$MERGED_PR" | jq -r '.merged_at')

  echo "" >&2
  echo "╔═══════════════════════════════════════════════════════════════╗" >&2
  echo "║  ORPHANED ISSUE DETECTED                                      ║" >&2
  echo "╠═══════════════════════════════════════════════════════════════╣" >&2
  echo "║  Issue #$ISSUE_NUMBER has merged PR #$MERGED_PR_NUM           " >&2
  echo "║  Merged at: $MERGED_AT                                        " >&2
  echo "║                                                               ║" >&2
  echo "║  Auto-closing issue as the work is complete.                  ║" >&2
  echo "╚═══════════════════════════════════════════════════════════════╝" >&2

  # Auto-close the orphaned issue
  if [ "$READ_ONLY_FLAG" != "--read-only" ]; then
    gh issue close "$ISSUE_NUMBER" --comment "Auto-closing: PR #$MERGED_PR_NUM was merged at $MERGED_AT.

This issue was still open because the PR body may not have used the 'Fixes #$ISSUE_NUMBER' format, or GitHub's auto-close didn't trigger.

Closed automatically by sprint-work-preflight.sh" 2>/dev/null || true
  fi

  echo "{\"action\": \"auto_closed\", \"reason\": \"merged_pr_detected\", \"issue\": \"$ISSUE_NUMBER\", \"merged_pr\": $MERGED_PR_NUM, \"merged_at\": \"$MERGED_AT\"}"
  exit 0
fi

# Check if issue is an epic that needs decomposition
# Epics should be broken into child issues before processing
ISSUE_LABELS=$(gh issue view "$ISSUE_NUMBER" --json labels --jq '.labels[].name' 2>/dev/null | tr '\n' ' ')
if echo "$ISSUE_LABELS" | grep -qw "epic"; then
  # Check if child issues exist with parent:N label
  CHILDREN_COUNT=$(gh issue list --label "parent:$ISSUE_NUMBER" --state open --json number 2>/dev/null | jq 'length' || echo "0")
  CHILDREN_CLOSED=$(gh issue list --label "parent:$ISSUE_NUMBER" --state closed --json number 2>/dev/null | jq 'length' || echo "0")
  CHILDREN_TOTAL=$((CHILDREN_COUNT + CHILDREN_CLOSED))

  if [ "$CHILDREN_TOTAL" -eq 0 ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  EPIC NEEDS DECOMPOSITION                                     ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Issue #$ISSUE_NUMBER is an epic with no child issues.        " >&2
    echo "║                                                               ║" >&2
    echo "║  Epics should be decomposed into smaller child issues         ║" >&2
    echo "║  before processing to enable faster, focused PRs.             ║" >&2
    echo "║                                                               ║" >&2
    echo "║  Run: /epic-decompose $ISSUE_NUMBER                           " >&2
    echo "║  Or manually create child issues with 'parent:$ISSUE_NUMBER' label" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
    echo "{\"action\": \"error\", \"reason\": \"epic_needs_decomposition\", \"issue\": \"$ISSUE_NUMBER\", \"message\": \"Epic has no child issues. Run /epic-decompose first.\"}" >&2
    exit 2
  fi

  # Epic has children - show status and suggest working on children instead
  if [ "$CHILDREN_COUNT" -gt 0 ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  EPIC WITH OPEN CHILDREN                                      ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Epic #$ISSUE_NUMBER has $CHILDREN_COUNT open child issues    " >&2
    echo "║  ($CHILDREN_CLOSED closed, $CHILDREN_TOTAL total)             " >&2
    echo "║                                                               ║" >&2
    echo "║  Work on children instead:                                    ║" >&2
    echo "║  /sprint-work --epic $ISSUE_NUMBER                            " >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
    echo "{\"action\": \"redirect_to_children\", \"reason\": \"epic_has_children\", \"issue\": \"$ISSUE_NUMBER\", \"open_children\": $CHILDREN_COUNT, \"closed_children\": $CHILDREN_CLOSED, \"message\": \"Use --epic flag to work on children\"}"
    exit 0
  fi
fi

# Check for explicit --worktree flag (opts out of container mode)
if [ "$WORKTREE_FLAG" = "true" ]; then
  echo "" >&2
  echo "╔═══════════════════════════════════════════════════════════════╗" >&2
  echo "║  WORKTREE EXECUTION MODE (EXPLICIT FLAG)                      ║" >&2
  echo "╠═══════════════════════════════════════════════════════════════╣" >&2
  echo "║  Issue #$ISSUE_NUMBER will use worktree mode (--worktree)      " >&2
  echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  # Fall through to worktree creation logic below
fi

# Check for explicit --container flag (deprecated, now the default)
if [ "$CONTAINER_FLAG" = "true" ] && [ "$WORKTREE_FLAG" != "true" ]; then
  echo "" >&2
  echo "╔═══════════════════════════════════════════════════════════════╗" >&2
  echo "║  CONTAINER EXECUTION MODE (EXPLICIT FLAG)                     ║" >&2
  echo "╠═══════════════════════════════════════════════════════════════╣" >&2
  echo "║  Issue #$ISSUE_NUMBER will run in container (--container)      " >&2
  echo "╚═══════════════════════════════════════════════════════════════╝" >&2

  # Get repository info for container launch
  REPO_FULL=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
  if [ -z "$REPO_FULL" ]; then
    echo "{\"action\": \"error\", \"reason\": \"repo_detection_failed\", \"message\": \"Could not detect repository\"}" >&2
    exit 2
  fi

  # Launch container (container-launch.sh handles token loading automatically)
  CONTAINER_LAUNCH="$SCRIPT_DIR/container-launch.sh"
  if [ -x "$CONTAINER_LAUNCH" ]; then
    if [ "$READ_ONLY_FLAG" = "--read-only" ]; then
      # For read-only mode, just report that container would be used
      echo "{\"action\": \"container_mode\", \"reason\": \"explicit_flag\", \"issue\": \"$ISSUE_NUMBER\", \"repo\": \"$REPO_FULL\", \"note\": \"read_only_mode\"}"
      exit 0
    fi

    echo "Launching container for issue #$ISSUE_NUMBER..." >&2
    # Execute container launch script with --sprint-work for autonomous mode
    # --sprint-work uses optimized workflow (container-sprint-workflow.sh) to reduce token usage
    # Build the command with conditional --detach flag for fire-and-forget mode
    CONTAINER_ARGS=("--issue" "$ISSUE_NUMBER" "--repo" "$REPO_FULL" "--branch" "$BASE_BRANCH" "--sprint-work")

    if [ -n "$CONTAINER_IMAGE" ]; then
      CONTAINER_ARGS+=("--image" "$CONTAINER_IMAGE")
    fi

    if [ "$FIRE_AND_FORGET" = "true" ]; then
      CONTAINER_ARGS+=("--detach")
      echo "Fire-and-forget mode: container will run in background" >&2
    fi

    exec "$CONTAINER_LAUNCH" "${CONTAINER_ARGS[@]}"
  else
    echo "{\"action\": \"error\", \"reason\": \"container_launch_missing\", \"message\": \"Container launch script not found at $CONTAINER_LAUNCH\"}" >&2
    exit 2
  fi
fi

# Skip container detection if --worktree flag was specified
if [ "$WORKTREE_FLAG" != "true" ]; then
  # Detect execution mode (container vs worktree)
  # Container is now the default (changed in #531)
  EXEC_MODE_SCRIPT="$SCRIPT_DIR/detect-execution-mode.sh"
  if [ -x "$EXEC_MODE_SCRIPT" ]; then
    EXEC_MODE_JSON=$("$EXEC_MODE_SCRIPT" "$ISSUE_NUMBER" 2>/dev/null || echo '{"mode": "container", "reason": "detection_failed"}')
    EXEC_MODE=$(echo "$EXEC_MODE_JSON" | jq -r '.mode // "container"')
    EXEC_REASON=$(echo "$EXEC_MODE_JSON" | jq -r '.reason // "unknown"')

    if [ "$EXEC_MODE" = "container" ] || [ "$EXEC_MODE" = "docker" ]; then
      echo "" >&2
      echo "╔═══════════════════════════════════════════════════════════════╗" >&2
      echo "║  CONTAINER EXECUTION MODE (DEFAULT)                           ║" >&2
      echo "╠═══════════════════════════════════════════════════════════════╣" >&2
      echo "║  Issue #$ISSUE_NUMBER will use container execution             " >&2
      echo "║  Reason: $EXEC_REASON" >&2
      echo "║                                                               ║" >&2
      echo "║  Use --worktree flag to opt into worktree mode instead.       ║" >&2
      echo "╚═══════════════════════════════════════════════════════════════╝" >&2

      # Get repository info for container launch
      REPO_FULL=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
      if [ -z "$REPO_FULL" ]; then
        echo "{\"action\": \"error\", \"reason\": \"repo_detection_failed\", \"message\": \"Could not detect repository\"}" >&2
        exit 2
      fi

      # Launch container (container-launch.sh handles token loading automatically)
      CONTAINER_LAUNCH="$SCRIPT_DIR/container-launch.sh"
      if [ -x "$CONTAINER_LAUNCH" ]; then
        if [ "$READ_ONLY_FLAG" = "--read-only" ]; then
          # For read-only mode, just report that container would be used
          echo "{\"action\": \"container_mode\", \"reason\": \"$EXEC_REASON\", \"issue\": \"$ISSUE_NUMBER\", \"repo\": \"$REPO_FULL\", \"note\": \"read_only_mode\"}"
          exit 0
        fi

        echo "Launching container for issue #$ISSUE_NUMBER..." >&2
        # Execute container launch script with --sprint-work for autonomous mode
        # --sprint-work uses optimized workflow (container-sprint-workflow.sh) to reduce token usage
        # Build the command with conditional --detach flag for fire-and-forget mode
        CONTAINER_ARGS=("--issue" "$ISSUE_NUMBER" "--repo" "$REPO_FULL" "--branch" "$BASE_BRANCH" "--sprint-work")

        if [ -n "$CONTAINER_IMAGE" ]; then
          CONTAINER_ARGS+=("--image" "$CONTAINER_IMAGE")
        fi

        if [ "$FIRE_AND_FORGET" = "true" ]; then
          CONTAINER_ARGS+=("--detach")
          echo "Fire-and-forget mode: container will run in background" >&2
        fi

        exec "$CONTAINER_LAUNCH" "${CONTAINER_ARGS[@]}"
      else
        echo "{\"action\": \"error\", \"reason\": \"container_launch_missing\", \"message\": \"Container launch script not found at $CONTAINER_LAUNCH\"}" >&2
        exit 2
      fi
    fi
  fi
fi

# If we reach here, worktree mode is being used (either explicit --worktree or container detection returned worktree)

# Validate base branch exists (if not dev, we need to verify it exists remotely)
if [ "$BASE_BRANCH" != "dev" ]; then
  # Fetch to ensure we have latest refs
  git fetch origin "$BASE_BRANCH" 2>/dev/null || true
  if ! git rev-parse --verify "origin/$BASE_BRANCH" >/dev/null 2>&1; then
    echo "{\"action\": \"error\", \"reason\": \"base_branch_not_found\", \"message\": \"Base branch '$BASE_BRANCH' does not exist on remote\"}" >&2
    exit 2
  fi
  echo "Using custom base branch: $BASE_BRANCH" >&2
fi

# Check for dependency conflicts with active worktrees
check_dependency_conflicts() {
  local issue_num="$1"

  # Skip if issue-dependencies.sh doesn't exist
  if [ ! -x "$SCRIPT_DIR/issue-dependencies.sh" ]; then
    return
  fi

  # Get dependencies for this issue
  local deps=$("$SCRIPT_DIR/issue-dependencies.sh" "$issue_num" 2>/dev/null || echo '{}')

  # Extract open dependencies (issues that should complete first)
  local open_deps=$(echo "$deps" | jq -r '
    [.dependencies.depends_on // [] | .[] | select(.state == "OPEN") | "#\(.number)"] | join(", ")' 2>/dev/null)

  # Check if any dependencies are currently being worked on (in other worktrees)
  local active_deps=""
  local dep_nums=$(echo "$deps" | jq -r '.dependencies.depends_on[]?.number // empty' 2>/dev/null)

  for dep_num in $dep_nums; do
    # Check if this dependency is checked out in a worktree
    local dep_worktree="$PARENT_DIR/${REPO_NAME}-issue-$dep_num"
    if [ -d "$dep_worktree" ]; then
      if [ -z "$active_deps" ]; then
        active_deps="#$dep_num"
      else
        active_deps="$active_deps, #$dep_num"
      fi
    fi
  done

  # Check for related issues in active worktrees (may have file overlap)
  local related_in_worktrees=""
  local related_nums=$(echo "$deps" | jq -r '.dependencies.related_to[]?.number // empty' 2>/dev/null)

  for rel_num in $related_nums; do
    local rel_worktree="$PARENT_DIR/${REPO_NAME}-issue-$rel_num"
    if [ -d "$rel_worktree" ]; then
      if [ -z "$related_in_worktrees" ]; then
        related_in_worktrees="#$rel_num"
      else
        related_in_worktrees="$related_in_worktrees, #$rel_num"
      fi
    fi
  done

  # Output warnings (these go to stderr so they're visible but don't affect JSON output)
  if [ -n "$open_deps" ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  DEPENDENCY WARNING                                           ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Issue #$issue_num depends on open issues: $open_deps" >&2
    echo "║  Consider completing dependencies first.                      ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  fi

  if [ -n "$active_deps" ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  ACTIVE DEPENDENCY WARNING                                    ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Dependencies in active worktrees: $active_deps" >&2
    echo "║  Work on those issues may affect this one.                    ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  fi

  if [ -n "$related_in_worktrees" ]; then
    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  RELATED ISSUE WARNING                                        ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  Related issues in active worktrees: $related_in_worktrees" >&2
    echo "║  May have file overlap - coordinate changes carefully.        ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  fi
}

# Run dependency check (non-blocking, just warnings)
check_dependency_conflicts "$ISSUE_NUMBER"

# Check for orphaned in-progress issues (non-blocking warning)
check_orphaned_in_progress() {
  local script_dir="$1"

  # Skip if validate-in-progress.sh doesn't exist
  if [ ! -x "$script_dir/validate-in-progress.sh" ]; then
    return
  fi

  # Get orphaned in-progress issues
  local orphaned_data=$("$script_dir/validate-in-progress.sh" 2>/dev/null || echo '{"total_orphaned": 0, "orphaned_issues": []}')
  local total_orphaned=$(echo "$orphaned_data" | jq -r '.total_orphaned // 0')

  if [ "$total_orphaned" -gt 0 ]; then
    # Get first 3 orphaned issues for display
    local orphaned_list=$(echo "$orphaned_data" | jq -r '.orphaned_issues[0:3] | map("#\(.number) - \(.title | if length > 40 then .[0:37] + "..." else . end)") | join("\n  ")')

    echo "" >&2
    echo "╔═══════════════════════════════════════════════════════════════╗" >&2
    echo "║  ORPHANED IN-PROGRESS ISSUES DETECTED                         ║" >&2
    echo "╠═══════════════════════════════════════════════════════════════╣" >&2
    echo "║  $total_orphaned issue(s) marked in-progress without active worktrees:" >&2
    echo "║  $orphaned_list" | fold -w 64 -s | sed 's/^/║  /' >&2
    echo "║                                                               ║" >&2
    echo "║  Consider moving these back to backlog or resuming work.     ║" >&2
    echo "║  Run: /sprint-status for full details                        ║" >&2
    echo "╚═══════════════════════════════════════════════════════════════╝" >&2
  fi
}

# Run orphaned issue check
check_orphaned_in_progress "$SCRIPT_DIR"

# If --force flag, allow continuation (for meta-fixes like fixing sprint-work itself)
if [ "$FORCE_FLAG" = "--force" ]; then
  echo "{\"action\": \"continue\", \"reason\": \"force_flag\", \"warning\": \"Worktree check bypassed\", \"base_branch\": \"$BASE_BRANCH\"}"
  exit 0
fi

# If --read-only flag, allow continuation (read-only operations are safe in main repo)
if [ "$READ_ONLY_FLAG" = "--read-only" ]; then
  echo "{\"action\": \"continue\", \"reason\": \"read_only\", \"note\": \"Read-only operations safe in main repo\", \"base_branch\": \"$BASE_BRANCH\"}"
  exit 0
fi

# If already in a worktree, allow continuation
if [ "$IS_WORKTREE" = "true" ]; then
  # Run worktree health checks before proceeding
  WORKTREE_PATH=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$WORKTREE_PATH" ] && [ -n "$ISSUE_NUMBER" ]; then
    check_worktree_health "$WORKTREE_PATH" "$ISSUE_NUMBER" "$CURRENT_BRANCH"
  fi

  WORKTREE_ISSUE=$(echo "$WORKTREE_JSON" | jq -r '.issue_number // empty')
  if [ "$WORKTREE_ISSUE" = "$ISSUE_NUMBER" ]; then
    # Generate and cache sprint state for the session
    TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
    SPRINT_STATE_FILE="$TOPLEVEL/.sprint-state.json"
    EPIC_CHECK_FILE="$TOPLEVEL/.epic-children-check"

    # Generate sprint state (cached for session to reduce API calls)
    if [ -x "$SCRIPT_DIR/generate-sprint-state.sh" ]; then
      if "$SCRIPT_DIR/generate-sprint-state.sh" "$ISSUE_NUMBER" --output "$SPRINT_STATE_FILE" --base-branch "$BASE_BRANCH" >/dev/null 2>&1; then
        echo "Sprint state cached at $SPRINT_STATE_FILE" >&2
      else
        echo "Warning: Failed to cache sprint state (non-blocking)" >&2
      fi
    fi

    # Check for epic children (if working on an epic issue)
    EPIC_INFO='{}'
    if [ -x "$SCRIPT_DIR/detect-epic-children.sh" ]; then
      EPIC_INFO=$("$SCRIPT_DIR/detect-epic-children.sh" "$ISSUE_NUMBER" --since-file "$EPIC_CHECK_FILE" 2>/dev/null || echo '{"is_epic": false}')

      IS_EPIC=$(echo "$EPIC_INFO" | jq -r '.is_epic // false')
      if [ "$IS_EPIC" = "true" ]; then
        NEW_CHILDREN=$(echo "$EPIC_INFO" | jq -r '.children.new_since_check // 0')
        OPEN_CHILDREN=$(echo "$EPIC_INFO" | jq -r '.children.open // 0')
        TOTAL_CHILDREN=$(echo "$EPIC_INFO" | jq -r '.children.total // 0')
        PERCENT=$(echo "$EPIC_INFO" | jq -r '.children.percent_complete // 0')

        # Show epic status
        echo "" >&2
        echo "╔═══════════════════════════════════════════════════════════════╗" >&2
        echo "║  EPIC WORKTREE DETECTED                                       ║" >&2
        echo "╠═══════════════════════════════════════════════════════════════╣" >&2
        echo "║  Epic #$ISSUE_NUMBER has $TOTAL_CHILDREN children ($PERCENT% complete)" >&2
        echo "║  Open: $OPEN_CHILDREN                                         " >&2
        if [ "$NEW_CHILDREN" -gt 0 ]; then
          echo "║                                                               ║" >&2
          echo "║  NEW: $NEW_CHILDREN children added since last check!         " >&2
          echo "║  Use /sprint-work --epic $ISSUE_NUMBER to see them           " >&2
        fi
        echo "╚═══════════════════════════════════════════════════════════════╝" >&2
      fi
    fi

    # Build response JSON with epic info and auto-detection status
    AUTO_DETECTED_JSON="${AUTO_DETECTED:-false}"
    echo "{\"action\": \"continue\", \"reason\": \"correct_worktree\", \"issue\": \"$ISSUE_NUMBER\", \"auto_detected\": $AUTO_DETECTED_JSON, \"sprint_state_file\": \"$SPRINT_STATE_FILE\", \"base_branch\": \"$BASE_BRANCH\", \"epic\": $EPIC_INFO}"
    exit 0
  else
    echo "{\"action\": \"error\", \"reason\": \"wrong_worktree\", \"expected\": \"$ISSUE_NUMBER\", \"actual\": \"$WORKTREE_ISSUE\", \"message\": \"You are in worktree for issue #$WORKTREE_ISSUE but requested #$ISSUE_NUMBER. Switch to correct worktree or use --force.\"}" >&2
    exit 2
  fi
fi

# In main repo with --issue specified - need to create worktree
WORKTREE_PATH="$PARENT_DIR/${REPO_NAME}-issue-$ISSUE_NUMBER"
BRANCH_NAME="feat/issue-$ISSUE_NUMBER"

# Helper function to copy to clipboard
copy_to_clipboard() {
  local cmd="$1"
  if command -v pbcopy >/dev/null 2>&1; then
    echo -n "$cmd" | pbcopy
    return 0
  elif command -v xclip >/dev/null 2>&1; then
    echo -n "$cmd" | xclip -selection clipboard
    return 0
  fi
  return 1
}

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
  if [ "$AUTO_LAUNCH" = "true" ]; then
    # Try to auto-launch terminal
    LAUNCH_RESULT=$("$SCRIPT_DIR/launch-worktree-terminal.sh" "$WORKTREE_PATH" "$ISSUE_NUMBER" 2>&1) || true
    LAUNCH_SUCCESS=$(echo "$LAUNCH_RESULT" | tail -1 | jq -r '.success // false' 2>/dev/null || echo "false")
    LAUNCH_METHOD=$(echo "$LAUNCH_RESULT" | tail -1 | jq -r '.method // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$LAUNCH_SUCCESS" = "true" ]; then
      cat <<EOF
{"action": "launched", "reason": "worktree_exists_auto_launched", "worktree_path": "$WORKTREE_PATH", "issue": "$ISSUE_NUMBER", "launch_method": "$LAUNCH_METHOD"}
EOF
      echo ""
      echo "╔═══════════════════════════════════════════════════════════════╗"
      echo "║  TERMINAL LAUNCHED - Check your $LAUNCH_METHOD                "
      echo "╠═══════════════════════════════════════════════════════════════╣"
      echo "║  Worktree: $WORKTREE_PATH"
      echo "║  Issue: #$ISSUE_NUMBER"
      echo "╚═══════════════════════════════════════════════════════════════╝"
      exit 0
    fi
    # Auto-launch failed, fall through to manual instructions
    echo "Auto-launch failed, showing manual instructions..." >&2
  fi

  # Manual instructions (fallback or --no-auto-launch)
  LAUNCH_CMD="cd $WORKTREE_PATH && claude \"/sprint-work --issue $ISSUE_NUMBER\""
  copy_to_clipboard "$LAUNCH_CMD"

  cat <<EOF
{"action": "switch", "reason": "worktree_exists", "worktree_path": "$WORKTREE_PATH", "issue": "$ISSUE_NUMBER"}
EOF
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  WORKTREE EXISTS - SWITCH TERMINALS                           ║"
  echo "╠═══════════════════════════════════════════════════════════════╣"
  echo "║                                                               ║"
  echo "║  Command copied to clipboard! Open new terminal and paste.   ║"
  echo "║                                                               ║"
  echo "║  Or manually run:                                             ║"
  echo "║  cd $WORKTREE_PATH"
  echo "║  claude \"/sprint-work --issue $ISSUE_NUMBER\""
  echo "║                                                               ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  exit 0
fi

# Helper function: handle post-worktree-creation (auto-launch or manual instructions)
handle_worktree_created() {
  local reason="$1"

  # Add checkout label to issue
  gh issue edit "$ISSUE_NUMBER" --add-label "wip:checked-out" 2>/dev/null || true

  if [ "$AUTO_LAUNCH" = "true" ]; then
    # Try to auto-launch terminal
    LAUNCH_RESULT=$("$SCRIPT_DIR/launch-worktree-terminal.sh" "$WORKTREE_PATH" "$ISSUE_NUMBER" 2>&1) || true
    LAUNCH_SUCCESS=$(echo "$LAUNCH_RESULT" | tail -1 | jq -r '.success // false' 2>/dev/null || echo "false")
    LAUNCH_METHOD=$(echo "$LAUNCH_RESULT" | tail -1 | jq -r '.method // "unknown"' 2>/dev/null || echo "unknown")

    if [ "$LAUNCH_SUCCESS" = "true" ]; then
      cat <<EOF
{"action": "created_and_launched", "reason": "$reason", "worktree_path": "$WORKTREE_PATH", "branch": "$BRANCH_NAME", "issue": "$ISSUE_NUMBER", "launch_method": "$LAUNCH_METHOD", "base_branch": "$BASE_BRANCH"}
EOF
      echo ""
      echo "╔═══════════════════════════════════════════════════════════════╗"
      echo "║  WORKTREE CREATED & TERMINAL LAUNCHED                         ║"
      echo "╠═══════════════════════════════════════════════════════════════╣"
      echo "║  Launch method: $LAUNCH_METHOD"
      echo "║  Worktree: $WORKTREE_PATH"
      echo "║  Issue: #$ISSUE_NUMBER"
      echo "╚═══════════════════════════════════════════════════════════════╝"
      return 0
    fi
    # Auto-launch failed, fall through to manual instructions
    echo "Auto-launch failed, showing manual instructions..." >&2
  fi

  # Manual instructions (fallback or --no-auto-launch)
  LAUNCH_CMD="cd $WORKTREE_PATH && claude \"/sprint-work --issue $ISSUE_NUMBER\""
  copy_to_clipboard "$LAUNCH_CMD"

  cat <<EOF
{"action": "created", "reason": "$reason", "worktree_path": "$WORKTREE_PATH", "branch": "$BRANCH_NAME", "issue": "$ISSUE_NUMBER", "base_branch": "$BASE_BRANCH"}
EOF
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  WORKTREE READY - SWITCH TERMINALS NOW                        ║"
  echo "╠═══════════════════════════════════════════════════════════════╣"
  echo "║                                                               ║"
  echo "║  Command copied to clipboard! Open new terminal and paste.   ║"
  echo "║                                                               ║"
  echo "║  Or manually run:                                             ║"
  echo "║  cd $WORKTREE_PATH"
  echo "║  claude \"/sprint-work --issue $ISSUE_NUMBER\""
  echo "║                                                               ║"
  echo "║  DO NOT continue in this terminal.                            ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
}

# Create the worktree
echo "Creating worktree at $WORKTREE_PATH..." >&2

# Log worktree creation attempt
if [[ -x "$LOG_CAPTURE" ]]; then
    "$LOG_CAPTURE" log-event "worktree_create_start" "{\"issue\":\"$ISSUE_NUMBER\",\"path\":\"$WORKTREE_PATH\",\"branch\":\"$BRANCH_NAME\"}" 2>/dev/null || true
fi

# Fetch latest from origin (use the base branch, not always dev)
if ! git fetch origin "$BASE_BRANCH" 2>&1 | head -5 >&2; then
  echo "Warning: Could not fetch origin/$BASE_BRANCH, continuing with local state..." >&2
fi

# Create worktree with new branch from the specified base branch
echo "Creating branch from origin/$BASE_BRANCH..." >&2
if git worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "origin/$BASE_BRANCH" 2>&1; then
  # Log successful worktree creation
  if [[ -x "$LOG_CAPTURE" ]]; then
      "$LOG_CAPTURE" log-event "worktree_created" "{\"issue\":\"$ISSUE_NUMBER\",\"path\":\"$WORKTREE_PATH\",\"branch\":\"$BRANCH_NAME\"}" 2>/dev/null || true
  fi
  handle_worktree_created "worktree_created"
  exit 0
else
  # Branch might already exist, try without -b
  if git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" 2>&1; then
    # Log successful worktree creation (existing branch)
    if [[ -x "$LOG_CAPTURE" ]]; then
        "$LOG_CAPTURE" log-event "worktree_created" "{\"issue\":\"$ISSUE_NUMBER\",\"path\":\"$WORKTREE_PATH\",\"branch\":\"$BRANCH_NAME\",\"existing_branch\":true}" 2>/dev/null || true
    fi
    handle_worktree_created "worktree_created_existing_branch"
    exit 0
  else
    # Log worktree creation failure
    if [[ -x "$LOG_CAPTURE" ]]; then
        "$LOG_CAPTURE" capture-error "git worktree add $WORKTREE_PATH" 1 "Failed to create worktree" 2>/dev/null || true
    fi
    echo "{\"action\": \"error\", \"reason\": \"worktree_creation_failed\", \"message\": \"Failed to create worktree at $WORKTREE_PATH\"}" >&2
    exit 2
  fi
fi
