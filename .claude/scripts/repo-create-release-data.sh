#!/bin/bash
# create-release-branch-data.sh
# Validates and prepares data for release branch creation
#
# Usage:
#   ./scripts/repo-create-release-data.sh <version> [source]
#   ./scripts/repo-create-release-data.sh 1.x
#   ./scripts/repo-create-release-data.sh 2.x v2.0.0
#
# Returns JSON with:
#   - Validation results
#   - Resolved source ref
#   - Branch name
#   - Commit details
#   - Go/no-go decision

set -euo pipefail

VERSION="${1:-}"
SOURCE="${2:-main}"

# Validate version provided
if [[ -z "$VERSION" ]]; then
  echo '{"error": "Usage: create-release-branch-data.sh <version> [source]", "valid": false}' >&2
  exit 1
fi

# Validate version format (N.x)
if ! echo "$VERSION" | grep -qE '^[0-9]+\.x$'; then
  jq -n \
    --arg version "$VERSION" \
    '{
      error: "Version must be in format N.x (e.g., 1.x, 2.x)",
      version: $version,
      valid: false,
      reason: "invalid_version_format"
    }'
  exit 1
fi

BRANCH_NAME="release/$VERSION"

# Fetch latest refs
git fetch origin --tags 2>/dev/null || true

# Validate source exists
SOURCE_REF=""
if git rev-parse --verify "$SOURCE" >/dev/null 2>&1; then
  SOURCE_REF="$SOURCE"
elif git rev-parse --verify "origin/$SOURCE" >/dev/null 2>&1; then
  SOURCE_REF="origin/$SOURCE"
elif git rev-parse --verify "refs/tags/$SOURCE" >/dev/null 2>&1; then
  SOURCE_REF="refs/tags/$SOURCE"
else
  jq -n \
    --arg source "$SOURCE" \
    --arg version "$VERSION" \
    '{
      error: ("Source \"" + $source + "\" not found (not a valid branch, tag, or commit)"),
      version: $version,
      source: $source,
      valid: false,
      reason: "invalid_source"
    }'
  exit 1
fi

# Get commit details for source
SOURCE_COMMIT=$(git rev-parse "$SOURCE_REF")
SOURCE_COMMIT_SHORT=$(git rev-parse --short "$SOURCE_REF")
SOURCE_MESSAGE=$(git log -1 --pretty=format:"%s" "$SOURCE_REF")

# Check if branch already exists locally
BRANCH_EXISTS_LOCAL=false
if git rev-parse --verify "$BRANCH_NAME" >/dev/null 2>&1; then
  BRANCH_EXISTS_LOCAL=true
fi

# Check if branch already exists on remote
BRANCH_EXISTS_REMOTE=false
if git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  BRANCH_EXISTS_REMOTE=true
fi

# Check working directory is clean
WORKING_DIR_CLEAN=true
if [[ -n $(git status --porcelain) ]]; then
  WORKING_DIR_CLEAN=false
fi

# Determine if operation can proceed
CAN_PROCEED=true
VALIDATION_ERRORS=()

if [[ "$BRANCH_EXISTS_LOCAL" == "true" ]]; then
  CAN_PROCEED=false
  VALIDATION_ERRORS+=("Branch $BRANCH_NAME already exists locally")
fi

if [[ "$BRANCH_EXISTS_REMOTE" == "true" ]]; then
  CAN_PROCEED=false
  VALIDATION_ERRORS+=("Branch $BRANCH_NAME already exists on remote")
fi

if [[ "$WORKING_DIR_CLEAN" == "false" ]]; then
  CAN_PROCEED=false
  VALIDATION_ERRORS+=("Working directory has uncommitted changes")
fi

# Build final JSON output
jq -n \
  --arg version "$VERSION" \
  --arg source "$SOURCE" \
  --arg source_ref "$SOURCE_REF" \
  --arg branch_name "$BRANCH_NAME" \
  --arg source_commit "$SOURCE_COMMIT" \
  --arg source_commit_short "$SOURCE_COMMIT_SHORT" \
  --arg source_message "$SOURCE_MESSAGE" \
  --argjson branch_exists_local "$BRANCH_EXISTS_LOCAL" \
  --argjson branch_exists_remote "$BRANCH_EXISTS_REMOTE" \
  --argjson working_dir_clean "$WORKING_DIR_CLEAN" \
  --argjson can_proceed "$CAN_PROCEED" \
  --argjson errors "$(printf '%s\n' "${VALIDATION_ERRORS[@]}" | jq -R . | jq -s .)" \
  '{
    valid: $can_proceed,
    version: $version,
    source: $source,
    source_ref: $source_ref,
    branch_name: $branch_name,
    commit: {
      sha: $source_commit,
      short_sha: $source_commit_short,
      message: $source_message
    },
    validation: {
      version_format_valid: true,
      source_exists: true,
      branch_exists_local: $branch_exists_local,
      branch_exists_remote: $branch_exists_remote,
      working_dir_clean: $working_dir_clean
    },
    can_proceed: $can_proceed,
    errors: $errors,
    command_preview: (if $can_proceed then "git checkout -b " + $branch_name + " " + $source_ref else null end)
  }'
