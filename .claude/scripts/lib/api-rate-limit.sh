#!/bin/bash
set -euo pipefail
# api-rate-limit.sh
# GitHub API rate limit monitoring and throttling utility
#
# Usage:
#   source scripts/lib/api-rate-limit.sh
#   check_rate_limit        # Check current rate limit status
#   wait_for_rate_limit     # Wait if rate limit is too low
#   gh_api_safe <args>      # Wrapper for gh api with rate limit checking
#
# Environment variables:
#   RATE_LIMIT_WARN_THRESHOLD=0.8    # Warn at 80% usage
#   RATE_LIMIT_BLOCK_THRESHOLD=0.95  # Block at 95% usage
#   RATE_LIMIT_CACHE_TTL=60          # Cache rate limit checks for 60s

set -e

# Configuration
RATE_LIMIT_WARN_THRESHOLD="${RATE_LIMIT_WARN_THRESHOLD:-0.8}"
RATE_LIMIT_BLOCK_THRESHOLD="${RATE_LIMIT_BLOCK_THRESHOLD:-0.95}"
RATE_LIMIT_CACHE_TTL="${RATE_LIMIT_CACHE_TTL:-60}"

# Cache directory
RATE_LIMIT_CACHE_DIR="${TMPDIR:-/tmp}/gh-rate-limit-cache"
mkdir -p "$RATE_LIMIT_CACHE_DIR"

# Get rate limit status from GitHub API
# Returns JSON with graphql and rest rate limits
get_rate_limit_status() {
  local cache_file="$RATE_LIMIT_CACHE_DIR/rate-limit.json"
  local cache_age=999999

  # Check cache age
  if [ -f "$cache_file" ]; then
    cache_age=$(($(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
  fi

  # Use cache if fresh
  if [ "$cache_age" -lt "$RATE_LIMIT_CACHE_TTL" ]; then
    cat "$cache_file"
    return 0
  fi

  # Fetch fresh rate limit data
  local rate_data
  rate_data=$(gh api /rate_limit 2>/dev/null || echo '{}')

  # Cache the result
  echo "$rate_data" > "$cache_file"
  echo "$rate_data"
}

# Check if we're approaching rate limits
# Returns: 0=ok, 1=warning, 2=critical
check_rate_limit() {
  local api_type="${1:-graphql}"  # graphql or core (REST)
  local rate_data

  rate_data=$(get_rate_limit_status)

  if [ "$rate_data" = "{}" ] || [ -z "$rate_data" ]; then
    # Can't get rate limit - assume OK to proceed
    return 0
  fi

  local remaining
  local limit
  local usage_pct

  if [ "$api_type" = "graphql" ]; then
    remaining=$(echo "$rate_data" | jq -r '.resources.graphql.remaining // 5000')
    limit=$(echo "$rate_data" | jq -r '.resources.graphql.limit // 5000')
  else
    remaining=$(echo "$rate_data" | jq -r '.resources.core.remaining // 5000')
    limit=$(echo "$rate_data" | jq -r '.resources.core.limit // 5000')
  fi

  # Calculate usage percentage
  if [ "$limit" -gt 0 ]; then
    usage_pct=$(echo "scale=2; ($limit - $remaining) / $limit" | bc)
  else
    usage_pct=0
  fi

  # Log current status
  local reset_time
  if [ "$api_type" = "graphql" ]; then
    reset_time=$(echo "$rate_data" | jq -r '.resources.graphql.reset // 0')
  else
    reset_time=$(echo "$rate_data" | jq -r '.resources.core.reset // 0')
  fi

  local reset_human=""
  if [ "$reset_time" -gt 0 ]; then
    local now=$(date +%s)
    local reset_in=$((reset_time - now))
    if [ "$reset_in" -gt 0 ]; then
      reset_human="(resets in $((reset_in / 60))m)"
    fi
  fi

  # Determine status
  if (( $(echo "$usage_pct >= $RATE_LIMIT_BLOCK_THRESHOLD" | bc -l) )); then
    echo "CRITICAL: $api_type API rate limit at ${remaining}/${limit} ($(echo "scale=0; $usage_pct * 100" | bc)% used) $reset_human" >&2
    return 2
  elif (( $(echo "$usage_pct >= $RATE_LIMIT_WARN_THRESHOLD" | bc -l) )); then
    echo "WARNING: $api_type API rate limit at ${remaining}/${limit} ($(echo "scale=0; $usage_pct * 100" | bc)% used) $reset_human" >&2
    return 1
  fi

  # All good
  return 0
}

# Wait for rate limit to recover if needed
# Returns when rate limit is below block threshold
wait_for_rate_limit() {
  local api_type="${1:-graphql}"
  local max_wait="${2:-900}"  # Default 15 minutes max wait
  local waited=0
  local check_interval=30

  while [ "$waited" -lt "$max_wait" ]; do
    check_rate_limit "$api_type"
    local status=$?

    if [ "$status" -lt 2 ]; then
      # Not critical - proceed
      return 0
    fi

    # Critical - wait and retry
    echo "Rate limit critical, waiting ${check_interval}s... (${waited}s/${max_wait}s elapsed)" >&2
    sleep "$check_interval"
    waited=$((waited + check_interval))

    # Clear cache to force fresh check
    rm -f "$RATE_LIMIT_CACHE_DIR/rate-limit.json"
  done

  echo "ERROR: Rate limit still critical after ${max_wait}s wait" >&2
  return 1
}

# Safe wrapper for gh api calls
# Checks rate limit before proceeding
gh_api_safe() {
  local api_type="core"  # Default to REST API

  # Detect if this is a GraphQL call
  if [[ "$*" == *"graphql"* ]] || [[ "$*" == *"-X POST"* && "$*" == *"query"* ]]; then
    api_type="graphql"
  fi

  # Check rate limit
  wait_for_rate_limit "$api_type" || return 1

  # Execute the gh api command
  gh api "$@"
}

# Prefer REST API over GraphQL for read operations
# Converts common GraphQL queries to REST equivalents
gh_query_rest() {
  local query_type="$1"
  shift

  case "$query_type" in
    pr-list)
      # gh pr list uses GraphQL by default, but we can force REST
      gh pr list "$@" --json number,title,state,url,headRefName,baseRefName
      ;;
    pr-view)
      # gh pr view with selective fields to minimize data transfer
      gh pr view "$@" --json number,title,body,state,url,headRefName,baseRefName,createdAt,mergedAt
      ;;
    issue-list)
      # Issue list with minimal fields
      gh issue list "$@" --json number,title,state,url,labels
      ;;
    milestone-list)
      # Use REST API for milestones
      gh api repos/:owner/:repo/milestones "$@"
      ;;
    *)
      echo "Unknown query type: $query_type" >&2
      return 1
      ;;
  esac
}

# Display current rate limit status
show_rate_limit_status() {
  local rate_data
  rate_data=$(get_rate_limit_status)

  if [ "$rate_data" = "{}" ] || [ -z "$rate_data" ]; then
    echo "Could not fetch rate limit status"
    return 1
  fi

  echo "GitHub API Rate Limits:"
  echo ""

  # GraphQL
  local gql_remaining=$(echo "$rate_data" | jq -r '.resources.graphql.remaining // 0')
  local gql_limit=$(echo "$rate_data" | jq -r '.resources.graphql.limit // 5000')
  local gql_reset=$(echo "$rate_data" | jq -r '.resources.graphql.reset // 0')
  local gql_pct=$(echo "scale=1; $gql_remaining * 100 / $gql_limit" | bc)

  echo "  GraphQL: ${gql_remaining}/${gql_limit} (${gql_pct}% remaining)"
  if [ "$gql_reset" -gt 0 ]; then
    local now=$(date +%s)
    local reset_in=$((gql_reset - now))
    if [ "$reset_in" -gt 0 ]; then
      echo "    Resets in: $((reset_in / 60)) minutes"
    fi
  fi

  # REST (core)
  local rest_remaining=$(echo "$rate_data" | jq -r '.resources.core.remaining // 0')
  local rest_limit=$(echo "$rate_data" | jq -r '.resources.core.limit // 5000')
  local rest_reset=$(echo "$rate_data" | jq -r '.resources.core.reset // 0')
  local rest_pct=$(echo "scale=1; $rest_remaining * 100 / $rest_limit" | bc)

  echo "  REST:    ${rest_remaining}/${rest_limit} (${rest_pct}% remaining)"
  if [ "$rest_reset" -gt 0 ]; then
    local now=$(date +%s)
    local reset_in=$((rest_reset - now))
    if [ "$reset_in" -gt 0 ]; then
      echo "    Resets in: $((reset_in / 60)) minutes"
    fi
  fi

  echo ""

  # Warning status
  check_rate_limit "graphql" >/dev/null 2>&1
  check_rate_limit "core" >/dev/null 2>&1
}

# Log API call for debugging/auditing
log_api_call() {
  local api_type="${1:-unknown}"
  local endpoint="${2:-unknown}"
  local log_file="$RATE_LIMIT_CACHE_DIR/api-calls.log"

  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $api_type $endpoint" >> "$log_file"
}

# Export functions for use in other scripts
export -f get_rate_limit_status
export -f check_rate_limit
export -f wait_for_rate_limit
export -f gh_api_safe
export -f gh_query_rest
export -f show_rate_limit_status
export -f log_api_call
