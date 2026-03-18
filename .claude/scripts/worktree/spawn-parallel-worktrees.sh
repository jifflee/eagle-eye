#!/bin/bash
set -euo pipefail
# spawn-parallel-worktrees.sh
# Spawn multiple worktrees for parallel issue execution
#
# Usage:
#   ./scripts/spawn-parallel-worktrees.sh ISSUE1 ISSUE2 [ISSUE3 ...]
#   ./scripts/spawn-parallel-worktrees.sh --from-candidates   # Use parallel-candidates output
#   ./scripts/spawn-parallel-worktrees.sh 162 160 157 --dry-run
#
# Options:
#   --dry-run           Show what would be done without creating worktrees
#   --from-candidates   Auto-detect parallel candidates from milestone
#   --max N             Maximum worktrees to spawn (default: 3)
#   --base-dir DIR      Base directory for worktrees (default: parent of repo)
#   --json              Output JSON result
#
# Exit Codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Git/worktree error
#   3 - Some worktrees failed to create

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
ISSUES=()
DRY_RUN=false
FROM_CANDIDATES=false
MAX_WORKTREES=3
BASE_DIR=""
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --from-candidates)
      FROM_CANDIDATES=true
      shift
      ;;
    --max)
      MAX_WORKTREES="$2"
      shift 2
      ;;
    --base-dir)
      BASE_DIR="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 ISSUE1 ISSUE2 [ISSUE3 ...] [OPTIONS]"
      echo ""
      echo "Spawn multiple worktrees for parallel issue execution."
      echo ""
      echo "Options:"
      echo "  --dry-run           Show what would be done"
      echo "  --from-candidates   Auto-detect from milestone backlog"
      echo "  --max N             Maximum worktrees (default: 3)"
      echo "  --base-dir DIR      Base directory for worktrees"
      echo "  --json              Output JSON result"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUES+=("$1")
      else
        echo "Error: Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Output helpers
log() {
  if ! $JSON_OUTPUT; then
    echo -e "$1"
  fi
}

log_warning() {
  log_warn "$@"
}

# Get repo root and base directory
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  log_error "Not in a git repository"
  exit 2
fi

if [ -z "$BASE_DIR" ]; then
  BASE_DIR=$(dirname "$REPO_ROOT")
fi

REPO_NAME=$(basename "$REPO_ROOT")

# If --from-candidates, get issues from parallel candidates
if $FROM_CANDIDATES; then
  log "Detecting parallel candidates..."
  CANDIDATES=$("$SCRIPT_DIR/issue-dependencies.sh" --parallel-candidates 2>/dev/null)

  if [ -z "$CANDIDATES" ] || [ "$(echo "$CANDIDATES" | jq -r '.parallel_candidates | length')" = "0" ]; then
    log_warning "No parallel candidates found"
    exit 0
  fi

  # Get issue numbers from candidates (up to MAX_WORKTREES)
  ISSUES=($(echo "$CANDIDATES" | jq -r ".parallel_candidates[:$MAX_WORKTREES][].number"))

  log "Found ${#ISSUES[@]} parallel candidates: ${ISSUES[*]}"
fi

# Validate we have issues to process
if [ ${#ISSUES[@]} -eq 0 ]; then
  log_error "No issues specified"
  echo "Usage: $0 ISSUE1 ISSUE2 [ISSUE3 ...]" >&2
  echo "       $0 --from-candidates" >&2
  exit 1
fi

# Limit to max worktrees
if [ ${#ISSUES[@]} -gt $MAX_WORKTREES ]; then
  log_warning "Limiting to $MAX_WORKTREES worktrees (requested ${#ISSUES[@]})"
  ISSUES=("${ISSUES[@]:0:$MAX_WORKTREES}")
fi

log ""
log "=== Spawning Parallel Worktrees ==="
log "Issues: ${ISSUES[*]}"
log "Base directory: $BASE_DIR"
log ""

# Track results
CREATED=()
FAILED=()
SKIPPED=()

# Check for existing worktrees
EXISTING_WORKTREES=$(git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/worktree //')

# Spawn worktrees for each issue
for ISSUE in "${ISSUES[@]}"; do
  BRANCH="feat/issue-$ISSUE"
  WORKTREE_DIR="$BASE_DIR/$REPO_NAME-issue-$ISSUE"

  log "${CYAN}Processing issue #$ISSUE...${NC}"

  # Check if worktree already exists
  if echo "$EXISTING_WORKTREES" | grep -q "$WORKTREE_DIR"; then
    log_warning "Worktree already exists for #$ISSUE at $WORKTREE_DIR"
    SKIPPED+=("$ISSUE")
    continue
  fi

  # Check if branch exists
  BRANCH_EXISTS=false
  if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
    BRANCH_EXISTS=true
  fi

  if $DRY_RUN; then
    log "(dry-run) Would create worktree at $WORKTREE_DIR"
    if $BRANCH_EXISTS; then
      log "(dry-run) Would use existing branch $BRANCH"
    else
      log "(dry-run) Would create new branch $BRANCH from dev"
    fi
    CREATED+=("$ISSUE")
    continue
  fi

  # Create worktree
  if $BRANCH_EXISTS; then
    # Use existing branch
    if git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null; then
      log_success "Created worktree for #$ISSUE (existing branch)"
      CREATED+=("$ISSUE")
    else
      log_error "Failed to create worktree for #$ISSUE"
      FAILED+=("$ISSUE")
    fi
  else
    # Create new branch from dev
    if git worktree add -b "$BRANCH" "$WORKTREE_DIR" dev 2>/dev/null; then
      log_success "Created worktree for #$ISSUE (new branch)"
      CREATED+=("$ISSUE")
    else
      log_error "Failed to create worktree for #$ISSUE"
      FAILED+=("$ISSUE")
    fi
  fi
done

log ""
log "=== Summary ==="
log "Created: ${#CREATED[@]}"
log "Skipped: ${#SKIPPED[@]}"
log "Failed: ${#FAILED[@]}"

if [ ${#CREATED[@]} -gt 0 ] && ! $DRY_RUN; then
  log ""
  log "Worktrees ready for work:"
  for ISSUE in "${CREATED[@]}"; do
    log "  ${CYAN}cd $BASE_DIR/$REPO_NAME-issue-$ISSUE${NC}"
    log "  ${CYAN}claude /sprint-work --issue $ISSUE${NC}"
    log ""
  done
fi

# JSON output
if $JSON_OUTPUT; then
  CREATED_JSON=$(printf '%s\n' "${CREATED[@]}" | jq -R . | jq -s 'map(tonumber)')
  SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s 'map(tonumber)')
  FAILED_JSON=$(printf '%s\n' "${FAILED[@]}" | jq -R . | jq -s 'map(tonumber)')

  [ -z "$CREATED_JSON" ] && CREATED_JSON="[]"
  [ -z "$SKIPPED_JSON" ] && SKIPPED_JSON="[]"
  [ -z "$FAILED_JSON" ] && FAILED_JSON="[]"

  jq -n \
    --argjson created "$CREATED_JSON" \
    --argjson skipped "$SKIPPED_JSON" \
    --argjson failed "$FAILED_JSON" \
    --arg base_dir "$BASE_DIR" \
    --arg repo_name "$REPO_NAME" \
    '{
      success: (($failed | length) == 0),
      base_dir: $base_dir,
      repo_name: $repo_name,
      worktrees: {
        created: $created,
        skipped: $skipped,
        failed: $failed
      },
      paths: [$created[] | {
        issue: .,
        path: ($base_dir + "/" + $repo_name + "-issue-" + (. | tostring)),
        branch: ("feat/issue-" + (. | tostring))
      }]
    }'
fi

# Exit with error if any failed
if [ ${#FAILED[@]} -gt 0 ]; then
  exit 3
fi

exit 0
