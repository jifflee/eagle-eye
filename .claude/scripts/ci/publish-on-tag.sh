#!/usr/bin/env bash
# ============================================================
# Script: publish-on-tag.sh
# Purpose: Auto-publish package to GitHub Packages on git tag push
#
# This script detects if the current ref is a version tag (v*)
# and publishes the package to GitHub Packages if all checks pass.
#
# Usage:
#   Local (manual):
#     git tag v1.2.3 && git push origin v1.2.3
#     ./scripts/ci/publish-on-tag.sh
#
#   CI/CD (automated):
#     Called by post-receive hook or CI pipeline when tag is pushed
#
# Requirements:
#   - Must be on a version tag (v*)
#   - Tag version must match package.json version
#   - All tests must pass
#   - NODE_AUTH_TOKEN environment variable must be set
#
# Exit codes:
#   0 - Package published successfully
#   1 - Validation failed or publish failed
#   2 - Not on a version tag (skip publishing)
#
# Related:
#   - scripts/publish-package.sh - Interactive publish script
#   - Issue #1079 - Set up GitHub Packages publish pipeline
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[publish-tag]${NC} $*"; }
success() { echo -e "${GREEN}[publish-tag]${NC} $*"; }
warn() { echo -e "${YELLOW}[publish-tag]${NC} $*"; }
error() { echo -e "${RED}[publish-tag]${NC} $*" >&2; }

# ─── Detect if running on a version tag ──────────────────────────────────────

info "Checking if running on a version tag..."

# Get current ref - could be a branch or tag
CURRENT_REF=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# If HEAD is detached, check if we're on a tag
if [[ "$CURRENT_REF" == "HEAD" ]]; then
  # Try to get tag name
  CURRENT_TAG=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")

  if [[ -z "$CURRENT_TAG" ]]; then
    info "Not on a tag (detached HEAD). Skipping publish."
    exit 2
  fi

  # Check if tag matches version pattern (v*)
  if [[ ! "$CURRENT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Tag '$CURRENT_TAG' is not a version tag (expected format: vX.Y.Z). Skipping publish."
    exit 2
  fi

  TAG_VERSION="${CURRENT_TAG#v}"  # Remove 'v' prefix
  info "Running on version tag: $CURRENT_TAG"
else
  # On a branch - check if a version tag points to current commit
  CURRENT_TAG=$(git tag --points-at HEAD | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || echo "")

  if [[ -z "$CURRENT_TAG" ]]; then
    info "Not on a version tag. Skipping publish."
    exit 2
  fi

  TAG_VERSION="${CURRENT_TAG#v}"
  info "Version tag '$CURRENT_TAG' points to current commit on branch '$CURRENT_REF'"
fi

# ─── Validate tag matches package.json version ────────────────────────────────

info "Validating tag version matches package.json..."

if [[ ! -f "$REPO_ROOT/package.json" ]]; then
  error "package.json not found"
  exit 1
fi

PACKAGE_VERSION=$(jq -r '.version' "$REPO_ROOT/package.json")

if [[ "$TAG_VERSION" != "$PACKAGE_VERSION" ]]; then
  error "Version mismatch:"
  error "  Git tag:      $TAG_VERSION"
  error "  package.json: $PACKAGE_VERSION"
  error ""
  error "Please update package.json to match the tag or use the correct tag."
  exit 1
fi

success "Version validated: v$TAG_VERSION"

# ─── Run tests ─────────────────────────────────────────────────────────────────

info "Running test suite..."

if [[ -f "$REPO_ROOT/scripts/test-runner.sh" ]]; then
  if ! "$REPO_ROOT/scripts/test-runner.sh"; then
    error "Tests failed. Cannot publish."
    exit 1
  fi
  success "All tests passed"
else
  warn "Test runner not found at scripts/test-runner.sh"
  info "Attempting to run npm test..."

  if ! npm test; then
    error "Tests failed. Cannot publish."
    exit 1
  fi
  success "npm test passed"
fi

# ─── Validate package structure ───────────────────────────────────────────────

info "Validating package structure..."

# Check required files listed in package.json "files" array exist
MISSING_FILES=()

while IFS= read -r file_pattern; do
  # Remove trailing slash and wildcard for directory checks
  base_pattern="${file_pattern%/}"
  base_pattern="${base_pattern%%\**}"

  # Check if path exists (file or directory)
  if [[ ! -e "$REPO_ROOT/$base_pattern" ]]; then
    MISSING_FILES+=("$file_pattern")
  fi
done < <(jq -r '.files[]' "$REPO_ROOT/package.json")

if [[ ${#MISSING_FILES[@]} -gt 0 ]]; then
  error "Missing files/directories listed in package.json:"
  for missing in "${MISSING_FILES[@]}"; do
    error "  - $missing"
  done
  exit 1
fi

# Validate packs.json if it exists
if [[ -f "$REPO_ROOT/packs.json" ]]; then
  if ! jq empty "$REPO_ROOT/packs.json" 2>/dev/null; then
    error "packs.json is not valid JSON"
    exit 1
  fi
  info "packs.json validated"
fi

success "Package structure valid"

# ─── Check authentication ──────────────────────────────────────────────────────

info "Checking npm authentication..."

# Verify NODE_AUTH_TOKEN is set
if [[ -z "${NODE_AUTH_TOKEN:-}" ]]; then
  error "NODE_AUTH_TOKEN environment variable not set"
  error ""
  error "To publish, set your GitHub Personal Access Token:"
  error "  export NODE_AUTH_TOKEN=ghp_xxxxxxxxxxxx"
  error ""
  error "The token needs 'write:packages' permission."
  error ""
  error "For local development, you can store it in macOS Keychain:"
  error "  security add-generic-password -a \"\$USER\" -s \"npm-publish-token\" -w \"YOUR_TOKEN\""
  exit 1
fi

# Validate token format (should start with ghp_, gho_, or github_pat_)
if [[ ! "$NODE_AUTH_TOKEN" =~ ^(ghp_|gho_|github_pat_) ]]; then
  warn "NODE_AUTH_TOKEN doesn't match expected GitHub token format"
  warn "Expected format: ghp_*, gho_*, or github_pat_*"
fi

success "Authentication token found"

# ─── Create .npmrc for GitHub Packages ─────────────────────────────────────────

info "Configuring npm for GitHub Packages..."

# Create temporary .npmrc in repo root (will be used by npm publish)
cat > "$REPO_ROOT/.npmrc.tmp" <<EOF
@jifflee:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=\${NODE_AUTH_TOKEN}
EOF

# Ensure cleanup on exit
trap 'rm -f "$REPO_ROOT/.npmrc.tmp"' EXIT

success "npm configured for GitHub Packages"

# ─── Publish to GitHub Packages ────────────────────────────────────────────────

info "Publishing @jifflee/claude-tastic@$TAG_VERSION to GitHub Packages..."

cd "$REPO_ROOT"

# Use temporary .npmrc for publish
if NPM_CONFIG_USERCONFIG="$REPO_ROOT/.npmrc.tmp" npm publish; then
  success "✓ Published @jifflee/claude-tastic@$TAG_VERSION"
else
  error "Publish failed"
  exit 1
fi

# ─── Create GitHub release ─────────────────────────────────────────────────────

if command -v gh &>/dev/null; then
  info "Creating GitHub release for $CURRENT_TAG..."

  # Get commits since last tag
  LAST_TAG=$(git describe --tags --abbrev=0 "$CURRENT_TAG^" 2>/dev/null || echo "")

  if [[ -n "$LAST_TAG" ]]; then
    COMMITS=$(git log "$LAST_TAG..$CURRENT_TAG" --pretty=format:"- %s (%h)" --no-merges)
  else
    COMMITS=$(git log "$CURRENT_TAG" --pretty=format:"- %s (%h)" --no-merges --max-count=20)
  fi

  # Generate release notes
  RELEASE_NOTES="## Release $CURRENT_TAG

### Changes
$COMMITS

### Installation

\`\`\`bash
# Add to .npmrc (in consumer repo or ~/.npmrc):
@jifflee:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_PAT

# Install the package:
npm install @jifflee/claude-tastic@$TAG_VERSION
\`\`\`

### Upgrade

\`\`\`bash
npm update @jifflee/claude-tastic
\`\`\`

### Package Info

- **Package**: @jifflee/claude-tastic
- **Version**: $TAG_VERSION
- **Registry**: GitHub Packages (https://npm.pkg.github.com)
- **Access**: Private (requires GitHub PAT with \`read:packages\` scope)

---
Published: $(date -u +%Y-%m-%d)"

  if gh release create "$CURRENT_TAG" \
      --title "$CURRENT_TAG" \
      --notes "$RELEASE_NOTES" \
      --verify-tag 2>/dev/null; then
    success "Created GitHub release: $CURRENT_TAG"
  else
    warn "Failed to create GitHub release (package published successfully)"
  fi
else
  warn "gh CLI not found - skipping GitHub release creation"
  info "Install gh: https://cli.github.com/"
fi

# ─── Summary ───────────────────────────────────────────────────────────────────

echo ""
success "════════════════════════════════════════════════════════"
success "  Package Published Successfully!"
success "════════════════════════════════════════════════════════"
echo ""
echo "  Package:   @jifflee/claude-tastic@$TAG_VERSION"
echo "  Registry:  https://npm.pkg.github.com"
echo "  Tag:       $CURRENT_TAG"
echo ""
echo "Consumer repos can install with:"
echo ""
echo "  # Add to .npmrc:"
echo "  @jifflee:registry=https://npm.pkg.github.com"
echo "  //npm.pkg.github.com/:_authToken=YOUR_GITHUB_PAT"
echo ""
echo "  # Install:"
echo "  npm install @jifflee/claude-tastic@$TAG_VERSION"
echo ""
success "════════════════════════════════════════════════════════"
echo ""

exit 0
