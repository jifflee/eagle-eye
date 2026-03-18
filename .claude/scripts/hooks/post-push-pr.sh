#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: post-push-pr.sh
# Purpose: Send webhook to n8n after git push to trigger auto PR creation
# Usage: Called automatically by git-push wrapper or manually after push
#
# This script fires a webhook to n8n when:
# - Push is to a feat/issue-N branch
# - Branch has no existing PR
#
# Environment:
#   N8N_WEBHOOK_URL - Base URL for n8n webhooks (default: http://localhost:5678)
#   GITHUB_TOKEN - For checking existing PRs (optional, uses gh auth)
#
# Issue: #405 - Add automatic PR creation on issue branch commits
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common utilities if available
if [ -f "$SCRIPT_DIR/../lib/common.sh" ]; then
  source "$SCRIPT_DIR/../lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  die() { log_error "$*"; exit 1; }
fi

# Configuration
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-http://localhost:5678}"
N8N_WEBHOOK_PATH="${N8N_WEBHOOK_PATH:-/webhook/auto-pr-create}"
TIMEOUT_SECONDS=10

# Parse arguments
BRANCH=""
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# Get current branch if not specified
if [ -z "$BRANCH" ]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

if [ -z "$BRANCH" ]; then
  die "Could not determine current branch"
fi

# Extract issue number from branch name
# Supports: feat/issue-123, fix/issue-456, feature/issue-789
extract_issue_number() {
  local branch="$1"
  if [[ "$branch" =~ issue-([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

ISSUE_NUMBER=$(extract_issue_number "$BRANCH")

if [ -z "$ISSUE_NUMBER" ]; then
  log_info "Branch '$BRANCH' is not an issue branch (feat/issue-N), skipping auto PR"
  exit 0
fi

log_info "Detected issue branch: $BRANCH (issue #$ISSUE_NUMBER)"

# Check if PR already exists for this branch
check_existing_pr() {
  local pr_number
  pr_number=$(gh pr list --head "$BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
  echo "$pr_number"
}

if [ "$FORCE" = false ]; then
  EXISTING_PR=$(check_existing_pr)
  if [ -n "$EXISTING_PR" ]; then
    log_info "PR #$EXISTING_PR already exists for branch '$BRANCH', skipping"
    exit 0
  fi
fi

# Get repository info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")
if [ -z "$REPO" ]; then
  die "Could not determine repository name"
fi

# Get issue title for PR title
ISSUE_TITLE=$(gh issue view "$ISSUE_NUMBER" --json title -q '.title' 2>/dev/null || echo "")
if [ -z "$ISSUE_TITLE" ]; then
  log_warn "Could not fetch issue #$ISSUE_NUMBER title, using branch name"
  ISSUE_TITLE="Work on issue #$ISSUE_NUMBER"
fi

# Get latest commit info
COMMIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
COMMIT_MSG=$(git log -1 --pretty=format:'%s' 2>/dev/null || echo "")

# Build webhook payload
PAYLOAD=$(jq -n \
  --arg branch "$BRANCH" \
  --arg issue "$ISSUE_NUMBER" \
  --arg repo "$REPO" \
  --arg title "$ISSUE_TITLE" \
  --arg commit_sha "$COMMIT_SHA" \
  --arg commit_msg "$COMMIT_MSG" \
  '{
    event: "push_to_issue_branch",
    branch: $branch,
    issue_number: ($issue | tonumber),
    repo: $repo,
    suggested_title: $title,
    commit_sha: $commit_sha,
    commit_message: $commit_msg,
    timestamp: (now | todate)
  }'
)

log_info "Payload: $PAYLOAD"

if [ "$DRY_RUN" = true ]; then
  log_info "[DRY RUN] Would send webhook to: ${N8N_WEBHOOK_URL}${N8N_WEBHOOK_PATH}"
  log_info "[DRY RUN] Payload: $PAYLOAD"
  exit 0
fi

# Check if n8n is available
check_n8n_health() {
  curl -sf "${N8N_WEBHOOK_URL}/healthz" --max-time 2 &>/dev/null
}

if ! check_n8n_health; then
  log_warn "n8n is not available at ${N8N_WEBHOOK_URL}"
  log_info "To start n8n: ./scripts/n8n/n8n-start.sh"
  log_info "Skipping auto PR webhook (PR can be created manually)"
  exit 0
fi

# Send webhook to n8n
log_info "Sending webhook to n8n for auto PR creation..."

RESPONSE=$(curl -sf \
  --max-time "$TIMEOUT_SECONDS" \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${N8N_WEBHOOK_URL}${N8N_WEBHOOK_PATH}" 2>&1) || {
  log_warn "Failed to send webhook to n8n: $RESPONSE"
  log_info "PR can be created manually with: gh pr create --base dev"
  exit 0
}

log_success "Webhook sent successfully"
log_info "Response: $RESPONSE"

# Output for scripting
if [ -t 1 ]; then
  echo ""
  echo "n8n will create a draft PR for issue #$ISSUE_NUMBER"
  echo "Monitor progress at: ${N8N_WEBHOOK_URL}"
fi
