#!/bin/bash
set -euo pipefail
# pm-triage-data.sh
# Analyzes open issues in a milestone and generates triage recommendations
# size-ok: multi-dimension triage analysis with priority, type, status, and dependency recommendations
#
# Usage:
#   ./scripts/issue-triage-bulk-data.sh                    # Use active milestone
#   ./scripts/issue-triage-bulk-data.sh --milestone "name" # Specific milestone
#   ./scripts/issue-triage-bulk-data.sh --dry-run          # Preview only
#
# Outputs structured JSON with prioritization, type, status, and dependency recommendations

set -e

# Ensure we're in the repo root (required for gh commands and relative paths)
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

MILESTONE=""
DRY_RUN=false
FAST_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --fast)
      FAST_MODE=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Get active milestone if not specified
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestone-list --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Get milestone metadata
MILESTONE_DATA=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.title=="'"$MILESTONE"'") | {title: .title, due_on: .due_on, open_issues: .open_issues, closed_issues: .closed_issues}')

# Validate milestone exists
if [ -z "$MILESTONE_DATA" ]; then
  echo '{"error": "Milestone not found: '"$MILESTONE"'"}'
  exit 1
fi

# Get all open issues with full details
if $FAST_MODE; then
  # Fast mode: only process needs-triage issues
  OPEN_ISSUES=$(gh issue list --milestone "$MILESTONE" --state open --label "needs-triage" \
    --json number,title,body,labels,createdAt,updatedAt \
    --jq '.')
else
  OPEN_ISSUES=$(gh issue list --milestone "$MILESTONE" --state open \
    --json number,title,body,labels,createdAt,updatedAt \
    --jq '.')
fi

# Ensure OPEN_ISSUES is valid JSON array (default to empty array if null/empty)
if [ -z "$OPEN_ISSUES" ] || [ "$OPEN_ISSUES" = "null" ]; then
  OPEN_ISSUES='[]'
fi

# Get all epic issues for parent detection
SCRIPT_DIR="$(dirname "$0")"
EPICS=$(gh issue list --state open --label "epic" \
  --json number,title,body,labels \
  --jq '.' 2>/dev/null || echo '[]')

# Define label categories
STATUS_LABELS='["backlog", "in-progress", "blocked"]'
TYPE_LABELS='["bug", "feature", "tech-debt", "docs", "epic"]'
PRIORITY_LABELS='["P0", "P1", "P2", "P3"]'

# Keywords for priority detection (word boundaries enforced in jq)
P0_KEYWORDS='["critical", "security", "blocking", "urgent", "production", "outage", "down"]'
P1_KEYWORDS='["important", "high priority", "in-progress"]'
P3_KEYWORDS='["nice-to-have", "low priority", "minor", "cleanup"]'

# Keywords for type detection - use title prefix patterns
# These match Conventional Commits prefixes: fix:, feat:, docs:, etc.
TYPE_PREFIXES='{"bug": ["fix:", "fix(", "bug:", "bug("], "feature": ["feat:", "feat(", "feature:", "add:"], "docs": ["docs:", "docs(", "doc:"], "tech-debt": ["refactor:", "refactor(", "chore:", "perf:"]}'

# Analyze issues and generate recommendations
ANALYSIS=$(echo "$OPEN_ISSUES" | jq --argjson status "$STATUS_LABELS" \
  --argjson type "$TYPE_LABELS" \
  --argjson priority "$PRIORITY_LABELS" \
  --argjson p0_kw "$P0_KEYWORDS" \
  --argjson p1_kw "$P1_KEYWORDS" \
  --argjson p3_kw "$P3_KEYWORDS" \
  --argjson type_prefixes "$TYPE_PREFIXES" \
  '
  # Helper function to check if any keyword matches as a whole word
  def matches_keywords($text; $keywords):
    $text | ascii_downcase as $lower |
    ($keywords | any(. as $kw | $lower | test("\\b" + $kw + "\\b"; "i")));

  # Helper to detect type from title prefix (Conventional Commits style)
  def detect_type_from_prefix($title; $prefixes):
    $title | ascii_downcase as $lower |
    (
      if ($prefixes.bug | any(. as $p | $lower | startswith($p))) then "bug"
      elif ($prefixes.docs | any(. as $p | $lower | startswith($p))) then "docs"
      elif ($prefixes["tech-debt"] | any(. as $p | $lower | startswith($p))) then "tech-debt"
      elif ($prefixes.feature | any(. as $p | $lower | startswith($p))) then "feature"
      else null
      end
    );

  # Analyze each issue
  [.[] | {
    number: .number,
    title: .title,
    body: (.body // ""),
    labels: [.labels[].name],
    created_at: .createdAt,
    updated_at: .updatedAt,

    # Current labels by category
    current: {
      status: ([.labels[].name] | map(select(. as $l | $status | index($l))) | .[0] // null),
      type: ([.labels[].name] | map(select(. as $l | $type | index($l))) | .[0] // null),
      priority: ([.labels[].name] | map(select(. as $l | $priority | index($l))) | .[0] // null)
    },

    # Check for parent label (epic child)
    parent: ([.labels[].name] | map(select(startswith("parent:"))) | .[0] // null),

    # Calculate days since update
    days_stale: (
      (now - (.updatedAt | fromdateiso8601)) / 86400 | floor
    )
  }] |

  # Generate recommendations for each issue
  [.[] |
    # Determine recommended priority
    .title as $title |
    .body as $body |
    .current.type as $current_type |
    .current.status as $current_status |
    .parent as $parent |
    .days_stale as $days_stale |
    ($title + " " + $body) as $text |

    # Detect type from title prefix
    detect_type_from_prefix($title; $type_prefixes) as $prefix_type |

    # Priority recommendation logic
    # Note: Only check P0 keywords in TITLE, not body (body often has example text)
    (
      if matches_keywords($title; $p0_kw) then "P0"
      elif $current_status == "in-progress" then "P1"
      elif $current_type == "bug" or $prefix_type == "bug" then "P1"
      elif matches_keywords($title; $p1_kw) then "P1"
      elif matches_keywords($title; $p3_kw) then "P3"
      elif $current_type == "docs" or $prefix_type == "docs" then "P3"
      elif $parent != null then "P2"
      else "P2"
      end
    ) as $rec_priority |

    # Type recommendation (from prefix only - more reliable)
    $prefix_type as $rec_type |

    # Status recommendation logic
    (
      if $current_status == null then "backlog"
      elif $current_status == "in-progress" and $days_stale >= 3 then "blocked"
      else null
      end
    ) as $rec_status |

    # Generate priority reason
    (
      if matches_keywords($title; $p0_kw) then "Critical/blocking keyword in title"
      elif $current_status == "in-progress" then "Active work (in-progress)"
      elif $current_type == "bug" or $prefix_type == "bug" then "Bug priority"
      elif matches_keywords($title; $p3_kw) then "Low priority keyword in title"
      elif $current_type == "docs" or $prefix_type == "docs" then "Documentation issue"
      elif $parent != null then "Epic child (default P2)"
      else "Standard feature priority"
      end
    ) as $priority_reason |

    # Generate type reason
    (
      if $rec_type == "bug" then "Title uses fix:/bug: prefix"
      elif $rec_type == "docs" then "Title uses docs: prefix"
      elif $rec_type == "tech-debt" then "Title uses refactor:/chore: prefix"
      elif $rec_type == "feature" then "Title uses feat: prefix"
      else null
      end
    ) as $type_reason |

    # Generate status reason
    (
      if $rec_status == "backlog" then "No status label present"
      elif $rec_status == "blocked" then "No activity for \($days_stale) days"
      else null
      end
    ) as $status_reason |

    # Build recommendations object
    . + {
      recommendations: {
        priority: (if .current.priority == null and $rec_priority != null then {
          current: null,
          recommended: $rec_priority,
          reason: $priority_reason
        } else null end),

        type: (if .current.type == null and $rec_type != null then {
          current: null,
          recommended: $rec_type,
          reason: $type_reason
        } elif .current.type != null and $rec_type != null and .current.type != $rec_type then {
          current: .current.type,
          recommended: $rec_type,
          reason: $type_reason
        } else null end),

        status: (if $rec_status != null and .current.status != $rec_status then {
          current: .current.status,
          recommended: $rec_status,
          reason: $status_reason
        } else null end)
      }
    }
  ] |

  # Remove issues with no recommendations and clean up output
  [.[] | select(.recommendations.priority != null or .recommendations.type != null or .recommendations.status != null) | {
    number: .number,
    title: .title,
    current_labels: .labels,
    parent: .parent,
    days_stale: .days_stale,
    recommendations: .recommendations
  }]
')

# Find potential duplicates/similar issues (based on title similarity)
SIMILAR_ISSUES=$(echo "$OPEN_ISSUES" | jq '
  # Simple word-based similarity detection
  def extract_words: ascii_downcase | gsub("[^a-z0-9 ]"; "") | split(" ") | map(select(length > 3));

  # Compare two word arrays for overlap
  def similarity($a; $b):
    if ($a | length) == 0 or ($b | length) == 0 then 0
    else
      ([$a[] | select(. as $w | $b | index($w))] | length) as $overlap |
      ($overlap / ([($a | length), ($b | length)] | min) * 100 | floor)
    end;

  # Build pairs
  . as $issues |
  [range(length)] | [
    .[] as $i |
    .[($i + 1):] | .[] as $j |
    ($issues[$i].title | extract_words) as $a |
    ($issues[$j].title | extract_words) as $b |
    similarity($a; $b) as $sim |
    select($sim >= 50) |
    {
      issues: [$issues[$i].number, $issues[$j].number],
      titles: [$issues[$i].title, $issues[$j].title],
      similarity: $sim,
      suggestion: (if $sim >= 75 then "Mark as duplicate" else "Consider consolidating or linking" end),
      action: (if $sim >= 75 then "duplicate" else "review" end)
    }
  ]
')

# Find parent epic recommendations for issues without parent labels
PARENT_RECOMMENDATIONS=$(echo "$OPEN_ISSUES" "$EPICS" | jq -s '
  # Simple word-based relevance scoring
  def extract_words: ascii_downcase | gsub("[^a-z0-9 ]"; "") | split(" ") | map(select(length > 3));

  def relevance_score($issue_words; $epic_words):
    if ($issue_words | length) == 0 or ($epic_words | length) == 0 then 0
    else
      ([$issue_words[] | select(. as $w | $epic_words | index($w))] | length) as $overlap |
      ($overlap / ($issue_words | length) * 100 | floor)
    end;

  .[0] as $issues | .[1] as $epics |
  [
    $issues[] |
    select((.labels | map(.name) | map(select(startswith("parent:"))) | length) == 0) |  # No parent label
    . as $issue |
    ($issue.title + " " + ($issue.body // "") | extract_words) as $issue_words |
    [
      $epics[] |
      . as $epic |
      ($epic.title + " " + ($epic.body // "") | extract_words) as $epic_words |
      relevance_score($issue_words; $epic_words) as $score |
      select($score >= 40) |
      {epic_number: $epic.number, epic_title: $epic.title, score: $score}
    ] |
    sort_by(-.score) |
    .[0:3] |  # Top 3 matches
    select(length > 0) |
    {
      issue_number: $issue.number,
      issue_title: $issue.title,
      has_needs_triage: ([$issue.labels[].name] | index("needs-triage") != null),
      potential_parents: .,
      recommendation: (if .[0].score >= 60 then "Link to #\(.[0].epic_number)" else "Review matches" end)
    }
  ]
')

# Count recommendations by category
PARENT_COUNT=$(echo "$PARENT_RECOMMENDATIONS" | jq 'length')
DUPLICATE_COUNT=$(echo "$SIMILAR_ISSUES" | jq '[.[] | select(.action == "duplicate")] | length')

SUMMARY=$(echo "$ANALYSIS" | jq --argjson parent_count "$PARENT_COUNT" --argjson dup_count "$DUPLICATE_COUNT" '
  {
    priority_assignments: [.[] | select(.recommendations.priority != null)] | length,
    type_corrections: [.[] | select(.recommendations.type != null)] | length,
    status_updates: [.[] | select(.recommendations.status != null)] | length,
    parent_links: $parent_count,
    duplicates: $dup_count,
    total_issues_analyzed: (. | length)
  } |
  . + {
    total_recommendations: (.priority_assignments + .type_corrections + .status_updates + .parent_links + .duplicates)
  }
')

# Build final output
jq -n \
  --argjson milestone "$MILESTONE_DATA" \
  --argjson analysis "$ANALYSIS" \
  --argjson similar "$SIMILAR_ISSUES" \
  --argjson parents "$PARENT_RECOMMENDATIONS" \
  --argjson summary "$SUMMARY" \
  --argjson dry_run "$DRY_RUN" \
  --argjson fast_mode "$FAST_MODE" \
  '{
    milestone: $milestone,
    dry_run: $dry_run,
    fast_mode: $fast_mode,
    issues_with_recommendations: $analysis,
    parent_recommendations: $parents,
    similar_issues: $similar,
    summary: $summary,
    generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
  }'
