---
description: Create release/X.x branch from main or tag for LTS versions
---

# Create Release Branch

Creates a release branch (e.g., `release/1.x`) from main or a specific tag for long-term support (LTS) versions.

## Usage

```
/repo-create-release 1.x           # Create release/1.x from main
/repo-create-release 2.x v2.0.0    # Create release/2.x from tag v2.0.0
/repo-create-release --dry-run 1.x # Preview without creating
```

## Argument Handling

Arguments format: `[--dry-run] <version> [source]`

- `version`: Required. The major version for the release branch (e.g., `1.x`, `2.x`)
- `source`: Optional. Tag or commit to branch from. Defaults to `main`
- `--dry-run`: Optional. Preview the operation without making changes

**Example parsing:**
- `/repo-create-release 1.x` -> version=1.x, source=main
- `/repo-create-release 2.x v2.0.0` -> version=2.x, source=v2.0.0
- `/repo-create-release --dry-run 1.x` -> dry_run=true, version=1.x

## Steps

### 1. Parse Arguments

```bash
DRY_RUN=false
VERSION=""
SOURCE="main"

# Parse arguments from ARGUMENTS section
for arg in $ARGS; do
  if [ "$arg" = "--dry-run" ]; then
    DRY_RUN=true
  elif [ -z "$VERSION" ]; then
    VERSION="$arg"
  else
    SOURCE="$arg"
  fi
done
```

### 2. Validate Version Format

```bash
# Version must be in format N.x (e.g., 1.x, 2.x, 10.x)
if ! echo "$VERSION" | grep -qE '^[0-9]+\.x$'; then
  echo "Error: Version must be in format N.x (e.g., 1.x, 2.x)"
  exit 1
fi

BRANCH_NAME="release/$VERSION"
```

### 3. Validate Source Exists

```bash
git fetch origin --tags

# Check if source is a valid ref (branch, tag, or commit)
if ! git rev-parse --verify "$SOURCE" >/dev/null 2>&1; then
  # Try with origin/ prefix for branches
  if ! git rev-parse --verify "origin/$SOURCE" >/dev/null 2>&1; then
    echo "Error: Source '$SOURCE' not found (not a valid branch, tag, or commit)"
    exit 1
  fi
  SOURCE="origin/$SOURCE"
fi
```

### 4. Check Branch Doesn't Exist

```bash
# Check local
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  echo "Error: Branch '$BRANCH_NAME' already exists locally"
  exit 1
fi

# Check remote
if git ls-remote --exit-code origin "$BRANCH_NAME" >/dev/null 2>&1; then
  echo "Error: Branch '$BRANCH_NAME' already exists on origin"
  exit 1
fi
```

### 5. Dry Run Output (if --dry-run)

If `DRY_RUN=true`, display what would happen and exit:

```
## Dry Run: Create Release Branch

**Would create:** release/{version}
**From source:** {source}
**Source commit:** {commit_sha}

Commands that would run:
  git checkout -b release/{version} {source}
  git push -u origin release/{version}

No changes made (dry run mode).
```

### 6. Create Branch

```bash
# Get source commit for logging
SOURCE_COMMIT=$(git rev-parse --short "$SOURCE")

# Create branch from source
git checkout -b "$BRANCH_NAME" "$SOURCE"
```

### 7. Push to Origin

```bash
git push -u origin "$BRANCH_NAME"
```

### 8. Return to Main Branch

```bash
# Return to main for clean worktree state
git checkout main
```

## Output Format

### Success

```
## Release Branch Created

**Branch:** release/{version}
**Source:** {source} ({commit_sha})
**Pushed:** origin/release/{version}

### Next Steps

1. Cherry-pick fixes from main:
   git checkout release/{version}
   git cherry-pick <commit>
   git push origin release/{version}

2. Create patch releases:
   git tag v{version}.1
   git push origin v{version}.1

3. Document the LTS version in release notes
```

### Error: Branch Exists

```
## Error: Branch Already Exists

**Branch:** release/{version}
**Location:** {local|remote|both}

The release branch already exists. If you need to recreate it:
  git branch -d release/{version}           # Delete local
  git push origin --delete release/{version} # Delete remote
```

### Error: Invalid Version

```
## Error: Invalid Version Format

**Provided:** {input}
**Expected:** N.x (e.g., 1.x, 2.x, 10.x)

Release branch versions must be in the format of major version followed by .x
```

### Error: Source Not Found

```
## Error: Source Not Found

**Provided:** {source}
**Searched:** branches, tags, commits

Ensure the source exists:
  git fetch origin --tags
  git tag -l | grep {source}
  git branch -a | grep {source}
```

## Token Optimization

- **Data script:** `scripts/repo-create-release-data.sh`
- **Validation:** Pre-flight checks before operations
- **Savings:** ~40% reduction from inline git commands

## Notes

- WRITE operation - creates branch and pushes to origin
- Requires write access to origin repository
- Only creates branches in format `release/N.x` for LTS support
- Does not modify any existing branches (main, dev, or existing release branches)
- Source defaults to `main` if not specified
- Validates all preconditions before making changes
- Returns to main after branch creation (for clean worktree state)
- Release branches are long-lived for LTS support and cherry-pick backports
- Does NOT trigger auto-release workflow (which only monitors main)
- See BRANCHING_STRATEGY.md for release workflow integration
