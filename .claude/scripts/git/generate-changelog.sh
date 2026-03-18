#!/bin/bash
set -euo pipefail
# generate-changelog.sh
# Generates markdown changelog from commit history
#
# Usage:
#   ./scripts/generate-changelog.sh                   # From last tag to qa
#   ./scripts/generate-changelog.sh v1.2.3            # From specific tag to qa
#   ./scripts/generate-changelog.sh --from dev        # From dev branch
#   ./scripts/generate-changelog.sh --format pr       # For PR body (default)
#   ./scripts/generate-changelog.sh --format release  # For GitHub release
#   ./scripts/generate-changelog.sh --format file     # For CHANGELOG.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
FROM_REF=""
TO_BRANCH="qa"
OUTPUT_FORMAT="pr"

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --from)
      TO_BRANCH="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

# Restore positional parameters
set -- "${POSITIONAL[@]}"

# Get FROM_REF from positional arg or auto-detect
if [ -n "$1" ]; then
  FROM_REF="$1"
else
  # Auto-detect: use latest tag on main
  FROM_REF=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "")
fi

# Fetch latest
git fetch origin --tags 2>/dev/null || true

# Get commits to include
if [ -z "$FROM_REF" ]; then
  # No tags yet, get all commits on TO_BRANCH
  COMMITS=$(git log --oneline origin/"$TO_BRANCH" --max-count=50 2>/dev/null || echo "")
  RANGE="origin/$TO_BRANCH (last 50 commits)"
else
  # Get commits between FROM_REF and TO_BRANCH
  COMMITS=$(git log --oneline "$FROM_REF"..origin/"$TO_BRANCH" 2>/dev/null || echo "")
  RANGE="$FROM_REF..origin/$TO_BRANCH"
fi

# Categorize commits
FEATURES=()
FIXES=()
BREAKING=()
OTHER=()

while IFS= read -r commit; do
  [ -z "$commit" ] && continue

  # Extract commit hash and message
  HASH=$(echo "$commit" | awk '{print $1}')
  MESSAGE=$(echo "$commit" | cut -d' ' -f2-)

  # Check for breaking changes
  if echo "$MESSAGE" | grep -qiE '^[a-zA-Z]+(\([^)]*\))?!:'; then
    BREAKING+=("$MESSAGE")
    continue
  fi

  # Check commit body for BREAKING CHANGE
  if git log --format=%B -n 1 "$HASH" | grep -qiE 'BREAKING[ -]CHANGE:'; then
    BREAKING+=("$MESSAGE")
    continue
  fi

  # Check for features
  if echo "$MESSAGE" | grep -qiE '^feat(\([^)]*\))?:'; then
    FEATURES+=("$MESSAGE")
    continue
  fi

  # Check for fixes
  if echo "$MESSAGE" | grep -qiE '^fix(\([^)]*\))?:'; then
    FIXES+=("$MESSAGE")
    continue
  fi

  # Everything else (docs, chore, refactor, etc.)
  OTHER+=("$MESSAGE")
done <<< "$COMMITS"

# Helper function to format commit list
format_commits() {
  local commits=("$@")
  for commit in "${commits[@]}"; do
    # Extract issue number if present
    if [[ "$commit" =~ \(#([0-9]+)\) ]]; then
      echo "- $commit"
    elif [[ "$commit" =~ #([0-9]+) ]]; then
      echo "- $commit"
    else
      echo "- $commit"
    fi
  done
}

# Generate changelog based on format
case "$OUTPUT_FORMAT" in
  pr)
    # Format for PR body
    echo "## Changes"
    echo ""

    if [ ${#BREAKING[@]} -gt 0 ]; then
      echo "### ⚠️ Breaking Changes"
      echo ""
      format_commits "${BREAKING[@]}"
      echo ""
    fi

    if [ ${#FEATURES[@]} -gt 0 ]; then
      echo "### Features"
      echo ""
      format_commits "${FEATURES[@]}"
      echo ""
    fi

    if [ ${#FIXES[@]} -gt 0 ]; then
      echo "### Bug Fixes"
      echo ""
      format_commits "${FIXES[@]}"
      echo ""
    fi

    if [ ${#OTHER[@]} -gt 0 ]; then
      echo "### Other Changes"
      echo ""
      format_commits "${OTHER[@]}"
      echo ""
    fi

    if [ ${#BREAKING[@]} -eq 0 ] && [ ${#FEATURES[@]} -eq 0 ] && [ ${#FIXES[@]} -eq 0 ] && [ ${#OTHER[@]} -eq 0 ]; then
      echo "No changes found in range: $RANGE"
      echo ""
    fi
    ;;

  release)
    # Format for GitHub release notes
    if [ ${#BREAKING[@]} -gt 0 ]; then
      echo "## ⚠️ Breaking Changes"
      echo ""
      format_commits "${BREAKING[@]}"
      echo ""
    fi

    if [ ${#FEATURES[@]} -gt 0 ]; then
      echo "## What's New"
      echo ""
      format_commits "${FEATURES[@]}"
      echo ""
    fi

    if [ ${#FIXES[@]} -gt 0 ]; then
      echo "## Bug Fixes"
      echo ""
      format_commits "${FIXES[@]}"
      echo ""
    fi

    if [ ${#OTHER[@]} -gt 0 ]; then
      echo "## Other Changes"
      echo ""
      format_commits "${OTHER[@]}"
      echo ""
    fi

    # Add full changelog link
    if [ -n "$FROM_REF" ]; then
      echo "**Full Changelog**: https://github.com/\${GITHUB_REPOSITORY}/compare/$FROM_REF...HEAD"
    fi
    ;;

  file)
    # Format for CHANGELOG.md file
    VERSION="${2:-UNRELEASED}"
    DATE=$(date -u +%Y-%m-%d)

    echo "## [$VERSION] - $DATE"
    echo ""

    if [ ${#BREAKING[@]} -gt 0 ]; then
      echo "### ⚠️ BREAKING CHANGES"
      echo ""
      format_commits "${BREAKING[@]}"
      echo ""
    fi

    if [ ${#FEATURES[@]} -gt 0 ]; then
      echo "### Added"
      echo ""
      format_commits "${FEATURES[@]}"
      echo ""
    fi

    if [ ${#FIXES[@]} -gt 0 ]; then
      echo "### Fixed"
      echo ""
      format_commits "${FIXES[@]}"
      echo ""
    fi

    if [ ${#OTHER[@]} -gt 0 ]; then
      echo "### Changed"
      echo ""
      format_commits "${OTHER[@]}"
      echo ""
    fi
    ;;

  *)
    echo "Error: Unknown format: $OUTPUT_FORMAT" >&2
    echo "Valid formats: pr, release, file" >&2
    exit 1
    ;;
esac
