#!/bin/bash
# Data script for create-release-branch skill
# Fetches git and GitHub context for release branch creation

set -euo pipefail

REPO="${1:-}"

if [[ -z "$REPO" ]]; then
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
fi

if [[ -z "$REPO" ]]; then
    echo "Error: Not in a GitHub repository" >&2
    exit 1
fi

# Get local git state
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
LATEST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
COMMITS_SINCE_TAG=$(git rev-list "$LATEST_TAG"..HEAD --count 2>/dev/null || echo "0")

# Fetch GitHub release and branch data
gh api graphql -f query='
query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    defaultBranchRef {
      name
      target {
        ... on Commit {
          oid
          messageHeadline
        }
      }
    }
    refs(refPrefix: "refs/heads/release/", first: 20, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
      nodes {
        name
        target {
          ... on Commit {
            oid
            committedDate
          }
        }
      }
    }
    releases(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        tagName
        name
        isPrerelease
        createdAt
        publishedAt
      }
    }
  }
}' -f owner="${REPO%/*}" -f repo="${REPO#*/}" | jq -r \
  --arg repo "$REPO" \
  --arg currentBranch "$CURRENT_BRANCH" \
  --arg latestTag "$LATEST_TAG" \
  --arg commitsSinceTag "$COMMITS_SINCE_TAG" \
  '{
    repository: $repo,
    currentBranch: $currentBranch,
    latestTag: $latestTag,
    commitsSinceTag: $commitsSinceTag,
    defaultBranch: .data.repository.defaultBranchRef.name,
    defaultBranchCommit: .data.repository.defaultBranchRef.target.oid,
    existingReleaseBranches: [.data.repository.refs.nodes[] | {name, commit: .target.oid, date: .target.committedDate}],
    recentReleases: [.data.repository.releases.nodes[] | {tagName, name, isPrerelease, createdAt, publishedAt}]
  }'
