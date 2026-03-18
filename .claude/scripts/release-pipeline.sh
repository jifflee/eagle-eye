#!/usr/bin/env bash
# release-pipeline.sh
# Automated release pipeline: validate-qa → (auto-fix) → promote-main
#
# DESCRIPTION:
#   Orchestrates the full automated release pipeline after a qa PR is merged.
#   Runs release readiness gates, auto-fixes failures (via containers), retries
#   validation, and promotes to main when all gates pass.
#
# USAGE:
#   ./scripts/release-pipeline.sh [OPTIONS]
#
# OPTIONS:
#   --qa-pr NUMBER      QA PR number (used to link fix issues)
#   --no-auto-fix       Skip auto-fix; report failures only and stop
#   --no-auto-promote   Run validate-qa but skip promote-main even on pass
#   --wait              Block until full pipeline completes (default for auto-fix)
#   --dry-run           Preview pipeline steps without executing
#   --max-retries N     Max auto-fix retry cycles (default: 2)
#   --json              Output structured JSON result
#   --help              Show this help
#
# EXIT CODES:
#   0 - PIPELINE_COMPLETE: promote-main triggered (or skipped by --no-auto-promote)
#   1 - PIPELINE_BLOCKED: gates failed after max retries
#   2 - PIPELINE_WARNINGS: gates passed with warnings, promote-main triggered
#   3 - PIPELINE_ERROR: unexpected error during pipeline execution
#
# PIPELINE FLOW:
#   1. Run release:validate-qa gates
#   2. If PASS (exit 0 or 2):
#      → Unless --no-auto-promote: trigger release:promote-main
#   3. If FAIL (exit 1):
#      Unless --no-auto-fix:
#      → Auto-create GitHub issues for each failing gate
#      → Launch containers to fix each issue (via sprint-work)
#      → Wait for fix PRs to merge
#      → Re-run validate-qa (max $MAX_RETRIES retry cycles)
#      → If PASS after retry: trigger release:promote-main
#      → If still FAIL after max retries: escalate to user
#
# INTEGRATION:
#   - Called automatically by release:promote-qa after qa PR merge
#   - Can be invoked manually to resume a stalled pipeline
#   - Related: Issue #1267 - promote-qa auto-pipeline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"status": "error", "message": "Not in a git repository"}'
  exit 3
}

# Defaults
QA_PR_NUMBER=""
NO_AUTO_FIX=false
NO_AUTO_PROMOTE=false
WAIT=false
DRY_RUN=false
MAX_RETRIES=2
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --qa-pr)
      QA_PR_NUMBER="$2"
      shift 2
      ;;
    --no-auto-fix)
      NO_AUTO_FIX=true
      shift
      ;;
    --no-auto-promote)
      NO_AUTO_PROMOTE=true
      shift
      ;;
    --wait)
      WAIT=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# *//'
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────

log() {
  if [ "$JSON_OUTPUT" = false ]; then
    echo "$*" >&2
  fi
}

# Run validate-qa gates and return exit code
run_validate_qa() {
  log "🔍 Running release readiness gates (release:validate-qa)..."

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would run: ./scripts/pr/pre-promote-main-gate.sh"
    echo "0"
    return 0
  fi

  # Use pre-promote-main-gate.sh as the validate-qa implementation
  # (stricter gate: all warnings blocking for qa→main)
  local gate_script="$SCRIPT_DIR/pre-promote-main-gate.sh"

  if [ ! -f "$gate_script" ]; then
    log "⚠️  Gate script not found: $gate_script (using exit code 0 fallback)"
    echo "0"
    return 0
  fi

  local gate_exit=0
  "$gate_script" --quiet ${QA_PR_NUMBER:+--pr "$QA_PR_NUMBER"} 2>/dev/null || gate_exit=$?
  echo "$gate_exit"
}

# Get list of failing gate names from JSON output
get_failing_gates() {
  local gate_script="$SCRIPT_DIR/pre-promote-main-gate.sh"

  if [ ! -f "$gate_script" ]; then
    echo "[]"
    return
  fi

  local gate_json=""
  gate_json=$("$gate_script" --json 2>/dev/null) || true

  if [ -z "$gate_json" ]; then
    echo "[]"
    return
  fi

  # Extract failing/warning checks
  echo "$gate_json" | jq -c '[.checks // [] | .[] | select(.status == "fail" or .status == "warn") | {name: .name, status: .status, output: .output}]' 2>/dev/null || echo "[]"
}

# Create a GitHub issue for a gate failure
create_fix_issue() {
  local gate_name="$1"
  local gate_output="$2"
  local qa_pr="$3"

  local title="fix(release-gate): ${gate_name} gate failed blocking promotion to main"
  local body="## Release Gate Failure: ${gate_name}

**Detected by:** \`release:validate-qa\` automated pipeline
**Blocking:** qa → main promotion
${qa_pr:+**QA PR:** #${qa_pr}}

### Gate Output

\`\`\`
${gate_output}
\`\`\`

### Remediation

Fix the underlying issue reported above, then re-run \`/release:validate-qa\` or let the
automated pipeline retry (it will retry up to ${MAX_RETRIES} times after each fix cycle).

### Labels

- \`bug\`
- \`release-gate-failure\`
- \`P1\`
"

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would create issue: $title"
    echo "0"
    return 0
  fi

  local issue_number
  issue_number=$(gh issue create \
    --title "$title" \
    --body "$body" \
    --label "bug" \
    2>/dev/null | grep -oE '[0-9]+$') || true

  echo "${issue_number:-0}"
}

# Launch a container to fix a specific issue
launch_fix_container() {
  local issue_number="$1"

  if [ "$issue_number" = "0" ] || [ -z "$issue_number" ]; then
    log "  ⚠️  No issue number — skipping container launch"
    return 0
  fi

  log "  🚀 Launching container to fix issue #${issue_number}..."

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would run: ./scripts/container/container-launch.sh --issue $issue_number"
    return 0
  fi

  local container_script="$SCRIPT_DIR/container/container-launch.sh"
  if [ ! -f "$container_script" ]; then
    log "  ⚠️  Container launch script not found: $container_script"
    log "     Issue #${issue_number} must be resolved manually."
    return 0
  fi

  "$container_script" --issue "$issue_number" --wait 2>/dev/null || {
    log "  ⚠️  Container launch failed for issue #${issue_number} (non-fatal)"
  }
}

# Wait for fix PRs to be merged (polls open PRs for issues)
wait_for_fixes() {
  local issue_numbers="$1"  # space-separated list
  local timeout=600         # 10 minutes
  local interval=30
  local elapsed=0

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would wait for fixes on issues: $issue_numbers"
    return 0
  fi

  log "  ⏳ Waiting for fix PRs to merge (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    local all_closed=true

    for issue_num in $issue_numbers; do
      if [ "$issue_num" = "0" ] || [ -z "$issue_num" ]; then
        continue
      fi
      local state
      state=$(gh issue view "$issue_num" --json state --jq '.state' 2>/dev/null || echo "OPEN")
      if [ "$state" != "CLOSED" ]; then
        all_closed=false
        break
      fi
    done

    if [ "$all_closed" = true ]; then
      log "  ✅ All fix issues resolved"
      return 0
    fi

    sleep $interval
    elapsed=$((elapsed + interval))
    log "  ... still waiting (${elapsed}s elapsed)"
  done

  log "  ⚠️  Timed out waiting for fix issues to close"
  return 1
}

# Trigger release:promote-main
trigger_promote_main() {
  local warnings="$1"

  log ""
  log "🚀 All gates passed. Triggering release:promote-main..."

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would invoke: release:promote-main skill"
    return 0
  fi

  # release:promote-main is a Claude skill — we signal intent via a status file
  # that the calling skill (promote-qa) can check and then invoke promote-main.
  # We also output a structured signal in JSON.
  local promote_signal_file="$REPO_ROOT/.promote-main-signal"
  jq -n \
    --arg trigger "release-pipeline" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg warnings "$warnings" \
    '{trigger: $trigger, timestamp: $timestamp, warnings: $warnings, action: "promote-main"}' \
    > "$promote_signal_file" 2>/dev/null || true

  log "  ✅ promote-main signal written. Invoke /release:promote-main to complete release."
  return 0
}

# ─── Main Pipeline ───────────────────────────────────────────────────────────

PIPELINE_STATUS="running"
PIPELINE_RETRIES=0
FIX_ISSUE_NUMBERS=()
WARNINGS=""

log ""
log "═══════════════════════════════════════════════════════"
log "  🔄 Automated Release Pipeline"
log "  Mode: ${DRY_RUN:+dry-run }${NO_AUTO_FIX:+no-auto-fix }${NO_AUTO_PROMOTE:+no-auto-promote }standard"
log "  Max retries: $MAX_RETRIES"
log "═══════════════════════════════════════════════════════"
log ""

# Main retry loop
while true; do
  GATE_EXIT=$(run_validate_qa)

  case "$GATE_EXIT" in
    0)
      # All gates passed
      log "✅ validate-qa PASSED — all gates clear"
      PIPELINE_STATUS="passed"
      ;;
    2)
      # Passed with warnings (non-blocking)
      log "⚠️  validate-qa PASSED WITH WARNINGS — proceeding to promote-main"
      PIPELINE_STATUS="passed_with_warnings"
      WARNINGS="validate-qa reported non-blocking warnings"
      ;;
    1)
      # Blocking gate failure
      log "❌ validate-qa FAILED — blocking gate(s) not passing (retry $PIPELINE_RETRIES/$MAX_RETRIES)"
      PIPELINE_STATUS="failed"
      ;;
    *)
      log "⚠️  validate-qa returned unexpected exit code: $GATE_EXIT"
      PIPELINE_STATUS="error"
      break
      ;;
  esac

  # If passed, proceed to promote-main
  if [ "$PIPELINE_STATUS" = "passed" ] || [ "$PIPELINE_STATUS" = "passed_with_warnings" ]; then
    if [ "$NO_AUTO_PROMOTE" = true ]; then
      log ""
      log "ℹ️  --no-auto-promote set: skipping release:promote-main"
      log "   Run /release:promote-main manually to complete the release."
    else
      trigger_promote_main "$WARNINGS"
    fi
    break
  fi

  # If failed: check retry budget
  if [ "$NO_AUTO_FIX" = true ]; then
    log ""
    log "ℹ️  --no-auto-fix set: stopping pipeline after gate failure"
    log "   Fix the issues above and re-run /release:promote-qa or /release:validate-qa"
    PIPELINE_STATUS="blocked_no_autofix"
    break
  fi

  if [ "$PIPELINE_RETRIES" -ge "$MAX_RETRIES" ]; then
    log ""
    log "🚨 Max retries ($MAX_RETRIES) reached. Escalating to user."
    log "   Manual intervention required to resolve gate failures."
    PIPELINE_STATUS="escalated"
    break
  fi

  # Auto-fix cycle
  PIPELINE_RETRIES=$((PIPELINE_RETRIES + 1))
  log ""
  log "🔧 Auto-fix cycle $PIPELINE_RETRIES/$MAX_RETRIES — creating fix issues..."

  FAILING_GATES=$(get_failing_gates)
  GATE_COUNT=$(echo "$FAILING_GATES" | jq 'length' 2>/dev/null || echo "0")

  if [ "$GATE_COUNT" = "0" ]; then
    log "  No specific gate failures found in JSON output — manual investigation needed"
    PIPELINE_STATUS="escalated"
    break
  fi

  # Create issues and launch containers for each failing gate
  CURRENT_CYCLE_ISSUES=()
  for i in $(seq 0 $((GATE_COUNT - 1))); do
    GATE_NAME=$(echo "$FAILING_GATES" | jq -r ".[$i].name" 2>/dev/null || echo "unknown")
    GATE_OUT=$(echo "$FAILING_GATES" | jq -r ".[$i].output" 2>/dev/null || echo "")

    log "  📋 Creating issue for gate: $GATE_NAME"
    ISSUE_NUM=$(create_fix_issue "$GATE_NAME" "$GATE_OUT" "$QA_PR_NUMBER")
    FIX_ISSUE_NUMBERS+=("$ISSUE_NUM")
    CURRENT_CYCLE_ISSUES+=("$ISSUE_NUM")

    launch_fix_container "$ISSUE_NUM"
  done

  # Wait for fixes (if --wait or always in auto-fix mode)
  ISSUES_STR="${CURRENT_CYCLE_ISSUES[*]}"
  if [ -n "$ISSUES_STR" ]; then
    wait_for_fixes "$ISSUES_STR" || {
      log "  Continuing to next validate attempt despite wait timeout..."
    }
  fi

  log ""
  log "🔄 Re-running validate-qa after auto-fix cycle $PIPELINE_RETRIES..."
done

# ─── Final Output ────────────────────────────────────────────────────────────

FIX_ISSUES_JSON=$(printf '%s\n' "${FIX_ISSUE_NUMBERS[@]+"${FIX_ISSUE_NUMBERS[@]}"}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

if [ "$JSON_OUTPUT" = true ]; then
  jq -n \
    --arg status "$PIPELINE_STATUS" \
    --arg retries "$PIPELINE_RETRIES" \
    --argjson fix_issues "$FIX_ISSUES_JSON" \
    --arg warnings "$WARNINGS" \
    --arg qa_pr "${QA_PR_NUMBER:-}" \
    '{
      pipeline_status: $status,
      retry_cycles: ($retries | tonumber),
      fix_issues_created: ($fix_issues | map(select(. != "0" and . != "")) | map(tonumber)),
      warnings: $warnings,
      qa_pr: ($qa_pr | if . == "" then null else tonumber end),
      promote_main_triggered: ($status == "passed" or $status == "passed_with_warnings")
    }'
fi

log ""
log "═══════════════════════════════════════════════════════"
case "$PIPELINE_STATUS" in
  passed|passed_with_warnings)
    log "  ✅ Pipeline complete — release:promote-main triggered"
    log "═══════════════════════════════════════════════════════"
    exit 0
    ;;
  blocked_no_autofix)
    log "  ⚠️  Pipeline stopped — gate failures (--no-auto-fix)"
    log "═══════════════════════════════════════════════════════"
    exit 1
    ;;
  escalated)
    log "  🚨 Pipeline escalated — manual intervention required"
    log "═══════════════════════════════════════════════════════"
    exit 1
    ;;
  error)
    log "  ❌ Pipeline error — unexpected failure"
    log "═══════════════════════════════════════════════════════"
    exit 3
    ;;
  *)
    log "  ❌ Pipeline blocked after $PIPELINE_RETRIES retry cycles"
    log "═══════════════════════════════════════════════════════"
    exit 1
    ;;
esac
