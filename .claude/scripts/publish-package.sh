#!/usr/bin/env bash
# Publish claude-tastic package to GitHub Packages
# Interactive publishing script for maintainers
#
# NOTE: For automated tag-based publishing, use scripts/ci/publish-on-tag.sh
#
# Usage: ./scripts/publish-package.sh [--dry-run] [--patch|--minor|--major]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[publish]${NC} $*"; }
success() { echo -e "${GREEN}[publish]${NC} $*"; }
warn() { echo -e "${YELLOW}[publish]${NC} $*"; }
error() { echo -e "${RED}[publish]${NC} $*" >&2; }

# Parse flags
DRY_RUN=false
BUMP_TYPE="patch"

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
    --patch|--minor|--major)
      BUMP_TYPE="${arg#--}"
      ;;
    *)
      error "Unknown flag: $arg"
      echo "Usage: $0 [--dry-run] [--patch|--minor|--major]"
      exit 1
      ;;
  esac
done

# Step 1: Validate on main branch
info "Validating repository state..."

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  error "Must be on main branch (currently on: $CURRENT_BRANCH)"
  exit 1
fi

# Check for uncommitted changes
if ! git diff-index --quiet HEAD --; then
  error "Uncommitted changes detected. Commit or stash before publishing."
  exit 1
fi

# Sync with remote
git fetch origin main
LOCAL=$(git rev-parse @)
REMOTE=$(git rev-parse @{u})

if [[ "$LOCAL" != "$REMOTE" ]]; then
  error "Local main is not in sync with remote. Pull latest changes."
  exit 1
fi

success "Repository state valid"

# Step 2: Run tests
info "Running test suite..."

if [[ -f "$REPO_ROOT/scripts/test-runner.sh" ]]; then
  if ! "$REPO_ROOT/scripts/test-runner.sh"; then
    error "Tests failed"
    exit 1
  fi
  success "Tests passed"
else
  warn "Test runner not found, skipping tests"
fi

# Step 3: Validate package structure
info "Validating package structure..."

# Check packs.json exists
if [[ ! -f "$REPO_ROOT/packs.json" ]]; then
  error "packs.json not found"
  exit 1
fi

# Validate packs.json is valid JSON
if ! jq empty "$REPO_ROOT/packs.json" 2>/dev/null; then
  error "packs.json is not valid JSON"
  exit 1
fi

# Check all pack files exist
MISSING_FILES=()

while IFS= read -r pack_name; do
  info "Validating pack: $pack_name"

  # Get files for this pack
  mapfile -t pack_files < <(jq -r ".packs[\"$pack_name\"].files[]" "$REPO_ROOT/packs.json")

  for file_pattern in "${pack_files[@]}"; do
    # Expand glob patterns
    if [[ "$file_pattern" == *"*"* ]]; then
      # Glob pattern - check at least one file matches
      if ! compgen -G "$REPO_ROOT/$file_pattern" > /dev/null; then
        warn "No files match pattern: $file_pattern (pack: $pack_name)"
      fi
    else
      # Exact file - check exists
      if [[ ! -f "$REPO_ROOT/$file_pattern" && ! -d "$REPO_ROOT/$file_pattern" ]]; then
        MISSING_FILES+=("$file_pattern (pack: $pack_name)")
      fi
    fi
  done
done < <(jq -r '.packs | keys[]' "$REPO_ROOT/packs.json")

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
  error "Missing files in pack manifests:"
  for missing in "${MISSING_FILES[@]}"; do
    echo "  - $missing"
  done
  exit 1
fi

success "Package structure valid"

# Step 4: Bump version
info "Calculating version bump ($BUMP_TYPE)..."

CURRENT_VERSION=$(jq -r '.version' "$REPO_ROOT/package.json")
info "Current version: $CURRENT_VERSION"

# Calculate new version based on bump type
IFS='.' read -r -a VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR="${VERSION_PARTS[0]}"
MINOR="${VERSION_PARTS[1]}"
PATCH="${VERSION_PARTS[2]}"

case "$BUMP_TYPE" in
  patch)
    PATCH=$((PATCH + 1))
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
esac

NEW_VERSION="$MAJOR.$MINOR.$PATCH"
info "New version: $NEW_VERSION"

if [[ "$DRY_RUN" == "false" ]]; then
  # Update package.json
  jq ".version = \"$NEW_VERSION\"" "$REPO_ROOT/package.json" > "$REPO_ROOT/package.json.tmp"
  mv "$REPO_ROOT/package.json.tmp" "$REPO_ROOT/package.json"
  success "Updated package.json to v$NEW_VERSION"
else
  info "[DRY RUN] Would update package.json to v$NEW_VERSION"
fi

# Step 5: Check authentication
info "Checking npm authentication..."

# Check if .npmrc exists with GitHub Packages config
if [[ ! -f "$HOME/.npmrc" ]] || ! grep -q "@jifflee:registry=https://npm.pkg.github.com" "$HOME/.npmrc" 2>/dev/null; then
  warn ".npmrc not configured for GitHub Packages"
  info "Add to ~/.npmrc:"
  echo "  @jifflee:registry=https://npm.pkg.github.com"
  echo "  //npm.pkg.github.com/:_authToken=\${NODE_AUTH_TOKEN}"
fi

# Check for auth token
if [[ -z "${NODE_AUTH_TOKEN:-}" ]]; then
  warn "NODE_AUTH_TOKEN not set"
  info "Attempting to retrieve from macOS Keychain..."

  if command -v security &>/dev/null; then
    TOKEN=$(security find-generic-password -a "$USER" -s "npm-publish-token" -w 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then
      export NODE_AUTH_TOKEN="$TOKEN"
      success "Retrieved token from Keychain"
    else
      error "Token not found in Keychain (service: npm-publish-token)"
      info "Store token with: security add-generic-password -a \"\$USER\" -s \"npm-publish-token\" -w \"YOUR_TOKEN\""
      exit 1
    fi
  else
    error "NODE_AUTH_TOKEN not set and macOS Keychain not available"
    info "Set environment variable: export NODE_AUTH_TOKEN=your_github_pat"
    exit 1
  fi
fi

success "Authentication configured"

# Step 6: Build package
info "Building package..."

# Package is already in correct structure - no build needed
# Files are filtered via package.json "files" field

success "Package ready for publishing"

# Step 7: Publish to GitHub Packages
if [[ "$DRY_RUN" == "false" ]]; then
  info "Publishing to GitHub Packages..."

  cd "$REPO_ROOT"
  if npm publish; then
    success "Published @jifflee/claude-tastic@$NEW_VERSION"
  else
    error "Publish failed"
    exit 1
  fi
else
  info "[DRY RUN] Would publish @jifflee/claude-tastic@$NEW_VERSION"
fi

# Step 8: Create git tag
if [[ "$DRY_RUN" == "false" ]]; then
  info "Creating git tag v$NEW_VERSION..."

  git add package.json
  git commit -m "chore: bump version to v$NEW_VERSION"
  git tag -a "v$NEW_VERSION" -m "Release v$NEW_VERSION"
  git push origin main
  git push origin "v$NEW_VERSION"

  success "Created and pushed tag v$NEW_VERSION"
else
  info "[DRY RUN] Would create tag v$NEW_VERSION"
fi

# Step 9: Generate release notes
if [[ "$DRY_RUN" == "false" ]]; then
  info "Creating GitHub release..."

  # Get commits since last tag
  LAST_TAG=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || echo "")

  if [[ -n "$LAST_TAG" ]]; then
    COMMITS=$(git log "$LAST_TAG..HEAD" --pretty=format:"- %s (%h)" --no-merges)
  else
    COMMITS=$(git log --pretty=format:"- %s (%h)" --no-merges -10)
  fi

  RELEASE_NOTES="## Release v$NEW_VERSION

### Changes
$COMMITS

### Installation
\`\`\`bash
npm install @jifflee/claude-tastic@$NEW_VERSION
\`\`\`

### Upgrade
\`\`\`bash
npx claude-tastic update
\`\`\`

---
Published: $(date -u +%Y-%m-%d)"

  if gh release create "v$NEW_VERSION" --title "v$NEW_VERSION" --notes "$RELEASE_NOTES"; then
    success "Created GitHub release v$NEW_VERSION"
  else
    warn "Failed to create GitHub release (tag created successfully)"
  fi
else
  info "[DRY RUN] Would create GitHub release v$NEW_VERSION"
fi

# Summary
echo ""
success "Publishing complete!"
echo ""
echo "Published: @jifflee/claude-tastic@$NEW_VERSION"
echo "Registry:  https://npm.pkg.github.com"
echo "Tag:       v$NEW_VERSION"
echo ""
echo "Consumers can install with:"
echo "  npm install @jifflee/claude-tastic@$NEW_VERSION"
echo ""
info "For automated tag-based publishing, use: scripts/ci/publish-on-tag.sh"
info "For documentation, see: docs/PUBLISHING.md"
echo ""
