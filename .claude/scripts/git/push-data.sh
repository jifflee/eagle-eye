#!/usr/bin/env bash
# push-data.sh
# Data script for /push skill - gathers git state for push operations
#
# Outputs JSON with current git state:
#   repo_root, branch, remote, remote_url, unpushed_count,
#   unpushed_commits, tracking_branch, email, email_is_noreply,
#   has_staged, has_unstaged, has_untracked
#
# Exit codes: 0 = success, 1 = not a git repo, 2 = no remote

set -euo pipefail

# ─── Verify git repo ─────────────────────────────────────────────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ $? -ne 0 || -z "${REPO_ROOT}" ]]; then
  echo '{"error": "Not a git repository"}' >&2
  exit 1
fi

# ─── Branch info ──────────────────────────────────────────────────────────────

BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "detached")
REMOTE=$(git config "branch.${BRANCH}.remote" 2>/dev/null || echo "")

if [[ -z "${REMOTE}" ]]; then
  # Try default remote
  REMOTE=$(git remote 2>/dev/null | head -1)
fi

if [[ -z "${REMOTE}" ]]; then
  echo '{"error": "No remote configured"}' >&2
  exit 2
fi

REMOTE_URL=$(git remote get-url "${REMOTE}" 2>/dev/null || echo "unknown")

# ─── Tracking branch ─────────────────────────────────────────────────────────

TRACKING=$(git config "branch.${BRANCH}.merge" 2>/dev/null || echo "")
TRACKING_SHORT=""
if [[ -n "${TRACKING}" ]]; then
  TRACKING_SHORT="${TRACKING#refs/heads/}"
fi

# Check if remote branch exists
REMOTE_BRANCH_EXISTS="false"
if git ls-remote --heads "${REMOTE}" "${BRANCH}" 2>/dev/null | grep -q .; then
  REMOTE_BRANCH_EXISTS="true"
fi

# ─── Unpushed commits ────────────────────────────────────────────────────────

UNPUSHED_COUNT=0
UNPUSHED_COMMITS="[]"

if [[ "${REMOTE_BRANCH_EXISTS}" == "true" ]]; then
  UNPUSHED_COUNT=$(git rev-list "${REMOTE}/${BRANCH}..HEAD" --count 2>/dev/null || echo "0")
  if [[ "${UNPUSHED_COUNT}" -gt 0 ]]; then
    UNPUSHED_COMMITS=$(git log "${REMOTE}/${BRANCH}..HEAD" --format='{"hash":"%h","subject":"%s"}' 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
  fi
else
  # No remote branch — all local commits are unpushed
  UNPUSHED_COUNT=$(git rev-list HEAD --count 2>/dev/null || echo "0")
  if [[ "${UNPUSHED_COUNT}" -gt 0 ]]; then
    UNPUSHED_COMMITS=$(git log --format='{"hash":"%h","subject":"%s"}' -10 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
  fi
fi

# ─── Working tree status ─────────────────────────────────────────────────────

HAS_STAGED="false"
HAS_UNSTAGED="false"
HAS_UNTRACKED="false"

if ! git diff --cached --quiet 2>/dev/null; then
  HAS_STAGED="true"
fi

if ! git diff --quiet 2>/dev/null; then
  HAS_UNSTAGED="true"
fi

if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
  HAS_UNTRACKED="true"
fi

# ─── Email config ─────────────────────────────────────────────────────────────

EMAIL=$(git config user.email 2>/dev/null || echo "")
EMAIL_IS_NOREPLY="false"
if [[ "${EMAIL}" == *"noreply.github.com"* ]]; then
  EMAIL_IS_NOREPLY="true"
fi

# ─── GitHub username (for noreply fix) ────────────────────────────────────────

GH_USERNAME=""
if command -v gh >/dev/null 2>&1; then
  GH_USERNAME=$(gh api user --jq '.login' 2>/dev/null || echo "")
fi

GH_ID=""
if [[ -n "${GH_USERNAME}" ]] && command -v gh >/dev/null 2>&1; then
  GH_ID=$(gh api user --jq '.id' 2>/dev/null || echo "")
fi

# ─── Output JSON ──────────────────────────────────────────────────────────────

jq -n \
  --arg repo_root "${REPO_ROOT}" \
  --arg branch "${BRANCH}" \
  --arg remote "${REMOTE}" \
  --arg remote_url "${REMOTE_URL}" \
  --argjson unpushed_count "${UNPUSHED_COUNT}" \
  --argjson unpushed_commits "${UNPUSHED_COMMITS}" \
  --arg tracking_branch "${TRACKING_SHORT}" \
  --argjson remote_branch_exists "${REMOTE_BRANCH_EXISTS}" \
  --arg email "${EMAIL}" \
  --argjson email_is_noreply "${EMAIL_IS_NOREPLY}" \
  --argjson has_staged "${HAS_STAGED}" \
  --argjson has_unstaged "${HAS_UNSTAGED}" \
  --argjson has_untracked "${HAS_UNTRACKED}" \
  --arg gh_username "${GH_USERNAME}" \
  --arg gh_id "${GH_ID}" \
  '{
    repo_root: $repo_root,
    branch: $branch,
    remote: $remote,
    remote_url: $remote_url,
    unpushed_count: $unpushed_count,
    unpushed_commits: $unpushed_commits,
    tracking_branch: $tracking_branch,
    remote_branch_exists: $remote_branch_exists,
    email: $email,
    email_is_noreply: $email_is_noreply,
    has_staged: $has_staged,
    has_unstaged: $has_unstaged,
    has_untracked: $has_untracked,
    gh_username: $gh_username,
    gh_id: $gh_id
  }'
