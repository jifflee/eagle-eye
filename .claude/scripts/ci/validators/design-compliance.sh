#!/usr/bin/env bash
# ============================================================
# Script: design-compliance.sh
# Purpose: Unified design enforcement compliance checker
# Usage: ./scripts/ci/validators/design-compliance.sh [--verbose] [--output FILE]
# Exit codes: 0 = compliant, 1 = violations found, 2 = error
# ============================================================
# size-ok: comprehensive validation with multiple check categories

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Defaults
VERBOSE=false
OUTPUT_FILE=""
QUIET=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose) VERBOSE=true; shift ;;
    --quiet) QUIET=true; shift ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Logging functions
log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[INFO]${NC} $*"
  fi
}

log_warn() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_section() {
  if [[ "$QUIET" != "true" ]]; then
    echo ""
    echo -e "${BOLD}${BLUE}━━━ $* ━━━${NC}"
    echo ""
  fi
}

# Check prerequisites
check_prerequisites() {
  local missing=()

  for tool in jq find grep; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    exit 2
  fi
}

# Initialize results tracking
declare -a LAYER_NAMES=()
declare -a LAYER_SCORES=()
declare -a LAYER_STATUSES=()
declare -a LAYER_DETAILS=()

# Layer 1: Git Hooks Validation
check_git_hooks() {
  log_section "Layer 1: Git Hooks"

  local score=100
  local details=""
  local status="pass"

  # Check for pre-commit hook
  local hooks_found=0
  local hooks_expected=0

  # Check standard git hooks
  for hook in pre-commit pre-push; do
    hooks_expected=$((hooks_expected + 1))
    if [[ -f "$REPO_ROOT/.githooks/$hook" ]] || [[ -f "$REPO_ROOT/.husky/$hook" ]] || [[ -f "$REPO_ROOT/scripts/hooks/$hook" ]]; then
      hooks_found=$((hooks_found + 1))
      log_verbose "✓ Found $hook hook"
    else
      log_verbose "✗ Missing $hook hook"
      score=$((score - 20))
      details+="Missing $hook hook; "
    fi
  done

  # Check for custom hooks
  if [[ -f "$REPO_ROOT/hooks/end-of-turn.sh" ]]; then
    log_verbose "✓ Found end-of-turn hook"
  else
    log_verbose "✗ Missing end-of-turn hook"
    score=$((score - 10))
    details+="Missing end-of-turn hook; "
  fi

  # Validate hook scripts are executable
  local non_executable=0
  while IFS= read -r hook_file; do
    if [[ ! -x "$hook_file" ]]; then
      non_executable=$((non_executable + 1))
      log_verbose "✗ Hook not executable: $hook_file"
    fi
  done < <(find "$REPO_ROOT/scripts/hooks" -name "*.sh" 2>/dev/null || true)

  if [[ $non_executable -gt 0 ]]; then
    score=$((score - 10))
    details+="$non_executable hooks not executable; "
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "Git Hooks Score: $score/100 ($status)"

  LAYER_NAMES+=("git-hooks")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Layer 2: CI Scripts Integration
check_ci_scripts() {
  log_section "Layer 2: CI Scripts Integration"

  local score=100
  local details=""
  local status="pass"

  # Get list of all validator scripts
  local total_validators=0
  local integrated_validators=0

  while IFS= read -r validator; do
    total_validators=$((total_validators + 1))
    local basename_validator
    basename_validator=$(basename "$validator")

    # Check if integrated in run-pipeline.sh
    if grep -q "$basename_validator" "$REPO_ROOT/scripts/ci/runners/run-pipeline.sh" 2>/dev/null; then
      integrated_validators=$((integrated_validators + 1))
      log_verbose "✓ Integrated: $basename_validator"
    else
      log_verbose "✗ Not integrated: $basename_validator"
      details+="Not integrated: $basename_validator; "
    fi
  done < <(find "$REPO_ROOT/scripts/ci/validators" -name "*.sh" -type f 2>/dev/null || true)

  if [[ $total_validators -gt 0 ]]; then
    local integration_pct=$((integrated_validators * 100 / total_validators))
    score=$integration_pct
    log_verbose "Integration: $integrated_validators/$total_validators validators ($integration_pct%)"
  else
    log_warn "No CI validators found"
    score=0
    status="warn"
  fi

  # Check for run-pipeline.sh existence and executability
  if [[ ! -f "$REPO_ROOT/scripts/ci/runners/run-pipeline.sh" ]]; then
    score=0
    status="fail"
    details+="run-pipeline.sh missing; "
  elif [[ ! -x "$REPO_ROOT/scripts/ci/runners/run-pipeline.sh" ]]; then
    score=$((score - 20))
    status="warn"
    details+="run-pipeline.sh not executable; "
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "CI Scripts Score: $score/100 ($status)"

  LAYER_NAMES+=("ci-scripts")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Layer 3: Standards Documentation
check_standards_docs() {
  log_section "Layer 3: Standards Documentation"

  local score=100
  local details=""
  local status="pass"

  # Expected critical standards
  local -a expected_standards=(
    "NAMING_CONVENTIONS.md"
    "SCRIPT_STANDARDS.md"
    "REPOSITORY_STRUCTURE.md"
    "CI_PIPELINE.md"
  )

  local found_standards=0
  for std in "${expected_standards[@]}"; do
    if [[ -f "$REPO_ROOT/docs/standards/$std" ]]; then
      found_standards=$((found_standards + 1))
      log_verbose "✓ Found standard: $std"
    else
      log_verbose "✗ Missing standard: $std"
      score=$((score - 15))
      details+="Missing $std; "
    fi
  done

  # Check for standards directory structure
  if [[ ! -d "$REPO_ROOT/docs/standards" ]]; then
    score=0
    status="fail"
    details+="docs/standards/ directory missing; "
  fi

  # Count total standards docs
  local total_standards
  total_standards=$(find "$REPO_ROOT/docs/standards" -name "*.md" -type f 2>/dev/null | wc -l)
  log_verbose "Total standards documents: $total_standards"

  if [[ $total_standards -lt 10 ]]; then
    score=$((score - 10))
    details+="Only $total_standards standards docs (expected 10+); "
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "Standards Docs Score: $score/100 ($status)"

  LAYER_NAMES+=("standards-docs")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Layer 4: Agent Validation
check_agents() {
  log_section "Layer 4: Agent Validation"

  local score=100
  local details=""
  local status="pass"

  # Expected critical agents
  local -a expected_agents=(
    "guardrails-policy"
    "architect"
    "code-reviewer"
    "pr-code-reviewer"
  )

  local found_agents=0
  for agent in "${expected_agents[@]}"; do
    if [[ -f "$REPO_ROOT/.claude/agents/$agent.md" ]]; then
      found_agents=$((found_agents + 1))
      log_verbose "✓ Found agent: $agent"
    else
      log_verbose "✗ Missing agent: $agent"
      score=$((score - 15))
      details+="Missing $agent agent; "
    fi
  done

  # Check for agents directory
  if [[ ! -d "$REPO_ROOT/.claude/agents" ]]; then
    score=0
    status="fail"
    details+=".claude/agents/ directory missing; "
  else
    # Count total agents
    local total_agents
    total_agents=$(find "$REPO_ROOT/.claude/agents" -name "*.md" -type f 2>/dev/null | wc -l)
    log_verbose "Total agents: $total_agents"

    if [[ $total_agents -lt 10 ]]; then
      score=$((score - 10))
      details+="Only $total_agents agents (expected 10+); "
    fi
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "Agents Score: $score/100 ($status)"

  LAYER_NAMES+=("agents")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Layer 5: Schema Validation
check_schemas() {
  log_section "Layer 5: Schema Validation"

  local score=100
  local details=""
  local status="pass"

  # Expected schemas
  local -a expected_schemas=(
    "agent-manifest.schema.json"
    "skill-manifest.schema.json"
    "command-manifest.schema.json"
  )

  local found_schemas=0
  for schema in "${expected_schemas[@]}"; do
    if [[ -f "$REPO_ROOT/schemas/$schema" ]]; then
      found_schemas=$((found_schemas + 1))
      log_verbose "✓ Found schema: $schema"

      # Validate JSON syntax
      if ! jq empty "$REPO_ROOT/schemas/$schema" 2>/dev/null; then
        score=$((score - 10))
        details+="Invalid JSON in $schema; "
        log_verbose "✗ Invalid JSON: $schema"
      fi
    else
      log_verbose "✗ Missing schema: $schema"
      score=$((score - 20))
      details+="Missing $schema; "
    fi
  done

  # Check for schemas directory
  if [[ ! -d "$REPO_ROOT/schemas" ]]; then
    score=0
    status="fail"
    details+="schemas/ directory missing; "
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "Schemas Score: $score/100 ($status)"

  LAYER_NAMES+=("schemas")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Layer 6: Standards Drift Detection
check_standards_drift() {
  log_section "Layer 6: Standards Drift Detection"

  local score=100
  local details=""
  local status="pass"

  # Check naming conventions compliance
  local naming_violations=0

  # Check for files with spaces in names
  while IFS= read -r file; do
    if [[ "$file" == *" "* ]]; then
      naming_violations=$((naming_violations + 1))
      log_verbose "✗ File with spaces: $file"
    fi
  done < <(find "$REPO_ROOT" -type f -name "* *" 2>/dev/null | grep -v ".git/" || true)

  if [[ $naming_violations -gt 0 ]]; then
    score=$((score - naming_violations * 5))
    details+="$naming_violations files with spaces in names; "
  fi

  # Check for uppercase directory names (except allowed patterns)
  local uppercase_dirs=0
  while IFS= read -r dir; do
    local basename_dir
    basename_dir=$(basename "$dir")
    # Skip allowed patterns
    if [[ ! "$basename_dir" =~ ^(README|CONTRIBUTING|CHANGELOG|CLAUDE)$ ]]; then
      uppercase_dirs=$((uppercase_dirs + 1))
      log_verbose "✗ Uppercase directory: $dir"
    fi
  done < <(find "$REPO_ROOT" -type d -name "[A-Z]*" 2>/dev/null | grep -v ".git/" | grep -v "node_modules/" || true)

  if [[ $uppercase_dirs -gt 0 ]]; then
    score=$((score - uppercase_dirs * 3))
    details+="$uppercase_dirs uppercase directories; "
  fi

  # Check script naming conventions
  local script_violations=0
  while IFS= read -r script; do
    local basename_script
    basename_script=$(basename "$script")
    # Check for snake_case (should be kebab-case)
    if [[ "$basename_script" == *"_"* ]] && [[ ! "$basename_script" =~ ^test_ ]]; then
      script_violations=$((script_violations + 1))
      log_verbose "✗ Script with underscores: $script"
    fi
  done < <(find "$REPO_ROOT/scripts" -name "*.sh" -type f 2>/dev/null || true)

  if [[ $script_violations -gt 0 ]]; then
    score=$((score - script_violations * 2))
    details+="$script_violations scripts with naming violations; "
  fi

  # Cap score at 0
  if [[ $score -lt 0 ]]; then
    score=0
  fi

  if [[ $score -lt 70 ]]; then
    status="fail"
  elif [[ $score -lt 90 ]]; then
    status="warn"
  fi

  log_info "Standards Drift Score: $score/100 ($status)"

  LAYER_NAMES+=("standards-drift")
  LAYER_SCORES+=("$score")
  LAYER_STATUSES+=("$status")
  LAYER_DETAILS+=("$details")
}

# Calculate overall compliance score
calculate_overall_score() {
  local total=0
  local count=0

  for score in "${LAYER_SCORES[@]}"; do
    total=$((total + score))
    count=$((count + 1))
  done

  if [[ $count -gt 0 ]]; then
    echo $((total / count))
  else
    echo 0
  fi
}

# Generate JSON report
generate_json_report() {
  local overall_score="$1"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build layers array
  local layers_json="["
  local first=true
  for i in "${!LAYER_NAMES[@]}"; do
    if [[ "$first" != "true" ]]; then
      layers_json+=","
    fi
    first=false

    local name="${LAYER_NAMES[$i]}"
    local score="${LAYER_SCORES[$i]}"
    local status="${LAYER_STATUSES[$i]}"
    local details="${LAYER_DETAILS[$i]}"

    layers_json+=$(jq -n \
      --arg name "$name" \
      --argjson score "$score" \
      --arg status "$status" \
      --arg details "$details" \
      '{name: $name, score: $score, status: $status, details: $details}')
  done
  layers_json+="]"

  # Determine overall status
  local overall_status="pass"
  if [[ $overall_score -lt 70 ]]; then
    overall_status="fail"
  elif [[ $overall_score -lt 90 ]]; then
    overall_status="warn"
  fi

  jq -n \
    --arg timestamp "$timestamp" \
    --argjson overall_score "$overall_score" \
    --arg overall_status "$overall_status" \
    --argjson layers "$layers_json" \
    '{
      timestamp: $timestamp,
      overall_score: $overall_score,
      overall_status: $overall_status,
      layers: $layers,
      grade: (
        if $overall_score >= 95 then "A+"
        elif $overall_score >= 90 then "A"
        elif $overall_score >= 85 then "B+"
        elif $overall_score >= 80 then "B"
        elif $overall_score >= 75 then "C+"
        elif $overall_score >= 70 then "C"
        elif $overall_score >= 60 then "D"
        else "F"
        end
      )
    }'
}

# Print summary
print_summary() {
  local overall_score="$1"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Design Compliance Summary${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo ""

  # Determine grade
  local grade
  if [[ $overall_score -ge 95 ]]; then
    grade="A+"
  elif [[ $overall_score -ge 90 ]]; then
    grade="A"
  elif [[ $overall_score -ge 85 ]]; then
    grade="B+"
  elif [[ $overall_score -ge 80 ]]; then
    grade="B"
  elif [[ $overall_score -ge 75 ]]; then
    grade="C+"
  elif [[ $overall_score -ge 70 ]]; then
    grade="C"
  elif [[ $overall_score -ge 60 ]]; then
    grade="D"
  else
    grade="F"
  fi

  echo -e "  Overall Score: ${BOLD}$overall_score/100${NC} (Grade: $grade)"
  echo ""
  echo "  Layer Scores:"

  for i in "${!LAYER_NAMES[@]}"; do
    local name="${LAYER_NAMES[$i]}"
    local score="${LAYER_SCORES[$i]}"
    local status="${LAYER_STATUSES[$i]}"

    local color="$GREEN"
    local symbol="✓"
    if [[ "$status" == "fail" ]]; then
      color="$RED"
      symbol="✗"
    elif [[ "$status" == "warn" ]]; then
      color="$YELLOW"
      symbol="⚠"
    fi

    echo -e "    ${color}${symbol}${NC} $name: $score/100"
  done

  echo ""

  if [[ $overall_score -ge 90 ]]; then
    echo -e "  ${GREEN}✓ EXCELLENT${NC} - Design enforcement is strong"
  elif [[ $overall_score -ge 70 ]]; then
    echo -e "  ${YELLOW}⚠ ACCEPTABLE${NC} - Some improvements needed"
  else
    echo -e "  ${RED}✗ NEEDS WORK${NC} - Significant gaps in design enforcement"
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo ""
}

# Main execution
main() {
  cd "$REPO_ROOT"

  check_prerequisites

  log_info "Starting design compliance check..."
  log_info "Repository: $REPO_ROOT"
  echo ""

  # Run all layer checks
  check_git_hooks
  check_ci_scripts
  check_standards_docs
  check_agents
  check_schemas
  check_standards_drift

  # Calculate overall score
  local overall_score
  overall_score=$(calculate_overall_score)

  # Generate report
  local report
  report=$(generate_json_report "$overall_score")

  # Write report if requested
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" > "$OUTPUT_FILE"
    log_info "Report written to: $OUTPUT_FILE"
  fi

  # Print summary
  if [[ "$QUIET" != "true" ]]; then
    print_summary "$overall_score"
  fi

  # Exit with appropriate code
  if [[ $overall_score -ge 70 ]]; then
    exit 0
  else
    exit 1
  fi
}

main "$@"
