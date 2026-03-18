#!/bin/bash
set -euo pipefail
# changelog-cache.sh
# Changelog caching layer for dev→qa→main promotion pipeline
#
# This cache reduces API calls by capturing PR metadata and changelog
# during dev→qa promotion and reusing it during qa→main promotion.
#
# Usage:
#   source scripts/lib/changelog-cache.sh
#   cache_promotion_metadata "dev" "qa" "$pr_number" "$pr_body" "$changelog_json"
#   get_cached_changelog "qa" "main"
#   clear_promotion_cache "dev" "qa"

set -e

# Cache directory
CHANGELOG_CACHE_DIR="${TMPDIR:-/tmp}/gh-changelog-cache"
mkdir -p "$CHANGELOG_CACHE_DIR"

# Cache TTL: 7 days (long enough for dev→qa→main cycle)
CHANGELOG_CACHE_TTL="${CHANGELOG_CACHE_TTL:-604800}"

# Get cache key for a promotion
get_cache_key() {
  local from_branch="$1"
  local to_branch="$2"
  echo "${from_branch}-to-${to_branch}"
}

# Get cache file path
get_cache_file() {
  local cache_key="$1"
  echo "$CHANGELOG_CACHE_DIR/${cache_key}.json"
}

# Check if cache is fresh
is_cache_fresh() {
  local cache_file="$1"

  if [ ! -f "$cache_file" ]; then
    return 1
  fi

  local cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))

  if [ "$cache_age" -ge "$CHANGELOG_CACHE_TTL" ]; then
    return 1
  fi

  return 0
}

# Cache promotion metadata
# Stores PR number, body, changelog, and commit info
cache_promotion_metadata() {
  local from_branch="$1"
  local to_branch="$2"
  local pr_number="$3"
  local pr_body="$4"
  local changelog_json="$5"

  local cache_key=$(get_cache_key "$from_branch" "$to_branch")
  local cache_file=$(get_cache_file "$cache_key")

  # Get commit range for this promotion
  local commit_range=""
  local commit_count=0

  if git rev-parse --verify "origin/$from_branch" >/dev/null 2>&1 && git rev-parse --verify "origin/$to_branch" >/dev/null 2>&1; then
    commit_range=$(git log --oneline "origin/${to_branch}..origin/${from_branch}" 2>/dev/null || echo "")
    commit_count=$(echo "$commit_range" | grep -c . || echo 0)
  fi

  # Build cache entry
  local cache_entry
  cache_entry=$(jq -n \
    --arg from "$from_branch" \
    --arg to "$to_branch" \
    --argjson pr "$pr_number" \
    --arg pr_body "$pr_body" \
    --argjson changelog "$changelog_json" \
    --argjson commit_count "$commit_count" \
    --arg cached_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      from_branch: $from,
      to_branch: $to,
      pr_number: $pr,
      pr_body: $pr_body,
      changelog: $changelog,
      commit_count: $commit_count,
      cached_at: $cached_at
    }')

  echo "$cache_entry" > "$cache_file"

  echo "Cached promotion metadata: $from_branch → $to_branch (PR #${pr_number})" >&2
}

# Get cached changelog for a promotion
get_cached_changelog() {
  local from_branch="$1"
  local to_branch="$2"

  local cache_key=$(get_cache_key "$from_branch" "$to_branch")
  local cache_file=$(get_cache_file "$cache_key")

  if ! is_cache_fresh "$cache_file"; then
    echo "null"
    return 1
  fi

  cat "$cache_file"
}

# Get cached PR body for reuse in subsequent promotions
get_cached_pr_body() {
  local from_branch="$1"
  local to_branch="$2"

  local cache_data
  cache_data=$(get_cached_changelog "$from_branch" "$to_branch")

  if [ "$cache_data" = "null" ]; then
    echo ""
    return 1
  fi

  echo "$cache_data" | jq -r '.pr_body // ""'
}

# Get cached changelog JSON
get_cached_changelog_json() {
  local from_branch="$1"
  local to_branch="$2"

  local cache_data
  cache_data=$(get_cached_changelog "$from_branch" "$to_branch")

  if [ "$cache_data" = "null" ]; then
    echo "null"
    return 1
  fi

  echo "$cache_data" | jq '.changelog // null'
}

# Clear promotion cache
clear_promotion_cache() {
  local from_branch="$1"
  local to_branch="$2"

  local cache_key=$(get_cache_key "$from_branch" "$to_branch")
  local cache_file=$(get_cache_file "$cache_key")

  if [ -f "$cache_file" ]; then
    rm -f "$cache_file"
    echo "Cleared promotion cache: $from_branch → $to_branch" >&2
  fi
}

# Clear all old caches
cleanup_old_caches() {
  local retention_seconds="${1:-$CHANGELOG_CACHE_TTL}"
  local now=$(date +%s)
  local cleaned=0

  for cache_file in "$CHANGELOG_CACHE_DIR"/*.json; do
    [ -f "$cache_file" ] || continue

    local cache_age=$((now - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))

    if [ "$cache_age" -ge "$retention_seconds" ]; then
      rm -f "$cache_file"
      cleaned=$((cleaned + 1))
    fi
  done

  if [ "$cleaned" -gt 0 ]; then
    echo "Cleaned $cleaned old changelog cache(s)" >&2
  fi
}

# List all cached promotions
list_cached_promotions() {
  echo "Cached Promotions:"
  echo ""

  for cache_file in "$CHANGELOG_CACHE_DIR"/*.json; do
    [ -f "$cache_file" ] || continue

    local from=$(jq -r '.from_branch' "$cache_file")
    local to=$(jq -r '.to_branch' "$cache_file")
    local pr=$(jq -r '.pr_number' "$cache_file")
    local cached_at=$(jq -r '.cached_at' "$cache_file")
    local commit_count=$(jq -r '.commit_count' "$cache_file")

    local age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    local age_hours=$((age / 3600))

    if is_cache_fresh "$cache_file"; then
      echo "  ✓ $from → $to (PR #${pr}, ${commit_count} commits, ${age_hours}h old)"
    else
      echo "  ✗ $from → $to (PR #${pr}, EXPIRED, ${age_hours}h old)"
    fi
  done
}

# Chain cached changelogs for multi-stage promotion
# Example: dev→qa→main can reuse dev→qa changelog when promoting qa→main
get_chained_changelog() {
  local target_branch="$1"  # Final destination (e.g., "main")

  # Try to find changelog chain
  # For qa→main, first check if we have dev→qa cached
  local changelog_parts='[]'

  # Check dev→qa cache
  local dev_qa_cache=$(get_cached_changelog "dev" "qa" 2>/dev/null || echo "null")
  if [ "$dev_qa_cache" != "null" ]; then
    local dev_qa_changelog=$(echo "$dev_qa_cache" | jq '.changelog')
    changelog_parts=$(echo "$changelog_parts" | jq --argjson part "$dev_qa_changelog" '. + [$part]')
  fi

  # Return combined changelog
  if [ "$changelog_parts" = "[]" ]; then
    echo "null"
    return 1
  fi

  # Merge all changelog parts
  local merged_changelog
  merged_changelog=$(echo "$changelog_parts" | jq '
    {
      features: (map(.features // []) | flatten | unique),
      fixes: (map(.fixes // []) | flatten | unique),
      other: (map(.other // []) | flatten | unique)
    }
  ')

  echo "$merged_changelog"
}

# Export functions
export -f cache_promotion_metadata
export -f get_cached_changelog
export -f get_cached_pr_body
export -f get_cached_changelog_json
export -f clear_promotion_cache
export -f cleanup_old_caches
export -f list_cached_promotions
export -f get_chained_changelog
