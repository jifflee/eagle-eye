#!/bin/bash
set -euo pipefail
# calculate-version.sh
# Analyzes commit history and calculates next version based on conventional commits
#
# Usage:
#   ./scripts/calculate-version.sh                    # From qa to main
#   ./scripts/calculate-version.sh --from dev         # From dev to qa
#   ./scripts/calculate-version.sh --dry-run          # Preview only
#   ./scripts/calculate-version.sh --format json      # JSON output
#   ./scripts/calculate-version.sh --format text      # Human readable
#
# Exit codes:
#   0 - Success
#   1 - Error (no commits, invalid state, etc.)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
FROM_BRANCH="qa"
TO_BRANCH="main"
DRY_RUN=false
OUTPUT_FORMAT="json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --from)
      FROM_BRANCH="$2"
      shift 2
      ;;
    --to)
      TO_BRANCH="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Fetch latest
git fetch origin --tags 2>/dev/null || true

# Get current version (latest tag on target branch)
CURRENT_VERSION=$(git describe --tags --abbrev=0 origin/"$TO_BRANCH" 2>/dev/null || echo "")

if [ -z "$CURRENT_VERSION" ]; then
  CURRENT_VERSION="v0.0.0"
fi

# Parse current version
CLEAN_VERSION="${CURRENT_VERSION#v}"
IFS='.' read -r MAJOR MINOR PATCH <<< "$CLEAN_VERSION"
# Handle pre-release versions (strip everything after -)
PATCH="${PATCH%%-*}"

# Calculate next versions
NEXT_PATCH="v${MAJOR}.${MINOR}.$((PATCH + 1))"
NEXT_MINOR="v${MAJOR}.$((MINOR + 1)).0"
NEXT_MAJOR="v$((MAJOR + 1)).0.0"

# Get commits to analyze
if [ "$CURRENT_VERSION" = "v0.0.0" ]; then
  # No tags yet, analyze all commits on from_branch
  COMMITS=$(git log --oneline origin/"$FROM_BRANCH" -50 2>/dev/null || echo "")
else
  # Get commits between last tag and from_branch
  COMMITS=$(git log --oneline "$CURRENT_VERSION"..origin/"$FROM_BRANCH" 2>/dev/null || echo "")
fi

# Count commit types
BREAKING_COUNT=0
FEATURE_COUNT=0
FIX_COUNT=0
OTHER_COUNT=0

while IFS= read -r commit; do
  [ -z "$commit" ] && continue

  # Check for breaking changes
  # Pattern 1: Type with ! (feat!:, fix!:, etc.)
  if echo "$commit" | grep -qiE '^[a-f0-9]+ [a-zA-Z]+(\([^)]*\))?!:'; then
    BREAKING_COUNT=$((BREAKING_COUNT + 1))
    continue
  fi

  # Pattern 2: BREAKING CHANGE in commit message (requires full commit body)
  COMMIT_SHA=$(echo "$commit" | awk '{print $1}')
  if git log --format=%B -n 1 "$COMMIT_SHA" | grep -qiE 'BREAKING[ -]CHANGE:'; then
    BREAKING_COUNT=$((BREAKING_COUNT + 1))
    continue
  fi

  # Check for features
  if echo "$commit" | grep -qiE '^[a-f0-9]+ feat(\([^)]*\))?:'; then
    FEATURE_COUNT=$((FEATURE_COUNT + 1))
    continue
  fi

  # Check for fixes
  if echo "$commit" | grep -qiE '^[a-f0-9]+ fix(\([^)]*\))?:'; then
    FIX_COUNT=$((FIX_COUNT + 1))
    continue
  fi

  # Everything else
  OTHER_COUNT=$((OTHER_COUNT + 1))
done <<< "$COMMITS"

# Determine recommended version
if [ "$BREAKING_COUNT" -gt 0 ]; then
  RECOMMENDED="$NEXT_MAJOR"
  REASON="$BREAKING_COUNT breaking change(s) detected"
  BUMP_TYPE="major"
elif [ "$FEATURE_COUNT" -gt 0 ]; then
  RECOMMENDED="$NEXT_MINOR"
  REASON="$FEATURE_COUNT new feature(s) added"
  BUMP_TYPE="minor"
elif [ "$FIX_COUNT" -gt 0 ]; then
  RECOMMENDED="$NEXT_PATCH"
  REASON="$FIX_COUNT bug fix(es) applied"
  BUMP_TYPE="patch"
else
  RECOMMENDED="$NEXT_PATCH"
  REASON="No conventional commits found, defaulting to patch"
  BUMP_TYPE="patch"
fi

# Output
if [ "$OUTPUT_FORMAT" = "json" ]; then
  cat <<EOF
{
  "current_version": "$CURRENT_VERSION",
  "next_patch": "$NEXT_PATCH",
  "next_minor": "$NEXT_MINOR",
  "next_major": "$NEXT_MAJOR",
  "recommended": "$RECOMMENDED",
  "reason": "$REASON",
  "bump_type": "$BUMP_TYPE",
  "commits": {
    "breaking": $BREAKING_COUNT,
    "features": $FEATURE_COUNT,
    "fixes": $FIX_COUNT,
    "other": $OTHER_COUNT,
    "total": $((BREAKING_COUNT + FEATURE_COUNT + FIX_COUNT + OTHER_COUNT))
  },
  "analyzed_range": "$CURRENT_VERSION..origin/$FROM_BRANCH"
}
EOF
else
  # Text output
  cat <<EOF
Version Analysis
================

Current version: $CURRENT_VERSION
From branch: origin/$FROM_BRANCH
To branch: origin/$TO_BRANCH

Commit Analysis:
  Breaking changes: $BREAKING_COUNT
  Features: $FEATURE_COUNT
  Fixes: $FIX_COUNT
  Other: $OTHER_COUNT
  Total: $((BREAKING_COUNT + FEATURE_COUNT + FIX_COUNT + OTHER_COUNT))

Version Options:
  Patch:  $NEXT_PATCH
  Minor:  $NEXT_MINOR
  Major:  $NEXT_MAJOR

Recommended: $RECOMMENDED
Reason: $REASON
Bump type: $BUMP_TYPE
EOF
fi
