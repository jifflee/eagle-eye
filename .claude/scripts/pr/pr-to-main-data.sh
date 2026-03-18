#!/bin/bash
set -euo pipefail
# pr-to-main-data.sh
# Gathers data for promoting qa branch to main
#
# Usage:
#   ./scripts/pr-to-main-data.sh                        # Get promotion readiness
#   ./scripts/pr-to-main-data.sh --changelog            # Include changelog generation
#   ./scripts/pr-to-main-data.sh --release-gate         # Run full release readiness gate
#   ./scripts/pr-to-main-data.sh --release-gate --version v1.2.3  # Gate with specific version
#   ./scripts/pr-to-main-data.sh --release-gate --dry-run  # Preview release gate
#
# Note: This script promotes from qa, not dev. Use pr-to-qa-data.sh for dev → qa.
#
# Outputs structured JSON with branch state and version suggestions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source rate limit utility
if [ -f "$SCRIPT_DIR/lib/api-rate-limit.sh" ]; then
  source "$SCRIPT_DIR/lib/api-rate-limit.sh"
fi

# Source changelog cache utility
if [ -f "$SCRIPT_DIR/lib/changelog-cache.sh" ]; then
  source "$SCRIPT_DIR/lib/changelog-cache.sh"
fi

INCLUDE_CHANGELOG=false
RUN_RELEASE_GATE=false
RELEASE_GATE_VERSION="HEAD"
RELEASE_GATE_DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --changelog)
      INCLUDE_CHANGELOG=true
      shift
      ;;
    --release-gate)
      RUN_RELEASE_GATE=true
      shift
      ;;
    --version)
      RELEASE_GATE_VERSION="$2"
      shift 2
      ;;
    --dry-run)
      RELEASE_GATE_DRY_RUN=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Fetch latest
git fetch origin 2>/dev/null || true

# Function to get branch state
get_branch_state() {
  local ahead=0
  local behind=0

  if git rev-parse --verify origin/qa >/dev/null 2>&1 && git rev-parse --verify origin/main >/dev/null 2>&1; then
    ahead=$(git rev-list --count origin/main..origin/qa 2>/dev/null || echo 0)
    behind=$(git rev-list --count origin/qa..origin/main 2>/dev/null || echo 0)
  fi

  echo "{\"ahead\": $ahead, \"behind\": $behind}"
}

# Function to get latest tag
get_latest_tag() {
  git describe --tags --abbrev=0 origin/main 2>/dev/null || echo ""
}

# Function to suggest next version
suggest_version() {
  local latest="$1"

  if [ -z "$latest" ]; then
    echo "v0.1.0"
    return
  fi

  # Parse semver (strip v prefix if present)
  local version="${latest#v}"
  local major=$(echo "$version" | cut -d. -f1)
  local minor=$(echo "$version" | cut -d. -f2)
  local patch=$(echo "$version" | cut -d. -f3)

  # Suggest patch bump by default
  echo "v${major}.${minor}.$((patch + 1))"
}

# Function to get commits for changelog
get_commits() {
  local latest_tag="$1"

  if [ -n "$latest_tag" ]; then
    git log --oneline "$latest_tag"..origin/qa 2>/dev/null || echo ""
  else
    git log --oneline origin/main..origin/qa 2>/dev/null || echo ""
  fi
}

# Function to categorize commits
categorize_commits() {
  local commits="$1"

  local features=""
  local fixes=""
  local other=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE '^[a-f0-9]+ feat'; then
      features="$features\"$(echo "$line" | sed 's/"/\\"/g')\","
    elif echo "$line" | grep -qiE '^[a-f0-9]+ fix'; then
      fixes="$fixes\"$(echo "$line" | sed 's/"/\\"/g')\","
    else
      other="$other\"$(echo "$line" | sed 's/"/\\"/g')\","
    fi
  done <<< "$commits"

  # Remove trailing commas
  features="${features%,}"
  fixes="${fixes%,}"
  other="${other%,}"

  echo "{\"features\": [${features}], \"fixes\": [${fixes}], \"other\": [${other}]}"
}

# Get data
branch_state=$(get_branch_state)
latest_tag=$(get_latest_tag)

# Use calculate-version.sh for intelligent version suggestions (issue #937)
if [ -f "$SCRIPT_DIR/calculate-version.sh" ]; then
  version_data=$("$SCRIPT_DIR/calculate-version.sh" --format json 2>/dev/null || echo "{}")
  suggested_version=$(echo "$version_data" | jq -r '.recommended // "v0.1.0"')
else
  # Fallback to simple patch bump if calculate-version.sh not available
  suggested_version=$(suggest_version "$latest_tag")
  version_data="{}"
fi

# Check CI status on qa branch
ci_status=$(gh run list --branch qa --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo "unknown")

# Check for open PRs to qa
open_prs=$(gh pr list --base qa --state open --json number --jq 'length' 2>/dev/null || echo 0)

# Check for existing PR to main
existing_pr=$(gh pr list --head qa --base main --state open --json number,url --jq '.[0] // null' 2>/dev/null || echo "null")

# Determine if ready
ahead=$(echo "$branch_state" | jq '.ahead')
can_promote=false
block_reasons='[]'

if [ "$ahead" -eq 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["no commits ahead of main (qa is up to date)"]')
elif [ "$open_prs" -gt 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["open PRs to qa (wait for QA validation to complete)"]')
elif [ "$ci_status" != "success" ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["CI not passing on qa"]')
else
  can_promote=true
fi

# Get changelog if requested
# Try to use cached changelog from dev→qa promotion first
changelog='null'
if [ "$INCLUDE_CHANGELOG" = true ] && [ "$ahead" -gt 0 ]; then
  # Try to get cached changelog from dev→qa promotion
  if type get_cached_changelog_json >/dev/null 2>&1; then
    cached_changelog=$(get_cached_changelog_json "dev" "qa" 2>/dev/null || echo "null")
    if [ "$cached_changelog" != "null" ]; then
      changelog="$cached_changelog"
      echo "INFO: Using cached changelog from dev→qa promotion (saves API calls)" >&2
    fi
  fi

  # Fall back to generating changelog if cache miss
  if [ "$changelog" = "null" ]; then
    echo "INFO: Cache miss, generating changelog from git log" >&2
    commits=$(get_commits "$latest_tag")
    changelog=$(categorize_commits "$commits")
  fi
fi

# Get active milestone
# Check rate limit before making call
if type check_rate_limit >/dev/null 2>&1; then
  check_rate_limit "core" >/dev/null 2>&1 || true
fi

active_milestone=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // null' 2>/dev/null || echo "null")

# Run release readiness gate if requested
release_readiness='null'
if [ "$RUN_RELEASE_GATE" = true ]; then
  RELEASE_SCRIPT="$SCRIPT_DIR/release-readiness.sh"
  if [ -f "$RELEASE_SCRIPT" ]; then
    RELEASE_REPORT_FILE="/tmp/pr-to-main-release-gate-$$.json"
    RELEASE_GATE_ARGS=(--target-branch qa --report "$RELEASE_REPORT_FILE")

    if [ "$RELEASE_GATE_DRY_RUN" = true ]; then
      RELEASE_GATE_ARGS+=(--dry-run)
    fi

    # Include changelog generation in release gate
    if [ "$INCLUDE_CHANGELOG" = true ]; then
      RELEASE_GATE_ARGS+=(--changelog)
    fi

    RELEASE_EXIT=0
    "$RELEASE_SCRIPT" "$RELEASE_GATE_VERSION" "${RELEASE_GATE_ARGS[@]}" >/dev/null 2>&1 || RELEASE_EXIT=$?

    if [ -f "$RELEASE_REPORT_FILE" ]; then
      release_readiness=$(cat "$RELEASE_REPORT_FILE")
      rm -f "$RELEASE_REPORT_FILE"
    else
      # Build minimal status from exit code
      GATE_STATUS="unknown"
      case "$RELEASE_EXIT" in
        0) GATE_STATUS="ready" ;;
        1) GATE_STATUS="blocked" ;;
        2) GATE_STATUS="ready_with_warnings" ;;
      esac
      release_readiness="{\"status\":\"$GATE_STATUS\",\"exit_code\":$RELEASE_EXIT}"
    fi

    # Block promotion if release gate is blocked (exit code 1 = blocking failure)
    if [ "$RELEASE_EXIT" -eq 1 ]; then
      block_reasons=$(echo "$block_reasons" | jq '. + ["release readiness gate failed (blocking gates - run release-readiness.sh for details)"]')
      can_promote=false
    fi
  else
    release_readiness='{"status":"skip","reason":"release-readiness.sh not found"}'
  fi
fi

cat <<EOF
{
  "branch_state": $branch_state,
  "versions": {
    "latest_tag": $([ -n "$latest_tag" ] && echo "\"$latest_tag\"" || echo "null"),
    "suggested": "$suggested_version",
    "suggestions": [
      "$suggested_version",
      "v$(echo "${suggested_version#v}" | awk -F. '{print $1"."$2+1".0"}')",
      "v$(echo "${suggested_version#v}" | awk -F. '{print $1+1".0.0"}')"
    ],
    "analysis": $version_data
  },
  "readiness": {
    "ci_status": "$ci_status",
    "open_prs_to_qa": $open_prs,
    "can_promote": $can_promote,
    "block_reasons": $block_reasons
  },
  "existing_pr": $existing_pr,
  "active_milestone": $active_milestone,
  "changelog": $changelog,
  "release_readiness": $release_readiness,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
