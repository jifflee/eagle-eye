#!/usr/bin/env bash
#
# review-agent-docs.sh - Agent documentation quality review using opus model
# Feature #866 - Implement agent documentation review tool with quality scoring
# size-ok: comprehensive multi-dimension quality scoring with AI-assisted analysis
#
# Evaluates agent .md files against framework documentation standards.
# Uses the opus model for deep analysis of instruction quality.
#
# Usage:
#   ./scripts/review-agent-docs.sh                          # Review all agents
#   ./scripts/review-agent-docs.sh --agent architect        # Review single agent
#   ./scripts/review-agent-docs.sh --format json            # JSON output
#   ./scripts/review-agent-docs.sh --format markdown        # Markdown report
#   ./scripts/review-agent-docs.sh --output report.json     # Save to file
#   ./scripts/review-agent-docs.sh --threshold 70           # Fail below score
#   ./scripts/review-agent-docs.sh --no-ai                  # Skip AI analysis
#   ./scripts/review-agent-docs.sh --agents-dir /path/to    # Custom agents dir
#
# Exit codes:
#   0 - All agents meet threshold (or no threshold set)
#   1 - One or more agents below threshold
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────

AGENTS_DIR="$REPO_ROOT/core/agents"
MANIFESTS_DIR="$REPO_ROOT/manifests"
TARGET_AGENT=""
OUTPUT_FORMAT="text"
OUTPUT_FILE=""
SCORE_THRESHOLD=0
USE_AI=true
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Argument parsing ─────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 [options]

Review agent documentation files for quality using scoring dimensions.

Options:
  --agent NAME       Review a single agent (e.g. architect, pm-orchestrator)
  --agents-dir DIR   Path to agents directory (default: core/agents)
  --format FORMAT    Output format: text (default), json, markdown
  --output FILE      Save report to file
  --threshold N      Exit 1 if any agent scores below N (0-100)
  --no-ai            Skip AI-assisted analysis (static checks only)
  --verbose          Show detailed per-dimension breakdown
  -h, --help         Show this help

Scoring dimensions (each 0-20 points, total 0-100):
  completeness   - Required sections, frontmatter fields, content depth
  clarity        - Readability, actionable descriptions, concrete examples
  specificity    - Concrete tasks vs vague descriptions, measurable criteria
  boundaries     - Clear MUST/MUST NOT constraints, role definition
  constraints    - Explicit constraints, blocked operations alignment

Examples:
  $0                          # Review all agents
  $0 --agent architect        # Review single agent
  $0 --format json            # Machine-readable output
  $0 --threshold 70           # CI gate: fail if any agent < 70
  $0 --no-ai --format json    # Fast static-only review
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      TARGET_AGENT="$2"
      shift 2
      ;;
    --agents-dir)
      AGENTS_DIR="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --threshold)
      SCORE_THRESHOLD="$2"
      shift 2
      ;;
    --no-ai)
      USE_AI=false
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [ ! -d "$AGENTS_DIR" ]; then
  echo "Error: Agents directory not found: $AGENTS_DIR" >&2
  exit 2
fi

# ─── Static scoring functions ─────────────────────────────────────────────────

# Score completeness (0-20): required sections, frontmatter, content depth
score_completeness() {
  local file="$1"
  local score=0
  local issues=()
  local passes=()

  # Frontmatter presence (4 pts)
  local fm_count
  fm_count=$(grep -c "^---$" "$file" 2>/dev/null || echo 0)
  if [ "$fm_count" -ge 2 ]; then
    score=$((score + 2))
    passes+=("Has YAML frontmatter")

    # name field (1 pt)
    if grep -q "^name:" "$file"; then
      score=$((score + 1))
      passes+=("Has 'name' field")
    else
      issues+=("Missing 'name' field in frontmatter")
    fi

    # description field (1 pt)
    if grep -q "^description:" "$file"; then
      score=$((score + 1))
      passes+=("Has 'description' field")
    else
      issues+=("Missing 'description' field in frontmatter")
    fi
  else
    issues+=("Missing YAML frontmatter")
    issues+=("Missing 'name' field")
    issues+=("Missing 'description' field")
  fi

  # Required sections (8 pts)
  if grep -qi "^## ROLE" "$file"; then
    score=$((score + 2))
    passes+=("Has ROLE section")
  else
    issues+=("Missing '## ROLE' section")
  fi

  if grep -qiE "^## (PRIMARY OBJECTIVES|OBJECTIVES)" "$file"; then
    score=$((score + 2))
    passes+=("Has OBJECTIVES section")
  else
    issues+=("Missing '## OBJECTIVES' section")
  fi

  if grep -qi "^## BOUNDARIES" "$file"; then
    score=$((score + 2))
    passes+=("Has BOUNDARIES section")
  else
    issues+=("Missing '## BOUNDARIES' section")
  fi

  if grep -qiE "^## (HOW YOU WORK|METHOD|EXECUTION)" "$file"; then
    score=$((score + 2))
    passes+=("Has execution/method section")
  else
    issues+=("Missing execution method section (HOW YOU WORK/METHOD/EXECUTION)")
  fi

  # Content depth: body length (8 pts)
  local line_count
  line_count=$(wc -l < "$file")
  if [ "$line_count" -ge 80 ]; then
    score=$((score + 4))
    passes+=("Substantial content (${line_count} lines)")
  elif [ "$line_count" -ge 40 ]; then
    score=$((score + 2))
    issues+=("Moderate content depth (${line_count} lines, recommend 80+)")
  else
    issues+=("Thin content (${line_count} lines, recommend 80+)")
  fi

  # Subsections (numbered steps, bullet lists)
  local subsection_count
  subsection_count=$(grep -cE "^### " "$file" 2>/dev/null || echo 0)
  if [ "$subsection_count" -ge 3 ]; then
    score=$((score + 4))
    passes+=("Well-structured with ${subsection_count} subsections")
  elif [ "$subsection_count" -ge 1 ]; then
    score=$((score + 2))
    issues+=("Add more subsections for better structure (found ${subsection_count})")
  else
    issues+=("No subsections (###) found - consider structuring with subsections")
  fi

  # Cap at 20
  [ "$score" -gt 20 ] && score=20

  _build_dimension_json "completeness" "$score" "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" "$(printf '%s\n' "${passes[@]}" | jq -R . | jq -s .)"
}

# Score clarity (0-20): readability, actionable descriptions
score_clarity() {
  local file="$1"
  local score=0
  local issues=()
  local passes=()

  # Description starts with "Use this agent" (2 pts)
  if grep -qiE "^description:.*Use this agent" "$file"; then
    score=$((score + 2))
    passes+=("Description follows 'Use this agent to...' convention")
  else
    issues+=("Description should start with 'Use this agent to...'")
  fi

  # Active voice indicators: bullet lists with action verbs (4 pts)
  local bullet_count
  bullet_count=$(grep -cE "^- [A-Z]" "$file" 2>/dev/null || echo 0)
  if [ "$bullet_count" -ge 10 ]; then
    score=$((score + 4))
    passes+=("Rich action-oriented bullet lists (${bullet_count} items)")
  elif [ "$bullet_count" -ge 5 ]; then
    score=$((score + 2))
    passes+=("Good use of bullet lists (${bullet_count} items)")
  else
    issues+=("Add more action-oriented bullet lists (found ${bullet_count})")
  fi

  # Concrete examples or "e.g." / "for example" (2 pts)
  if grep -qiE "(e\.g\.|for example|such as|example:)" "$file"; then
    score=$((score + 2))
    passes+=("Contains concrete examples")
  else
    issues+=("Add concrete examples (e.g., ...) to improve clarity")
  fi

  # Numbered steps / ordered workflow (4 pts)
  local numbered_steps
  numbered_steps=$(grep -cE "^[0-9]+\." "$file" 2>/dev/null || echo 0)
  if [ "$numbered_steps" -ge 5 ]; then
    score=$((score + 4))
    passes+=("Clear numbered workflow steps (${numbered_steps} steps)")
  elif [ "$numbered_steps" -ge 2 ]; then
    score=$((score + 2))
    passes+=("Some numbered steps (${numbered_steps})")
  else
    issues+=("Add numbered steps to describe workflow (found ${numbered_steps})")
  fi

  # Invocation context: When to use / when not to use (4 pts)
  if grep -qiE "(When to (use|invoke|call)|Invoke when)" "$file"; then
    score=$((score + 2))
    passes+=("Has 'when to invoke' guidance")
  else
    issues+=("Add 'when to invoke' or 'When to use' guidance")
  fi

  if grep -qiE "(Do NOT|MUST NOT|never|should not)" "$file"; then
    score=$((score + 2))
    passes+=("Has explicit negative constraints")
  else
    issues+=("Add explicit 'Do NOT' / 'MUST NOT' statements")
  fi

  # Consistent formatting: bold emphasis (2 pts)
  local bold_count
  bold_count=$(grep -cE "\*\*[^*]+\*\*" "$file" 2>/dev/null || echo 0)
  if [ "$bold_count" -ge 3 ]; then
    score=$((score + 2))
    passes+=("Good use of emphasis (${bold_count} bold items)")
  else
    issues+=("Add bold emphasis for key terms (found ${bold_count})")
  fi

  # Communication style section (2 pts)
  if grep -qiE "^## (COMMUNICATION|OUTPUT FORMAT|STYLE)" "$file"; then
    score=$((score + 2))
    passes+=("Has communication/output format section")
  else
    issues+=("Add communication style or output format section")
  fi

  [ "$score" -gt 20 ] && score=20

  _build_dimension_json "clarity" "$score" "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" "$(printf '%s\n' "${passes[@]}" | jq -R . | jq -s .)"
}

# Score specificity (0-20): concrete tasks vs vague descriptions
score_specificity() {
  local file="$1"
  local score=0
  local issues=()
  local passes=()

  # Agent-to-agent interaction references (4 pts)
  local agent_refs
  agent_refs=$(grep -ciE "(agent|orchestrat)" "$file" 2>/dev/null || echo 0)
  if [ "$agent_refs" -ge 5 ]; then
    score=$((score + 4))
    passes+=("Specific agent interaction references (${agent_refs})")
  elif [ "$agent_refs" -ge 2 ]; then
    score=$((score + 2))
    passes+=("Some agent interaction references (${agent_refs})")
  else
    issues+=("Add specific references to which agents this interacts with")
  fi

  # Tool/technology specifics (4 pts)
  local tool_refs
  tool_refs=$(grep -cE "(github|git|bash|json|yaml|api|sdk|cli|jq|curl)" "$file" 2>/dev/null || echo 0)
  if [ "$tool_refs" -ge 5 ]; then
    score=$((score + 4))
    passes+=("Specific technology/tool references (${tool_refs})")
  elif [ "$tool_refs" -ge 2 ]; then
    score=$((score + 2))
    passes+=("Some tool references (${tool_refs})")
  else
    issues+=("Add specific tool/technology references")
  fi

  # Input/output specification (4 pts)
  if grep -qiE "(input|output|return|produc)" "$file"; then
    score=$((score + 2))
    passes+=("Describes inputs or outputs")
  else
    issues+=("Specify expected inputs and outputs")
  fi

  if grep -qiE "(format|structure|schema|json|markdown)" "$file"; then
    score=$((score + 2))
    passes+=("Specifies output format/structure")
  else
    issues+=("Specify output format (JSON, Markdown, etc.)")
  fi

  # Success/failure criteria (4 pts)
  if grep -qiE "(success|succeed|complet|done|finish)" "$file"; then
    score=$((score + 2))
    passes+=("Describes success criteria")
  else
    issues+=("Add success criteria ('You succeed when...')")
  fi

  if grep -qiE "(fail|error|escalat|block|reject)" "$file"; then
    score=$((score + 2))
    passes+=("Describes failure/escalation handling")
  else
    issues+=("Add failure/escalation handling")
  fi

  # SDLC phase specificity (4 pts)
  if grep -qiE "(phase|sdlc|stage|sequence|pipeline|workflow)" "$file"; then
    score=$((score + 4))
    passes+=("References SDLC phase or workflow sequence")
  else
    issues+=("Reference specific SDLC phases or workflow sequences")
  fi

  [ "$score" -gt 20 ] && score=20

  _build_dimension_json "specificity" "$score" "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" "$(printf '%s\n' "${passes[@]}" | jq -R . | jq -s .)"
}

# Score boundaries (0-20): clear role definition, MUST/MUST NOT
score_boundaries() {
  local file="$1"
  local score=0
  local issues=()
  local passes=()

  # MUST NOT constraints (6 pts)
  local must_not_count
  must_not_count=$(grep -cE "MUST NOT|You MUST NOT|Do NOT" "$file" 2>/dev/null || echo 0)
  if [ "$must_not_count" -ge 4 ]; then
    score=$((score + 6))
    passes+=("Strong negative constraints (${must_not_count} MUST NOT statements)")
  elif [ "$must_not_count" -ge 2 ]; then
    score=$((score + 4))
    passes+=("Good negative constraints (${must_not_count})")
  elif [ "$must_not_count" -ge 1 ]; then
    score=$((score + 2))
    issues+=("Add more MUST NOT statements (found ${must_not_count})")
  else
    issues+=("Add explicit MUST NOT / Do NOT constraints")
  fi

  # MUST DO constraints (4 pts)
  local must_count
  must_count=$(grep -cE "^You MUST|^MUST:" "$file" 2>/dev/null || echo 0)
  if [ "$must_count" -ge 3 ]; then
    score=$((score + 4))
    passes+=("Strong positive constraints (${must_count} MUST statements)")
  elif [ "$must_count" -ge 1 ]; then
    score=$((score + 2))
    passes+=("Some positive constraints (${must_count})")
  else
    issues+=("Add 'You MUST' positive constraint statements")
  fi

  # Scope definition: what the agent IS and IS NOT (4 pts)
  if grep -qiE "do(es)? NOT (write|implement|create|modify)" "$file"; then
    score=$((score + 2))
    passes+=("Explicitly states what agent does NOT do")
  else
    issues+=("State explicitly what this agent does NOT do (e.g., 'does not write code')")
  fi

  if grep -qiE "You (are|act as|serve as|function as)" "$file"; then
    score=$((score + 2))
    passes+=("Clear role identity statement")
  else
    issues+=("Add clear role identity ('You are the X agent'/'You act as...')")
  fi

  # Escalation paths (4 pts)
  if grep -qiE "(escalat|hand.?off|refer to|send.*to|invoke.*agent)" "$file"; then
    score=$((score + 4))
    passes+=("Defines escalation paths to other agents")
  else
    issues+=("Define escalation paths (when to involve other agents)")
  fi

  # Uncertainty handling (2 pts)
  if grep -qiE "(unclear|ambig|uncertain|missing|gap)" "$file"; then
    score=$((score + 2))
    passes+=("Handles uncertainty/ambiguity cases")
  else
    issues+=("Describe how to handle unclear or ambiguous situations")
  fi

  [ "$score" -gt 20 ] && score=20

  _build_dimension_json "boundaries" "$score" "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" "$(printf '%s\n' "${passes[@]}" | jq -R . | jq -s .)"
}

# Score constraints (0-20): alignment with manifest constraints
score_constraints() {
  local file="$1"
  local agent_name="$2"
  local score=0
  local issues=()
  local passes=()

  # Manifest alignment check
  local manifest_file="$MANIFESTS_DIR/${agent_name}.json"
  local has_manifest=false

  if [ -f "$manifest_file" ]; then
    has_manifest=true
    score=$((score + 4))
    passes+=("Has corresponding manifest file")

    # Check model field alignment
    local manifest_model
    manifest_model=$(jq -r '.model // "haiku"' "$manifest_file" 2>/dev/null || echo "haiku")
    local doc_model
    doc_model=$(grep "^model:" "$file" 2>/dev/null | sed 's/model: *//' | tr -d '"' "'" | xargs || echo "")

    if [ -n "$doc_model" ]; then
      if [ "$doc_model" = "$manifest_model" ]; then
        score=$((score + 2))
        passes+=("Model field consistent with manifest (${manifest_model})")
      else
        issues+=("Model mismatch: doc says '${doc_model}', manifest says '${manifest_model}'")
      fi
    else
      issues+=("Add 'model:' field to frontmatter")
    fi

    # Check trust tier mentioned (2 pts)
    local manifest_tier
    manifest_tier=$(jq -r '.trust_tier // ""' "$manifest_file" 2>/dev/null || echo "")
    if [ -n "$manifest_tier" ]; then
      score=$((score + 2))
      passes+=("Manifest defines trust tier: ${manifest_tier}")
    else
      issues+=("Manifest missing trust_tier field")
    fi

    # Check blocked operations alignment (4 pts)
    local blocked_ops
    blocked_ops=$(jq -r '.constraints.blocked_operations // [] | join(", ")' "$manifest_file" 2>/dev/null || echo "")
    if [ -n "$blocked_ops" ]; then
      score=$((score + 4))
      passes+=("Manifest defines blocked operations: ${blocked_ops}")
    else
      issues+=("Define blocked_operations in manifest")
    fi
  else
    issues+=("No manifest file found at manifests/${agent_name}.json")
    issues+=("Create manifest to define permissions and constraints")
  fi

  # In-doc constraint quality
  local constraint_count
  constraint_count=$(grep -cE "(blocked|forbidden|prohibited|not allowed|cannot|must not)" "$file" 2>/dev/null || echo 0)
  if [ "$constraint_count" -ge 5 ]; then
    score=$((score + 4))
    passes+=("Rich constraint documentation (${constraint_count} constraint references)")
  elif [ "$constraint_count" -ge 2 ]; then
    score=$((score + 2))
    passes+=("Some constraints documented (${constraint_count})")
  else
    issues+=("Add more explicit constraint documentation (found ${constraint_count})")
  fi

  # Permission tier reference (2 pts)
  if grep -qiE "(T0|T1|T2|T3|READ.?ONLY|WRITE.?LIMITED|WRITE.?FULL|MANAGED)" "$file"; then
    score=$((score + 2))
    passes+=("References permission tier")
  else
    issues+=("Consider referencing permission tier (T0/T1/T2/T3 or READ-ONLY/WRITE-FULL)")
  fi

  # Security/safety constraints (2 pts)
  if grep -qiE "(securit|vulnerabilit|secret|credential|token|auth)" "$file"; then
    score=$((score + 2))
    passes+=("References security considerations")
  else
    issues+=("Add security/safety constraint references if applicable")
  fi

  [ "$score" -gt 20 ] && score=20

  _build_dimension_json "constraints" "$score" "$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)" "$(printf '%s\n' "${passes[@]}" | jq -R . | jq -s .)"
}

# Helper: build dimension JSON - filters empty strings from arrays
_build_dimension_json() {
  local dimension="$1"
  local score="$2"
  local issues_json="$3"
  local passes_json="$4"

  # Filter out empty strings that can result from empty bash arrays
  local filtered_issues filtered_passes
  filtered_issues=$(echo "$issues_json" | jq '[.[] | select(. != "")]')
  filtered_passes=$(echo "$passes_json" | jq '[.[] | select(. != "")]')

  cat <<EOF
{
  "dimension": "$dimension",
  "score": $score,
  "max": 20,
  "issues": $filtered_issues,
  "passes": $filtered_passes
}
EOF
}

# Helper: safely format an array to JSON, handling empty arrays
_array_to_json() {
  if [ "${#@}" -eq 0 ]; then
    echo "[]"
  else
    printf '%s\n' "$@" | jq -R . | jq -s '[.[] | select(. != "")]'
  fi
}

# ─── Per-agent review ─────────────────────────────────────────────────────────

review_agent() {
  local file="$1"
  local agent_name
  agent_name=$(basename "$file" .md)

  if [ "$VERBOSE" = true ]; then
    echo -e "${CYAN}  Reviewing: ${agent_name}${NC}" >&2
  fi

  # Run all dimension scorers
  local dim_completeness dim_clarity dim_specificity dim_boundaries dim_constraints
  dim_completeness=$(score_completeness "$file")
  dim_clarity=$(score_clarity "$file")
  dim_specificity=$(score_specificity "$file")
  dim_boundaries=$(score_boundaries "$file")
  dim_constraints=$(score_constraints "$file" "$agent_name")

  # Extract per-dimension scores
  local s_completeness s_clarity s_specificity s_boundaries s_constraints
  s_completeness=$(echo "$dim_completeness" | jq -r '.score')
  s_clarity=$(echo "$dim_clarity" | jq -r '.score')
  s_specificity=$(echo "$dim_specificity" | jq -r '.score')
  s_boundaries=$(echo "$dim_boundaries" | jq -r '.score')
  s_constraints=$(echo "$dim_constraints" | jq -r '.score')

  local total_score
  total_score=$((s_completeness + s_clarity + s_specificity + s_boundaries + s_constraints))

  # Determine grade
  local grade
  if [ "$total_score" -ge 90 ]; then
    grade="A"
  elif [ "$total_score" -ge 80 ]; then
    grade="B"
  elif [ "$total_score" -ge 70 ]; then
    grade="C"
  elif [ "$total_score" -ge 60 ]; then
    grade="D"
  else
    grade="F"
  fi

  # Collect all issues as top-level suggestions
  local all_issues
  all_issues=$(jq -s '
    [.[].issues[]] | unique
  ' \
    <(echo "$dim_completeness") \
    <(echo "$dim_clarity") \
    <(echo "$dim_specificity") \
    <(echo "$dim_boundaries") \
    <(echo "$dim_constraints"))

  # AI-assisted analysis (if enabled and claude CLI available)
  local ai_analysis="null"
  if [ "$USE_AI" = true ] && command -v claude &>/dev/null; then
    ai_analysis=$(run_ai_analysis "$file" "$agent_name" "$total_score") || ai_analysis="null"
  fi

  cat <<EOF
{
  "agent": "$agent_name",
  "file": "$file",
  "total_score": $total_score,
  "max_score": 100,
  "grade": "$grade",
  "dimensions": [
    $dim_completeness,
    $dim_clarity,
    $dim_specificity,
    $dim_boundaries,
    $dim_constraints
  ],
  "suggestions": $all_issues,
  "ai_analysis": $ai_analysis,
  "reviewed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# ─── AI-assisted analysis ─────────────────────────────────────────────────────

run_ai_analysis() {
  local file="$1"
  local agent_name="$2"
  local static_score="$3"

  # Build a focused prompt for opus
  local prompt
  prompt=$(cat <<PROMPT
Analyze this agent documentation file for quality. Be concise and actionable.

Agent: ${agent_name}
Static score: ${static_score}/100

Documentation content:
$(cat "$file")

Respond with ONLY a valid JSON object (no markdown, no explanation):
{
  "overall_assessment": "one sentence assessment",
  "top_improvements": ["improvement 1", "improvement 2", "improvement 3"],
  "strengths": ["strength 1", "strength 2"],
  "instruction_quality": "high|medium|low",
  "model_appropriateness": "well-matched|over-powered|under-powered",
  "ai_score_adjustment": -5 to 5
}
PROMPT
)

  # Use claude CLI with opus model (pipe mode, non-interactive)
  local ai_response
  ai_response=$(echo "$prompt" | timeout 60 claude --model claude-opus-4-5 --print 2>/dev/null || echo "")

  # Validate and extract JSON from response
  if [ -n "$ai_response" ]; then
    # Try to extract JSON object from response
    local json_part
    json_part=$(echo "$ai_response" | grep -o '{.*}' | head -1 2>/dev/null || echo "")

    if echo "$json_part" | jq empty 2>/dev/null; then
      echo "$json_part"
      return 0
    fi
  fi

  # Fallback: return null if AI analysis failed
  echo "null"
}

# ─── Batch review ─────────────────────────────────────────────────────────────

review_all_agents() {
  local results="[]"
  local agent_files=()

  if [ -n "$TARGET_AGENT" ]; then
    # Single agent mode
    local agent_file="$AGENTS_DIR/${TARGET_AGENT}.md"
    if [ ! -f "$agent_file" ]; then
      echo "Error: Agent file not found: $agent_file" >&2
      exit 2
    fi
    agent_files=("$agent_file")
  else
    # Batch mode: all agent .md files
    while IFS= read -r -d '' f; do
      agent_files+=("$f")
    done < <(find "$AGENTS_DIR" -name "*.md" -type f -print0 2>/dev/null | sort -z)
  fi

  if [ "${#agent_files[@]}" -eq 0 ]; then
    echo "No agent files found in: $AGENTS_DIR" >&2
    exit 2
  fi

  echo -e "${BLUE}Reviewing ${#agent_files[@]} agent(s)...${NC}" >&2

  local agent_results=()
  for f in "${agent_files[@]}"; do
    local result
    result=$(review_agent "$f")
    agent_results+=("$result")
  done

  # Combine results into JSON array
  results=$(printf '%s\n' "${agent_results[@]}" | jq -s '.')

  echo "$results"
}

# ─── Output formatters ────────────────────────────────────────────────────────

format_text() {
  local results="$1"

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         AGENT DOCUMENTATION QUALITY REVIEW                  ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""

  local agent_count total_score avg_score failed_count
  agent_count=$(echo "$results" | jq 'length')
  total_score=$(echo "$results" | jq '[.[].total_score] | add // 0')
  avg_score=$(echo "$results" | jq '[.[].total_score] | add / length | floor // 0')
  failed_count=$(echo "$results" | jq --argjson t "$SCORE_THRESHOLD" '[.[] | select(.total_score < $t)] | length')

  echo "Summary:"
  echo "  Agents reviewed:  $agent_count"
  echo "  Average score:    ${avg_score}/100"
  if [ "$SCORE_THRESHOLD" -gt 0 ]; then
    echo -e "  Below threshold:  ${failed_count} (threshold: ${SCORE_THRESHOLD})"
  fi
  echo ""

  # Per-agent results
  echo "$results" | jq -r '.[] | @base64' | while IFS= read -r encoded; do
    local agent_json
    agent_json=$(echo "$encoded" | base64 --decode)

    local name score grade
    name=$(echo "$agent_json" | jq -r '.agent')
    score=$(echo "$agent_json" | jq -r '.total_score')
    grade=$(echo "$agent_json" | jq -r '.grade')

    local color
    case "$grade" in
      A) color="$GREEN" ;;
      B) color="$GREEN" ;;
      C) color="$YELLOW" ;;
      D) color="$YELLOW" ;;
      F) color="$RED" ;;
      *) color="$NC" ;;
    esac

    echo -e "${color}  [$grade] ${name}: ${score}/100${NC}"

    if [ "$VERBOSE" = true ]; then
      echo "$agent_json" | jq -r '
        .dimensions[] |
        "    " + .dimension + ": " + (.score|tostring) + "/20"
      '
    fi

    # Show top suggestions
    local suggestions
    suggestions=$(echo "$agent_json" | jq -r '.suggestions[:3][] // empty' 2>/dev/null || true)
    if [ -n "$suggestions" ]; then
      echo "       Suggestions:"
      echo "$suggestions" | while IFS= read -r s; do
        echo "         - $s"
      done
    fi

    echo ""
  done

  echo "══════════════════════════════════════════════════════════════"
  if [ "$SCORE_THRESHOLD" -gt 0 ] && [ "$failed_count" -gt 0 ]; then
    echo -e "${RED}✗ $failed_count agent(s) below threshold of $SCORE_THRESHOLD${NC}"
  else
    echo -e "${GREEN}✓ Review complete — average score: ${avg_score}/100${NC}"
  fi
  echo "══════════════════════════════════════════════════════════════"
}

format_json() {
  local results="$1"

  local agent_count avg_score timestamp
  agent_count=$(echo "$results" | jq 'length')
  avg_score=$(echo "$results" | jq '[.[].total_score] | add / length | floor // 0')
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --argjson results "$results" \
    --argjson agent_count "$agent_count" \
    --argjson avg_score "$avg_score" \
    --argjson threshold "$SCORE_THRESHOLD" \
    --arg timestamp "$timestamp" \
    '{
      "summary": {
        "agents_reviewed": $agent_count,
        "average_score": $avg_score,
        "score_threshold": $threshold,
        "agents_below_threshold": ($results | map(select(.total_score < $threshold)) | length),
        "grade_distribution": {
          "A": ($results | map(select(.grade == "A")) | length),
          "B": ($results | map(select(.grade == "B")) | length),
          "C": ($results | map(select(.grade == "C")) | length),
          "D": ($results | map(select(.grade == "D")) | length),
          "F": ($results | map(select(.grade == "F")) | length)
        }
      },
      "agents": $results,
      "generated_at": $timestamp
    }'
}

format_markdown() {
  local results="$1"

  local avg_score timestamp
  avg_score=$(echo "$results" | jq '[.[].total_score] | add / length | floor // 0')
  timestamp=$(date -u "+%Y-%m-%d %H:%M UTC")

  cat <<EOF
# Agent Documentation Quality Review

**Generated:** $timestamp
**Average Score:** ${avg_score}/100
**Score Threshold:** ${SCORE_THRESHOLD}

## Summary

| Agent | Score | Grade | Top Issue |
|-------|-------|-------|-----------|
EOF

  echo "$results" | jq -r '.[] | [.agent, (.total_score|tostring), .grade, (.suggestions[0] // "—")] | @tsv' | \
    while IFS=$'\t' read -r agent score grade top_issue; do
      echo "| $agent | $score/100 | $grade | $top_issue |"
    done

  echo ""
  echo "## Detailed Reports"
  echo ""

  echo "$results" | jq -r '.[] | @base64' | while IFS= read -r encoded; do
    local agent_json
    agent_json=$(echo "$encoded" | base64 --decode)

    local name score grade
    name=$(echo "$agent_json" | jq -r '.agent')
    score=$(echo "$agent_json" | jq -r '.total_score')
    grade=$(echo "$agent_json" | jq -r '.grade')

    echo "### $name (Score: $score/100 — Grade: $grade)"
    echo ""
    echo "| Dimension | Score | Max |"
    echo "|-----------|-------|-----|"
    echo "$agent_json" | jq -r '.dimensions[] | "| " + .dimension + " | " + (.score|tostring) + " | 20 |"'
    echo ""

    local suggestions
    suggestions=$(echo "$agent_json" | jq -r '.suggestions[] // empty' 2>/dev/null || true)
    if [ -n "$suggestions" ]; then
      echo "**Improvement Suggestions:**"
      echo ""
      echo "$suggestions" | while IFS= read -r s; do
        echo "- $s"
      done
      echo ""
    fi
  done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  # Run reviews
  local results
  results=$(review_all_agents)

  # Format output
  local output
  case "$OUTPUT_FORMAT" in
    json)
      output=$(format_json "$results")
      ;;
    markdown|md)
      output=$(format_markdown "$results")
      ;;
    text|*)
      output=$(format_text "$results")
      ;;
  esac

  # Write to file or stdout
  if [ -n "$OUTPUT_FILE" ]; then
    echo "$output" > "$OUTPUT_FILE"
    echo -e "${GREEN}Report saved to: $OUTPUT_FILE${NC}" >&2
  else
    echo "$output"
  fi

  # Check threshold
  if [ "$SCORE_THRESHOLD" -gt 0 ]; then
    local failed_count
    failed_count=$(echo "$results" | jq --argjson t "$SCORE_THRESHOLD" '[.[] | select(.total_score < $t)] | length')
    if [ "$failed_count" -gt 0 ]; then
      exit 1
    fi
  fi

  exit 0
}

main
