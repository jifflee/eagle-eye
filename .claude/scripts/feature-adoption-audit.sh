#!/usr/bin/env bash
#
# feature-adoption-audit.sh - Track newly implemented features and verify they are being used
# Feature #769 - Create feature adoption tracker
# size-ok: comprehensive feature adoption analysis from closed issues
#
# Usage:
#   ./scripts/feature-adoption-audit.sh                          # Check last 10 closed issues
#   ./scripts/feature-adoption-audit.sh --limit 20               # Check last 20 closed issues
#   ./scripts/feature-adoption-audit.sh --days 30                # Check last 30 days
#   ./scripts/feature-adoption-audit.sh --milestone "Sprint 1"   # Check specific milestone
#   ./scripts/feature-adoption-audit.sh --format json            # Output as JSON
#   ./scripts/feature-adoption-audit.sh --format markdown        # Output as markdown
#
# Exit codes:
#   0 - All features are adopted
#   1 - Unused features found (not an error, but informational)
#   2 - Usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default options
LIMIT=10
DAYS=""
MILESTONE=""
OUTPUT_FORMAT="text"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --days)
      DAYS="$2"
      shift 2
      ;;
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --limit N           Number of recent closed issues to check (default: 10)"
      echo "  --days N            Check issues closed in last N days"
      echo "  --milestone NAME    Check issues in specific milestone"
      echo "  --format FORMAT     Output format (text, json, markdown)"
      echo "  -h, --help          Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Temporary directory for intermediate files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ===========================
# DATA COLLECTION FUNCTIONS
# ===========================

get_closed_issues() {
  local search_query=""

  if [ -n "$MILESTONE" ]; then
    # Get issues from specific milestone
    gh issue list --milestone "$MILESTONE" --state closed \
      --json number,title,closedAt,labels,body \
      --limit "$LIMIT" > "$TMPDIR/closed_issues.json"
  elif [ -n "$DAYS" ]; then
    # Get issues closed in last N days
    local since_date
    since_date=$(date -u -d "$DAYS days ago" +%Y-%m-%d 2>/dev/null || date -u -v-"${DAYS}"d +%Y-%m-%d 2>/dev/null)
    gh issue list --state closed --search "closed:>=$since_date sort:updated-desc" \
      --json number,title,closedAt,labels,body \
      --limit "$LIMIT" > "$TMPDIR/closed_issues.json"
  else
    # Get last N closed issues
    gh issue list --state closed \
      --json number,title,closedAt,labels,body \
      --limit "$LIMIT" > "$TMPDIR/closed_issues.json"
  fi
}

get_pr_for_issue() {
  local issue_number=$1

  # Find merged PR that closes this issue
  gh pr list --state merged --search "closes:#$issue_number OR fixes:#$issue_number OR resolves:#$issue_number" \
    --json number,title,mergedAt,files \
    --limit 1 2>/dev/null || echo "[]"
}

analyze_file_usage() {
  local file_path=$1
  local filename=$(basename "$file_path")
  local file_type=""
  local usage_locations=()
  local is_used=false

  # Skip if file doesn't exist
  if [ ! -f "$REPO_ROOT/$file_path" ]; then
    echo '{"exists": false, "is_used": false, "usage_count": 0, "locations": [], "file_type": "unknown"}'
    return
  fi

  # Determine file type
  case "$file_path" in
    *.sh)
      file_type="shell_script"
      ;;
    *.py)
      file_type="python"
      ;;
    *.js|*.ts|*.jsx|*.tsx)
      file_type="javascript"
      ;;
    *.md)
      file_type="documentation"
      ;;
    *.yaml|*.yml)
      file_type="config"
      ;;
    *)
      file_type="other"
      ;;
  esac

  # Search for usage based on file type
  case "$file_type" in
    shell_script)
      # Look for source/execution references
      local script_name=$(basename "$file_path")

      # Search for sourcing: source script.sh, . script.sh
      local source_refs=$(grep -r "source.*$script_name\|^\. .*$script_name" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        2>/dev/null | wc -l | tr -d ' ')

      # Search for execution: ./script.sh, scripts/script.sh
      local exec_refs=$(grep -r "[./]$script_name\|scripts/$script_name" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        2>/dev/null | wc -l | tr -d ' ')

      local usage_count=$((source_refs + exec_refs))

      if [ "$usage_count" -gt 0 ]; then
        is_used=true
        # Get top 3 usage locations
        mapfile -t usage_locations < <(grep -r "[./]$script_name\|scripts/$script_name\|source.*$script_name" "$REPO_ROOT" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
          2>/dev/null | head -3 | sed "s|$REPO_ROOT/||" | cut -d: -f1)
      fi
      ;;

    python)
      # Look for import statements
      local module_name="${filename%.py}"
      local import_refs=$(grep -r "from.*$module_name import\|import.*$module_name" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        --include="*.py" 2>/dev/null | wc -l | tr -d ' ')

      if [ "$import_refs" -gt 0 ]; then
        is_used=true
        mapfile -t usage_locations < <(grep -r "from.*$module_name import\|import.*$module_name" "$REPO_ROOT" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
          --include="*.py" 2>/dev/null | head -3 | sed "s|$REPO_ROOT/||" | cut -d: -f1)
      fi
      ;;

    javascript)
      # Look for import/require statements
      local module_name="${filename%.*}"
      local import_refs=$(grep -rE "from ['\"].*$module_name['\"]|require\(['\"].*$module_name['\"]\)|import.*['\"].*$module_name['\"]" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        --include="*.js" --include="*.ts" --include="*.jsx" --include="*.tsx" 2>/dev/null | wc -l | tr -d ' ')

      if [ "$import_refs" -gt 0 ]; then
        is_used=true
        mapfile -t usage_locations < <(grep -rE "from ['\"].*$module_name['\"]|require\(['\"].*$module_name['\"]\)|import.*['\"].*$module_name['\"]" "$REPO_ROOT" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
          --include="*.js" --include="*.ts" 2>/dev/null | head -3 | sed "s|$REPO_ROOT/||" | cut -d: -f1)
      fi
      ;;

    documentation)
      # Check if referenced in other docs or README files
      local doc_refs=$(grep -r "$filename" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        --include="*.md" 2>/dev/null | wc -l | tr -d ' ')

      # Documentation is less critical - mark as used with lower threshold
      if [ "$doc_refs" -gt 0 ]; then
        is_used=true
        mapfile -t usage_locations < <(grep -r "$filename" "$REPO_ROOT" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
          --include="*.md" 2>/dev/null | head -3 | sed "s|$REPO_ROOT/||" | cut -d: -f1)
      else
        # Check if it's a README or main doc (self-contained)
        if [[ "$filename" =~ ^(README|CONTRIBUTING|CHANGELOG|LICENSE) ]]; then
          is_used=true
        fi
      fi
      ;;

    config)
      # Check if config file is loaded/referenced
      local config_refs=$(grep -r "$filename" "$REPO_ROOT" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
        2>/dev/null | wc -l | tr -d ' ')

      if [ "$config_refs" -gt 0 ]; then
        is_used=true
        mapfile -t usage_locations < <(grep -r "$filename" "$REPO_ROOT" \
          --exclude-dir=.git --exclude-dir=node_modules --exclude="$file_path" \
          2>/dev/null | head -3 | sed "s|$REPO_ROOT/||" | cut -d: -f1)
      fi
      ;;
  esac

  # Build JSON output
  local locations_json=$(printf '%s\n' "${usage_locations[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')

  cat <<EOF
{
  "exists": true,
  "is_used": $is_used,
  "usage_count": ${#usage_locations[@]},
  "locations": $locations_json,
  "file_type": "$file_type"
}
EOF
}

suggest_integration_points() {
  local file_path=$1
  local file_type=$2
  local suggestions=()

  case "$file_type" in
    shell_script)
      # Check if it's a data script
      if [[ "$file_path" =~ -data\.sh$ ]]; then
        local skill_name=$(basename "$file_path" | sed 's/-data\.sh$//')
        if [ -f "$REPO_ROOT/skills/$skill_name.md" ] || [ -f "$REPO_ROOT/core/skills/$skill_name/SKILL.md" ]; then
          suggestions+=("Already has skill definition - integration complete")
        else
          suggestions+=("Create skill file: skills/$skill_name.md to make it invokable")
        fi
      elif [[ "$file_path" =~ ^scripts/audit ]]; then
        suggestions+=("Should be documented in docs/skills/repo-health-skills.md")
        suggestions+=("Consider creating skill file for slash command invocation")
      elif [[ "$file_path" =~ ^scripts/ci/ ]]; then
        suggestions+=("Should be called from CI workflows (if not restricted)")
      elif [[ "$file_path" =~ ^scripts/ ]]; then
        suggestions+=("Consider importing in relevant skill scripts")
        suggestions+=("Add documentation in main README or docs/")
      fi
      ;;

    python)
      if [[ "$file_path" =~ ^src/mcp/ ]]; then
        suggestions+=("Import in src/mcp/server.py or main MCP entrypoint")
        suggestions+=("Add to MCP tool registry if it's a tool")
      elif [[ "$file_path" =~ ^src/ ]]; then
        suggestions+=("Import in relevant application modules")
        suggestions+=("Add unit tests in tests/ directory")
      fi
      ;;

    documentation)
      if [[ "$file_path" =~ ^docs/ ]]; then
        suggestions+=("Link from main README.md or docs/index.md")
        suggestions+=("Add to table of contents if present")
      fi
      ;;

    config)
      if [[ "$file_path" =~ ^contracts/skills/ ]]; then
        suggestions+=("Ensure corresponding skill implementation exists")
      elif [[ "$file_path" =~ \.yaml$|\.yml$ ]]; then
        suggestions+=("Load in application configuration loader")
      fi
      ;;
  esac

  # Generic suggestions if none specific
  if [ ${#suggestions[@]} -eq 0 ]; then
    suggestions+=("Review if this file should be integrated into existing workflows")
    suggestions+=("Consider adding usage examples in documentation")
  fi

  printf '%s\n' "${suggestions[@]}" | jq -R . | jq -s .
}

determine_severity() {
  local file_path=$1
  local file_type=$2
  local issue_labels=$3

  # Parse labels
  local is_epic=false
  local is_critical=false
  local is_feature=false

  if echo "$issue_labels" | jq -e 'any(. == "epic")' > /dev/null 2>&1; then
    is_epic=true
  fi

  if echo "$issue_labels" | jq -e 'any(. == "P0" or . == "P1" or . == "critical")' > /dev/null 2>&1; then
    is_critical=true
  fi

  if echo "$issue_labels" | jq -e 'any(. == "feature" or . == "enhancement")' > /dev/null 2>&1; then
    is_feature=true
  fi

  # Determine severity
  if [ "$is_epic" = true ] || [ "$is_critical" = true ]; then
    echo "critical"
  elif [[ "$file_path" =~ ^scripts/ ]] && [ "$file_type" = "shell_script" ] && [ "$is_feature" = true ]; then
    echo "high"
  elif [[ "$file_path" =~ ^src/ ]] && [ "$file_type" != "documentation" ]; then
    echo "high"
  elif [ "$file_type" = "documentation" ]; then
    echo "low"
  elif [[ "$file_path" =~ ^tests/ ]]; then
    echo "low"
  else
    echo "medium"
  fi
}

# ===========================
# MAIN ANALYSIS
# ===========================

analyze_features() {
  echo -e "${BLUE}Analyzing feature adoption...${NC}" >&2

  # Get closed issues
  get_closed_issues

  local total_issues=$(jq 'length' "$TMPDIR/closed_issues.json")
  echo -e "${CYAN}Found $total_issues closed issues to analyze${NC}" >&2

  local results="[]"
  local issue_num=0

  # Process each issue
  while IFS= read -r issue; do
    ((issue_num++))
    local issue_number=$(echo "$issue" | jq -r '.number')
    local issue_title=$(echo "$issue" | jq -r '.title')
    local issue_labels=$(echo "$issue" | jq -c '.labels')

    echo -e "${CYAN}[$issue_num/$total_issues] Analyzing #$issue_number: $issue_title${NC}" >&2

    # Get associated PR
    local pr_data=$(get_pr_for_issue "$issue_number")
    local pr_count=$(echo "$pr_data" | jq 'length')

    if [ "$pr_count" -eq 0 ]; then
      # No PR found - skip or note
      continue
    fi

    local pr_number=$(echo "$pr_data" | jq -r '.[0].number')
    local pr_files=$(echo "$pr_data" | jq -c '.[0].files')

    # Analyze each file in the PR
    local file_analyses="[]"
    while IFS= read -r file_obj; do
      local file_path=$(echo "$file_obj" | jq -r '.path')
      local additions=$(echo "$file_obj" | jq -r '.additions')

      # Skip test files, very small changes, and deletions
      if [ "$additions" -lt 10 ]; then
        continue
      fi

      # Analyze usage
      local usage_data=$(analyze_file_usage "$file_path")
      local is_used=$(echo "$usage_data" | jq -r '.is_used')
      local usage_count=$(echo "$usage_data" | jq -r '.usage_count')
      local usage_locations=$(echo "$usage_data" | jq -c '.locations')
      local file_type=$(echo "$usage_data" | jq -r '.file_type')

      # Determine severity
      local severity=$(determine_severity "$file_path" "$file_type" "$issue_labels")

      # Get integration suggestions
      local suggestions=$(suggest_integration_points "$file_path" "$file_type")

      # Build file analysis
      local file_analysis=$(cat <<EOF
{
  "path": "$file_path",
  "type": "$file_type",
  "additions": $additions,
  "is_used": $is_used,
  "usage_count": $usage_count,
  "usage_locations": $usage_locations,
  "severity": "$severity",
  "suggestions": $suggestions
}
EOF
)
      file_analyses=$(echo "$file_analyses" | jq --argjson fa "$file_analysis" '. + [$fa]')
    done < <(echo "$pr_files" | jq -c '.[]')

    # Only include if there are files to analyze
    if [ "$(echo "$file_analyses" | jq 'length')" -gt 0 ]; then
      local issue_result=$(cat <<EOF
{
  "issue": {
    "number": $issue_number,
    "title": $(echo "$issue_title" | jq -R .),
    "closed_at": $(echo "$issue" | jq '.closedAt'),
    "labels": $issue_labels
  },
  "pr": {
    "number": $pr_number
  },
  "files": $file_analyses,
  "unused_count": $(echo "$file_analyses" | jq '[.[] | select(.is_used == false)] | length'),
  "total_files": $(echo "$file_analyses" | jq 'length')
}
EOF
)
      results=$(echo "$results" | jq --argjson ir "$issue_result" '. + [$ir]')
    fi
  done < <(jq -c '.[]' "$TMPDIR/closed_issues.json")

  echo "$results" > "$TMPDIR/analysis_results.json"
}

# ===========================
# OUTPUT FORMATTING
# ===========================

format_text_output() {
  local results=$(cat "$TMPDIR/analysis_results.json")
  local total_analyzed=$(echo "$results" | jq 'length')
  local total_files=$(echo "$results" | jq '[.[].files | length] | add // 0')
  local total_unused=$(echo "$results" | jq '[.[].unused_count] | add // 0')
  local total_used=$((total_files - total_unused))

  echo ""
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║         FEATURE ADOPTION REPORT                              ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Summary:"
  echo "  Issues Analyzed:     $total_analyzed"
  echo "  Total Files:         $total_files"
  echo -e "  ${GREEN}Used:${NC}                $total_used"
  echo -e "  ${RED}Not Used:${NC}            $total_unused"

  if [ "$total_files" -gt 0 ]; then
    local adoption_rate=$((total_used * 100 / total_files))
    echo "  Adoption Rate:       ${adoption_rate}%"
  fi

  echo ""

  # Show unused features by severity
  local critical_unused=$(echo "$results" | jq '[.[].files[] | select(.is_used == false and .severity == "critical")] | length')
  local high_unused=$(echo "$results" | jq '[.[].files[] | select(.is_used == false and .severity == "high")] | length')
  local medium_unused=$(echo "$results" | jq '[.[].files[] | select(.is_used == false and .severity == "medium")] | length')
  local low_unused=$(echo "$results" | jq '[.[].files[] | select(.is_used == false and .severity == "low")] | length')

  if [ "$total_unused" -gt 0 ]; then
    echo -e "${RED}━━━ Unused Features ━━━${NC}"
    echo ""

    if [ "$critical_unused" -gt 0 ]; then
      echo -e "${RED}CRITICAL SEVERITY (${critical_unused} files):${NC}"
      echo "$results" | jq -r '.[] | select(.unused_count > 0) | .issue.number as $issue_num | .files[] | select(.is_used == false and .severity == "critical") | "  #\($issue_num): \(.path) (\(.type))"'
      echo ""
    fi

    if [ "$high_unused" -gt 0 ]; then
      echo -e "${YELLOW}HIGH SEVERITY (${high_unused} files):${NC}"
      echo "$results" | jq -r '.[] | select(.unused_count > 0) | .issue.number as $issue_num | .files[] | select(.is_used == false and .severity == "high") | "  #\($issue_num): \(.path) (\(.type))"'
      echo ""
    fi

    if [ "$medium_unused" -gt 0 ]; then
      echo -e "${YELLOW}MEDIUM SEVERITY (${medium_unused} files):${NC}"
      echo "$results" | jq -r '.[] | select(.unused_count > 0) | .issue.number as $issue_num | .files[] | select(.is_used == false and .severity == "medium") | "  #\($issue_num): \(.path) (\(.type))"'
      echo ""
    fi

    echo -e "${BLUE}━━━ Integration Recommendations ━━━${NC}"
    echo ""

    # Show top recommendations for critical and high severity
    echo "$results" | jq -r '
      .[] |
      select(.unused_count > 0) |
      .issue.number as $issue_num |
      .issue.title as $issue_title |
      .files[] |
      select(.is_used == false and (.severity == "critical" or .severity == "high")) |
      "Issue #\($issue_num): \($issue_title)\nFile: \(.path)\nRecommendations:\n\(.suggestions | map("  • " + .) | join("\n"))\n"
    '
  else
    echo -e "${GREEN}✓ All implemented features are being used!${NC}"
  fi

  echo ""
  echo "══════════════════════════════════════════════════════════════"
}

format_json_output() {
  local results=$(cat "$TMPDIR/analysis_results.json")
  local total_analyzed=$(echo "$results" | jq 'length')
  local total_files=$(echo "$results" | jq '[.[].files | length] | add // 0')
  local total_unused=$(echo "$results" | jq '[.[].unused_count] | add // 0')
  local total_used=$((total_files - total_unused))

  cat <<EOF
{
  "summary": {
    "issues_analyzed": $total_analyzed,
    "total_files": $total_files,
    "files_used": $total_used,
    "files_unused": $total_unused,
    "adoption_rate": $([ "$total_files" -gt 0 ] && echo "scale=2; $total_used * 100 / $total_files" | bc || echo 0)
  },
  "issues": $results,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

format_markdown_output() {
  local results=$(cat "$TMPDIR/analysis_results.json")
  local total_analyzed=$(echo "$results" | jq 'length')
  local total_files=$(echo "$results" | jq '[.[].files | length] | add // 0')
  local total_unused=$(echo "$results" | jq '[.[].unused_count] | add // 0')
  local total_used=$((total_files - total_unused))

  cat <<EOF
# Feature Adoption Report

**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

## Summary

| Metric | Count |
|--------|-------|
| Issues Analyzed | $total_analyzed |
| Total Files | $total_files |
| Files Used | $total_used |
| Files Unused | $total_unused |
| Adoption Rate | $([ "$total_files" -gt 0 ] && echo "scale=1; $total_used * 100 / $total_files" | bc || echo 0)% |

## Recently Implemented Features

| Issue | Feature | Files Created | Usage Status |
|-------|---------|---------------|--------------|
EOF

  echo "$results" | jq -r '
    .[] |
    "| #\(.issue.number) | \(.issue.title) | \(.total_files) files | \(if .unused_count == 0 then "✓ All used" else "\(.unused_count) not used" end) |"
  '

  local total_unused=$(echo "$results" | jq '[.[].unused_count] | add // 0')

  if [ "$total_unused" -gt 0 ]; then
    cat <<EOF

## Unused Features Detail

EOF

    echo "$results" | jq -r '
      .[] |
      select(.unused_count > 0) |
      "### Issue #\(.issue.number): \(.issue.title)\n\n**Files not in use:**\n\n" +
      (.files[] | select(.is_used == false) | "- `\(.path)` (\(.type), severity: \(.severity))\n") +
      "\n"
    '

    cat <<EOF

## Integration Recommendations

EOF

    echo "$results" | jq -r '
      .[] |
      select(.unused_count > 0) |
      .issue.number as $issue_num |
      .files[] |
      select(.is_used == false and (.severity == "critical" or .severity == "high")) |
      "### \(.path)\n\n**Issue:** #\($issue_num)  \n**Type:** \(.type)  \n**Severity:** \(.severity)\n\n**Recommendations:**\n\n" +
      (.suggestions | map("- " + .) | join("\n")) + "\n\n"
    '
  fi

  cat <<EOF

---
*Generated by feature-adoption-audit.sh*
EOF
}

# ===========================
# MAIN EXECUTION
# ===========================

main() {
  # Validate dependencies
  if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is required but not installed" >&2
    exit 2
  fi

  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 2
  fi

  # Run analysis
  analyze_features

  # Format output
  case "$OUTPUT_FORMAT" in
    json)
      format_json_output
      ;;
    markdown|md)
      format_markdown_output
      ;;
    text|*)
      format_text_output
      ;;
  esac

  # Exit code based on findings
  local total_unused=$(jq '[.[].unused_count] | add // 0' "$TMPDIR/analysis_results.json")
  if [ "$total_unused" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}

main
