# Package Publishing Scripts

Scripts for publishing the `@jifflee/claude-tastic` package to GitHub Packages.

## Overview

The publishing pipeline supports:

- ✓ **Automated publishing** on version tag push (`v*`)
- ✓ **Version validation** (tag must match package.json)
- ✓ **Pre-publish testing** (all tests must pass)
- ✓ **Dry-run validation** for PRs
- ✓ **Package structure validation**
- ✓ **GitHub Releases** creation with auto-generated notes

## Scripts

### `publish-on-tag.sh`

**Purpose:** Automated publishing when version tag is pushed.

**Triggers:**
- Git tag matching `vX.Y.Z` format
- Can be run manually on a tagged commit

**What it does:**
1. Detects version tag
2. Validates tag matches package.json version
3. Runs full test suite
4. Validates package structure
5. Publishes to GitHub Packages
6. Creates GitHub Release (if gh CLI available)

**Usage:**

```bash
# Automatic (recommended):
git tag v1.2.3
git push origin v1.2.3
# Publishing happens automatically

# Manual execution (must be on a tag):
git checkout v1.2.3
./scripts/ci/publish-on-tag.sh
```

**Requirements:**
- `NODE_AUTH_TOKEN` environment variable (GitHub PAT with `write:packages`)
- Must be on a version tag
- All tests must pass
- Tag version must match package.json

**Exit codes:**
- `0` - Published successfully
- `1` - Validation or publish failed
- `2` - Not on a version tag (skipped)

**Environment variables:**
```bash
# Required for publishing:
export NODE_AUTH_TOKEN=ghp_xxxxxxxxxxxx

# Or retrieve from macOS Keychain:
# Script auto-retrieves from service "npm-publish-token"
```

### `validators/validate-package-publish.sh`

**Purpose:** Dry-run validation for PRs (no actual publishing).

**What it checks:**
- ✓ `package.json` is valid and has required fields
- ✓ All files in `"files"` array exist
- ✓ `packs.json` is valid (if present)
- ✓ `npm pack` dry-run succeeds
- ✓ Tests pass
- ✓ No uncommitted `package.json` changes

**Usage:**

```bash
# Standard validation:
./scripts/ci/validators/validate-package-publish.sh

# Strict mode (fail on warnings):
./scripts/ci/validators/validate-package-publish.sh --strict

# Verbose output:
./scripts/ci/validators/validate-package-publish.sh --verbose
```

**Exit codes:**
- `0` - All checks passed, ready to publish
- `1` - Validation failed
- `2` - Tool error

**Integration:**
```bash
# In PR validation:
./scripts/ci/runners/run-pipeline.sh --pre-pr
# (includes validate-package-publish.sh)

# Pre-commit hook:
./scripts/ci/validators/validate-package-publish.sh --strict
```

## Publishing Workflow

### 1. Development

```bash
# Work on features
git checkout -b feat/my-feature
# ... make changes ...
git commit -m "feat: add new feature"
git push origin feat/my-feature
```

### 2. PR Validation

When PR is opened, validation runs automatically:

```bash
# Runs in CI:
./scripts/ci/validators/validate-package-publish.sh
```

This catches issues like:
- Invalid package.json
- Missing files
- Failing tests
- Invalid package structure

### 3. Release Preparation

```bash
# Merge to main
git checkout main
git pull origin main

# Update version
vim package.json  # or: npm version patch/minor/major

# Commit version bump
git add package.json
git commit -m "chore: bump version to v1.2.3"
git push origin main
```

### 4. Publishing

```bash
# Create and push version tag
git tag v1.2.3
git push origin v1.2.3

# Publishing happens automatically via publish-on-tag.sh
```

### 5. Verification

```bash
# Check GitHub Packages:
# https://github.com/jifflee/claude-tastic/pkgs/npm/claude-tastic

# Check GitHub Release:
# https://github.com/jifflee/claude-tastic/releases/tag/v1.2.3

# Test installation in consumer repo:
npm install @jifflee/claude-tastic@1.2.3
```

## Configuration

### package.json

Required configuration:

```json
{
  "name": "@jifflee/claude-tastic",
  "version": "1.2.3",
  "private": false,
  "publishConfig": {
    "registry": "https://npm.pkg.github.com"
  },
  "files": [
    "agents/",
    ".claude/",
    "config/",
    "scripts/",
    "templates/",
    "bin/",
    "packs.json"
  ]
}
```

**Key points:**
- `name` must be scoped to `@jifflee/`
- `private: false` means "publishable" (NOT public access)
- `publishConfig.registry` must point to GitHub Packages
- `files` array explicitly lists what to include

### Authentication

#### For Publishing (Maintainers)

**Option 1: Environment variable**

```bash
export NODE_AUTH_TOKEN=ghp_xxxxxxxxxxxx
```

**Option 2: macOS Keychain (recommended)**

```bash
# Store token:
security add-generic-password \
  -a "$USER" \
  -s "npm-publish-token" \
  -w "ghp_xxxxxxxxxxxx"

# Script auto-retrieves it
```

**Token requirements:**
- Permission: `write:packages`
- Scope: `repo` (for private repo access)

#### For Installing (Consumer Repos)

Create `.npmrc` in consumer repo:

```ini
@jifflee:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=YOUR_GITHUB_PAT
```

**Token requirements:**
- Permission: `read:packages`

**Security:** Add `.npmrc` to `.gitignore`!

## CI/CD Integration

### Local CI Pipeline

Add to `run-pipeline.sh`:

```bash
# Pre-PR validation
if [[ "$MODE" == "pre-pr" ]]; then
  run_check "validate-package-publish" \
    "./scripts/ci/validators/validate-package-publish.sh"
fi
```

### GitHub Actions (Future)

When workflow scope is available:

**.github/workflows/publish.yml:**

```yaml
name: Publish Package

on:
  push:
    tags:
      - 'v*.*.*'

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          registry-url: 'https://npm.pkg.github.com'
      - run: npm ci
      - run: ./scripts/ci/publish-on-tag.sh
        env:
          NODE_AUTH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Troubleshooting

### Problem: "Version mismatch"

**Cause:** Tag version doesn't match package.json

**Fix:**
```bash
# Check versions
git describe --tags
jq -r .version package.json

# Option 1: Update package.json
vim package.json
git add package.json && git commit -m "chore: fix version"

# Option 2: Use correct tag
git tag -d v1.2.3  # Delete wrong tag
git tag v1.2.4     # Create correct tag
```

### Problem: "Tests failed"

**Cause:** Test suite is failing

**Fix:**
```bash
# Debug locally
./scripts/test-runner.sh

# Fix tests
# Commit fixes
# Re-push tag
```

### Problem: "NODE_AUTH_TOKEN not set"

**Cause:** Missing publish token

**Fix:**
```bash
# Get token from: https://github.com/settings/tokens
# Needs: write:packages permission

export NODE_AUTH_TOKEN=ghp_xxxxxxxxxxxx

# Or store in Keychain (macOS):
security add-generic-password \
  -a "$USER" \
  -s "npm-publish-token" \
  -w "ghp_xxxxxxxxxxxx"
```

### Problem: "Package already exists"

**Cause:** Version already published (cannot overwrite)

**Fix:**
```bash
# Must bump version
npm version patch  # or minor/major
git add package.json
git commit -m "chore: bump version"
git tag v$(jq -r .version package.json)
git push origin main --tags
```

### Problem: "Missing files in package"

**Cause:** Files listed in package.json don't exist

**Fix:**
```bash
# Check what's missing:
./scripts/ci/validators/validate-package-publish.sh --verbose

# Update package.json "files" array
vim package.json

# Or create missing files/directories
```

## Best Practices

### 1. Always validate before tagging

```bash
./scripts/ci/validators/validate-package-publish.sh --strict
```

### 2. Test package contents locally

```bash
# See what would be published:
npm pack --dry-run

# Create actual tarball:
npm pack

# Inspect contents:
tar -xzf *.tgz
ls -la package/
rm -rf package *.tgz
```

### 3. Use semantic versioning

- **Major (X.0.0)**: Breaking changes
- **Minor (0.X.0)**: New features, backward compatible
- **Patch (0.0.X)**: Bug fixes

### 4. Keep tokens secure

- ✓ Never commit tokens to git
- ✓ Use environment variables or Keychain
- ✓ Add `.npmrc` to `.gitignore`
- ✓ Rotate tokens regularly

### 5. Document releases

- Update CHANGELOG.md
- Write clear commit messages
- Tag with descriptive messages

```bash
git tag -a v1.2.3 -m "Release v1.2.3: Add feature X, fix bug Y"
```

## Package Contents

What gets published (from `package.json` `files` array):

```
@jifflee/claude-tastic/
├── agents/             # Agent definitions
├── .claude/
│   ├── agents/        # Built-in agents
│   ├── commands/      # Skills/commands
│   └── hooks/         # Lifecycle hooks
├── config/            # Default configs
├── manifests/         # Agent manifests
├── schemas/           # JSON schemas
├── scripts/           # Utility scripts
├── templates/         # File templates
├── bin/               # CLI executables
├── packs.json         # Pack definitions
└── AI.md              # AI documentation
```

**Excluded** (not published):
- `node_modules/`
- `.git/`
- `tests/`
- `*.test.js`, `*.spec.js`
- `.env` files
- Development configs

## Related Documentation

- **Main publishing guide:** [docs/PUBLISHING.md](../../docs/PUBLISHING.md)
- **GitHub Packages docs:** https://docs.github.com/en/packages
- **npm publishing:** https://docs.npmjs.com/packages-and-modules

## Related Issues

- **#1079** - Set up GitHub Packages publish pipeline (this feature)
- **#1075** - Package deployment (parent epic)
- **#1031** - Add package attestation and provenance validation

## Support

For publishing issues:
1. Check troubleshooting section above
2. Run validation: `./scripts/ci/validators/validate-package-publish.sh --verbose`
3. Review logs in CI output
4. Check GitHub Packages console
