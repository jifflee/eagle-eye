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

### 1. Gather Data

```bash
./scripts/pr/pr-to-main-data.sh --changelog
```

Returns JSON with branch state, version suggestions, readiness checks, and changelog.

### 2. Pre-flight Checks

Use the JSON output from the data script:

- `branch_state.ahead`: qa ahead of main (must be > 0)
- `readiness.open_prs_to_qa`: Must be 0
- `readiness.ci_status`: Must be "success"
- `readiness.can_promote`: Overall readiness flag

**Validate:**
- qa ahead of main (AHEAD > 0)
- No open PRs to qa
- CI passing on qa
- QA validation complete

### 2a. External Deployment Check (Public Repos Only)

**For external (public) repos, run external deployment readiness check before proceeding:**

```bash
# Check if repo is configured as public
if [ -f "config/repo-profile.yaml" ]; then
  VISIBILITY=$(yq eval '.visibility.type' config/repo-profile.yaml 2>/dev/null || echo "private")

  if [[ "$VISIBILITY" == "public" ]]; then
    echo "Running external deployment readiness check..."
    echo "This validates the repository is safe for public release."
    echo ""

    # Run external deployment check
    if ! ./scripts/ci/validators/external-deployment-check.sh; then
      echo ""
      echo "ERROR: External deployment check FAILED"
      echo "This is an external (public) repository."
      echo "Promotion to main is BLOCKED until all checks pass."
      echo ""
      echo "Actions required:"
      echo "  1. Review the check failures above"
      echo "  2. Fix issues (remove sensitive data, add documentation, etc.)"
      echo "  3. Re-run /pr-to-main to verify"
      echo ""
      exit 1
    fi

    echo "✓ External deployment check passed: repository is ready for public release"
  else
    echo "External deployment check skipped (private repository)"
  fi
fi
```

**External deployment check validates:**

**Category 1: No Sensitive Data Leakage**
- No hardcoded secrets, API keys, tokens, or credentials
- No `.env` files or sensitive configs committed
- No internal URLs, IPs, or infrastructure references
- No private registry references or internal package names

**Category 2: Public-Readiness**
- README.md exists and is meaningful (not a stub)
- LICENSE file exists
- CONTRIBUTING.md exists (recommended)
- No internal-only documentation references
- No references to private repos or internal tools

**Category 3: Dependency Safety**
- No private/internal dependencies that external users can't access
- No pinned versions pointing to private registries
- All dependencies are publicly available

**Category 4: Code Safety**
- No excessive debug/development artifacts (console.logs, etc.)
- No test fixtures with real data
- No TODO hacks or commented-out code with sensitive context

**If check fails:** Promotion is blocked. Fix findings and re-run.

### 3. Determine Version

If `--tag` not specified, use suggestions from data script:

From JSON output:
- `versions.latest_tag`: Current version on main
- `versions.suggested`: Default patch bump
- `versions.suggestions`: Array of [patch, minor, major] options

**Version bump rules:**
- BREAKING → Major (v1.0.0 → v2.0.0)
- feat → Minor (v1.0.0 → v1.1.0)
- fix only → Patch (v1.0.0 → v1.0.1)

### 4. Generate Changelog

The data script with `--changelog` flag provides pre-categorized commits:

From JSON `changelog`:
- `features`: Array of feature commits
- `fixes`: Array of bug fix commits
- `other`: Array of other commits

Group by: Features, Fixes, Other

### 5. Create PR

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

### 6. Post-merge Tag (automated)

**Tags and releases are now created automatically!**

After the release PR is merged to main, create the tag and release manually:

```bash
git checkout main && git pull
git tag -a {version} -m "Release {version}"
git push origin {version}
gh release create {version} --notes "{changelog}"
```

### 7. Milestone Auto-close (post-merge)

After PR is merged, check if the active milestone should be closed:

```bash
# Get active milestone
MILESTONE=$(gh api repos/:owner/:repo/milestone-list --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0]')
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
gh api repos/:owner/:repo/milestone-list/$MILESTONE_NUM -X PATCH -f state=closed
```

**If declined (n):**
- Skip milestone closure
- User can manually close later with `/milestone:close-safe`

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

## Token Optimization

- Uses `scripts/pr/pr-to-main-data.sh` for all data gathering
- Returns structured JSON with pre-computed readiness checks
- Single batch of API calls (branch state + CI status + PRs + milestone)
- Changelog pre-categorized by commit type (features/fixes/other)
- ~400-725 tokens per invocation (vs ~2000 without script)
- 63% token savings through batched gh API calls with jq

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
- **NEW:** Runs external deployment check for public repos before promotion
- **NEW:** Validates sensitive data, public-readiness, dependency safety, and code safety
- **NEW:** Blocks promotion if any check fails (4 categories: sensitive data, public-readiness, dependencies, code safety)
- **NEW:** Uses config/repo-profile.yaml to determine if check is required
- **NEW:** Private repos skip the external deployment check (no change to current behavior)
- Related issues: #933 (environment-tiered SDLC), #934 (public/private repo detection), #1129 (unified SDLC)
