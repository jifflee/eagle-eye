---
description: Promote qa branch to main with release tagging and approval workflow
---

# PR to Main

Promotes `qa` to `main` for production release with version tagging and changelog.

**Note:** This skill promotes from `qa`, not `dev`. Use `/pr-to-qa` first to promote dev to qa for QA validation.

## Usage

```
/pr-to-main                    # Create PR from qa to main
/pr-to-main --tag v1.2.0       # Specify version
/pr-to-main --dry-run          # Preview release
/pr-to-main --changelog        # Generate changelog
```

## Steps

### 1. Pre-flight Checks

```bash
git fetch origin
AHEAD=$(git rev-list --count origin/main..origin/qa)
OPEN_PRS=$(gh pr list --base qa --state open --json number | jq length)
CI_STATUS=$(gh run list --branch qa --limit 1 --json conclusion --jq '.[0].conclusion')
```

**Validate:**
- qa ahead of main (AHEAD > 0)
- No open PRs to qa
- CI passing on qa
- QA validation complete

### 2. Determine Version

If `--tag` not specified, analyze commits:

```bash
LAST_TAG=$(git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "v0.0.0")
BREAKING=$(git log $LAST_TAG..origin/qa --oneline | grep -c "BREAKING\|!" || true)
FEATURES=$(git log $LAST_TAG..origin/qa --oneline | grep -c "^feat" || true)
```

**Version bump:**
- BREAKING → Major (v1.0.0 → v2.0.0)
- feat → Minor (v1.0.0 → v1.1.0)
- fix only → Patch (v1.0.0 → v1.0.1)

### 3. Generate Changelog (if --changelog)

```bash
git log $LAST_TAG..origin/qa --pretty=format:"- %s" | \
  grep -E "^- (feat|fix|docs|refactor):" | head -30
```

Group by: Features, Fixes, Other

### 4. Create PR

```bash
gh pr create --base main --head qa \
  --title "release: {version}" \
  --body "## Release {version}

### Changes
{changelog_or_commit_summary}

### Checklist
- [ ] All local validation checks pass
- [ ] Reviewed by maintainer
- [ ] Ready for release"
```

### 5. Post-merge Tag (automated)

**Tags and releases are now created automatically!**

After the release PR is merged to main, create the tag and release manually:
```bash
git checkout main && git pull
git tag -a {version} -m "Release {version}"
git push origin {version}
gh release create {version} --notes "{changelog}"
```

### 6. Milestone Auto-close (post-merge)

After PR is merged, check if the active milestone should be closed:

```bash
# Get active milestone
MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0]')
MILESTONE_TITLE=$(echo "$MILESTONE" | jq -r '.title')
MILESTONE_NUM=$(echo "$MILESTONE" | jq -r '.number')

# Check for open issues in milestone
OPEN_ISSUES=$(gh issue list --milestone "$MILESTONE_TITLE" --state open --json number | jq length)
```

**If OPEN_ISSUES == 0:**

Prompt user:
```
All issues in milestone "{MILESTONE_TITLE}" are closed.
Close milestone? [y/n]
```

**If confirmed (y):**
```bash
gh api repos/:owner/:repo/milestones/$MILESTONE_NUM -X PATCH -f state=closed
```

**If declined (n):**
- Skip milestone closure
- User can manually close later with `/close-milestone`

**If OPEN_ISSUES > 0:**
- Skip prompt (milestone still has open work)
- Display: "Milestone has {n} open issues remaining"

## Output Format

```
## Pre-flight Check

**Source:** qa
**Target:** main
**Commits:** {n}
**Open PRs to qa:** {n}
**CI Status:** {status}
**QA Validation:** Complete

---

## Version Selection

**Last release:** {version}
**Suggested:** {version} ({reason})

---

## Release PR Created

**PR:** #{n}
**URL:** {url}
**Version:** {version}

Next steps:
1. Review and merge PR
2. Tag will be created: `git tag -a {version}`

---

## Post-Merge: Milestone Check

**Milestone:** {name}
**Open issues:** {n}

[If 0 open issues]
All issues in milestone "{name}" are closed.
Close milestone? [y/n]

[If confirmed]
✓ Milestone "{name}" closed

[If open issues remain]
⚠ Milestone has {n} open issues remaining (skipping auto-close)
```

## Version Bump Guidelines

- BREAKING changes (or `!` in commit type) -> Must be major bump
- `feat:` commits -> Must be at least minor bump
- `fix:` only commits -> Patch bump allowed

## Notes

- WRITE operation - creates PR, may close milestone
- Requires user confirmation for version
- Does NOT auto-merge (requires human approval)
- Tags and releases are created manually after merge
- **After merge:** prompts to close milestone if all issues complete
- See BRANCHING_STRATEGY.md for workflow
