---
description: Promote dev branch to qa for QA validation
argument-hint: "[--dry-run] [--changelog] [--auto-merge] [--milestone X] [--selective] [--list-candidates]"
---

# PR to QA

Promotes `dev` to `qa` for QA/staging validation before production release.

## Usage

### Basic Promotion Modes

```bash
# Full promotion (default) - promote all commits from dev to qa
/pr-to-qa

# Preview promotion without creating PR
/pr-to-qa --dry-run

# Include detailed changelog in PR body
/pr-to-qa --changelog

# Create PR and auto-merge when CI passes
/pr-to-qa --auto-merge
/pr-to-qa --auto-merge --wait  # Wait for CI before returning
```

### Selective Promotion Modes (Issue #971)

```bash
# Milestone-gated promotion - only promote complete milestone
/pr-to-qa --milestone "sprint-2/8"

# Label-based selective promotion - only promote PRs with promote:qa label
/pr-to-qa --selective

# Preview what would be promoted
/pr-to-qa --milestone "sprint-2/8" --dry-run
/pr-to-qa --selective --dry-run

# List promotion candidates without creating PR
/pr-to-qa --list-candidates              # Full promotion (all commits)
/pr-to-qa --list-candidates --milestone "sprint-2/8"  # Milestone filter
/pr-to-qa --list-candidates --selective  # PRs with promote:qa label
```

### Promotion Strategies

| Mode | Command | Use Case |
|------|---------|----------|
| **Full** (default) | `/pr-to-qa` | Promote all dev commits to qa - use when all work is production-ready |
| **Milestone-gated** | `/pr-to-qa --milestone X` | Promote only when milestone X is complete - primary recommendation for controlled releases |
| **Selective** | `/pr-to-qa --selective` | Promote only PRs tagged with `promote:qa` label - fallback for partial milestone promotion |
| **Dry-run** | `/pr-to-qa --dry-run` | Preview changes before promotion |

## Promotion Flow Details

### Milestone-Gated Promotion (Recommended)

**Philosophy:** Only merge to dev what's ready for QA. Milestones define promotion batches.

**Flow:**
1. Work happens on feature branches → PR to dev
2. PRs merged to dev during sprint (only production-ready work)
3. When milestone ready for QA: `/pr-to-qa --milestone "sprint-2/8"`
4. Validates milestone is complete (all issues closed)
5. Creates PR from dev → qa with milestone-scoped changelog
6. QA validation (automated + manual tests)
7. `/pr-to-main` when QA passes

**Benefits:**
- Simple and proven workflow
- Works with existing tooling
- Identical code path from dev → qa → main (no cherry-picks)
- Clear batch boundaries via milestones

### Label-Based Selective Promotion (Fallback)

**Philosophy:** For cases where milestone-gating is too coarse.

**Flow:**
1. Tag specific PRs/issues with `promote:qa` label
2. Run `/pr-to-qa --selective`
3. Script identifies all `promote:qa` labeled PRs
4. Creates PR from dev → qa with only selected changes
5. QA validation
6. After QA passes, merge to qa, then `/pr-to-main`

**When to use:**
- Partial milestone promotion needed
- Hotfix promotion outside normal milestone flow
- Experimental work on dev that shouldn't go to QA yet

### Pre-Promotion Validation

Before any promotion mode:
- ✅ All selected PRs are merged and closed
- ✅ CI passing on dev for selected work
- ✅ No blocking issues in selected work
- ✅ Pre-promote-qa gate passes (10 quality checks)
- ✅ Milestone complete (milestone mode only)
- ✅ At least one PR with `promote:qa` label (selective mode only)

## Steps

### 1. Pre-flight Checks

**Step 1a: Run Pre-Promotion Quality Gate**

```bash
# Run quality gate before allowing promotion
./scripts/pr/pre-promote-qa-gate.sh

# Capture exit code
GATE_EXIT=$?

if [ "$GATE_EXIT" -eq 1 ]; then
  echo "BLOCKED: Pre-promotion gate failed. Fix issues before promoting."
  exit 1
fi

# Capture warnings for PR body
if [ "$GATE_EXIT" -eq 2 ]; then
  GATE_WARNINGS=$(./scripts/pr/pre-promote-qa-gate.sh --json | jq -r '.checks[] | select(.status == "warn") | "- [\(.name)] \(.output)"')
fi
```

**Gate checks (10 total):**
1. Test suite (./scripts/test-runner.sh) - BLOCKING
2. Lint / ShellCheck (./scripts/ci/refactor-lint.sh) - BLOCKING
3. Refactor scan (critical severity) - BLOCKING
4. Security scan (./scripts/ci/sensitivity-scan.sh) - BLOCKING
5. Repo settings drift (./scripts/ci/validate-repo-settings.sh) - BLOCKING
6. Environment tier compliance (./scripts/ci/validate-environment-tier.sh qa) - BLOCKING
7. Repo naming validation (./scripts/ci/validate-repo-naming.sh) - WARNING
8. Doc freshness (./scripts/scan-docs.sh) - WARNING
9. Open PR check (gh pr list --base dev) - BLOCKING
10. CI status on dev (gh api) - BLOCKING

**Exit codes:**
- 0: PASS - all gates passed, proceed with promotion
- 1: FAIL - blocking gate failed, promotion blocked
- 2: WARN - non-blocking warnings, proceed but include in PR
- 3: ERROR - gate script error

See [scripts/pr/pre-promote-qa-gate.sh](/scripts/pr/pre-promote-qa-gate.sh) for implementation details.

**Step 1b: Run Basic Data Validation**

```bash
# Run the data script for additional branch validation
./scripts/pr/pr-to-qa-data.sh
```

**Validate:**
- dev ahead of qa (commits to promote)
- No open PRs to dev (all work merged)
- CI passing on dev
- Environment tier compliance (checked by gate script)

### 2. Gather Changes

```bash
# Get commits since last qa promotion
git fetch origin
COMMITS=$(git log --oneline origin/qa..origin/dev)
COMMIT_COUNT=$(git rev-list --count origin/qa..origin/dev)
```

### 3. Tier Validation (Optional)

**Status:** Planned for issue #933 - not currently enforced

```bash
# Preview tier compliance (dry-run)
./scripts/ci/validate-environment-tier.sh --dry-run qa

# Validate tier compliance (will be enforced in CI/CD)
./scripts/ci/validate-environment-tier.sh qa
```

Checks that promoted code complies with QA tier restrictions:
- No development-only agents
- No scaffolding tools
- No dev-specific scripts

See [COMMIT_PROMOTION_STRATEGY.md](/docs/COMMIT_PROMOTION_STRATEGY.md) for tier details.

### 4. Generate Changelog (if --changelog)

```bash
git log origin/qa..origin/dev --pretty=format:"- %s" | \
  grep -E "^- (feat|fix|docs|refactor):" | head -30
```

Group by: Features, Fixes, Other

### 5. Create PR

```bash
# Build PR body with gate results
PR_BODY="## QA Validation

### Pre-Promotion Gate Results
✅ All quality gates passed
${GATE_WARNINGS:+
### ⚠️ Warnings (Non-Blocking)
$GATE_WARNINGS
}

### Changes for QA Review
{changelog_or_commit_summary}

### QA Checklist
- [ ] Functional testing complete
- [ ] Regression testing complete
- [ ] Performance acceptable
- [ ] No blocking issues found

### After QA Sign-off
Use \`/pr-to-main\` to promote qa to main for production release."

gh pr create --base qa --head dev \
  --title "qa: Promote dev for QA validation" \
  --body "$PR_BODY"
```

**Note:** If the pre-promotion gate found warnings (exit code 2), they will be included in the PR body for visibility but do not block the promotion.

### 6. Post-Creation

After PR is created:
- Notify QA team (if configured)
- Update any tracking tickets
- Wait for QA validation before promoting to main

### 6a. Auto-Merge (if --auto-merge flag)

When `--auto-merge` flag is used:

```bash
./scripts/auto-promote-to-qa.sh --wait
# OR for current milestone:
./scripts/auto-promote-to-qa.sh "${milestone}" --wait
```

**Behavior:**
1. Creates PR from dev→qa (or uses existing)
2. Waits for CI checks to pass (if `--wait`)
3. Auto-merges when PR is in CLEAN state
4. Returns JSON result

**Flags:**
- `--auto-merge`: Enable automatic merge after PR creation
- `--auto-merge --wait`: Wait for CI before merge attempt
- `--auto-merge --dry-run`: Preview without action

**Output (success):**
```json
{
  "action": "merged",
  "pr": {"number": 123, "url": "...", "merged": true},
  "commits_promoted": 5,
  "message": "Successfully promoted dev to qa"
}
```

**Output (blocked):**
```json
{
  "action": "blocked",
  "block_reasons": ["CI not passing on dev"],
  "message": "Cannot auto-promote"
}
```

## Output Format

```
## Pre-flight Check

**Source:** dev
**Target:** qa
**Commits:** {n}
**Open PRs to dev:** {n}
**CI Status:** {status}

---

## QA Promotion PR Created

**PR:** #{n}
**URL:** {url}

### Changes Included
{commit_summary}

---

## Next Steps

1. QA team reviews and tests changes
2. Address any QA feedback
3. After QA sign-off, run `/pr-to-main` to release to production
```

## Dry Run Format

```
## Dry Run: PR to QA

**Would create PR:**
- Source: dev
- Target: qa
- Commits: {n}

### Changes to Promote
{commit_list}

**No PR created** (dry run mode)
```

## Token Optimization

- **Data script:** `scripts/pr/pr-to-qa-data.sh`
- **API calls:** 3 batched (branch status, open PRs, CI status)
- **Savings:** ~65% reduction from inline gh calls

## Label: promote:qa

**Label:** `promote:qa`
**Color:** Green (#0E8A16)
**Purpose:** Mark PRs/issues ready for QA promotion in selective mode

**Usage:**
```bash
# Apply label to PR or issue
gh issue edit 123 --add-label "promote:qa"
gh pr edit 456 --add-label "promote:qa"

# Remove label after successful promotion
gh issue edit 123 --remove-label "promote:qa"
```

**Lifecycle:**
1. Apply `promote:qa` when work is ready for QA
2. Run `/pr-to-qa --selective` to promote labeled work
3. Label is removed after successful promotion to qa
4. Can be applied manually or via `/label-issue`

## Notes

- WRITE operation - creates PR
- Requires user confirmation (unless --auto-merge)
- Does NOT auto-merge by default (requires QA sign-off)
- Use `--auto-merge` for automatic merge after CI passes
- Uses `scripts/auto-promote-to-qa.sh` for auto-merge logic
- Use `/pr-to-main` after QA validation to release to production
- **Pre-promotion gate enforced:** All code must pass quality gates before promotion (Issue #955)
- Gate cache: 30 minutes per HEAD SHA (use `--no-cache` to force re-run)
- `/pr-to-main` uses stricter gate: `scripts/pr/pre-promote-main-gate.sh` (all warnings blocking)
- **Selective promotion (Issue #971):**
  - Milestone-gated promotion is the primary mechanism for controlled releases
  - Label-based selective promotion (`--selective`) is a fallback for partial milestone promotion
  - Both modes retain QA testing capability (automated CI + manual validation)
  - What you test on qa = what goes to main (no cherry-picks, identical SHAs)
- See BRANCHING_STRATEGY.md for full workflow

## Related Documentation

- [scripts/pr/pre-promote-qa-gate.sh](/scripts/pr/pre-promote-qa-gate.sh) - Pre-promotion quality gate for dev→qa
- [scripts/pr/pre-promote-main-gate.sh](/scripts/pr/pre-promote-main-gate.sh) - Stricter quality gate for qa→main
- [config/repo-profile.yaml](/config/repo-profile.yaml) - Promotion gates configuration
- [COMMIT_PROMOTION_STRATEGY.md](/docs/COMMIT_PROMOTION_STRATEGY.md) - Promotion strategy and rollback
- [BRANCHING_STRATEGY.md](/docs/BRANCHING_STRATEGY.md) - Branch workflow
- [environment-tiers.yaml](/configs/environment-tiers.yaml) - Tier configuration
