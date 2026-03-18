#!/bin/bash
set -euo pipefail
# skill-analyzer-data.sh
# Analyzes skills for token efficiency and identifies scripting opportunities
# size-ok: multi-metric skill analysis with efficiency scoring and recommendations
#
# Usage:
#   ./scripts/audit-skills-data.sh              # Analyze all skills
#   ./scripts/audit-skills-data.sh "capture"    # Analyze specific skill
#   ./scripts/audit-skills-data.sh --detailed   # Include line numbers
#
# Outputs structured JSON with efficiency metrics and recommendations

set -e

SKILL_NAME="${1:-}"
DETAILED=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --detailed)
      DETAILED=true
      shift
      ;;
    *)
      SKILL_NAME="$1"
      shift
      ;;
  esac
done

# Find skill directories
COMMANDS_DIR="core/commands"
SKILLS_DIR="core/skills"
USER_COMMANDS_DIR="$HOME/.claude/commands"

# Create temp directory
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Initialize results array
echo '[]' > "$TMPDIR/results.json"

# Function to analyze a single skill file
analyze_skill() {
  local filepath="$1"
  local filename=$(basename "$filepath" .md)

  # Skip if not a markdown file
  [[ "$filepath" != *.md ]] && return

  # Read file content
  local content=$(cat "$filepath")
  local line_count=$(wc -l < "$filepath" | tr -d ' ')

  # Initialize score at 100
  local score=100
  local patterns=()
  local recommendations=()

  # === DETECT NEGATIVE PATTERNS ===

  # Pattern 1: gh commands without jq piping (token-heavy)
  local gh_without_jq=$(grep -c 'gh \(issue\|pr\|api\)' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  local gh_with_jq=$(grep -c 'gh.*| *jq' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  gh_without_jq=${gh_without_jq:-0}
  gh_with_jq=${gh_with_jq:-0}
  local gh_raw=$((gh_without_jq - gh_with_jq))
  if [ "$gh_raw" -gt 0 ]; then
    # Deduct 5 per raw gh command, max 25
    local deduction=$((gh_raw * 5))
    [ "$deduction" -gt 25 ] && deduction=25
    score=$((score - deduction))
    patterns+=("{\"type\":\"gh-without-jq\",\"count\":$gh_raw,\"impact\":-$deduction}")
  fi

  # Pattern 2: "Parse the output" type instructions
  local parse_count=$(grep -ciE '(parse|analyze|extract) (the |this )?(output|response|result|JSON)' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  parse_count=${parse_count:-0}
  if [ "$parse_count" -gt 0 ]; then
    score=$((score - 10))
    patterns+=("{\"type\":\"claude-parsing\",\"count\":$parse_count,\"impact\":-10}")
  fi

  # Pattern 3: Manual counting/aggregating
  local count_count=$(grep -ciE '(count|total|sum|calculate) (the |how many)' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  count_count=${count_count:-0}
  if [ "$count_count" -gt 0 ]; then
    score=$((score - 10))
    patterns+=("{\"type\":\"manual-counting\",\"count\":$count_count,\"impact\":-10}")
  fi

  # Pattern 4: JSON handling without jq mention
  local json_refs=$(grep -ci 'JSON' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  local jq_refs=$(grep -c 'jq' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  json_refs=${json_refs:-0}
  jq_refs=${jq_refs:-0}
  if [ "$json_refs" -gt 0 ] && [ "$jq_refs" -eq 0 ]; then
    score=$((score - 10))
    patterns+=("{\"type\":\"json-without-jq\",\"count\":$json_refs,\"impact\":-10}")
  fi

  # Pattern 5: No script reference (no optimization)
  local script_refs=$(grep -c 'scripts/' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  script_refs=${script_refs:-0}
  if [ "$script_refs" -eq 0 ]; then
    score=$((score - 30))
    patterns+=("{\"type\":\"no-script-reference\",\"count\":1,\"impact\":-30}")
    recommendations+=("\"Create data-gathering script: scripts/${filename}-data.sh\"")
  fi

  # Pattern 6: No Token Optimization section
  local has_token_section=$(grep -c '## Token Optimization' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  has_token_section=${has_token_section:-0}
  if [ "$has_token_section" -eq 0 ]; then
    score=$((score - 15))
    patterns+=("{\"type\":\"no-optimization-docs\",\"count\":1,\"impact\":-15}")
    recommendations+=("\"Add Token Optimization section documenting efficiency\"")
  fi

  # Pattern 7: Format as table/list instructions (Claude formatting)
  local format_count=$(grep -ciE '(format|display|output) (as |in )?(table|markdown|list)' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  format_count=${format_count:-0}
  if [ "$format_count" -gt 2 ]; then
    score=$((score - 5))
    patterns+=("{\"type\":\"formatting-instructions\",\"count\":$format_count,\"impact\":-5}")
  fi

  # === DETECT POSITIVE PATTERNS ===

  # Bonus 1: Has Token Optimization section
  if [ "$has_token_section" -gt 0 ]; then
    score=$((score + 10))
    patterns+=("{\"type\":\"has-optimization-docs\",\"count\":1,\"impact\":10}")
  fi

  # Bonus 2: References data script
  local data_script_refs=$(grep -c '\-data\.sh' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  data_script_refs=${data_script_refs:-0}
  if [ "$data_script_refs" -gt 0 ]; then
    score=$((score + 15))
    patterns+=("{\"type\":\"has-data-script\",\"count\":$data_script_refs,\"impact\":15}")
  fi

  # Bonus 3: Uses jq for JSON
  if [ "$jq_refs" -gt 0 ]; then
    score=$((score + 10))
    patterns+=("{\"type\":\"uses-jq\",\"count\":$jq_refs,\"impact\":10}")
  fi

  # Bonus 4: Has batch/single-pass language
  local batch_refs=$(grep -ciE '(batch|single pass|one (api )?call)' "$filepath" 2>/dev/null | tr -d '[:space:]' || echo 0)
  batch_refs=${batch_refs:-0}
  if [ "$batch_refs" -gt 0 ]; then
    score=$((score + 5))
    patterns+=("{\"type\":\"batch-language\",\"count\":$batch_refs,\"impact\":5}")
  fi

  # Ensure score stays in bounds
  [ "$score" -lt 0 ] && score=0
  [ "$score" -gt 100 ] && score=100

  # Estimate tokens (rough heuristic based on patterns)
  local est_current=$((500 + (100 - score) * 30))
  local est_optimized=$((500 + (100 - 85) * 15))
  [ "$score" -ge 80 ] && est_optimized=$est_current

  # Build patterns JSON array
  local patterns_json="["
  local first=true
  for p in "${patterns[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      patterns_json+=","
    fi
    patterns_json+="$p"
  done
  patterns_json+="]"

  # Build recommendations JSON array
  local recommendations_json="["
  first=true
  for r in "${recommendations[@]}"; do
    if [ "$first" = true ]; then
      first=false
    else
      recommendations_json+=","
    fi
    recommendations_json+="$r"
  done
  recommendations_json+="]"

  # Determine complexity
  local complexity="low"
  [ "$line_count" -gt 100 ] && complexity="medium"
  [ "$line_count" -gt 250 ] && complexity="high"

  # Determine score category
  local category="needs-work"
  [ "$score" -ge 50 ] && category="fair"
  [ "$score" -ge 80 ] && category="good"

  # Determine effort to optimize
  local effort="easy"
  [ "$score" -lt 60 ] && effort="medium"
  [ "$score" -lt 40 ] && effort="hard"

  # Output JSON for this skill
  cat <<EOF
{
  "name": "$filename",
  "path": "$filepath",
  "score": $score,
  "category": "$category",
  "line_count": $line_count,
  "complexity": "$complexity",
  "patterns": $patterns_json,
  "recommendations": $recommendations_json,
  "tokens_estimate": {
    "current": $est_current,
    "optimized": $est_optimized,
    "savings_percent": $(( (est_current - est_optimized) * 100 / est_current ))
  },
  "effort": "$effort"
}
EOF
}

# Analyze skills
skills_json="["
first_skill=true

# Function to add skill to results
add_skill_result() {
  local result="$1"
  if [ "$first_skill" = true ]; then
    first_skill=false
  else
    skills_json+=","
  fi
  skills_json+="$result"
}

# If specific skill requested
if [ -n "$SKILL_NAME" ] && [ "$SKILL_NAME" != "--detailed" ]; then
  # Try to find the skill
  if [ -f "$COMMANDS_DIR/$SKILL_NAME.md" ]; then
    result=$(analyze_skill "$COMMANDS_DIR/$SKILL_NAME.md")
    add_skill_result "$result"
  elif [ -f "$SKILLS_DIR/$SKILL_NAME/SKILL.md" ]; then
    result=$(analyze_skill "$SKILLS_DIR/$SKILL_NAME/SKILL.md")
    add_skill_result "$result"
  elif [ -f "$USER_COMMANDS_DIR/$SKILL_NAME.md" ]; then
    result=$(analyze_skill "$USER_COMMANDS_DIR/$SKILL_NAME.md")
    add_skill_result "$result"
  else
    echo '{"error": "Skill not found: '"$SKILL_NAME"'"}'
    exit 1
  fi
else
  # Analyze all skills in commands directory
  if [ -d "$COMMANDS_DIR" ]; then
    for file in "$COMMANDS_DIR"/*.md; do
      [ -f "$file" ] || continue
      result=$(analyze_skill "$file")
      add_skill_result "$result"
    done
  fi

  # Analyze all skills in skills directory
  if [ -d "$SKILLS_DIR" ]; then
    for dir in "$SKILLS_DIR"/*/; do
      [ -d "$dir" ] || continue
      if [ -f "${dir}SKILL.md" ]; then
        result=$(analyze_skill "${dir}SKILL.md")
        add_skill_result "$result"
      fi
    done
  fi

  # Analyze all skills in user commands directory
  if [ -d "$USER_COMMANDS_DIR" ]; then
    for file in "$USER_COMMANDS_DIR"/*.md; do
      [ -f "$file" ] || continue
      result=$(analyze_skill "$file")
      add_skill_result "$result"
    done
  fi
fi

skills_json+="]"

# Calculate summary statistics
total_skills=$(echo "$skills_json" | jq 'length')
avg_score=$(echo "$skills_json" | jq 'if length > 0 then ([.[].score] | add / length | floor) else 0 end')
good_count=$(echo "$skills_json" | jq '[.[] | select(.category == "good")] | length')
fair_count=$(echo "$skills_json" | jq '[.[] | select(.category == "fair")] | length')
needs_work_count=$(echo "$skills_json" | jq '[.[] | select(.category == "needs-work")] | length')

# Calculate total token estimates
total_current=$(echo "$skills_json" | jq '[.[].tokens_estimate.current] | add // 0')
total_optimized=$(echo "$skills_json" | jq '[.[].tokens_estimate.optimized] | add // 0')

# Build final output
cat <<EOF
{
  "summary": {
    "total_skills": $total_skills,
    "average_score": $avg_score,
    "by_category": {
      "good": $good_count,
      "fair": $fair_count,
      "needs_work": $needs_work_count
    },
    "token_estimates": {
      "total_current": $total_current,
      "total_optimized": $total_optimized,
      "potential_savings_percent": $(( total_current > 0 ? (total_current - total_optimized) * 100 / total_current : 0 ))
    }
  },
  "skills": $skills_json,
  "analyzed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
