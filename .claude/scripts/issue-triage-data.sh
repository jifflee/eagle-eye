#!/bin/bash
set -euo pipefail
# issue-triage-data.sh
# Gathers issue data for triage analysis
# size-ok: multi-mode data gathering with single-issue and batch milestone analysis
#
# Usage:
#   ./scripts/issue-triage-data.sh <issue_number>           # Single issue
#   ./scripts/issue-triage-data.sh --milestone "<name>"     # Batch mode
#
# Outputs structured JSON with issue content, detected patterns, and quality scores

set -e

ISSUE_NUMBER=""
MILESTONE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    *)
      ISSUE_NUMBER="$1"
      shift
      ;;
  esac
done

# Function to detect issue type from labels
detect_type_from_labels() {
  local labels="$1"
  if echo "$labels" | grep -qi "bug"; then
    echo "bug"
  elif echo "$labels" | grep -qi "feature"; then
    echo "feature"
  elif echo "$labels" | grep -qi "tech-debt"; then
    echo "tech-debt"
  elif echo "$labels" | grep -qi "docs"; then
    echo "docs"
  else
    echo "unknown"
  fi
}

# Function to detect sections in body
detect_sections() {
  local body="$1"
  local type="$2"

  local has_repro_steps=false
  local has_expected=false
  local has_actual=false
  local has_acceptance=false
  local has_problem=false
  local has_solution=false

  # Bug patterns
  if echo "$body" | grep -qiE "(steps to reproduce|repro|reproduction)"; then
    has_repro_steps=true
  fi
  if echo "$body" | grep -qiE "(expected|should)"; then
    has_expected=true
  fi
  if echo "$body" | grep -qiE "(actual|instead|but)"; then
    has_actual=true
  fi

  # Feature patterns
  if echo "$body" | grep -qiE "(acceptance criteria|\- \[ \])"; then
    has_acceptance=true
  fi

  # Tech-debt patterns
  if echo "$body" | grep -qiE "(problem|issue|technical debt)"; then
    has_problem=true
  fi
  if echo "$body" | grep -qiE "(proposed|solution|approach)"; then
    has_solution=true
  fi

  cat <<EOF
{
  "repro_steps": $has_repro_steps,
  "expected": $has_expected,
  "actual": $has_actual,
  "acceptance_criteria": $has_acceptance,
  "problem_statement": $has_problem,
  "proposed_solution": $has_solution
}
EOF
}

# Function to calculate quality score
calculate_score() {
  local has_type_label="$1"
  local has_priority_label="$2"
  local body_length="$3"
  local sections_json="$4"
  local issue_type="$5"

  local score=0

  # Type label (+10)
  [ "$has_type_label" = "true" ] && score=$((score + 10))

  # Priority label (+10)
  [ "$has_priority_label" = "true" ] && score=$((score + 10))

  # Body length (+10 if >= 50 chars)
  [ "$body_length" -ge 50 ] && score=$((score + 10))

  # Required sections based on type (+40 max)
  local required_found=0
  local required_total=0

  case "$issue_type" in
    bug)
      required_total=3
      if echo "$sections_json" | jq -e '.repro_steps == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      if echo "$sections_json" | jq -e '.expected == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      if echo "$sections_json" | jq -e '.actual == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      ;;
    feature)
      required_total=1
      if echo "$sections_json" | jq -e '.acceptance_criteria == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      ;;
    tech-debt)
      required_total=2
      if echo "$sections_json" | jq -e '.problem_statement == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      if echo "$sections_json" | jq -e '.proposed_solution == true' > /dev/null 2>&1; then
        required_found=$((required_found + 1))
      fi
      ;;
    *)
      # Unknown type, skip section check
      required_total=1
      required_found=1
      ;;
  esac

  if [ "$required_total" -gt 0 ]; then
    local section_score=$((40 * required_found / required_total))
    score=$((score + section_score))
  fi

  # Optional sections bonus (+20 max, +10 per additional section)
  local optional_count=0
  echo "$sections_json" | jq -e '.acceptance_criteria == true' > /dev/null 2>&1 && optional_count=$((optional_count + 1))
  echo "$sections_json" | jq -e '.problem_statement == true' > /dev/null 2>&1 && optional_count=$((optional_count + 1))
  echo "$sections_json" | jq -e '.proposed_solution == true' > /dev/null 2>&1 && optional_count=$((optional_count + 1))

  local optional_bonus=$((optional_count * 10))
  [ "$optional_bonus" -gt 20 ] && optional_bonus=20
  score=$((score + optional_bonus))

  # Cap at 100
  [ "$score" -gt 100 ] && score=100

  echo "$score"
}

# Function to analyze a single issue
analyze_issue() {
  local number="$1"

  # Fetch issue data
  local issue_data=$(gh issue view "$number" --json number,title,body,labels,milestone,state)

  local title=$(echo "$issue_data" | jq -r '.title')
  local body=$(echo "$issue_data" | jq -r '.body // ""')
  local state=$(echo "$issue_data" | jq -r '.state')
  local labels=$(echo "$issue_data" | jq -r '[.labels[].name] | join(",")')
  local milestone=$(echo "$issue_data" | jq -r '.milestone.title // "none"')
  local body_length=${#body}

  # Detect type
  local issue_type=$(detect_type_from_labels "$labels")
  local has_type_label="false"
  [[ "$labels" =~ (bug|feature|tech-debt|docs) ]] && has_type_label="true"

  # Check priority
  local has_priority_label="false"
  [[ "$labels" =~ (P0|P1|P2|P3) ]] && has_priority_label="true"

  # Detect sections
  local sections=$(detect_sections "$body" "$issue_type")

  # Calculate score
  local score=$(calculate_score "$has_type_label" "$has_priority_label" "$body_length" "$sections" "$issue_type")

  # Determine status
  local status="needs_improvement"
  [ "$score" -ge 60 ] && status="acceptable"
  [ "$score" -ge 80 ] && status="ready"

  # Generate missing sections list
  local missing=()
  case "$issue_type" in
    bug)
      echo "$sections" | jq -e '.repro_steps == false' > /dev/null 2>&1 && missing+=("reproduction_steps")
      echo "$sections" | jq -e '.expected == false' > /dev/null 2>&1 && missing+=("expected_behavior")
      echo "$sections" | jq -e '.actual == false' > /dev/null 2>&1 && missing+=("actual_behavior")
      ;;
    feature)
      echo "$sections" | jq -e '.acceptance_criteria == false' > /dev/null 2>&1 && missing+=("acceptance_criteria")
      ;;
    tech-debt)
      echo "$sections" | jq -e '.problem_statement == false' > /dev/null 2>&1 && missing+=("problem_statement")
      echo "$sections" | jq -e '.proposed_solution == false' > /dev/null 2>&1 && missing+=("proposed_solution")
      ;;
  esac

  # Build missing JSON array
  local missing_json="["
  local first=true
  for m in "${missing[@]}"; do
    [ "$first" = true ] && first=false || missing_json+=","
    missing_json+="\"$m\""
  done
  missing_json+="]"

  # Output JSON
  cat <<EOF
{
  "number": $number,
  "title": $(echo "$title" | jq -Rs .),
  "state": "$state",
  "type": "$issue_type",
  "milestone": "$milestone",
  "labels": $(echo "$labels" | jq -Rs 'split(",") | map(select(length > 0))'),
  "body_length": $body_length,
  "has_type_label": $has_type_label,
  "has_priority_label": $has_priority_label,
  "sections": $sections,
  "missing_sections": $missing_json,
  "score": $score,
  "status": "$status"
}
EOF
}

# Main execution
if [ -n "$ISSUE_NUMBER" ]; then
  # Single issue mode
  analyze_issue "$ISSUE_NUMBER"
elif [ -n "$MILESTONE" ]; then
  # Batch mode - get all issues with needs-triage label
  issues=$(gh issue list --milestone "$MILESTONE" --label "needs-triage" --json number --jq '.[].number')

  if [ -z "$issues" ]; then
    # If no needs-triage issues, return empty result
    cat <<EOF
{
  "milestone": "$MILESTONE",
  "issues": [],
  "summary": {
    "total": 0,
    "needs_improvement": 0,
    "acceptable": 0,
    "ready": 0,
    "average_score": 0
  }
}
EOF
    exit 0
  fi

  # Analyze each issue
  results="["
  first=true
  total_score=0
  count=0
  needs_improvement=0
  acceptable=0
  ready=0

  for num in $issues; do
    result=$(analyze_issue "$num")
    [ "$first" = true ] && first=false || results+=","
    results+="$result"

    score=$(echo "$result" | jq -r '.score')
    status=$(echo "$result" | jq -r '.status')
    total_score=$((total_score + score))
    count=$((count + 1))

    case "$status" in
      needs_improvement) needs_improvement=$((needs_improvement + 1)) ;;
      acceptable) acceptable=$((acceptable + 1)) ;;
      ready) ready=$((ready + 1)) ;;
    esac
  done

  results+="]"

  # Calculate average
  avg_score=0
  [ "$count" -gt 0 ] && avg_score=$((total_score / count))

  cat <<EOF
{
  "milestone": "$MILESTONE",
  "issues": $results,
  "summary": {
    "total": $count,
    "needs_improvement": $needs_improvement,
    "acceptable": $acceptable,
    "ready": $ready,
    "average_score": $avg_score
  }
}
EOF
else
  echo '{"error": "Usage: issue-triage-data.sh <issue_number> OR --milestone <name>"}'
  exit 1
fi
