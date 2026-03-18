#!/bin/bash
set -euo pipefail
# sprint-status-data.sh
# Gathers all sprint status data in a single pass for token-efficient Claude analysis
# size-ok: single-pass data aggregator combining milestone, velocity, and dependency metrics
#
# Usage: ./scripts/sprint-status-data.sh [MILESTONE] [--velocity] [--all] [--deps] [--minimal] [--full]
#
# Tiered Output Modes:
#   --minimal  Counts, priority queue, recommended next only (~3s)
#   (default)  Core status + PM recommendations (~5s)
#   --full     All sections including health, audit, containers (~10s)
#
# Outputs structured JSON with all metrics needed for /sprint-status

set -e

# Ensure we're in the repo root (required for gh commands and relative paths)
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

MILESTONE=""
INCLUDE_VELOCITY=false
SHOW_ALL=false
INCLUDE_DEPS=false
AUTO_MERGE=false
MODE="default"  # minimal, default, full

# Parse flags and positional arguments
for arg in "$@"; do
  case $arg in
    --velocity) INCLUDE_VELOCITY=true ;;
    --all) SHOW_ALL=true ;;
    --deps) INCLUDE_DEPS=true ;;
    --auto-merge) AUTO_MERGE=true ;;
    --minimal) MODE="minimal" ;;
    --full) MODE="full" ;;
    --*) ;; # Skip unknown flags
    *)
      # First non-flag argument is the milestone
      if [ -z "$MILESTONE" ]; then
        MILESTONE="$arg"
      fi
      ;;
  esac
done

# If --all flag, just return all milestones summary
if [ "$SHOW_ALL" = true ]; then
  gh api repos/:owner/:repo/milestones --jq '
    [.[] | select(.state=="open")] |
    sort_by(.due_on) |
    {
      milestones: [.[] | {
        title: .title,
        due_on: .due_on,
        open_issues: .open_issues,
        closed_issues: .closed_issues,
        total: (.open_issues + .closed_issues),
        progress: (if (.open_issues + .closed_issues) > 0 then ((.closed_issues / (.open_issues + .closed_issues)) * 100 | floor) else 0 end)
      }]
    }'
  exit 0
fi

# Get milestone if not specified (use earliest due date)
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Auto-merge mergeable PRs before gathering data (if requested)
AUTO_MERGE_RESULT='{"merged": [], "failed": [], "skipped": [], "summary": {"merged_count": 0, "failed_count": 0, "skipped_count": 0, "dry_run": false}}'
if [ "$AUTO_MERGE" = true ]; then
  if [ -x "$SCRIPT_DIR/sprint-status-auto-merge.sh" ] 2>/dev/null || [ -x "$(dirname "$0")/sprint-status-auto-merge.sh" ]; then
    SCRIPT_PATH="${SCRIPT_DIR:-$(dirname "$0")}/sprint-status-auto-merge.sh"
    AUTO_MERGE_RESULT=$("$SCRIPT_PATH" --milestone "$MILESTONE" 2>/dev/null || echo "$AUTO_MERGE_RESULT")

    # If any PRs were merged, pull latest to sync repository
    MERGED_COUNT=$(echo "$AUTO_MERGE_RESULT" | jq -r '.summary.merged_count // 0')
    if [ "$MERGED_COUNT" -gt 0 ]; then
      echo "Syncing repository after $MERGED_COUNT merge(s)..." >&2
      git fetch origin >/dev/null 2>&1 || true
      # Only pull if we're on a tracked branch (not in detached HEAD or worktree)
      if git symbolic-ref -q HEAD >/dev/null 2>&1; then
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if git config "branch.${CURRENT_BRANCH}.remote" >/dev/null 2>&1; then
          git pull --ff-only origin "$CURRENT_BRANCH" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
fi

# Get milestone metadata
MILESTONE_DATA=$(gh api repos/:owner/:repo/milestones --jq '.[] | select(.title=="'"$MILESTONE"'") | {title: .title, due_on: .due_on, open_issues: .open_issues, closed_issues: .closed_issues}')

# Gather all counts (these run sequentially but output is batched)
TOTAL=$(gh issue list --milestone "$MILESTONE" --state all --json number 2>/dev/null | jq length)
OPEN=$(gh issue list --milestone "$MILESTONE" --state open --json number 2>/dev/null | jq length)
CLOSED=$(gh issue list --milestone "$MILESTONE" --state closed --json number 2>/dev/null | jq length)

# By status label
BACKLOG=$(gh issue list --milestone "$MILESTONE" --label "backlog" --state open --json number 2>/dev/null | jq length)
IN_PROGRESS=$(gh issue list --milestone "$MILESTONE" --label "in-progress" --state open --json number 2>/dev/null | jq length)
BLOCKED=$(gh issue list --milestone "$MILESTONE" --label "blocked" --state open --json number 2>/dev/null | jq length)

# By type
BUGS=$(gh issue list --milestone "$MILESTONE" --label "bug" --state open --json number 2>/dev/null | jq length)
FEATURES=$(gh issue list --milestone "$MILESTONE" --label "feature" --state open --json number 2>/dev/null | jq length)
TECH_DEBT=$(gh issue list --milestone "$MILESTONE" --label "tech-debt" --state open --json number 2>/dev/null | jq length)
DOCS=$(gh issue list --milestone "$MILESTONE" --label "docs" --state open --json number 2>/dev/null | jq length)

# By priority
P0=$(gh issue list --milestone "$MILESTONE" --label "P0" --state open --json number 2>/dev/null | jq length)
P1=$(gh issue list --milestone "$MILESTONE" --label "P1" --state open --json number 2>/dev/null | jq length)
P2=$(gh issue list --milestone "$MILESTONE" --label "P2" --state open --json number 2>/dev/null | jq length)
P3=$(gh issue list --milestone "$MILESTONE" --label "P3" --state open --json number 2>/dev/null | jq length)

# Get open issues with details (extended for health analysis)
# Note: body excluded to keep output size manageable (was causing 40K+ token outputs)
# Skip in minimal mode to reduce cache size (issue #393)
if [ "$MODE" != "minimal" ]; then
  OPEN_ISSUES=$(gh issue list --milestone "$MILESTONE" --state open --json number,title,labels,createdAt,updatedAt 2>/dev/null | jq '.')
else
  OPEN_ISSUES='[]'
fi

# Get milestone issue numbers for PR matching (as JSON array)
MILESTONE_ISSUE_NUMS=$(gh issue list --milestone "$MILESTONE" --state all --json number --jq '[.[].number]' 2>/dev/null)

# Get all open PRs with merge status and review state
ALL_PRS=$(gh pr list --state open --json number,title,headRefName,mergeable,mergeStateStatus,body,isDraft,reviewDecision 2>/dev/null)

# Get merged PRs to detect orphaned issues (PR merged but issue still open)
# This prevents reporting issues as "ready for work" when their PR was already merged
MERGED_PRS=$(gh pr list --state merged --json number,body,mergedAt --jq '[.[] | {
  pr_number: .number,
  merged_at: .mergedAt,
  linked_issue: ((.body // "") | capture("(?i)(?:fixes|closes|resolves) #(?<num>[0-9]+)") | .num | tonumber) // null
}] | map(select(.linked_issue != null))' 2>/dev/null || echo '[]')

# Filter PRs to those linked to milestone issues and extract merge status with lifecycle state
# Then enhance with health data from pr-health-check logic
PR_STATUS=$(echo "$ALL_PRS" | jq --argjson issues "$MILESTONE_ISSUE_NUMS" '
  [.[] |
    # Extract linked issue from body (Fixes #N, Closes #N, Resolves #N)
    . as $pr |
    (($pr.body // "") | capture("(?i)(?:fixes|closes|resolves) #(?<num>[0-9]+)") | .num | tonumber) as $linked |
    select($linked != null and ($issues | index($linked))) |
    {
      pr_number: .number,
      title: .title,
      linked_issue: $linked,
      branch: .headRefName,
      mergeable: .mergeable,
      merge_state: .mergeStateStatus,
      is_draft: .isDraft,
      review_decision: .reviewDecision,
      # Derive PR lifecycle state for sprint-status visibility
      # States: draft, open (under review), ready (approved + mergeable), blocked (CI failing or review changes requested)
      lifecycle_state: (
        if .isDraft then "draft"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == "APPROVED" then "ready"
        elif .mergeStateStatus == "CLEAN" then "open"
        elif .mergeStateStatus == "BLOCKED" or .reviewDecision == "CHANGES_REQUESTED" then "blocked"
        elif .mergeStateStatus == "UNSTABLE" then "unstable"
        elif .mergeStateStatus == "BEHIND" then "behind"
        else "open"
        end
      ),
      # Recommended action based on lifecycle state
      action_needed: (
        if .isDraft then "Complete draft and mark ready for review"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == "APPROVED" then "Ready to merge → then cleanup worktree"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == null then "Awaiting review"
        elif .mergeStateStatus == "BLOCKED" then "Resolve blocking issues (CI or conflicts)"
        elif .mergeStateStatus == "UNSTABLE" then "Fix failing CI checks"
        elif .mergeStateStatus == "BEHIND" then "Update branch with base"
        elif .reviewDecision == "CHANGES_REQUESTED" then "Address review feedback"
        else "Development in progress"
        end
      )
    }
  ]')

# Enhance PR status with health check data
# For each PR, calculate health metrics inline to avoid extra API calls
if [ -n "$PR_STATUS" ] && [ "$(echo "$PR_STATUS" | jq 'length')" -gt 0 ]; then
  # Fetch base branch (typically main or master)
  BASE_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")

  # Ensure we have latest refs
  git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || true

  # Enhance each PR with health data
  PR_STATUS=$(echo "$PR_STATUS" | jq --arg base "$BASE_BRANCH" '[.[] |
    .branch as $head |
    # Calculate commits behind base
    ($head | @sh "git rev-list --count origin/\($head)..origin/\($base) 2>/dev/null || echo 0") as $behind_cmd |
    # Calculate total commits in PR
    (@sh "gh pr view \(.pr_number) --json commits --jq \".commits | length\" 2>/dev/null || echo 0") as $total_cmd |
    # Calculate unique commits (not in base)
    (@sh "git rev-list --count origin/\($base)..origin/\($head) 2>/dev/null || echo 0") as $unique_cmd |

    . + {
      health: {
        # Placeholder for shell commands - will be replaced in next step
        status: "UNKNOWN",
        commits_upstream: 0,
        commits_behind_base: 0,
        recommended_action: "unknown"
      }
    }
  ]')

  # Now enhance with actual health data by calling git commands for each PR
  ENHANCED_PR_STATUS="[]"
  for pr_num in $(echo "$PR_STATUS" | jq -r '.[].pr_number'); do
    PR_ENTRY=$(echo "$PR_STATUS" | jq ".[] | select(.pr_number == $pr_num)")
    HEAD_BRANCH=$(echo "$PR_ENTRY" | jq -r '.branch')
    MERGEABLE=$(echo "$PR_ENTRY" | jq -r '.mergeable')

    # Ensure branch refs are available
    git fetch origin "$HEAD_BRANCH" --quiet 2>/dev/null || true

    # Calculate health metrics
    COMMITS_TOTAL=$(gh pr view "$pr_num" --json commits --jq '.commits | length' 2>/dev/null || echo "0")
    COMMITS_BEHIND_BASE=$(git rev-list --count "origin/$HEAD_BRANCH..origin/$BASE_BRANCH" 2>/dev/null || echo "0")
    UNIQUE_COMMITS=$(git rev-list --count "origin/$BASE_BRANCH..origin/$HEAD_BRANCH" 2>/dev/null || echo "$COMMITS_TOTAL")
    COMMITS_UPSTREAM=$((COMMITS_TOTAL - UNIQUE_COMMITS))

    # Determine health status and recommendation
    HEALTH_STATUS="READY"
    HEALTH_ACTION="merge"
    HEALTH_REASON="PR is ready to merge"

    if [ "$COMMITS_UPSTREAM" -eq "$COMMITS_TOTAL" ] && [ "$COMMITS_TOTAL" -gt 0 ]; then
      HEALTH_STATUS="STALE"
      HEALTH_ACTION="close"
      HEALTH_REASON="All commits already in base branch"
    elif [ "$MERGEABLE" = "CONFLICTING" ]; then
      HEALTH_STATUS="CONFLICTING"
      HEALTH_ACTION="rebase"
      HEALTH_REASON="Has merge conflicts that need resolution"
    elif [ "$COMMITS_BEHIND_BASE" -gt 0 ]; then
      HEALTH_STATUS="NEEDS_REBASE"
      HEALTH_ACTION="rebase"
      HEALTH_REASON="Branch is behind base by $COMMITS_BEHIND_BASE commit(s)"
    else
      # Check for failed checks
      CHECKS_STATUS=$(gh pr checks "$pr_num" --json state 2>/dev/null || echo "[]")
      FAILED_CHECKS=$(echo "$CHECKS_STATUS" | jq '[.[] | select(.state == "FAILURE" or .state == "ERROR")] | length' 2>/dev/null || echo "0")

      if [ "$FAILED_CHECKS" -gt 0 ]; then
        HEALTH_STATUS="BLOCKED"
        HEALTH_ACTION="fix"
        HEALTH_REASON="Required checks failing ($FAILED_CHECKS check(s))"
      fi
    fi

    # Update PR entry with health data
    PR_ENTRY=$(echo "$PR_ENTRY" | jq \
      --arg status "$HEALTH_STATUS" \
      --argjson upstream "$COMMITS_UPSTREAM" \
      --argjson behind "$COMMITS_BEHIND_BASE" \
      --arg action "$HEALTH_ACTION" \
      --arg reason "$HEALTH_REASON" \
      '.health = {
        status: $status,
        commits_upstream: $upstream,
        commits_behind_base: $behind,
        recommended_action: $action,
        reason: $reason
      }')

    # Add to enhanced list
    ENHANCED_PR_STATUS=$(echo "$ENHANCED_PR_STATUS" | jq --argjson entry "$PR_ENTRY" '. + [$entry]')
  done

  PR_STATUS="$ENHANCED_PR_STATUS"
fi


# Label audit - check for missing required labels - skip in minimal mode
# Required: at least one status label (backlog, in-progress, blocked) and one type label (bug, feature, tech-debt, docs)
if [ "$MODE" != "minimal" ]; then
  STATUS_LABELS='["backlog", "in-progress", "blocked"]'
  TYPE_LABELS='["bug", "feature", "tech-debt", "docs", "epic"]'
  PRIORITY_LABELS='["P0", "P1", "P2", "P3"]'

  LABEL_AUDIT=$(echo "$OPEN_ISSUES" | jq --argjson status "$STATUS_LABELS" --argjson type "$TYPE_LABELS" --argjson priority "$PRIORITY_LABELS" '
    [.[] | {
      number: .number,
      title: .title,
      current_labels: [.labels[].name],
      missing: {
        status: (if ([.labels[].name] | any(. as $l | $status | index($l))) then null else "status" end),
        type: (if ([.labels[].name] | any(. as $l | $type | index($l))) then null else "type" end),
        priority: (if ([.labels[].name] | any(. as $l | $priority | index($l))) then null else "priority" end)
      }
    } | select(.missing.status != null or .missing.type != null or .missing.priority != null)]
  ')
else
  LABEL_AUDIT='[]'
fi

# Identify orphaned issues (open issues with merged PRs) - skip in minimal mode
# These should be auto-closed but weren't due to missing "Fixes #N" format
if [ "$MODE" != "minimal" ]; then
  ORPHANED_ISSUES=$(echo "$OPEN_ISSUES" | jq --argjson merged "$MERGED_PRS" '
    ($merged | map(.linked_issue) | unique) as $merged_issues |
    [.[] | select(.number as $n | $merged_issues | index($n))] |
    [.[] |
      .number as $issue_num |
      ($merged | map(select(.linked_issue == $issue_num)) | .[0]) as $pr_info |
      {
        number: .number,
        title: .title,
        merged_pr: ($pr_info.pr_number // null),
        merged_at: ($pr_info.merged_at // null),
        recommendation: "Auto-close: PR was already merged"
      }
    ]
  ')
else
  ORPHANED_ISSUES='[]'
fi

# Calculate recommended next issues with prioritization logic
# Priority order: P0 > P1 > P2 > P3, then bug > feature > tech-debt > docs
# Also considers: epic children (parent:N label), age, checked-out status
# Excludes: issues with merged PRs (orphaned issues)
# In minimal mode, fetch only backlog issues to reduce API calls and data size
if [ "$MODE" = "minimal" ]; then
  # Fetch only backlog issues (smaller dataset for recommendations)
  BACKLOG_ISSUES=$(gh issue list --milestone "$MILESTONE" --label "backlog" --state open --json number,title,labels 2>/dev/null | jq '.')
  RECOMMENDED_NEXT=$(echo "$BACKLOG_ISSUES" | jq --argjson merged "$MERGED_PRS" '
    # Get list of issue numbers with merged PRs (orphaned issues)
    ($merged | map(.linked_issue) | unique) as $orphaned |

    # Filter out checked-out and orphaned issues (already backlog-only from query)
    [.[] | select(
      ([.labels[].name] | any(. == "wip:checked-out") | not) and
      (.number as $n | $orphaned | index($n) | not)
    )] |

    # Score and rank each issue
    [.[] | {
      number: .number,
      title: .title,
      labels: [.labels[].name],

      # Extract parent reference from labels (parent:N pattern)
      parent: ([.labels[].name | select(startswith("parent:"))] | first // null | if . then (split(":")[1] | tonumber) else null end),

      # Calculate priority score (P0=400, P1=300, P2=200, P3=100)
      priority_score: (
        if ([.labels[].name] | any(. == "P0")) then 400
        elif ([.labels[].name] | any(. == "P1")) then 300
        elif ([.labels[].name] | any(. == "P2")) then 200
        elif ([.labels[].name] | any(. == "P3")) then 100
        else 50 end
      ),

      # Calculate type score (bug=40, feature=30, tech-debt=20, docs=10)
      type_score: (
        if ([.labels[].name] | any(. == "bug")) then 40
        elif ([.labels[].name] | any(. == "feature")) then 30
        elif ([.labels[].name] | any(. == "tech-debt")) then 20
        elif ([.labels[].name] | any(. == "docs")) then 10
        else 5 end
      ),

      # Determine type for display
      type: (
        if ([.labels[].name] | any(. == "bug")) then "bug"
        elif ([.labels[].name] | any(. == "feature")) then "feature"
        elif ([.labels[].name] | any(. == "tech-debt")) then "tech-debt"
        elif ([.labels[].name] | any(. == "docs")) then "docs"
        else "unknown" end
      ),

      # Determine priority for display
      priority: (
        if ([.labels[].name] | any(. == "P0")) then "P0"
        elif ([.labels[].name] | any(. == "P1")) then "P1"
        elif ([.labels[].name] | any(. == "P2")) then "P2"
        elif ([.labels[].name] | any(. == "P3")) then "P3"
        else "unset" end
      )
    }] |

    # Calculate total score
    [.[] | . + {
      total_score: (.priority_score + .type_score + (if .parent != null then 25 else 0 end))
    }] |

    # Sort by total score descending, take top 5
    sort_by(-.total_score) | .[0:5] |

    # Output clean recommendations (minimal fields)
    [.[] | {
      number: .number,
      title: (.title | if length > 50 then .[0:47] + "..." else . end),
      type: .type,
      priority: .priority,
      parent: .parent
    }]
  ')
else
  RECOMMENDED_NEXT=$(echo "$OPEN_ISSUES" | jq --argjson merged "$MERGED_PRS" '
  # Get list of issue numbers with merged PRs (orphaned issues)
  ($merged | map(.linked_issue) | unique) as $orphaned |

  # Filter to backlog only (not in-progress, not blocked, not checked-out, not orphaned)
  [.[] | select(
    ([.labels[].name] | any(. == "backlog")) and
    ([.labels[].name] | any(. == "in-progress") | not) and
    ([.labels[].name] | any(. == "blocked") | not) and
    ([.labels[].name] | any(. == "wip:checked-out") | not) and
    (.number as $n | $orphaned | index($n) | not)
  )] |

  # Score and rank each issue
  [.[] | {
    number: .number,
    title: .title,
    labels: [.labels[].name],
    created_at: .createdAt,

    # Extract parent reference from labels (parent:N pattern)
    parent: ([.labels[].name | select(startswith("parent:"))] | first // null | if . then (split(":")[1] | tonumber) else null end),

    # Calculate priority score (P0=400, P1=300, P2=200, P3=100)
    priority_score: (
      if ([.labels[].name] | any(. == "P0")) then 400
      elif ([.labels[].name] | any(. == "P1")) then 300
      elif ([.labels[].name] | any(. == "P2")) then 200
      elif ([.labels[].name] | any(. == "P3")) then 100
      else 50 end
    ),

    # Calculate type score (bug=40, feature=30, tech-debt=20, docs=10)
    type_score: (
      if ([.labels[].name] | any(. == "bug")) then 40
      elif ([.labels[].name] | any(. == "feature")) then 30
      elif ([.labels[].name] | any(. == "tech-debt")) then 20
      elif ([.labels[].name] | any(. == "docs")) then 10
      else 5 end
    ),

    # Bonus for needs-attention label
    attention_bonus: (if ([.labels[].name] | any(. == "needs-attention")) then 50 else 0 end),

    # Determine type for display
    type: (
      if ([.labels[].name] | any(. == "bug")) then "bug"
      elif ([.labels[].name] | any(. == "feature")) then "feature"
      elif ([.labels[].name] | any(. == "tech-debt")) then "tech-debt"
      elif ([.labels[].name] | any(. == "docs")) then "docs"
      else "unknown" end
    ),

    # Determine priority for display
    priority: (
      if ([.labels[].name] | any(. == "P0")) then "P0"
      elif ([.labels[].name] | any(. == "P1")) then "P1"
      elif ([.labels[].name] | any(. == "P2")) then "P2"
      elif ([.labels[].name] | any(. == "P3")) then "P3"
      else "unset" end
    )
  }] |

  # Calculate total score and reasoning
  [.[] |
    # Store type for fallback reasoning (referenced via $t later in pipe)
    .type as $t |
    . + {
      total_score: (.priority_score + .type_score + .attention_bonus + (if .parent != null then 25 else 0 end)),
      reasoning: (
        [
          (if .priority_score >= 300 then "high priority (\(.priority))" else null end),
          (if .type == "bug" then "bug fix needed" else null end),
          (if .parent != null then "epic child (parent:\(.parent))" else null end),
          (if .attention_bonus > 0 then "needs attention" else null end),
          (if .priority_score < 100 then "no priority set" else null end)
        ] | map(select(. != null)) |
        if length == 0 then [$t] else . end | join(", ")
      )
    }
  ] |

  # Sort by total score descending, take top 5
  sort_by(-.total_score) | .[0:5] |

  # Output clean recommendations
  [.[] | {
    number: .number,
    title: (.title | if length > 50 then .[0:47] + "..." else . end),
    type: .type,
    priority: .priority,
    score: .total_score,
    reasoning: .reasoning,
    parent: .parent
  }]
')
fi

# Build JSON output based on mode
# Minimal mode: counts + priority queue + recommendations only (target: <10KB per issue #393)
# Default/Full mode: includes open_issues, active_issues, health, audit data
if [ "$MODE" = "minimal" ]; then
  # Check for any PRs or stale issues to set flags
  HAS_PRS=$(echo "$PR_STATUS" | jq 'length > 0')
  HAS_STALE=$([ "$IN_PROGRESS" -gt 0 ] && echo "true" || echo "false")

  OUTPUT=$(jq -n \
    --arg mode "$MODE" \
    --argjson milestone "$MILESTONE_DATA" \
    --argjson total "$TOTAL" \
    --argjson open "$OPEN" \
    --argjson closed "$CLOSED" \
    --argjson backlog "$BACKLOG" \
    --argjson in_progress "$IN_PROGRESS" \
    --argjson blocked "$BLOCKED" \
    --argjson p0 "$P0" \
    --argjson p1 "$P1" \
    --argjson p2 "$P2" \
    --argjson p3 "$P3" \
    --argjson recommended_next "$RECOMMENDED_NEXT" \
    --argjson has_prs "$HAS_PRS" \
    --argjson has_stale "$HAS_STALE" \
    '{
      mode: $mode,
      milestone: $milestone,
      counts: {
        total: $total,
        open: $open,
        closed: $closed
      },
      by_status: {
        backlog: $backlog,
        in_progress: $in_progress,
        blocked: $blocked
      },
      by_priority: {
        p0: $p0,
        p1: $p1,
        p2: $p2,
        p3: $p3
      },
      recommended_next: $recommended_next,
      flags: {
        has_prs: $has_prs,
        has_in_progress: ($in_progress > 0),
        has_blocked: ($blocked > 0)
      }
    }')
else
  # Default/Full mode: include all data
  OUTPUT=$(jq -n \
    --arg mode "$MODE" \
    --argjson milestone "$MILESTONE_DATA" \
    --argjson total "$TOTAL" \
    --argjson open "$OPEN" \
    --argjson closed "$CLOSED" \
    --argjson backlog "$BACKLOG" \
    --argjson in_progress "$IN_PROGRESS" \
    --argjson blocked "$BLOCKED" \
    --argjson bugs "$BUGS" \
    --argjson features "$FEATURES" \
    --argjson tech_debt "$TECH_DEBT" \
    --argjson docs "$DOCS" \
    --argjson p0 "$P0" \
    --argjson p1 "$P1" \
    --argjson p2 "$P2" \
    --argjson p3 "$P3" \
    --argjson open_issues "$OPEN_ISSUES" \
    --argjson pr_status "$PR_STATUS" \
    --argjson label_audit "$LABEL_AUDIT" \
    --argjson recommended_next "$RECOMMENDED_NEXT" \
    --argjson orphaned_issues "$ORPHANED_ISSUES" \
    '{
      mode: $mode,
      milestone: $milestone,
      counts: {
        total: $total,
        open: $open,
        closed: $closed
      },
      by_status: {
        backlog: $backlog,
        in_progress: $in_progress,
        blocked: $blocked,
        completed: $closed
      },
      by_type: {
        bug: $bugs,
        feature: $features,
        tech_debt: $tech_debt,
        docs: $docs
      },
      by_priority: {
        p0: $p0,
        p1: $p1,
        p2: $p2,
        p3: $p3
      },
      open_issues: $open_issues,
      pr_status: $pr_status,
      label_audit: $label_audit,
      recommended_next: $recommended_next,
      orphaned_issues: $orphaned_issues
    }')
fi

# Add auto-merge results if auto-merge was performed
if [ "$AUTO_MERGE" = true ]; then
  OUTPUT=$(echo "$OUTPUT" | jq --argjson auto_merge "$AUTO_MERGE_RESULT" '. + {auto_merge_results: $auto_merge}')
fi

# Add velocity metrics if requested (only in default or full mode)
if [ "$INCLUDE_VELOCITY" = true ] && [ "$MODE" != "minimal" ]; then
  # Get recently closed issues
  VELOCITY_DATA=$(gh issue list --milestone "$MILESTONE" --state closed \
    --json number,closedAt,createdAt \
    --jq 'sort_by(.closedAt) | reverse | .[0:10]' 2>/dev/null)

  # Get issues closed in last 7 days
  WEEK_AGO=$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d "7 days ago" +%Y-%m-%d)
  CLOSED_THIS_WEEK=$(echo "$VELOCITY_DATA" | jq --arg week_ago "$WEEK_AGO" '[.[] | select(.closedAt >= $week_ago)] | length')

  OUTPUT=$(echo "$OUTPUT" | jq \
    --argjson velocity_data "$VELOCITY_DATA" \
    --argjson closed_this_week "$CLOSED_THIS_WEEK" \
    '. + {
      velocity: {
        closed_this_week: $closed_this_week,
        recent_closures: $velocity_data
      }
    }')
fi

# Add worktree cleanup data (default and full mode only)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$MODE" != "minimal" ] && [ -x "$SCRIPT_DIR/sprint-status-worktrees.sh" ]; then
  WORKTREE_DATA=$("$SCRIPT_DIR/sprint-status-worktrees.sh" 2>/dev/null || echo '{"worktrees_for_cleanup": [], "total_issue_worktrees": 0}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson worktrees "$WORKTREE_DATA" '. + {worktrees: $worktrees}')
fi

# Add unpushed work data (full mode only)
if [ "$MODE" = "full" ] && [ -x "$SCRIPT_DIR/sprint-status-unpushed.sh" ]; then
  UNPUSHED_DATA=$("$SCRIPT_DIR/sprint-status-unpushed.sh" 2>/dev/null || echo '{"unpushed_work": [], "total_with_unpushed": 0}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson unpushed "$UNPUSHED_DATA" '. + {unpushed_work_review: $unpushed}')
fi

# Add repository sync status (full mode only)
if [ "$MODE" = "full" ] && [ -x "$SCRIPT_DIR/sync-main-repo.sh" ]; then
  SYNC_STATUS=$("$SCRIPT_DIR/sync-main-repo.sh" --check 2>/dev/null || echo '{"error": "sync check failed"}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson repo_sync "$SYNC_STATUS" '. + {repo_sync_status: $repo_sync}')
fi

# Add container status data (full mode only)
if [ "$MODE" = "full" ] && [ -x "$SCRIPT_DIR/sprint-status-containers.sh" ]; then
  CONTAINER_DATA=$("$SCRIPT_DIR/sprint-status-containers.sh" 2>/dev/null || echo '{"available": false, "containers": [], "summary": {}}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson containers "$CONTAINER_DATA" '. + {container_status: $containers}')
fi

# Add n8n workflow health (default and full mode - shows in sprint-status by default)
if [ "$MODE" != "minimal" ] && [ -x "$SCRIPT_DIR/sprint-status-n8n.sh" ]; then
  N8N_DATA=$("$SCRIPT_DIR/sprint-status-n8n.sh" 2>/dev/null || echo '{"available": false}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson n8n "$N8N_DATA" '. + {n8n_health: $n8n}')
fi

# Add repo-level CI status (full mode only)
if [ "$MODE" = "full" ] && [ -x "$SCRIPT_DIR/sprint-status-repo-ci.sh" ]; then
  REPO_CI_DATA=$("$SCRIPT_DIR/sprint-status-repo-ci.sh" 2>/dev/null || echo '{"available": false, "repo_level_ci": {"has_failures": false}}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson repo_ci "$REPO_CI_DATA" '. + {repo_ci_status: $repo_ci}')
fi

# Add branch audit status (full mode only)
if [ "$MODE" = "full" ] && [ -x "$SCRIPT_DIR/branch-audit.sh" ]; then
  BRANCH_AUDIT_DATA=$("$SCRIPT_DIR/branch-audit.sh" --audit 2>/dev/null || echo '{"total_remote_branches": 0, "stale_merged_branches": {"count": 0, "branches": []}}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson branch_audit "$BRANCH_AUDIT_DATA" '. + {branch_audit: $branch_audit}')
fi

# Add local CI dashboard status (default and full mode)
if [ "$MODE" != "minimal" ] && [ -x "$SCRIPT_DIR/ci-status-data.sh" ]; then
  LOCAL_CI_DATA=$("$SCRIPT_DIR/ci-status-data.sh" 2>/dev/null || echo '{"overall_status": "unknown", "summary": {"total_modes": 0, "passing": 0, "failing": 0}}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson local_ci "$LOCAL_CI_DATA" '. + {local_ci_status: $local_ci}')
fi

# Add orphaned in-progress issue validation (default and full mode only)
if [ "$MODE" != "minimal" ] && [ -x "$SCRIPT_DIR/validate-in-progress.sh" ]; then
  ORPHANED_IN_PROGRESS=$("$SCRIPT_DIR/validate-in-progress.sh" "$MILESTONE" 2>/dev/null || echo '{"orphaned_issues": [], "total_in_progress": 0, "total_orphaned": 0}')
  OUTPUT=$(echo "$OUTPUT" | jq --argjson orphaned_progress "$ORPHANED_IN_PROGRESS" '. + {orphaned_in_progress: $orphaned_progress}')
fi

# Add dependency data if requested or if there are active issues (full mode only)
if [ "$MODE" = "full" ] && ([ "$INCLUDE_DEPS" = true ] || [ "$IN_PROGRESS" -gt 0 ]); then
  if [ -x "$SCRIPT_DIR/issue-dependencies.sh" ]; then
    # Build dependency graph for milestone
    DEPS_GRAPH=$("$SCRIPT_DIR/issue-dependencies.sh" --graph "$MILESTONE" 2>/dev/null || echo '{"issues": [], "edges": [], "merge_order": []}')

    # Get file overlap data for active worktrees
    FILE_OVERLAPS=$("$SCRIPT_DIR/detect-file-overlaps.sh" 2>/dev/null || echo '{"overlaps": [], "worktrees_analyzed": 0}')

    # Get parallel work analysis (combines dependencies + file overlaps + epic sequencing)
    PARALLEL_ANALYSIS="{}"
    if [ -x "$SCRIPT_DIR/analyze-parallel-work.sh" ]; then
      PARALLEL_ANALYSIS=$("$SCRIPT_DIR/analyze-parallel-work.sh" "$MILESTONE" 2>/dev/null || echo '{"sequential_work": [], "parallel_safe": []}')
    fi

    OUTPUT=$(echo "$OUTPUT" | jq \
      --argjson deps_graph "$DEPS_GRAPH" \
      --argjson file_overlaps "$FILE_OVERLAPS" \
      --argjson parallel_analysis "$PARALLEL_ANALYSIS" \
      '. + {
        dependencies: {
          graph: $deps_graph,
          file_overlaps: $file_overlaps,
          parallel_analysis: $parallel_analysis
        }
      }')
  fi
fi

echo "$OUTPUT"
