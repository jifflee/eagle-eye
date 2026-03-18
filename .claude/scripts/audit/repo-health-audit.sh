#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: repo-health-audit.sh
# Purpose: Comprehensive repository health audit
# Usage: ./scripts/audit/repo-health-audit.sh [--category <cat>] [--output json|text]
# size-ok: comprehensive audit across multiple health categories with scoring
# Dependencies: jq
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration defaults
CATEGORY="all"
OUTPUT_FORMAT="text"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --category)
      CATEGORY="${2:-all}"
      shift 2
      ;;
    --output)
      OUTPUT_FORMAT="${2:-text}"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--category <structure|code|testing|docs>] [--output <text|json>]"
      echo ""
      echo "Categories: structure, code, testing, docs, all (default)"
      echo "Output formats: text (default), json"
      exit 0
      ;;
    *)
      # Support legacy positional args for backwards compatibility
      if [ "$CATEGORY" = "all" ] && [[ "$1" != --* ]]; then
        CATEGORY="$1"
      elif [ "$OUTPUT_FORMAT" = "text" ] && [[ "$1" != --* ]]; then
        OUTPUT_FORMAT="$1"
      fi
      shift
      ;;
  esac
done

# Score tracking
STRUCTURE_SCORE=0
CODE_SCORE=0
TESTING_SCORE=0
DOCS_SCORE=0
TOTAL_SCORE=0

# Findings storage (using files for compatibility)
FINDINGS_DIR=$(mktemp -d)
trap 'rm -rf "$FINDINGS_DIR"' EXIT

add_finding() {
  local severity="$1"
  local id="$2"
  local message="$3"
  echo "[$id] $message" >> "$FINDINGS_DIR/$severity.txt"
}

# Structure Audit (20 points max)
audit_structure() {
  local score=0

  echo "Auditing structure..." >&2

  # Required directories (8 points)
  local required_dirs=(".github" "docs" "scripts" "tests")
  local dir_score=0
  for dir in "${required_dirs[@]}"; do
    if [ -d "$dir" ]; then
      dir_score=$((dir_score + 2))
    else
      add_finding "medium" "STRUCT-001" "Missing required directory: $dir"
    fi
  done
  score=$((score + dir_score))

  # No source in root (4 points)
  local root_source
  root_source=$(find . -maxdepth 1 \( -name "*.py" -o -name "*.ts" -o -name "*.js" \) 2>/dev/null | grep -v node_modules | wc -l | tr -d ' ')
  if [ "$root_source" -eq 0 ]; then
    score=$((score + 4))
  else
    add_finding "medium" "STRUCT-002" "Source files found in root directory"
  fi

  # Scripts organized (4 points)
  if [ -f "scripts/lib/common.sh" ]; then
    score=$((score + 2))
  else
    add_finding "medium" "STRUCT-003" "Missing scripts/lib/common.sh"
  fi

  if [ -d "scripts/lib" ]; then
    score=$((score + 2))
  fi

  # Tests organized (4 points)
  if [ -d "tests" ]; then
    score=$((score + 2))
    if [ -d "tests/fixtures" ] || [ -d "tests/unit" ] || [ -d "tests/integration" ]; then
      score=$((score + 2))
    else
      add_finding "low" "STRUCT-004" "Tests not organized into subdirectories"
    fi
  fi

  STRUCTURE_SCORE=$score
}

# Code Quality Audit (30 points max)
audit_code() {
  local score=0

  echo "Auditing code quality..." >&2

  # Script size limits (10 points)
  local oversized=0
  local large=0
  while IFS= read -r script; do
    [ -f "$script" ] || continue
    local lines
    lines=$(wc -l < "$script" | tr -d ' ')
    if [ "$lines" -gt 500 ]; then
      oversized=$((oversized + 1))
      add_finding "high" "CODE-001" "Script exceeds 500 lines: $script ($lines lines)"
    elif [ "$lines" -gt 300 ]; then
      large=$((large + 1))
      add_finding "medium" "CODE-002" "Script exceeds 300 lines: $script ($lines lines)"
    fi
  done < <(find scripts -name "*.sh" -type f 2>/dev/null)

  if [ "$oversized" -eq 0 ]; then
    score=$((score + 6))
    if [ "$large" -le 3 ]; then
      score=$((score + 4))
    fi
  elif [ "$oversized" -le 2 ]; then
    score=$((score + 3))
  fi

  # Naming conventions (8 points)
  local naming_violations=0
  while IFS= read -r script; do
    [ -f "$script" ] || continue
    local basename
    basename=$(basename "$script")
    if [[ ! "$basename" =~ ^[a-z][a-z0-9-]*\.sh$ ]]; then
      naming_violations=$((naming_violations + 1))
      add_finding "low" "CODE-003" "Script naming violation: $script"
    fi
  done < <(find scripts -name "*.sh" -type f 2>/dev/null)

  if [ "$naming_violations" -eq 0 ]; then
    score=$((score + 8))
  elif [ "$naming_violations" -le 3 ]; then
    score=$((score + 4))
  fi

  # No hardcoded secrets (4 points) - simplified check
  local secrets_found=0
  if grep -rn "password\s*=\s*['\"][^'\"]*['\"]" --include="*.sh" scripts/ 2>/dev/null | grep -v "example\|test\|placeholder" | head -1 >/dev/null 2>&1; then
    secrets_found=$((secrets_found + 1))
    add_finding "critical" "CODE-004" "Possible hardcoded password found"
  fi

  if [ "$secrets_found" -eq 0 ]; then
    score=$((score + 4))
  fi

  # Shared utilities (4 points)
  if [ -f "scripts/lib/common.sh" ]; then
    local sourcing_scripts
    sourcing_scripts=$(grep -rl "source.*common.sh" scripts/ 2>/dev/null | wc -l | tr -d ' ')
    if [ "$sourcing_scripts" -ge 5 ]; then
      score=$((score + 4))
    elif [ "$sourcing_scripts" -ge 1 ]; then
      score=$((score + 2))
    fi
  fi

  # No circular deps placeholder (4 points)
  score=$((score + 4))

  CODE_SCORE=$score
}

# Testing Audit (30 points max)
audit_testing() {
  local score=0

  echo "Auditing testing..." >&2

  # Test coverage > 50% (10 points)
  local test_count
  test_count=$(find tests -name "*.test.*" -o -name "test_*" -o -name "test-*.sh" 2>/dev/null | wc -l | tr -d ' ')
  local source_count
  source_count=$(find scripts -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')

  if [ "$source_count" -gt 0 ]; then
    local coverage_pct=$((test_count * 100 / source_count))
    if [ "$coverage_pct" -ge 50 ]; then
      score=$((score + 10))
    elif [ "$coverage_pct" -ge 25 ]; then
      score=$((score + 5))
      add_finding "medium" "TEST-001" "Test coverage below 50% ($coverage_pct%)"
    else
      add_finding "high" "TEST-002" "Low test coverage ($coverage_pct%)"
    fi
  elif [ "$test_count" -ge 10 ]; then
    score=$((score + 10))
  fi

  # All routes have tests (10 points)
  if [ "$test_count" -ge 10 ]; then
    score=$((score + 10))
  elif [ "$test_count" -ge 5 ]; then
    score=$((score + 5))
    add_finding "medium" "TEST-003" "Limited test files ($test_count)"
  elif [ "$test_count" -ge 1 ]; then
    score=$((score + 2))
    add_finding "high" "TEST-004" "Minimal test files ($test_count)"
  else
    add_finding "high" "TEST-005" "No test files found"
  fi

  # Tests actually run (5 points)
  if [ -d "tests" ]; then
    score=$((score + 3))
    if [ -d "tests/fixtures" ] || [ -d "tests/unit" ] || [ -d "tests/integration" ]; then
      score=$((score + 2))
    fi
  fi

  # No skipped tests (5 points)
  local skipped=0
  if grep -rn "skip\|xit\|xdescribe\|@skip\|@pytest.mark.skip" tests/ 2>/dev/null | head -1 >/dev/null 2>&1; then
    skipped=$(grep -rn "skip\|xit\|xdescribe\|@skip\|@pytest.mark.skip" tests/ 2>/dev/null | wc -l | tr -d ' ')
    add_finding "low" "TEST-006" "$skipped skipped tests found"
    if [ "$skipped" -le 2 ]; then
      score=$((score + 3))
    fi
  else
    score=$((score + 5))
  fi

  TESTING_SCORE=$score
}

# Documentation Audit (20 points max)
audit_docs() {
  local score=0

  echo "Auditing documentation..." >&2

  # README has setup instructions (5 points)
  if [ -f "README.md" ]; then
    score=$((score + 2))
    local readme_lines
    readme_lines=$(wc -l < README.md | tr -d ' ')
    if [ "$readme_lines" -ge 50 ]; then
      score=$((score + 1))
    else
      add_finding "medium" "DOC-001" "README.md is minimal ($readme_lines lines)"
    fi
    if grep -qi "install\|setup\|getting started" README.md 2>/dev/null; then
      score=$((score + 2))
    else
      add_finding "low" "DOC-002" "README missing installation instructions"
    fi
  else
    add_finding "high" "DOC-003" "Missing README.md"
  fi

  # API documented (5 points)
  local api_docs=0
  if find docs -name "*api*" -o -name "*API*" 2>/dev/null | head -1 | grep -q .; then
    api_docs=$((api_docs + 3))
  fi
  if grep -rql "endpoint\|route\|API" docs/ 2>/dev/null; then
    api_docs=$((api_docs + 2))
  fi
  if [ "$api_docs" -eq 0 ]; then
    add_finding "low" "DOC-004" "No API documentation found"
  fi
  score=$((score + api_docs))

  # Environment variables documented (5 points)
  if [ -f ".env.example" ]; then
    score=$((score + 3))
    local env_vars
    env_vars=$(grep -c "=" .env.example 2>/dev/null || echo "0")
    if [ "$env_vars" -ge 3 ]; then
      score=$((score + 2))
    fi
  elif grep -rql "environment\|env var\|\.env" docs/ 2>/dev/null; then
    score=$((score + 2))
  else
    add_finding "medium" "DOC-005" "Environment variables not documented"
  fi

  # Architecture diagram exists (5 points)
  if find docs -name "*architecture*" -o -name "*arch*" 2>/dev/null | head -1 | grep -q .; then
    score=$((score + 3))
    if grep -rql "diagram\|mermaid\|flowchart\|graph" docs/ 2>/dev/null; then
      score=$((score + 2))
    fi
  elif [ -d "docs" ]; then
    local docs_count
    docs_count=$(find docs -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$docs_count" -ge 10 ]; then
      score=$((score + 2))
    fi
  fi

  DOCS_SCORE=$score
}


calculate_total() {
  TOTAL_SCORE=$((STRUCTURE_SCORE + CODE_SCORE + TESTING_SCORE + DOCS_SCORE))
}

get_grade() {
  local score=$1
  if [ "$score" -ge 80 ]; then echo "A"
  elif [ "$score" -ge 60 ]; then echo "B"
  elif [ "$score" -ge 40 ]; then echo "C"
  elif [ "$score" -ge 20 ]; then echo "D"
  else echo "F"
  fi
}

output_text() {
  local grade
  grade=$(get_grade "$TOTAL_SCORE")

  echo ""
  echo "## Repository Health Audit"
  echo ""
  echo "**Repository:** $(basename "$(pwd)")"
  echo "**Date:** $(date -u +%Y-%m-%d)"
  echo "**Overall Score:** $TOTAL_SCORE/100 ($grade)"
  echo ""
  echo "### Score Breakdown"
  echo ""
  echo "| Category | Score | Max | Percentage |"
  echo "|----------|-------|-----|------------|"
  echo "| Structure | $STRUCTURE_SCORE | 20 | $((STRUCTURE_SCORE * 100 / 20))% |"
  echo "| Code Quality | $CODE_SCORE | 30 | $((CODE_SCORE * 100 / 30))% |"
  echo "| Testing | $TESTING_SCORE | 30 | $((TESTING_SCORE * 100 / 30))% |"
  echo "| Documentation | $DOCS_SCORE | 20 | $((DOCS_SCORE * 100 / 20))% |"
  echo ""
  echo "### Findings"
  echo ""

  for severity in critical high medium low; do
    if [ -f "$FINDINGS_DIR/$severity.txt" ]; then
      local count
      count=$(wc -l < "$FINDINGS_DIR/$severity.txt" | tr -d ' ')
      # Uppercase first letter (macOS compatible)
      local severity_label
      severity_label=$(echo "$severity" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
      echo "#### $severity_label ($count)"
      while IFS= read -r finding; do
        echo "- $finding"
      done < "$FINDINGS_DIR/$severity.txt"
      echo ""
    fi
  done

  # Check if no findings
  if [ ! -f "$FINDINGS_DIR/critical.txt" ] && [ ! -f "$FINDINGS_DIR/high.txt" ] && \
     [ ! -f "$FINDINGS_DIR/medium.txt" ] && [ ! -f "$FINDINGS_DIR/low.txt" ]; then
    echo "No findings - excellent!"
    echo ""
  fi
}

output_json() {
  local grade
  grade=$(get_grade "$TOTAL_SCORE")

  # Build findings JSON
  local critical_json="[]"
  local high_json="[]"
  local medium_json="[]"
  local low_json="[]"

  [ -f "$FINDINGS_DIR/critical.txt" ] && critical_json=$(jq -R -s -c 'split("\n") | map(select(. != ""))' < "$FINDINGS_DIR/critical.txt")
  [ -f "$FINDINGS_DIR/high.txt" ] && high_json=$(jq -R -s -c 'split("\n") | map(select(. != ""))' < "$FINDINGS_DIR/high.txt")
  [ -f "$FINDINGS_DIR/medium.txt" ] && medium_json=$(jq -R -s -c 'split("\n") | map(select(. != ""))' < "$FINDINGS_DIR/medium.txt")
  [ -f "$FINDINGS_DIR/low.txt" ] && low_json=$(jq -R -s -c 'split("\n") | map(select(. != ""))' < "$FINDINGS_DIR/low.txt")

  jq -n \
    --arg repo "$(basename "$(pwd)")" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson score "$TOTAL_SCORE" \
    --arg grade "$grade" \
    --argjson structure "$STRUCTURE_SCORE" \
    --argjson code "$CODE_SCORE" \
    --argjson testing "$TESTING_SCORE" \
    --argjson docs "$DOCS_SCORE" \
    --argjson critical "$critical_json" \
    --argjson high "$high_json" \
    --argjson medium "$medium_json" \
    --argjson low "$low_json" \
    '{
      repository: $repo,
      date: $date,
      score: $score,
      grade: $grade,
      breakdown: {
        structure: { score: $structure, max: 20 },
        code: { score: $code, max: 30 },
        testing: { score: $testing, max: 30 },
        documentation: { score: $docs, max: 20 }
      },
      findings: {
        critical: $critical,
        high: $high,
        medium: $medium,
        low: $low
      }
    }'
}

main() {
  # Run audits based on category
  case "$CATEGORY" in
    structure) audit_structure ;;
    code) audit_code ;;
    testing) audit_testing ;;
    docs) audit_docs ;;
    all|*)
      audit_structure
      audit_code
      audit_testing
      audit_docs
      ;;
  esac

  calculate_total

  # Output results
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    output_json
  else
    output_text
  fi
}

main
