#!/bin/bash
set -euo pipefail
# rollback-production.sh
# Rollback production (main branch) to a previous release
#
# Usage:
#   ./scripts/rollback-production.sh                    # Interactive mode
#   ./scripts/rollback-production.sh v1.2.0             # Rollback to specific version
#   ./scripts/rollback-production.sh --last-release     # Rollback to previous release
#   ./scripts/rollback-production.sh --dry-run v1.2.0   # Preview rollback
#
# Related: COMMIT_PROMOTION_STRATEGY.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
DRY_RUN=false
TARGET_VERSION=""
ROLLBACK_MODE=""
FORCE=false
CREATE_ROLLBACK_RELEASE=true

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --last-release)
      ROLLBACK_MODE="last-release"
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --no-release)
      CREATE_ROLLBACK_RELEASE=false
      shift
      ;;
    -*)
      echo "Unknown option: $1"
      exit 1
      ;;
    *)
      TARGET_VERSION="$1"
      shift
      ;;
  esac
done

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo -e "${RED}Error: Not in a git repository${NC}"
  exit 1
fi

# Fetch latest
echo "Fetching latest from origin..."
git fetch origin --tags

# Get current production version
CURRENT_VERSION=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "unknown")

# Determine rollback target
if [ "$ROLLBACK_MODE" = "last-release" ]; then
  echo ""
  echo "Finding previous release..."

  # Get second-to-last tag
  TARGET_VERSION=$(git tag --sort=-creatordate | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed -n '2p')

  if [ -z "$TARGET_VERSION" ]; then
    echo -e "${RED}Error: Could not find previous release tag${NC}"
    exit 1
  fi

  echo "Previous release found: $TARGET_VERSION"
elif [ -z "$TARGET_VERSION" ]; then
  # Interactive mode - show recent releases
  echo ""
  echo "Recent production releases:"
  echo ""
  git tag --sort=-creatordate | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -10

  echo ""
  read -p "Enter version tag to rollback to: " TARGET_VERSION

  if [ -z "$TARGET_VERSION" ]; then
    echo -e "${RED}Error: No version specified${NC}"
    exit 1
  fi
fi

# Validate version tag exists
if ! git rev-parse "$TARGET_VERSION" >/dev/null 2>&1; then
  echo -e "${RED}Error: Invalid version tag: $TARGET_VERSION${NC}"
  exit 1
fi

# Get version details
TARGET_COMMIT=$(git rev-parse "$TARGET_VERSION")
TARGET_DATE=$(git log -1 --pretty=format:"%cd" --date=short "$TARGET_VERSION")

# Calculate new rollback version
if [ "$CREATE_ROLLBACK_RELEASE" = true ]; then
  # Parse current version for patch bump
  CURRENT_CLEAN="${CURRENT_VERSION#v}"
  IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_CLEAN"
  ROLLBACK_VERSION="v${MAJOR}.${MINOR}.$((PATCH + 1))"
else
  ROLLBACK_VERSION="(no new release - revert commit only)"
fi

# Show rollback plan
echo ""
echo "==================================================================="
echo "Production Rollback Plan"
echo "==================================================================="
echo ""
echo "Current version: $CURRENT_VERSION"
echo "Rollback to: $TARGET_VERSION"
echo "Release date: $TARGET_DATE"
echo "New release version: $ROLLBACK_VERSION"
echo ""

# Show what will be undone
COMMITS_TO_UNDO=$(git rev-list "$TARGET_VERSION"..origin/main --count)
echo "Commits to undo: $COMMITS_TO_UNDO"
echo ""

if [ "$COMMITS_TO_UNDO" -gt 0 ]; then
  echo "Commits that will be rolled back:"
  git log --oneline "$TARGET_VERSION"..origin/main
  echo ""
fi

# Confirm unless force
if [ "$FORCE" != true ] && [ "$DRY_RUN" != true ]; then
  echo -e "${RED}⚠️  WARNING: This will rollback production to an earlier version${NC}"
  echo ""
  echo "This action will:"
  echo "1. Revert main branch to $TARGET_VERSION"
  if [ "$CREATE_ROLLBACK_RELEASE" = true ]; then
    echo "2. Create rollback release: $ROLLBACK_VERSION"
  fi
  echo "3. Update production deployment"
  echo ""
  read -p "Continue with production rollback? (type 'ROLLBACK' to confirm): " CONFIRM

  if [ "$CONFIRM" != "ROLLBACK" ]; then
    echo "Rollback cancelled"
    exit 0
  fi
fi

# Execute rollback
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo -e "${YELLOW}[DRY RUN] Would execute:${NC}"
  echo "git checkout main"
  echo "git revert -m 1 <merge-commits-since-$TARGET_VERSION>"
  if [ "$CREATE_ROLLBACK_RELEASE" = true ]; then
    echo "git tag -a $ROLLBACK_VERSION -m 'Rollback to $TARGET_VERSION'"
    echo "git push origin main $ROLLBACK_VERSION"
  else
    echo "git push origin main"
  fi
  echo ""
  echo "No changes made (dry run mode)"
  exit 0
fi

echo ""
echo "Executing rollback..."

# Checkout main
git checkout main 2>/dev/null || git checkout -b main origin/main
git pull origin main

# Create revert commits for all merges since target
echo "Creating revert commits..."

# Get all merge commits between target and current
MERGE_COMMITS=$(git rev-list --merges "$TARGET_VERSION"..HEAD | tac)

if [ -z "$MERGE_COMMITS" ]; then
  echo -e "${YELLOW}No merge commits found. Using direct revert...${NC}"
  git revert --no-edit "$TARGET_VERSION"..HEAD
else
  # Revert each merge commit
  for commit in $MERGE_COMMITS; do
    echo "Reverting merge: $(git log -1 --oneline "$commit")"
    git revert -m 1 --no-edit "$commit" || {
      echo -e "${RED}Error: Revert failed${NC}"
      echo "Manual intervention required"
      exit 1
    }
  done
fi

# Create rollback release if requested
if [ "$CREATE_ROLLBACK_RELEASE" = true ]; then
  echo ""
  echo "Creating rollback release: $ROLLBACK_VERSION"

  git tag -a "$ROLLBACK_VERSION" -m "Rollback to $TARGET_VERSION

Production incident required rollback from $CURRENT_VERSION.
This release reverts to the state of $TARGET_VERSION.

Rollback performed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "Pushing rollback to origin..."
  git push origin main "$ROLLBACK_VERSION"

  # Create GitHub release
  if command -v gh >/dev/null 2>&1; then
    echo "Creating GitHub release..."
    gh release create "$ROLLBACK_VERSION" \
      --title "$ROLLBACK_VERSION (Rollback)" \
      --notes "**Production Rollback**

This release rolls back production to $TARGET_VERSION.

**Previous version:** $CURRENT_VERSION
**Rollback to:** $TARGET_VERSION
**Rollback version:** $ROLLBACK_VERSION

See incident report for details on why rollback was necessary." \
      || echo "Note: GitHub release creation failed (may need manual creation)"
  fi
else
  echo "Pushing revert commits to origin..."
  git push origin main
fi

# Verify
echo ""
echo -e "${GREEN}✅ Rollback executed${NC}"
echo ""
echo "Production rolled back to: $TARGET_VERSION"
if [ "$CREATE_ROLLBACK_RELEASE" = true ]; then
  echo "Rollback release: $ROLLBACK_VERSION"
fi
echo "Undid $COMMITS_TO_UNDO commits via revert"
echo ""
echo "==================================================================="
echo "Post-Rollback Actions Required"
echo "==================================================================="
echo ""
echo "1. Verify production health:"
echo "   ./scripts/production-health-check.sh"
echo ""
echo "2. Monitor for 1 hour:"
echo "   ./scripts/monitor-production.sh --duration 60"
echo ""
echo "3. Sync rollback to qa and dev:"
echo "   git checkout qa && git merge main && git push origin qa"
echo "   git checkout dev && git merge main && git push origin dev"
echo ""
echo "4. Create incident report:"
echo "   Document why rollback was needed"
echo "   Create issues for fixes required"
echo ""
echo "5. Plan fix-forward release:"
echo "   Fix issues on dev"
echo "   Test thoroughly"
echo "   Promote through normal qa → main flow"
