#!/bin/bash
set -euo pipefail
# analyze-parallel-work.sh
# Analyzes which issues can be worked on in parallel vs sequentially
# size-ok: combines dependency graph, file overlap, and epic sequencing analysis
#
# DESCRIPTION:
#   Comprehensive analysis of parallelization opportunities for sprint issues.
#   Combines three orthogonal signals:
#   1. Explicit dependencies (blocks/depends-on from issue bodies)
#   2. File overlap risks (issues touching the same files)
#   3. Epic sequencing (parent:N relationships suggesting ordering)
#
# USAGE:
#   ./scripts/analyze-parallel-work.sh [MILESTONE]
#
# OUTPUT:
#   JSON with parallel vs sequential work recommendations

set -e

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}'
  exit 1
}

MILESTONE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get milestone if not specified (use earliest due date)
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Get backlog issues (available for work)
BACKLOG_ISSUES=$(gh issue list --milestone "$MILESTONE" --label "backlog" --state open --json number,title,labels,body 2>/dev/null)

if [ -z "$BACKLOG_ISSUES" ] || [ "$BACKLOG_ISSUES" = "[]" ]; then
  echo '{
    "milestone": "'"$MILESTONE"'",
    "sequential_work": [],
    "parallel_safe": [],
    "conflict_risks": [],
    "summary": {
      "total_backlog": 0,
      "sequential_required": 0,
      "parallel_ready": 0,
      "conflict_risks": 0
    },
    "recommendations": []
  }'
  exit 0
fi

# Get dependency graph from issue-dependencies.sh
DEPS_DATA="{}"
if [ -x "$SCRIPT_DIR/issue-dependencies.sh" ]; then
  DEPS_DATA=$("$SCRIPT_DIR/issue-dependencies.sh" --graph "$MILESTONE" 2>/dev/null || echo '{"edges": [], "issues": []}')
fi

# Get file overlap data from detect-file-overlaps.sh
# Note: This only works if there are active worktrees; for backlog analysis we check conceptual overlaps
FILE_OVERLAPS="{}"
if [ -x "$SCRIPT_DIR/detect-file-overlaps.sh" ]; then
  FILE_OVERLAPS=$("$SCRIPT_DIR/detect-file-overlaps.sh" 2>/dev/null || echo '{"overlaps": []}')
fi

# Extract dependency edges
DEPENDENCY_EDGES=$(echo "$DEPS_DATA" | jq '[.edges[] | select(.type == "depends_on")]')

# Build comprehensive analysis
ANALYSIS=$(echo "$BACKLOG_ISSUES" | jq --argjson deps "$DEPENDENCY_EDGES" --argjson overlaps "$FILE_OVERLAPS" '
  # Get all backlog issue numbers
  [.[].number] as $backlog_nums |

  # For each backlog issue, analyze constraints
  [.[] |
    .number as $num |
    .body as $body |
    [.labels[].name] as $labels |

    # Check for explicit dependencies on other backlog issues
    ($deps | map(select(.from == $num and ([.to] | inside($backlog_nums)))) | map(.to)) as $depends_on_backlog |

    # Check if other backlog issues depend on this one
    ($deps | map(select(.to == $num and ([.from] | inside($backlog_nums)))) | map(.from)) as $blocks_backlog |

    # Extract parent reference (epic sequencing)
    ([.labels[].name | select(startswith("parent:"))] | first // null |
      if . then (split(":")[1] | tonumber) else null end) as $parent |

    # Check if this issue is an epic with children in backlog
    (if ($labels | any(. == "epic")) then
      [$backlog_nums[] | . as $candidate |
        if ($backlog_nums | index($candidate)) then
          # Check if candidate has parent:$num label (would need to query, simplified here)
          null
        else null end
      ] | map(select(. != null))
    else [] end) as $children |

    # Determine constraint type
    {
      number: $num,
      title: .title,
      labels: $labels,
      constraints: {
        explicit_deps: $depends_on_backlog,
        blocks_issues: $blocks_backlog,
        parent_epic: $parent,
        has_children: (($labels | any(. == "epic")) and $children != [])
      },
      has_constraints: (
        ($depends_on_backlog | length > 0) or
        ($blocks_backlog | length > 0) or
        $parent != null or
        (($labels | any(. == "epic")) and $children != [])
      )
    }
  ] |

  # Classify issues
  {
    sequential_work: [.[] | select(.has_constraints == true)],
    parallel_safe: [.[] | select(.has_constraints == false)]
  } |

  # Add conflict risk analysis
  . + {
    conflict_risks: (
      # Check for issues with same parent (may need sequencing within epic)
      [.sequential_work[] | select(.constraints.parent_epic != null)] |
      group_by(.constraints.parent_epic) |
      map(select(length > 1)) |
      map({
        parent_epic: .[0].constraints.parent_epic,
        issues: [.[].number],
        risk: "shared_epic",
        description: "Multiple issues in same epic - consider sequencing"
      })
    )
  } |

  # Generate summary and recommendations
  . + {
    summary: {
      total_backlog: ((.sequential_work | length) + (.parallel_safe | length)),
      sequential_required: (.sequential_work | length),
      parallel_ready: (.parallel_safe | length),
      conflict_risks: (.conflict_risks | length)
    },
    recommendations: (
      [
        # Recommend foundational issues first
        (if (.sequential_work | map(select(.constraints.blocks_issues | length > 0)) | length) > 0 then
          {
            priority: 1,
            action: "Complete foundational issues first",
            issues: [.sequential_work[] | select(.constraints.blocks_issues | length > 0) | .number],
            reason: "These issues block other work"
          }
        else empty end),

        # Recommend epic parents before children
        (if (.sequential_work | map(select(.constraints.has_children == true)) | length) > 0 then
          {
            priority: 2,
            action: "Complete epic parents before children",
            issues: [.sequential_work[] | select(.constraints.has_children == true) | .number],
            reason: "Child issues may depend on epic foundation"
          }
        else empty end),

        # Highlight parallel opportunities
        (if (.parallel_safe | length > 1) then
          {
            priority: 3,
            action: "Safe for parallel execution",
            issues: [.parallel_safe[] | .number],
            reason: "No dependencies or conflicts detected"
          }
        else empty end),

        # Warn about conflict risks
        (if (.conflict_risks | length > 0) then
          {
            priority: 4,
            action: "Review for potential conflicts",
            issues: ([.conflict_risks[].issues[]] | unique),
            reason: "Issues may have implicit ordering requirements"
          }
        else empty end)
      ] | sort_by(.priority)
    )
  }
')

# Add file overlap insights if available
if [ "$(echo "$FILE_OVERLAPS" | jq '.overlaps | length')" -gt 0 ]; then
  ANALYSIS=$(echo "$ANALYSIS" | jq --argjson overlaps "$FILE_OVERLAPS" '
    .file_overlap_risks = [
      $overlaps.overlaps[] |
      {
        file: .file,
        affected_worktrees: [.worktrees[].issue],
        risk_level: (if (.worktrees | length) >= 3 then "high"
                     elif (.worktrees | length) == 2 then "medium"
                     else "low" end)
      }
    ]
  ')
fi

# Build final output with milestone context
jq -n \
  --arg milestone "$MILESTONE" \
  --argjson analysis "$ANALYSIS" \
  '
  {
    milestone: $milestone,
    sequential_work: $analysis.sequential_work,
    parallel_safe: $analysis.parallel_safe,
    conflict_risks: $analysis.conflict_risks,
    file_overlap_risks: ($analysis.file_overlap_risks // []),
    summary: $analysis.summary,
    recommendations: $analysis.recommendations
  }
  '
