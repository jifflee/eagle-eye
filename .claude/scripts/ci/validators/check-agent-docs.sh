#!/usr/bin/env bash
# ============================================================
# Script: check-agent-docs.sh
# Purpose: CI check for agent documentation quality enforcement
#
# Runs the agent documentation quality review tool on changed or all
# agent .md files and manifest files. Enforces a minimum quality
# threshold, configurable severity (warn vs block), and scoped to
# only run when agent docs are actually modified.
#
# Usage:
#   ./scripts/ci/check-agent-docs.sh [OPTIONS]
#
# Options:
#   --threshold N      Minimum score (0-100) for pass/fail (default: 70)
#   --severity MODE    warn=exit 0 on failure, block=exit 1 on failure (default: block)
#   --scope MODE       changed=only review changed agent docs, all=review everything (default: changed)
#   --agents-dir DIR   Path to agents directory (default: core/agents)
#   --output FILE      Write JSON report to FILE
#   --no-ai            Skip AI-assisted analysis (static checks only, faster for CI)
#   --verbose          Verbose output
#   --dry-run          Show what would run without running
#   --help             Show this help
#
# Exit codes:
#   0  All agent docs meet quality threshold (or no agent docs changed)
#   1  One or more agent docs below quality threshold (when --severity block)
#   2  Usage/configuration error
#
# Environment variables:
#   AGENT_DOC_THRESHOLD    Override --threshold (0-100)
#   AGENT_DOC_SEVERITY     Override --severity (warn|block)
#   AGENT_DOC_SCOPE        Override --scope (changed|all)
#
# Integration:
#   This script is auto-discovered by run-pipeline.sh via .ci-config.json.
#   Runs in pre-pr and pre-merge modes when agent docs are modified.
#   Only triggers when *.md files in core/agents/ or manifests/*.json
#   are changed (scoped check).
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_SCRIPT="$REPO_ROOT/scripts/review-agent-docs.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

THRESHOLD="${AGENT_DOC_THRESHOLD:-70}"
SEVERITY="${AGENT_DOC_SEVERITY:-block}"
SCOPE="${AGENT_DOC_SCOPE:-changed}"
AGENTS_DIR="$REPO_ROOT/core/agents"
OUTPUT_FILE=""
USE_AI=false
VERBOSE=false
DRY_RUN=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ──────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)   THRESHOLD="$2"; shift 2 ;;
    --severity)    SEVERITY="$2"; shift 2 ;;
    --scope)       SCOPE="$2"; shift 2 ;;
    --agents-dir)  AGENTS_DIR="$2"; shift 2 ;;
    --output)      OUTPUT_FILE="$2"; shift 2 ;;
    --no-ai)       USE_AI=false; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --help|-h)     show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

# Validate threshold is a number in range
if ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]] || [[ "$THRESHOLD" -gt 100 ]]; then
  echo -e "${RED}[ERROR]${NC} --threshold must be an integer 0-100 (got: $THRESHOLD)" >&2
  exit 2
fi

# Validate severity
if [[ "$SEVERITY" != "warn" && "$SEVERITY" != "block" ]]; then
  echo -e "${RED}[ERROR]${NC} --severity must be 'warn' or 'block' (got: $SEVERITY)" >&2
  exit 2
fi

# Validate scope
if [[ "$SCOPE" != "changed" && "$SCOPE" != "all" ]]; then
  echo -e "${RED}[ERROR]${NC} --scope must be 'changed' or 'all' (got: $SCOPE)" >&2
  exit 2
fi

# Review script must exist
if [[ ! -f "$REVIEW_SCRIPT" ]]; then
  echo -e "${RED}[ERROR]${NC} Review script not found: $REVIEW_SCRIPT" >&2
  exit 2
fi

if [[ ! -x "$REVIEW_SCRIPT" ]]; then
  echo -e "${RED}[ERROR]${NC} Review script is not executable: $REVIEW_SCRIPT" >&2
  exit 2
fi

# ─── Detect Changed Agent Files ───────────────────────────────────────────────

# Returns a list of agent names that have changed (relative to HEAD or staged)
get_changed_agent_names() {
  local changed_names=()

  # Try git diff for staged changes (pre-commit) and committed changes (pre-pr/pre-merge)
  local changed_files=""
  if changed_files=$(git diff --name-only HEAD 2>/dev/null); then
    : # committed changes since HEAD
  fi
  # Also include staged files
  local staged_files=""
  if staged_files=$(git diff --cached --name-only 2>/dev/null); then
    : # staged changes
  fi

  # Combine and deduplicate
  local all_changed
  all_changed=$(printf '%s\n%s\n' "$changed_files" "$staged_files" | sort -u | grep -v '^$' || true)

  if [[ -z "$all_changed" ]]; then
    # Fallback: compare to main/master branch if no local changes detected
    local base_branch=""
    for branch in main master dev; do
      if git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null || \
         git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
        base_branch="$branch"
        break
      fi
    done

    if [[ -n "$base_branch" ]]; then
      all_changed=$(git diff --name-only "origin/${base_branch}...HEAD" 2>/dev/null || \
                    git diff --name-only "${base_branch}...HEAD" 2>/dev/null || true)
    fi
  fi

  if [[ -z "$all_changed" ]]; then
    return
  fi

  # Extract agent names from changed files:
  # - core/agents/<name>.md
  # - manifests/<name>.json
  while IFS= read -r file; do
    local agent_name=""
    if [[ "$file" =~ ^core/agents/([^/]+)\.md$ ]]; then
      agent_name="${BASH_REMATCH[1]}"
    elif [[ "$file" =~ ^manifests/([^/]+)\.json$ ]]; then
      agent_name="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$agent_name" ]]; then
      # Verify agent doc actually exists
      local agent_file="$AGENTS_DIR/${agent_name}.md"
      if [[ -f "$agent_file" ]]; then
        changed_names+=("$agent_name")
      fi
    fi
  done <<< "$all_changed"

  # Output unique names
  if [[ ${#changed_names[@]} -gt 0 ]]; then
    printf '%s\n' "${changed_names[@]}" | sort -u
  fi
}

# ─── Print Header ─────────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo -e "${BOLD}Agent Documentation Quality Check${NC}"
  echo -e "Scope: ${CYAN}$SCOPE${NC}  |  Threshold: ${CYAN}$THRESHOLD${NC}  |  Severity: ${CYAN}$SEVERITY${NC}"
  echo "────────────────────────────────────────"
  echo ""
}

# ─── Run Review ───────────────────────────────────────────────────────────────

run_review() {
  local -a review_args=()

  review_args+=("--agents-dir" "$AGENTS_DIR")
  review_args+=("--format" "json")
  review_args+=("--threshold" "$THRESHOLD")

  if [[ "$USE_AI" == "false" ]]; then
    review_args+=("--no-ai")
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    review_args+=("--verbose")
  fi

  if [[ -n "$OUTPUT_FILE" ]]; then
    review_args+=("--output" "$OUTPUT_FILE")
  fi

  # Add single agent or run batch
  if [[ "${1:-}" == "--agent" ]] && [[ -n "${2:-}" ]]; then
    review_args+=("--agent" "$2")
  fi

  "$REVIEW_SCRIPT" "${review_args[@]}"
}

# ─── Format Results ───────────────────────────────────────────────────────────

format_results() {
  local json_output="$1"
  local threshold="$2"

  local agents_reviewed average_score agents_below
  agents_reviewed=$(echo "$json_output" | jq '.summary.agents_reviewed')
  average_score=$(echo "$json_output" | jq '.summary.average_score')
  agents_below=$(echo "$json_output" | jq '.summary.agents_below_threshold // 0')

  echo ""
  echo -e "${BOLD}Results:${NC}"
  echo "  Agents reviewed:     $agents_reviewed"
  echo "  Average score:       $average_score/100"
  echo "  Quality threshold:   $threshold/100"
  echo "  Below threshold:     $agents_below"
  echo ""

  # Show per-agent summary table
  echo -e "${BOLD}Agent Quality Scores:${NC}"
  echo ""
  printf "  %-35s  %6s  %5s  %s\n" "AGENT" "SCORE" "GRADE" "STATUS"
  printf "  %-35s  %6s  %5s  %s\n" "─────────────────────────────────────" "──────" "─────" "──────"

  echo "$json_output" | jq -r --argjson thresh "$threshold" '
    .agents[] |
    [
      .agent,
      (.total_score | tostring),
      .grade,
      (if .total_score >= $thresh then "PASS" else "FAIL" end)
    ] | @tsv
  ' | while IFS=$'\t' read -r agent score grade status; do
    local status_color="$GREEN"
    if [[ "$status" == "FAIL" ]]; then
      status_color="$RED"
    fi
    printf "  %-35s  %6s  %5s  %b%s%b\n" \
      "$agent" "$score" "$grade" "$status_color" "$status" "$NC"
  done

  echo ""

  # Show failing agents with details
  local failing_count
  failing_count=$(echo "$json_output" | jq --argjson thresh "$threshold" \
    '[.agents[] | select(.total_score < $thresh)] | length')

  if [[ "$failing_count" -gt 0 ]]; then
    echo -e "${RED}${BOLD}Agents Below Quality Threshold ($threshold):${NC}"
    echo ""

    echo "$json_output" | jq -r --argjson thresh "$threshold" '
      .agents[] | select(.total_score < $thresh) |
      "  Agent: \(.agent) (score: \(.total_score)/100, grade: \(.grade))\n" +
      "  Issues:\n" +
      (
        .dimensions[] |
        select(.issues | length > 0) |
        "    [\(.dimension)] " + (.issues | join(", "))
      ) + "\n" +
      "  Suggestions:\n" +
      (.suggestions[:3] | map("    • " + .) | join("\n")) + "\n"
    ' 2>/dev/null || true

    echo ""
    echo -e "${BOLD}How to fix:${NC}"
    echo "  1. Run the review tool for detailed analysis:"
    echo "     ./scripts/review-agent-docs.sh --format markdown --verbose"
    echo "  2. See documentation standards:"
    echo "     docs/AGENT_DOC_REVIEW.md"
    echo "  3. Key improvements to make:"
    echo "     • Add YAML frontmatter with name, description, and model fields"
    echo "     • Include ROLE, OBJECTIVES, BOUNDARIES, and HOW YOU WORK sections"
    echo "     • Add MUST NOT constraints and escalation paths"
    echo "     • Create/update manifests/<name>.json with trust_tier and blocked_operations"
    echo ""
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  print_header

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run agent doc quality check with:"
    echo "  Scope:     $SCOPE"
    echo "  Threshold: $THRESHOLD"
    echo "  Severity:  $SEVERITY"
    echo "  AI:        ${USE_AI}"
    echo "  Agents dir: $AGENTS_DIR"
    exit 0
  fi

  # ── Scope: changed ────────────────────────────────────────────────────────

  if [[ "$SCOPE" == "changed" ]]; then
    echo -e "${BLUE}[INFO]${NC} Detecting changed agent docs..."

    local changed_agents=()
    while IFS= read -r agent; do
      [[ -n "$agent" ]] && changed_agents+=("$agent")
    done < <(get_changed_agent_names || true)

    if [[ ${#changed_agents[@]} -eq 0 ]]; then
      echo -e "${GREEN}✓${NC} No agent docs changed — skipping quality check"
      echo ""
      exit 0
    fi

    echo -e "${BLUE}[INFO]${NC} Found ${#changed_agents[@]} changed agent doc(s): ${changed_agents[*]}"
    echo ""

    local overall_exit=0
    local all_json_results='{"summary":{"agents_reviewed":0,"average_score":0,"agents_below_threshold":0},"agents":[]}'

    for agent_name in "${changed_agents[@]}"; do
      echo -e "${BLUE}[CHECK]${NC} Reviewing: $agent_name"

      local json_output exit_code=0
      json_output=$(run_review --agent "$agent_name" 2>/dev/null) || exit_code=$?

      # Aggregate results
      all_json_results=$(echo "$all_json_results $json_output" | jq -s '
        {
          "summary": {
            "agents_reviewed": (.[0].summary.agents_reviewed + .[1].summary.agents_reviewed),
            "average_score": (
              if (.[0].summary.agents_reviewed + .[1].summary.agents_reviewed) > 0
              then ((.[0].summary.average_score * .[0].summary.agents_reviewed) +
                    (.[1].summary.average_score * .[1].summary.agents_reviewed)) /
                   (.[0].summary.agents_reviewed + .[1].summary.agents_reviewed)
              else 0
              end | round
            ),
            "agents_below_threshold": (
              (.[0].summary.agents_below_threshold // 0) +
              (.[1].summary.agents_below_threshold // 0)
            )
          },
          "agents": (.[0].agents + .[1].agents)
        }
      ' 2>/dev/null || echo "$json_output")

      # Check threshold for this agent
      local agent_score
      agent_score=$(echo "$json_output" | jq ".agents[0].total_score // 0")
      if [[ "$agent_score" -lt "$THRESHOLD" ]]; then
        overall_exit=1
      fi
    done

    format_results "$all_json_results" "$THRESHOLD"

    # Write combined output file if requested
    if [[ -n "$OUTPUT_FILE" ]]; then
      echo "$all_json_results" | jq '.' > "$OUTPUT_FILE"
      echo -e "${BLUE}[INFO]${NC} Report written to: $OUTPUT_FILE"
    fi

    # Determine final exit code based on severity
    if [[ "$overall_exit" -ne 0 ]]; then
      if [[ "$SEVERITY" == "warn" ]]; then
        echo -e "${YELLOW}⚠  WARN${NC}: One or more agent docs below quality threshold $THRESHOLD"
        echo -e "   Severity is '${SEVERITY}' — not blocking CI"
        echo ""
        exit 0
      else
        echo -e "${RED}✗  FAIL${NC}: One or more agent docs below quality threshold $THRESHOLD"
        echo -e "   Run: ${CYAN}./scripts/review-agent-docs.sh --format markdown --verbose${NC}"
        echo ""
        exit 1
      fi
    else
      echo -e "${GREEN}✓  PASS${NC}: All changed agent docs meet quality threshold $THRESHOLD"
      echo ""
      exit 0
    fi

  fi

  # ── Scope: all ────────────────────────────────────────────────────────────

  echo -e "${BLUE}[INFO]${NC} Reviewing all agent docs in: $AGENTS_DIR"
  echo ""

  local json_output exit_code=0

  local -a review_args=()
  review_args+=("--agents-dir" "$AGENTS_DIR")
  review_args+=("--format" "json")
  review_args+=("--threshold" "$THRESHOLD")
  [[ "$USE_AI" == "false" ]] && review_args+=("--no-ai")
  [[ "$VERBOSE" == "true" ]] && review_args+=("--verbose")
  [[ -n "$OUTPUT_FILE" ]] && review_args+=("--output" "$OUTPUT_FILE")

  json_output=$("$REVIEW_SCRIPT" "${review_args[@]}" 2>/dev/null) || exit_code=$?

  format_results "$json_output" "$THRESHOLD"

  if [[ -n "$OUTPUT_FILE" ]]; then
    echo -e "${BLUE}[INFO]${NC} Report written to: $OUTPUT_FILE"
  fi

  # Agents below threshold → exit_code 1 from review script
  if [[ "$exit_code" -ne 0 ]]; then
    if [[ "$SEVERITY" == "warn" ]]; then
      echo -e "${YELLOW}⚠  WARN${NC}: One or more agent docs below quality threshold $THRESHOLD"
      echo -e "   Severity is '${SEVERITY}' — not blocking CI"
      echo ""
      exit 0
    else
      echo -e "${RED}✗  FAIL${NC}: One or more agent docs below quality threshold $THRESHOLD"
      echo -e "   Run: ${CYAN}./scripts/review-agent-docs.sh --format markdown --verbose${NC}"
      echo ""
      exit 1
    fi
  else
    echo -e "${GREEN}✓  PASS${NC}: All agent docs meet quality threshold $THRESHOLD"
    echo ""
    exit 0
  fi
}

main "$@"
