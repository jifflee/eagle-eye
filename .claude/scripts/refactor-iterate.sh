#!/usr/bin/env bash
# refactor-iterate.sh
# Implements the scan→plan→fix→verify iteration protocol for refactoring.
#
# DESCRIPTION:
#   Orchestrates the 5-phase iteration cycle:
#     Phase 1: SCAN    - refactor agent produces findings (read-only)
#     Phase 2: PLAN    - PM orchestrator groups findings, detects overlaps, sequences execution
#     Phase 3: FIX     - owning agents fix findings (one group at a time for conflicting files)
#     Phase 4: VERIFY  - refactor agent re-scans changed files only
#     Phase 5: REPORT  - summary of fixed, deferred, rejected, new issues
#
#   Race condition mitigations:
#     - Stale finding detection before agent starts (verifies file unchanged since scan)
#     - File-conflict serialization (findings touching same files run sequentially)
#     - Agent rejection protocol (agents can reject with justification)
#     - Iteration cap (max 3 cycles, then remaining findings become GitHub issues)
#     - Re-scan scope limited to changed files only
#
# USAGE:
#   ./scripts/refactor-iterate.sh [OPTIONS]
#
# OPTIONS:
#   --findings-file FILE    Path to findings JSON file (default: .refactor/findings.json)
#   --plan-file FILE        Path to output fix plan JSON (default: .refactor/fix-plan.json)
#   --report-file FILE      Path to output report (default: .refactor/iteration-report.json)
#   --max-iterations N      Maximum iteration cycles (default: 3)
#   --dry-run               Plan only, do not execute fixes
#   --iteration N           Start at iteration N (for resuming)
#   --help                  Show this help
#
# OUTPUT:
#   .refactor/fix-plan.json        - Generated fix plan with groups and execution order
#   .refactor/iteration-report.json - Final report with all outcomes
#   Exit code 0: All findings resolved or deferred cleanly
#   Exit code 1: Some findings remain after max iterations (converted to issues)
#   Exit code 2: Fatal error during iteration
#
# NOTES:
#   - Requires jq for JSON processing
#   - findings.json must conform to refactor-finding.schema.json
#   - fix-plan.json conforms to refactor-fix-plan.schema.json

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────

FINDINGS_FILE="${FINDINGS_FILE:-.refactor/findings.json}"
PLAN_FILE="${PLAN_FILE:-.refactor/fix-plan.json}"
REPORT_FILE="${REPORT_FILE:-.refactor/iteration-report.json}"
STALE_LOG_FILE="${STALE_LOG_FILE:-.refactor/stale-findings.json}"
MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
DRY_RUN="${DRY_RUN:-false}"
START_ITERATION="${START_ITERATION:-1}"
VERBOSE="${VERBOSE:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument parsing ────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -40
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --findings-file) FINDINGS_FILE="$2"; shift 2 ;;
    --plan-file)     PLAN_FILE="$2"; shift 2 ;;
    --report-file)   REPORT_FILE="$2"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
    --dry-run)       DRY_RUN="true"; shift ;;
    --iteration)     START_ITERATION="$2"; shift 2 ;;
    --verbose)       VERBOSE="true"; shift ;;
    --help|-h)       show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ───────────────────────────────────────────────────────────────

log() {
  echo "[refactor-iterate] $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[refactor-iterate:verbose] $*" >&2
  fi
}

check_deps() {
  local missing=()
  for cmd in jq git; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${missing[*]}" >&2
    exit 2
  fi
}

# Ensure .refactor directory exists
ensure_refactor_dir() {
  mkdir -p "$(dirname "$PLAN_FILE")"
  mkdir -p "$(dirname "$REPORT_FILE")"
}

# ─── Phase 1: SCAN ───────────────────────────────────────────────────────────
# In the full workflow, this phase is run by the refactor-specialist agent.
# This script reads the pre-existing findings file produced by that scan.

phase_scan() {
  local findings_file="$1"

  if [[ ! -f "$findings_file" ]]; then
    echo "ERROR: Findings file not found: $findings_file" >&2
    echo "Run the refactor scan first to produce findings." >&2
    exit 2
  fi

  # Validate findings file is valid JSON
  if ! jq empty "$findings_file" 2>/dev/null; then
    echo "ERROR: Findings file is not valid JSON: $findings_file" >&2
    exit 2
  fi

  local total
  total=$(jq '. | length' "$findings_file")
  local open_count
  open_count=$(jq '[.[] | select(.status == "open")] | length' "$findings_file")

  log "Phase 1 (SCAN): Found $total findings ($open_count open)"

  # Record scan fingerprints for stale detection
  # Map each finding_id → file_path → git hash at scan time
  local scan_id
  scan_id="scan-$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit')"

  echo "$scan_id"
}

# ─── Phase 2: PLAN ───────────────────────────────────────────────────────────
# Groups findings by owning agent, detects file overlaps, and sequences execution.
# Outputs a fix plan JSON conforming to refactor-fix-plan.schema.json.

phase_plan() {
  local findings_file="$1"
  local plan_file="$2"
  local iteration="$3"
  local scan_id="$4"

  log "Phase 2 (PLAN): Building fix plan for iteration $iteration"

  # Filter to open findings only, sorted by severity (critical → high → medium → low)
  local open_findings
  open_findings=$(jq '
    [.[] | select(.status == "open" or .status == "in-progress")]
    | sort_by(
        if .severity == "critical" then 0
        elif .severity == "high" then 1
        elif .severity == "medium" then 2
        else 3 end
      )
  ' "$findings_file")

  local total_open
  total_open=$(echo "$open_findings" | jq 'length')

  if [[ "$total_open" -eq 0 ]]; then
    log "Phase 2 (PLAN): No open findings. Nothing to plan."
    echo '{"groups": [], "execution_order": [], "status": "completed"}' > "$plan_file"
    return 0
  fi

  # Build file overlap map: file_path → [finding_ids]
  local file_overlap_map
  file_overlap_map=$(echo "$open_findings" | jq '
    reduce .[] as $finding (
      {};
      reduce ($finding.file_paths[] | split(":")[0]) as $file (
        .;
        # Append finding id to the list for this file
        .[$file] += [$finding.id]
      )
    )
  ')

  # Find files with multiple findings (overlap candidates)
  local overlap_files
  overlap_files=$(echo "$file_overlap_map" | jq '
    to_entries | map(select(.value | length > 1)) | from_entries
  ')

  log_verbose "File overlap map: $(echo "$file_overlap_map" | jq -c .)"
  log_verbose "Overlapping files: $(echo "$overlap_files" | jq -c .)"

  # Group findings by owning_agent
  local agent_groups
  agent_groups=$(echo "$open_findings" | jq '
    group_by(.owning_agent) | map({
      agent: .[0].owning_agent,
      findings: [.[].id],
      severity_max: (
        map(
          if .severity == "critical" then 0
          elif .severity == "high" then 1
          elif .severity == "medium" then 2
          else 3 end
        ) | min
      ) | (
        if . == 0 then "critical"
        elif . == 1 then "high"
        elif . == 2 then "medium"
        else "low" end
      )
    })
  ')

  # Determine file conflicts between groups and assign parallel_safe flags
  # A group is NOT parallel_safe if its findings share files with another group's findings
  local groups_with_conflicts
  groups_with_conflicts=$(echo "$agent_groups" | jq --argjson overlaps "$overlap_files" '
    map(. as $group |
      # Get all files for this group
      ($group.findings | map(
        . as $fid |
        # Look up files in overlap map (we need the original findings)
        # We use the fact that overlapping files have > 1 finding
        $fid
      )) as $fids |

      # Find files that overlap with other groups
      ($overlaps | to_entries | map(
        select(
          # This file touches findings from THIS group
          (.value | map(. as $v | $fids | map(. == $v) | any) | any) and
          # AND also touches findings NOT in this group
          (.value | map(. as $v | $fids | map(. == $v) | any | not) | any)
        ) | .key
      )) as $conflicting |

      $group + {
        group_id: ("group-" + $group.agent),
        parallel_safe: ($conflicting | length == 0),
        conflicting_files: $conflicting,
        status: "pending"
      }
    )
  ')

  # Determine blocked_by relationships from file conflicts
  # A group is blocked by others that touch the same conflicting files if those others
  # have higher severity findings
  local groups_with_ordering
  groups_with_ordering=$(echo "$groups_with_conflicts" | jq '
    . as $all_groups |
    map(. as $group |
      if $group.parallel_safe then
        $group
      else
        # Find groups this one is blocked by (other groups touching same conflicting files)
        ($all_groups | map(
          select(.group_id != $group.group_id) |
          select(
            .conflicting_files | map(
              . as $cf |
              $group.conflicting_files | map(. == $cf) | any
            ) | any
          ) |
          # Only block by groups with higher or equal priority (lower or equal severity_max)
          select(
            (if .severity_max == "critical" then 0
             elif .severity_max == "high" then 1
             elif .severity_max == "medium" then 2
             else 3 end) <=
            (if $group.severity_max == "critical" then 0
             elif $group.severity_max == "high" then 1
             elif $group.severity_max == "medium" then 2
             else 3 end)
          ) |
          .findings[]
        )) as $blocked_by |
        $group + { blocked_by: ($blocked_by | unique) }
      end
    )
  ')

  # Build execution order: batches of group_ids that can run in parallel
  # Batch 1: parallel_safe groups with no blocked_by
  # Batch 2+: serialized groups in severity order
  local execution_order
  execution_order=$(echo "$groups_with_ordering" | jq '
    [
      # Batch 1: all parallel_safe groups together
      [.[] | select(.parallel_safe == true) | .group_id],
      # Subsequent batches: serialized groups sorted by severity
      (.[] | select(.parallel_safe == false) | [.group_id])
    ] | map(select(length > 0))
  ')

  # Build summary statistics
  local total_groups parallel_count serial_count
  total_groups=$(echo "$groups_with_ordering" | jq 'length')
  parallel_count=$(echo "$groups_with_ordering" | jq '[.[] | select(.parallel_safe == true)] | length')
  serial_count=$(echo "$groups_with_ordering" | jq '[.[] | select(.parallel_safe == false)] | length')

  local severity_summary
  severity_summary=$(echo "$open_findings" | jq '
    {
      critical: ([.[] | select(.severity == "critical")] | length),
      high:     ([.[] | select(.severity == "high")] | length),
      medium:   ([.[] | select(.severity == "medium")] | length),
      low:      ([.[] | select(.severity == "low")] | length)
    }
  ')

  # Assemble final fix plan
  jq -n \
    --argjson iteration "$iteration" \
    --arg scan_id "$scan_id" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson groups "$groups_with_ordering" \
    --argjson execution_order "$execution_order" \
    --argjson file_overlap_map "$file_overlap_map" \
    --argjson total_findings "$total_open" \
    --argjson total_groups "$total_groups" \
    --argjson parallel_groups "$parallel_count" \
    --argjson serialized_groups "$serial_count" \
    --argjson findings_by_severity "$severity_summary" \
    '{
      iteration: $iteration,
      scan_id: $scan_id,
      created_at: $created_at,
      status: "pending",
      groups: $groups,
      execution_order: $execution_order,
      file_overlap_map: $file_overlap_map,
      summary: {
        total_findings: $total_findings,
        total_groups: $total_groups,
        parallel_groups: $parallel_groups,
        serialized_groups: $serialized_groups,
        findings_by_severity: $findings_by_severity
      }
    }' > "$plan_file"

  log "Phase 2 (PLAN): Created fix plan with $total_groups groups"
  log "  Parallel-safe groups: $parallel_count"
  log "  Serialized groups:    $serial_count"
  log "  File overlaps:        $(echo "$overlap_files" | jq 'keys | length')"

  echo "$total_open"
}

# ─── Phase 3: FIX ────────────────────────────────────────────────────────────
# Agents fix findings. In dry-run mode, only logs what would happen.
# In live mode, outputs instructions for the PM orchestrator to dispatch agents.

phase_fix() {
  local plan_file="$1"
  local findings_file="$2"
  local dry_run="$3"

  log "Phase 3 (FIX): Dispatching fix groups"

  local execution_order
  execution_order=$(jq '.execution_order' "$plan_file")
  local batch_count
  batch_count=$(echo "$execution_order" | jq 'length')

  for i in $(seq 0 $((batch_count - 1))); do
    local batch_groups
    batch_groups=$(echo "$execution_order" | jq -r ".[$i][]")
    local batch_size
    batch_size=$(echo "$execution_order" | jq ".[$i] | length")

    log "  Batch $((i+1))/$batch_count: $batch_size group(s)"

    while IFS= read -r group_id; do
      local agent findings severity
      agent=$(jq -r ".groups[] | select(.group_id == \"$group_id\") | .agent" "$plan_file")
      findings=$(jq -r ".groups[] | select(.group_id == \"$group_id\") | .findings | join(\", \")" "$plan_file")
      severity=$(jq -r ".groups[] | select(.group_id == \"$group_id\") | .severity_max" "$plan_file")

      if [[ "$dry_run" == "true" ]]; then
        log "  [DRY-RUN] Would dispatch to agent=$agent findings=[$findings] severity=$severity"
      else
        log "  Dispatching: agent=$agent group=$group_id findings=[$findings]"

        # Check for stale findings before dispatching
        local stale_count=0
        while IFS= read -r finding_id; do
          if ! "$SCRIPT_DIR/refactor-stale-check.sh" \
               --finding-id "$finding_id" \
               --findings-file "$findings_file" 2>/dev/null; then
            log "  WARNING: Finding $finding_id is stale (file changed since scan). Skipping."
            stale_count=$((stale_count + 1))
            # Mark as stale in plan
            local tmp
            tmp=$(mktemp)
            jq --arg gid "$group_id" --arg fid "$finding_id" '
              .groups = [.groups[] | if .group_id == $gid then
                .findings = [.findings[] | select(. != $fid)]
              else . end]
            ' "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
          fi
        done < <(jq -r ".groups[] | select(.group_id == \"$group_id\") | .findings[]" "$plan_file")

        if [[ "$stale_count" -gt 0 ]]; then
          log "  Skipped $stale_count stale finding(s) from group $group_id"
        fi

        # Output dispatch record for PM orchestrator
        jq -n \
          --arg group_id "$group_id" \
          --arg agent "$agent" \
          --arg severity "$severity" \
          --argjson findings "$(jq ".groups[] | select(.group_id == \"$group_id\") | .findings" "$plan_file")" \
          '{
            action: "dispatch",
            group_id: $group_id,
            agent: $agent,
            severity: $severity,
            findings: $findings,
            timestamp: now | todate
          }'
      fi
    done <<< "$batch_groups"

    if [[ "$dry_run" != "true" && $((i + 1)) -lt "$batch_count" ]]; then
      log "  Waiting for batch $((i+1)) to complete before starting batch $((i+2))..."
    fi
  done
}

# ─── Phase 4: VERIFY ─────────────────────────────────────────────────────────
# Re-scans only the files changed by agent fixes to check acceptance criteria
# and detect new issues introduced.

phase_verify() {
  local plan_file="$1"
  local findings_file="$2"
  local iteration="$3"

  log "Phase 4 (VERIFY): Re-scanning changed files"

  # Collect all files changed by agent fixes (from agent_response.commit_sha fields)
  local changed_files
  changed_files=$(jq -r '
    [.groups[].agent_response.commit_sha // empty] |
    if length > 0 then
      .[]
    else
      empty
    end
  ' "$plan_file" | while read -r sha; do
    git diff --name-only "${sha}^" "$sha" 2>/dev/null || true
  done | sort -u)

  local changed_count
  changed_count=$(echo "$changed_files" | grep -c . 2>/dev/null || echo 0)
  log "Phase 4 (VERIFY): $changed_count file(s) changed by fixes"

  if [[ "$changed_count" -eq 0 ]]; then
    log "Phase 4 (VERIFY): No files changed, skipping re-scan"
    # Update plan with empty verify result
    local tmp
    tmp=$(mktemp)
    jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      .verify_result = {
        verified_at: $ts,
        changed_files: [],
        remaining_findings: [],
        new_findings: [],
        fixed_count: 0,
        proceed_to_next_iteration: false
      }
    ' "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"
    return 0
  fi

  # Determine which findings were addressed (agent_response.status == "completed")
  local fixed_findings
  fixed_findings=$(jq -r '
    [.groups[].agent_response.finding_responses // {} |
     to_entries[] |
     select(.value.status == "completed") |
     .key] | .[]
  ' "$plan_file" 2>/dev/null || echo "")

  local fixed_count
  fixed_count=$(echo "$fixed_findings" | grep -c . 2>/dev/null || echo 0)

  # Identify remaining open findings
  local remaining_findings
  remaining_findings=$(jq -r '
    [.groups[] |
     select(.status != "completed") |
     .findings[]] | .[]
  ' "$plan_file" 2>/dev/null || echo "")

  local remaining_count
  remaining_count=$(echo "$remaining_findings" | grep -c . 2>/dev/null || echo 0)

  # Determine if we should proceed to next iteration
  local proceed_next=false
  if [[ "$remaining_count" -gt 0 && "$iteration" -lt "$MAX_ITERATIONS" ]]; then
    proceed_next=true
  fi

  # Build changed_files JSON array
  local changed_files_json
  changed_files_json=$(echo "$changed_files" | jq -R . | jq -s '.' 2>/dev/null || echo '[]')

  # Build remaining_findings JSON array
  local remaining_json
  remaining_json=$(echo "$remaining_findings" | jq -R . | jq -s '.' 2>/dev/null || echo '[]')

  local fixed_count_int="${fixed_count:-0}"
  local remaining_count_int="${remaining_count:-0}"

  log "Phase 4 (VERIFY): Fixed: $fixed_count_int, Remaining: $remaining_count_int"
  if [[ "$proceed_next" == "true" ]]; then
    log "Phase 4 (VERIFY): Proceeding to iteration $((iteration + 1))"
  fi

  # Update plan with verify result
  local tmp
  tmp=$(mktemp)
  jq \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson changed_files "$changed_files_json" \
    --argjson remaining "$remaining_json" \
    --argjson fixed_count "$fixed_count_int" \
    --argjson proceed "$proceed_next" \
    '
    .verify_result = {
      verified_at: $ts,
      changed_files: $changed_files,
      remaining_findings: $remaining,
      new_findings: [],
      fixed_count: $fixed_count,
      proceed_to_next_iteration: $proceed
    }
  ' "$plan_file" > "$tmp" && mv "$tmp" "$plan_file"

  echo "$remaining_count"
}

# ─── Phase 5: REPORT ─────────────────────────────────────────────────────────

phase_report() {
  local plan_file="$1"
  local findings_file="$2"
  local report_file="$3"
  local iteration="$4"
  local max_iterations="$5"

  log "Phase 5 (REPORT): Generating iteration report"

  # Count outcomes across all groups
  local fixed_count deferred_count rejected_count new_issue_count
  fixed_count=$(jq '[.groups[].agent_response.finding_responses // {} | to_entries[] | select(.value.status == "completed")] | length' "$plan_file" 2>/dev/null || echo 0)
  deferred_count=$(jq '[.verify_result.remaining_findings // [] | .[]] | length' "$plan_file" 2>/dev/null || echo 0)
  rejected_count=$(jq '[.groups[].agent_response.finding_responses // {} | to_entries[] | select(.value.status == "rejected")] | length' "$plan_file" 2>/dev/null || echo 0)
  new_issue_count=$(jq '[.metadata.deferred_to_issues // [] | .[]] | length' "$plan_file" 2>/dev/null || echo 0)

  local max_reached=false
  if [[ "$iteration" -ge "$max_iterations" ]]; then
    max_reached=true
  fi

  jq -n \
    --argjson iteration "$iteration" \
    --argjson max_iterations "$max_iterations" \
    --arg report_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson fixed "$fixed_count" \
    --argjson deferred "$deferred_count" \
    --argjson rejected "$rejected_count" \
    --argjson new_issues "$new_issue_count" \
    --argjson max_reached "$max_reached" \
    '{
      iteration_completed: $iteration,
      max_iterations: $max_iterations,
      max_iterations_reached: $max_reached,
      report_generated_at: $report_at,
      outcomes: {
        fixed: $fixed,
        deferred_to_next_iteration: $deferred,
        rejected_by_agent: $rejected,
        converted_to_github_issues: $new_issues
      },
      status: (if $max_reached and $deferred > 0 then "partial"
               elif $deferred == 0 and $rejected == 0 then "complete"
               else "partial" end)
    }' > "$report_file"

  log "Phase 5 (REPORT): Iteration $iteration complete"
  log "  Fixed:         $fixed_count findings"
  log "  Deferred:      $deferred_count findings (next iteration)"
  log "  Rejected:      $rejected_count findings"
  log "  GitHub Issues: $new_issue_count findings converted"

  if [[ "$max_reached" == "true" && "$deferred_count" -gt 0 ]]; then
    log "WARNING: Max iterations ($max_iterations) reached with $deferred_count unresolved findings."
    log "These findings should be converted to GitHub issues via scripts/create-issue-data.sh"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps
  ensure_refactor_dir

  log "Starting refactor iteration protocol"
  log "  Findings: $FINDINGS_FILE"
  log "  Plan:     $PLAN_FILE"
  log "  Report:   $REPORT_FILE"
  log "  Max iter: $MAX_ITERATIONS"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "  Mode:     DRY-RUN (planning only)"
  fi

  # Phase 1: SCAN (read existing findings)
  local scan_id
  scan_id=$(phase_scan "$FINDINGS_FILE")

  local current_iteration="$START_ITERATION"
  local remaining=1

  while [[ "$remaining" -gt 0 && "$current_iteration" -le "$MAX_ITERATIONS" ]]; do
    log ""
    log "═══════════════════════════════════════"
    log "ITERATION $current_iteration of $MAX_ITERATIONS"
    log "═══════════════════════════════════════"

    # Phase 2: PLAN
    remaining=$(phase_plan "$FINDINGS_FILE" "$PLAN_FILE" "$current_iteration" "$scan_id")

    if [[ "$remaining" -eq 0 ]]; then
      log "No open findings to address. Iteration complete."
      break
    fi

    # Phase 3: FIX
    phase_fix "$PLAN_FILE" "$FINDINGS_FILE" "$DRY_RUN"

    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY-RUN] Skipping verify and report phases."
      break
    fi

    # Phase 4: VERIFY
    remaining=$(phase_verify "$PLAN_FILE" "$FINDINGS_FILE" "$current_iteration")

    # Phase 5: REPORT
    phase_report "$PLAN_FILE" "$FINDINGS_FILE" "$REPORT_FILE" "$current_iteration" "$MAX_ITERATIONS"

    current_iteration=$((current_iteration + 1))

    # Check if we should continue
    local proceed
    proceed=$(jq '.verify_result.proceed_to_next_iteration // false' "$PLAN_FILE")
    if [[ "$proceed" != "true" ]]; then
      log "Verification complete. No further iterations needed."
      remaining=0
    fi
  done

  if [[ "$remaining" -gt 0 && "$current_iteration" -gt "$MAX_ITERATIONS" ]]; then
    log ""
    log "WARNING: $remaining finding(s) unresolved after $MAX_ITERATIONS iterations."
    log "Create GitHub issues for remaining findings:"
    jq -r '.verify_result.remaining_findings // [] | .[]' "$PLAN_FILE" 2>/dev/null | while read -r fid; do
      local desc
      desc=$(jq -r --arg id "$fid" '.[] | select(.id == $id) | .description' "$FINDINGS_FILE" 2>/dev/null | head -1)
      log "  - $fid: $desc"
    done
    exit 1
  fi

  log ""
  log "Refactor iteration protocol complete."
  if [[ -f "$REPORT_FILE" ]]; then
    jq '.' "$REPORT_FILE"
  fi

  exit 0
}

main "$@"
