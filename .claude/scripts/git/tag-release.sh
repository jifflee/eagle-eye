#!/bin/bash
set -euo pipefail
# tag-release.sh
# Creates git tag and GitHub release for merged release PR
#
# Usage:
#   ./scripts/tag-release.sh                         # Auto-detect from latest merged PR
#   ./scripts/tag-release.sh v1.3.0                  # Explicit version
#   ./scripts/tag-release.sh --dry-run               # Preview only
#   ./scripts/tag-release.sh --no-changelog          # Skip CHANGELOG.md update
#
# Exit codes:
#   0 - Success
#   1 - Error (not on main, tag exists, etc.)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
VERSION=""
DRY_RUN=false
UPDATE_CHANGELOG=true
FORCE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-changelog)
      UPDATE_CHANGELOG=false
      shift
      ;;
    --force)
      FORCE=true
      shift
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

# Get version from positional arg or auto-detect
if [ -n "$1" ]; then
  VERSION="$1"
fi

echo -e "${BLUE}## Auto-Tag Release${NC}"
echo ""

# Safety check: must be on main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo -e "${RED}Error: Must be on main branch (currently on: $CURRENT_BRANCH)${NC}"
  echo "Run: git checkout main && git pull"
  exit 1
fi

# Pull latest
echo "Pulling latest from origin/main..."
git pull origin main

# Auto-detect version from latest merged PR if not provided
if [ -z "$VERSION" ]; then
  echo ""
  echo "Detecting latest merged release PR..."

  # Get most recent closed PR to main with "release:" in title
  PR_DATA=$(gh pr list --base main --state merged --limit 10 --json number,title,mergedAt,body | \
    jq -r '.[] | select(.title | startswith("release:")) | @json' | head -n1)

  if [ -z "$PR_DATA" ]; then
    echo -e "${RED}Error: No merged release PR found${NC}"
    echo "Expected PR title format: 'release: vX.Y.Z'"
    echo ""
    echo "Run with explicit version: ./scripts/tag-release.sh v1.3.0"
    exit 1
  fi

  PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
  PR_NUMBER=$(echo "$PR_DATA" | jq -r '.number')
  PR_BODY=$(echo "$PR_DATA" | jq -r '.body')
  PR_MERGED_AT=$(echo "$PR_DATA" | jq -r '.mergedAt')

  # Extract version from PR title
  VERSION=$(echo "$PR_TITLE" | sed -nE 's/^release:[[:space:]]*(v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?).*/\1/p')

  if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Could not extract version from PR title: $PR_TITLE${NC}"
    echo "Expected format: 'release: vX.Y.Z'"
    exit 1
  fi

  echo -e "${GREEN}✅ Found: PR #$PR_NUMBER \"$PR_TITLE\" (merged at $PR_MERGED_AT)${NC}"
  echo ""
fi

echo "Extracted version: $VERSION"

# Validate version format
SEMVER_REGEX='^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?$'
if [[ ! "$VERSION" =~ $SEMVER_REGEX ]]; then
  echo -e "${RED}Error: Invalid version format: $VERSION${NC}"
  echo "Expected: vX.Y.Z or vX.Y.Z-alpha.N"
  exit 1
fi
echo -e "${GREEN}✅ Version is valid semver${NC}"

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
  if [ "$FORCE" = false ]; then
    echo -e "${RED}Error: Tag $VERSION already exists${NC}"
    echo "Use --force to recreate (will delete existing tag)"
    exit 1
  else
    echo -e "${YELLOW}⚠️  Tag $VERSION exists, will be recreated (--force)${NC}"
    if [ "$DRY_RUN" = false ]; then
      git tag -d "$VERSION" 2>/dev/null || true
      git push origin ":refs/tags/$VERSION" 2>/dev/null || true
    fi
  fi
else
  echo -e "${GREEN}✅ Tag does not exist${NC}"
fi

# Dry run exit point
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo -e "${YELLOW}[DRY RUN] Would execute:${NC}"
  echo "1. Create annotated tag: $VERSION"
  echo "2. Push tag to origin"
  echo "3. Create GitHub release"
  if [ "$UPDATE_CHANGELOG" = true ]; then
    echo "4. Update CHANGELOG.md"
  fi
  echo ""
  echo "No changes made (dry run mode)"
  exit 0
fi

echo ""
echo "Creating tag $VERSION..."

# Create annotated tag
# Use PR body as tag message if available, otherwise generate changelog
if [ -n "$PR_BODY" ]; then
  TAG_MESSAGE="Release $VERSION

$PR_BODY

Created from PR #$PR_NUMBER"
else
  CHANGELOG=$("$SCRIPT_DIR/generate-changelog.sh" --format release)
  TAG_MESSAGE="Release $VERSION

$CHANGELOG"
fi

git tag -a "$VERSION" -m "$TAG_MESSAGE"
echo -e "${GREEN}✅ Tag created locally${NC}"

# Push tag
echo "Pushing tag to origin..."
git push origin "$VERSION"
echo -e "${GREEN}✅ Tag pushed to origin${NC}"

echo ""
echo "Creating GitHub release..."

# Create GitHub release with PR body or auto-generated notes
if [ -n "$PR_BODY" ]; then
  # Use PR body as release notes
  echo "$PR_BODY" > /tmp/release-notes-$$.md
  gh release create "$VERSION" \
    --title "$VERSION" \
    --notes-file /tmp/release-notes-$$.md \
    --verify-tag
  rm -f /tmp/release-notes-$$.md
else
  # Auto-generate release notes
  gh release create "$VERSION" \
    --title "$VERSION" \
    --generate-notes \
    --verify-tag
fi

RELEASE_URL=$(gh release view "$VERSION" --json url --jq '.url')
echo -e "${GREEN}✅ Release $VERSION created${NC}"
echo "   URL: $RELEASE_URL"

# Update CHANGELOG.md if requested
if [ "$UPDATE_CHANGELOG" = true ]; then
  echo ""
  echo "Updating CHANGELOG.md..."

  CHANGELOG_FILE="CHANGELOG.md"
  if [ ! -f "$CHANGELOG_FILE" ]; then
    # Create new CHANGELOG.md
    cat > "$CHANGELOG_FILE" <<EOF
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

EOF
  fi

  # Generate changelog entry
  CHANGELOG_ENTRY=$("$SCRIPT_DIR/generate-changelog.sh" --format file "$VERSION")

  # Insert after header (before first ## heading)
  if grep -q "^## \[" "$CHANGELOG_FILE"; then
    # Insert before first release entry
    sed -i "/^## \[/i\\
$CHANGELOG_ENTRY\\
" "$CHANGELOG_FILE"
  else
    # Append to end
    echo "" >> "$CHANGELOG_FILE"
    echo "$CHANGELOG_ENTRY" >> "$CHANGELOG_FILE"
  fi

  echo -e "${GREEN}✅ CHANGELOG.md updated${NC}"

  # Commit CHANGELOG.md
  if git diff --quiet "$CHANGELOG_FILE"; then
    echo "   (No changes to commit)"
  else
    git add "$CHANGELOG_FILE"
    git commit -m "docs: update CHANGELOG.md for $VERSION"
    git push origin main
    echo -e "${GREEN}✅ CHANGELOG.md committed and pushed${NC}"
  fi
fi

echo ""
echo -e "${GREEN}## Release Complete${NC}"
echo ""
echo "Version: $VERSION"
echo "Tag: $VERSION"
echo "Release: $RELEASE_URL"
echo ""

# Show next steps
echo "Next steps:"
echo "1. Verify release notes are accurate"
echo "2. Monitor production deployment"
if [ -n "$PR_NUMBER" ]; then
  echo "3. Close milestone if all issues complete (check PR #$PR_NUMBER)"
fi
echo ""
