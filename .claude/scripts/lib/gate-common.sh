#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: gate-common.sh
# Purpose: Shared utilities for quality gate scripts
# Usage: source "$(dirname "$0")/lib/gate-common.sh"
# Dependencies: common.sh, jq
# ============================================================

# Prevent double-sourcing
if [ -n "${_GATE_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
readonly _GATE_COMMON_SH_LOADED=1

# Source common utilities if not already loaded
SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${_COMMON_SH_LOADED:-}" ]; then
  source "${SCRIPT_LIB_DIR}/common.sh"
fi

# ============================================================
# Cache Management Functions
# ============================================================

# Get the HEAD SHA of the current git repository
# Usage: head_sha=$(gate_get_head_sha)
gate_get_head_sha() {
  git rev-parse HEAD 2>/dev/null || echo "unknown"
}

# Get the HEAD SHA for a specific PR
# Usage: head_sha=$(gate_get_pr_head_sha "123")
gate_get_pr_head_sha() {
  local pr_num="$1"
  # Try GitHub CLI first
  if command -v gh &>/dev/null; then
    gh pr view "$pr_num" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo ""
  else
    # Fall back to local git HEAD
    git rev-parse HEAD 2>/dev/null || echo ""
  fi
}

# Get the cache file path for a given identifier and SHA
# Usage: cache_file=$(gate_get_cache_file "$CACHE_DIR" "prefix" "$head_sha")
gate_get_cache_file() {
  local cache_dir="$1"
  local prefix="$2"
  local head_sha="$3"
  local short_sha="${head_sha:0:12}"
  echo "$cache_dir/${prefix}-${short_sha}.json"
}

# Check if a cached result exists and is valid
# Returns 0 and prints cached JSON if valid, 1 if invalid/expired
# Usage: if cached=$(gate_check_cache "$CACHE_DIR" "prefix" "$head_sha" "$ttl_minutes" "$no_cache"); then ...
gate_check_cache() {
  local cache_dir="$1"
  local prefix="$2"
  local head_sha="$3"
  local ttl_minutes="${4:-30}"
  local no_cache="${5:-false}"

  if [[ "$no_cache" == "true" ]]; then
    log_debug "Cache bypass requested (--no-cache)"
    return 1
  fi

  local cache_file
  cache_file=$(gate_get_cache_file "$cache_dir" "$prefix" "$head_sha")

  if [[ -f "$cache_file" ]]; then
    local cache_age_seconds
    cache_age_seconds=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0) ))
    local cache_ttl_seconds=$((ttl_minutes * 60))

    if [[ $cache_age_seconds -lt $cache_ttl_seconds ]]; then
      log_debug "Using cached result (${cache_age_seconds}s old): $cache_file"
      cat "$cache_file"
      return 0
    else
      log_debug "Cache expired (${cache_age_seconds}s old), re-running checks"
      rm -f "$cache_file"
    fi
  fi
  return 1
}

# Write a result to the cache
# Usage: gate_write_cache "$CACHE_DIR" "prefix" "$head_sha" "$result_json"
gate_write_cache() {
  local cache_dir="$1"
  local prefix="$2"
  local head_sha="$3"
  local result_json="$4"

  mkdir -p "$cache_dir"
  local cache_file
  cache_file=$(gate_get_cache_file "$cache_dir" "$prefix" "$head_sha")
  echo "$result_json" > "$cache_file"
  log_debug "Result cached: $cache_file"

  # Prune old cache files (keep last 20)
  find "$cache_dir" -name "${prefix}-*.json" -type f 2>/dev/null | \
    sort -t'-' -k2,2n | head -n -20 | xargs rm -f 2>/dev/null || true
}

# ============================================================
# Report Generation Functions
# ============================================================

# Build a gate report in JSON format
# Usage: report=$(gate_build_report "$identifier" "$head_sha" "$checks_json" "$gate_status" "$gate_summary" "$duration")
gate_build_report() {
  local identifier="$1"
  local head_sha="$2"
  local checks_json="$3"
  local gate_status="$4"
  local gate_summary="$5"
  local duration="$6"

  local timestamp
  timestamp=$(timestamp)

  jq -n \
    --arg identifier "$identifier" \
    --arg head_sha "$head_sha" \
    --arg timestamp "$timestamp" \
    --arg gate_status "$gate_status" \
    --arg gate_summary "$gate_summary" \
    --argjson duration "$duration" \
    --argjson checks "$checks_json" \
    '{
      identifier: $identifier,
      head_sha: $head_sha,
      timestamp: $timestamp,
      gate_status: $gate_status,
      gate_summary: $gate_summary,
      duration_seconds: $duration,
      checks: $checks
    }'
}

# Print a human-readable report header
# Usage: gate_print_report_header "PR Validation Gate" "PR #123" "$head_sha" "$duration"
gate_print_report_header() {
  local title="$1"
  local subtitle="$2"
  local head_sha="$3"
  local duration="$4"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  $title${NC}"
  if [[ -n "$subtitle" ]]; then
    echo -e "${BOLD}  $subtitle${NC}"
  fi
  echo -e "${BOLD}════════════════════════════════════════════════${NC}"
  echo ""
  echo "  SHA:      ${head_sha:0:12}"
  echo "  Duration: ${duration}s"
  echo ""
}

# Print a check result line in human-readable format
# Usage: gate_print_check_result "$check_name" "$status" "$duration"
gate_print_check_result() {
  local name="$1"
  local status="$2"
  local dur="$3"

  local icon color
  case "$status" in
    pass) icon="✓"; color="$GREEN" ;;
    fail) icon="✗"; color="$RED" ;;
    warn) icon="⚠"; color="$YELLOW" ;;
    skip) icon="○"; color="$CYAN" ;;
    *)    icon="?"; color="$NC" ;;
  esac
  printf "  %b%s%b  %-12s %bs%b\n" "$color" "$icon" "$NC" "$name" "$NC" "$dur" "$NC"
}

# Print detailed failures and remediations
# Usage: gate_print_failures "$report_json"
gate_print_failures() {
  local report="$1"

  echo ""
  local has_issues=false
  while IFS= read -r check_json; do
    local check_name check_status check_output
    check_name=$(echo "$check_json" | jq -r '.name')
    check_status=$(echo "$check_json" | jq -r '.status')
    check_output=$(echo "$check_json" | jq -r '.output // ""')

    if [[ "$check_status" == "fail" || "$check_status" == "warn" ]]; then
      has_issues=true
      if [[ "$check_status" == "fail" ]]; then
        echo -e "  ${RED}[${check_name^^}]${NC} FAILED"
      else
        echo -e "  ${YELLOW}[${check_name^^}]${NC} WARNING"
      fi

      if [[ -n "$check_output" ]]; then
        echo "$check_output" | head -5 | sed 's/^/    /'
      fi

      # Print remediations
      local rems
      rems=$(echo "$check_json" | jq -r '.remediations[]? // empty')
      if [[ -n "$rems" ]]; then
        echo "    Remediation:"
        echo "$rems" | sed 's/^/      • /'
      fi
      echo ""
    fi
  done < <(echo "$report" | jq -c '.checks[]')
}

# Print the final gate status
# Usage: gate_print_status "$gate_status" "$gate_summary" "$identifier"
gate_print_status() {
  local gate_status="$1"
  local gate_summary="$2"
  local identifier="$3"

  echo -e "${BOLD}────────────────────────────────────────────────${NC}"
  case "$gate_status" in
    PASS)
      echo -e "  ${GREEN}${BOLD}✓ GATE PASSED${NC} - $gate_summary"
      echo -e "  ${GREEN}Merge is cleared for: $identifier${NC}"
      ;;
    FAIL)
      echo -e "  ${RED}${BOLD}✗ GATE BLOCKED${NC} - $gate_summary"
      echo -e "  ${RED}Merge is BLOCKED for: $identifier${NC}"
      echo -e "  Fix the above failures and re-run the gate."
      ;;
    WARN)
      echo -e "  ${YELLOW}${BOLD}⚠ GATE PASSED WITH WARNINGS${NC} - $gate_summary"
      echo -e "  ${YELLOW}Merge is cleared (warnings are non-blocking): $identifier${NC}"
      echo -e "  Consider addressing warnings before merging."
      ;;
    ERROR)
      echo -e "  ${RED}${BOLD}? GATE ERROR${NC} - $gate_summary"
      echo -e "  Gate could not complete. Check logs above."
      ;;
    SKIP|BYPASS)
      echo -e "  ${YELLOW}${BOLD}⚠ GATE BYPASSED${NC} - $gate_summary"
      ;;
  esac
  echo -e "${BOLD}════════════════════════════════════════════════${NC}"
  echo ""
}

# ============================================================
# Check Runner Functions
# ============================================================

# Build a check result in JSON format
# Usage: result=$(gate_build_check_result "$name" "$status" "$output" "$details" "$duration" "$blocking" "$remediations_json")
gate_build_check_result() {
  local name="$1"
  local status="$2"
  local output="$3"
  local details="${4:-}"
  local duration="${5:-0}"
  local blocking="${6:-true}"
  local remediations_json="${7:-[]}"

  jq -n \
    --arg name "$name" \
    --arg status "$status" \
    --arg output "$output" \
    --arg details "$details" \
    --argjson duration "$duration" \
    --argjson blocking "$blocking" \
    --argjson remediations "$remediations_json" \
    '{
      name: $name,
      status: $status,
      output: $output,
      details: $details,
      duration_seconds: $duration,
      blocking: $blocking,
      remediations: $remediations
    }'
}

# Build a remediations JSON array from bash array
# Usage: remediations_json=$(gate_build_remediations "${remediations[@]}")
gate_build_remediations() {
  printf '%s\n' "$@" | jq -R . | jq -s . 2>/dev/null || echo "[]"
}

# Run a command with timeout and capture output
# Usage: if gate_run_check_command "$timeout" "$cmd" output_var; then ...
gate_run_check_command() {
  local timeout_sec="$1"
  local cmd="$2"
  local output_var="$3"

  local tmp_out; tmp_out=$(mktemp)
  local exit_code=0

  timeout "$timeout_sec" bash -c "$cmd" 2>&1 > "$tmp_out" || exit_code=$?
  eval "$output_var=\$(cat \"$tmp_out\")"
  rm -f "$tmp_out"

  return $exit_code
}

# Determine overall gate status from check results
# Usage: gate_status=$(gate_determine_status "$checks_json" "$block_on_warn")
gate_determine_status() {
  local checks_json="$1"
  local block_on_warn="${2:-false}"

  local has_fail=false
  local has_warn=false
  local has_blocking_fail=false

  # Check each result
  while IFS= read -r result; do
    local c_status c_blocking
    c_status=$(echo "$result" | jq -r '.status')
    c_blocking=$(echo "$result" | jq -r '.blocking // true')

    case "$c_status" in
      fail)
        has_fail=true
        if [[ "$c_blocking" == "true" ]]; then
          has_blocking_fail=true
        fi
        ;;
      warn)
        has_warn=true
        ;;
    esac
  done < <(echo "$checks_json" | jq -c '.[]')

  # Determine status
  if [[ "$has_blocking_fail" == "true" ]]; then
    echo "FAIL"
  elif [[ "$has_fail" == "true" ]]; then
    echo "FAIL"
  elif [[ "$has_warn" == "true" ]] && [[ "$block_on_warn" == "true" ]]; then
    echo "FAIL"
  elif [[ "$has_warn" == "true" ]]; then
    echo "WARN"
  else
    echo "PASS"
  fi
}

# Generate gate summary message from status
# Usage: gate_summary=$(gate_generate_summary "$gate_status" "$checks_json" "$block_on_warn")
gate_generate_summary() {
  local gate_status="$1"
  local checks_json="$2"
  local block_on_warn="${3:-false}"

  case "$gate_status" in
    FAIL)
      local fail_count
      if [[ "$block_on_warn" == "true" ]]; then
        fail_count=$(echo "$checks_json" | jq '[.[] | select(.status == "fail" or .status == "warn")] | length')
        echo "$fail_count check(s) failed (warnings treated as failures) - merge is BLOCKED"
      else
        fail_count=$(echo "$checks_json" | jq '[.[] | select(.status == "fail")] | length')
        echo "$fail_count check(s) failed - merge is BLOCKED"
      fi
      ;;
    WARN)
      local warn_count
      warn_count=$(echo "$checks_json" | jq '[.[] | select(.status == "warn")] | length')
      echo "$warn_count warning(s) detected - merge is cleared with caution"
      ;;
    PASS)
      echo "All checks passed - merge is cleared"
      ;;
    *)
      echo "Unknown status"
      ;;
  esac
}

# ============================================================
# Issue Creation Functions
# ============================================================

# Check if an issue already exists for a specific gate finding
# Usage: if gate_issue_exists "$gate_name" "$check_name"; then ...
gate_issue_exists() {
  local gate_name="$1"
  local check_name="$2"

  if ! command -v gh &>/dev/null; then
    log_debug "gh CLI not available, skipping duplicate check"
    return 1
  fi

  # Search for open issues with gate-finding label and matching title
  local search_title="[Gate] ${gate_name}: ${check_name}"
  local existing_issues
  existing_issues=$(gh issue list \
    --state open \
    --label "gate-finding" \
    --search "$search_title" \
    --json number,title \
    --limit 5 2>/dev/null || echo "[]")

  local issue_count
  issue_count=$(echo "$existing_issues" | jq -r 'length' 2>/dev/null || echo "0")

  if [[ "$issue_count" -gt 0 ]]; then
    log_debug "Found existing issue for gate finding: $search_title"
    return 0
  fi

  return 1
}

# Create a GitHub issue from a gate finding
# Usage: gate_create_issue "$gate_name" "$check_json" "$pr_number"
gate_create_issue() {
  local gate_name="$1"
  local check_json="$2"
  local pr_number="${3:-}"

  # Extract check details
  local check_name check_status check_output check_details check_blocking remediations
  check_name=$(echo "$check_json" | jq -r '.name')
  check_status=$(echo "$check_json" | jq -r '.status')
  check_output=$(echo "$check_json" | jq -r '.output // ""')
  check_details=$(echo "$check_json" | jq -r '.details // ""')
  check_blocking=$(echo "$check_json" | jq -r '.blocking // true')
  remediations=$(echo "$check_json" | jq -r '.remediations[]? // empty' 2>/dev/null || echo "")

  # Determine priority based on status and blocking flag
  local priority
  if [[ "$check_status" == "fail" && "$check_blocking" == "true" ]]; then
    priority="P1"
  elif [[ "$check_status" == "fail" ]]; then
    priority="P2"
  else
    priority="P2"
  fi

  # Build issue title
  local issue_title="[Gate] ${gate_name}: ${check_name} failed"

  # Build issue body
  local issue_body
  issue_body=$(cat <<EOF
## Gate Finding

This issue was automatically created from a promotion gate failure.

### Details

- **Gate:** ${gate_name}
- **Check:** ${check_name}
- **Status:** ${check_status}
- **Blocking:** ${check_blocking}
- **Priority:** ${priority}

### Finding

${check_output}

EOF
)

  # Add details if present
  if [[ -n "$check_details" && "$check_details" != "null" ]]; then
    issue_body+=$(cat <<EOF

### Check Output

\`\`\`
${check_details}
\`\`\`

EOF
)
  fi

  # Add remediations if present
  if [[ -n "$remediations" ]]; then
    issue_body+=$(cat <<EOF

### Remediation Steps

EOF
)
    echo "$remediations" | while IFS= read -r remediation; do
      issue_body+="- $remediation"$'\n'
    done
    issue_body+=$'\n'
  fi

  # Add reproduction command
  local script_path="${BASH_SOURCE[1]}"
  local script_name
  script_name=$(basename "$script_path" 2>/dev/null || echo "gate script")
  issue_body+=$(cat <<EOF

### Reproduction

Run the gate again to reproduce:

\`\`\`bash
./${script_name}
\`\`\`

EOF
)

  # Add PR link if available
  if [[ -n "$pr_number" ]]; then
    issue_body+=$(cat <<EOF

### Related PR

This finding was discovered during promotion gate validation for PR #${pr_number}.

EOF
)
  fi

  # Add footer
  issue_body+=$(cat <<EOF

---

*Automated issue created from gate finding*
*Gate: ${gate_name}*
*Check: ${check_name}*
EOF
)

  # Determine labels
  local labels="bug,gate-finding,${priority}"
  if [[ "$check_status" == "warn" ]]; then
    labels+=",warning"
  fi

  # Create the issue
  log_info "Creating issue: $issue_title"
  local issue_url
  if issue_url=$(gh issue create \
    --title "$issue_title" \
    --body "$issue_body" \
    --label "$labels" 2>&1); then
    log_info "✓ Issue created: $issue_url"
    echo "$issue_url"
    return 0
  else
    log_error "✗ Failed to create issue: $issue_url"
    return 1
  fi
}

# Create issues from all failed/warning checks in a gate report
# Usage: gate_create_issues_from_report "$gate_name" "$report_json" "$pr_number" "$dry_run"
gate_create_issues_from_report() {
  local gate_name="$1"
  local report_json="$2"
  local pr_number="${3:-}"
  local dry_run="${4:-false}"

  if ! command -v gh &>/dev/null; then
    log_error "gh CLI is required to create issues but is not installed"
    return 1
  fi

  if ! gh auth status &>/dev/null 2>&1; then
    log_error "gh CLI is not authenticated. Run 'gh auth login' first."
    return 1
  fi

  local created_count=0
  local skipped_count=0
  local failed_count=0

  # Process each failed or warning check
  while IFS= read -r check_json; do
    local check_name check_status
    check_name=$(echo "$check_json" | jq -r '.name')
    check_status=$(echo "$check_json" | jq -r '.status')

    # Skip if check passed
    if [[ "$check_status" == "pass" || "$check_status" == "skip" ]]; then
      continue
    fi

    # Check for duplicates
    if gate_issue_exists "$gate_name" "$check_name"; then
      log_info "Skipping duplicate issue for: $check_name"
      skipped_count=$((skipped_count + 1))
      continue
    fi

    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
      log_info "[DRY RUN] Would create issue for: $check_name (status: $check_status)"
      created_count=$((created_count + 1))
      continue
    fi

    # Create the issue
    if gate_create_issue "$gate_name" "$check_json" "$pr_number"; then
      created_count=$((created_count + 1))
    else
      failed_count=$((failed_count + 1))
    fi
  done < <(echo "$report_json" | jq -c '.checks[]')

  # Print summary
  echo ""
  log_info "Issue creation summary:"
  log_info "  Created: $created_count"
  log_info "  Skipped (duplicates): $skipped_count"
  if [[ $failed_count -gt 0 ]]; then
    log_warn "  Failed: $failed_count"
  fi
  echo ""

  return 0
}
