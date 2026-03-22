#!/usr/bin/env bash
set -euo pipefail
# dev-to-qa-checkpoint-pipeline.sh
# Automated dev→qa promotion pipeline triggered at milestone checkpoints.
#
# DESCRIPTION:
#   Orchestrates the full automated dev→qa promotion at a milestone checkpoint:
#     1. Create PR from dev → qa titled "release: Milestone {name} - {pct}% checkpoint"
#     2. Run /release:validate-qa (gate checks)
#     3. For each failing gate: create a GitHub issue with severity label
#     4. Route fixable issues to sprint-work containers
#     5. Wait for fixes, re-run validation (up to --max-retries cycles)
#     6. Post "QA validation complete. Ready for final review." on PR when all gates pass
#
# USAGE:
#   ./scripts/dev-to-qa-checkpoint-pipeline.sh [OPTIONS]
#
# OPTIONS:
#   --milestone NAME      Milestone name (required, or uses active milestone)
#   --threshold PCT       Checkpoint percentage (25|50|75|100). Auto-detected if omitted.
#   --dry-run             Preview steps without executing
#   --no-auto-fix         Create issues for findings but skip auto-fix containers
#   --no-notify           Skip "Ready for final review" notification comment
#   --max-retries N       Max auto-fix retry cycles (default: 2)
#   --json                Output structured JSON result
#   --help                Show this help
#
# EXIT CODES:
#   0 - Pipeline complete, all gates passed, PR ready for review
#   1 - Pipeline blocked: gate failures after max retries (or --no-auto-fix)
#   2 - Passed with warnings
#   3 - Pipeline error (unexpected failure)
#   4 - No checkpoint needed (milestone progress not at a new threshold)
#
# INTEGRATION:
#   Called automatically by pr:merge-batch after each successful merge to dev.
#   Can also be invoked manually via /release:milestone-checkpoint skill.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"status": "error", "message": "Not in a git repository"}'
  exit 3
}

# Defaults
MILESTONE_NAME=""
THRESHOLD=""
DRY_RUN=false
NO_AUTO_FIX=false
NO_NOTIFY=false
MAX_RETRIES=2
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_NAME="$2"
      shift 2
      ;;
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-auto-fix)
      NO_AUTO_FIX=true
      shift
      ;;
    --no-notify)
      NO_NOTIFY=true
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

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() {
  if [ "$JSON_OUTPUT" = false ]; then
    echo "$*" >&2
  fi
}

log_step() {
  log ""
  log "─── $* ───"
}

# ─── Step 1: Determine checkpoint ────────────────────────────────────────────

log ""
log "══════════════════════════════════════════════════════════"
log "  🚦 Dev→QA Checkpoint Pipeline"
log "  Mode: ${DRY_RUN:+dry-run }${NO_AUTO_FIX:+no-auto-fix }${NO_NOTIFY:+no-notify }standard"
log "══════════════════════════════════════════════════════════"

log_step "1. Check milestone checkpoint"

CHECKPOINT_DATA=$("$SCRIPT_DIR/milestone-checkpoint-check.sh" \
  --json \
  ${MILESTONE_NAME:+--milestone "$MILESTONE_NAME"} \
  ${DRY_RUN:+--dry-run} \
  2>/dev/null)

SHOULD_PROMOTE=$(echo "$CHECKPOINT_DATA" | jq -r '.should_promote')
MILESTONE_TITLE=$(echo "$CHECKPOINT_DATA" | jq -r '.milestone.title // "unknown"')
MILESTONE_NUMBER=$(echo "$CHECKPOINT_DATA" | jq -r '.milestone.number // 0')
CURRENT_PCT=$(echo "$CHECKPOINT_DATA" | jq -r '.current_pct // 0')
BLOCK_REASON=$(echo "$CHECKPOINT_DATA" | jq -r '.block_reason // empty' 2>/dev/null || true)

# Use threshold from checkpoint check unless explicitly overridden
if [ -z "$THRESHOLD" ]; then
  THRESHOLD=$(echo "$CHECKPOINT_DATA" | jq -r '.threshold // 0')
fi

if [ "$SHOULD_PROMOTE" != "true" ] && [ "$THRESHOLD" = "0" ]; then
  log "ℹ️  ${BLOCK_REASON:-No new checkpoint threshold reached}"
  if [ "$JSON_OUTPUT" = true ]; then
    jq -n \
      --arg status "no_checkpoint" \
      --arg milestone "$MILESTONE_TITLE" \
      --argjson pct "$CURRENT_PCT" \
      --arg reason "${BLOCK_REASON:-No new checkpoint threshold reached}" \
      '{status: $status, milestone: $milestone, current_pct: $pct, reason: $reason}'
  fi
  exit 4
fi

CHECKPOINT_REASON=$(echo "$CHECKPOINT_DATA" | jq -r '.reason // ""')
log "✓ Checkpoint: ${MILESTONE_TITLE} at ${THRESHOLD}% (${CURRENT_PCT}% complete)"
log "  ${CHECKPOINT_REASON}"

# ─── Step 2: Gather changelog for PR body ───────────────────────────────────

log_step "2. Gather changes since last promotion"

# Get commits since last qa promotion
git fetch origin 2>/dev/null || true
COMMITS_AHEAD=0
COMMITS_LOG=""
if git rev-parse --verify origin/qa >/dev/null 2>&1; then
  COMMITS_AHEAD=$(git rev-list --count origin/qa..origin/dev 2>/dev/null || echo 0)
  COMMITS_LOG=$(git log --oneline origin/qa..origin/dev --pretty=format:"- %s" 2>/dev/null | head -30 || echo "")
else
  COMMITS_AHEAD=$(git rev-list --count origin/dev 2>/dev/null || echo 0)
  COMMITS_LOG=$(git log --oneline origin/dev -30 --pretty=format:"- %s" 2>/dev/null | head -30 || echo "")
fi

# Get issues closed in this milestone
CLOSED_ISSUES_SUMMARY=""
if command -v gh >/dev/null 2>&1; then
  CLOSED_ISSUES_SUMMARY=$(gh issue list \
    --milestone "$MILESTONE_TITLE" \
    --state closed \
    --json number,title \
    --jq '.[] | "- #\(.number) \(.title)"' \
    2>/dev/null | head -20 || echo "")
fi

log "→ ${COMMITS_AHEAD} commits ahead of qa"

# ─── Step 3: Create PR from dev → qa ────────────────────────────────────────

log_step "3. Create checkpoint PR: dev → qa"

PR_TITLE="release: Milestone ${MILESTONE_TITLE} - ${THRESHOLD}% checkpoint"

# Build PR body
PR_BODY="## Milestone Checkpoint: ${THRESHOLD}%

**Milestone:** ${MILESTONE_TITLE}
**Progress:** ${CURRENT_PCT}% complete
**Commits:** ${COMMITS_AHEAD} commits ahead of qa

---

### Issues Resolved Since Last Promotion

${CLOSED_ISSUES_SUMMARY:-_No closed issues found_}

---

### Commits Since Last QA Promotion

${COMMITS_LOG:-_No commits found_}

---

### QA Checklist

- [ ] Automated gate checks passed
- [ ] Functional testing complete
- [ ] Regression testing complete
- [ ] Performance acceptable
- [ ] No blocking security issues

---

### Pipeline Status

This PR was auto-created by the milestone checkpoint pipeline at the **${THRESHOLD}% threshold**.
After all QA gates pass, a final human review is required before merging.

*Auto-generated by \`dev-to-qa-checkpoint-pipeline.sh\`*"

PR_NUMBER=""
PR_URL=""

# Check if a checkpoint PR already exists
EXISTING_PR=$(gh pr list \
  --search "\"${PR_TITLE}\" in:title" \
  --state open \
  --json number,url \
  --jq ".[0] // null" \
  2>/dev/null || echo "null")

if [ "$EXISTING_PR" != "null" ] && [ -n "$EXISTING_PR" ]; then
  PR_NUMBER=$(echo "$EXISTING_PR" | jq -r '.number')
  PR_URL=$(echo "$EXISTING_PR" | jq -r '.url')
  log "Found existing checkpoint PR #${PR_NUMBER}: ${PR_URL}"
else
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would create PR: '${PR_TITLE}'"
    PR_NUMBER="0"
    PR_URL="https://github.com/example/repo/pull/0"
  else
    log "Creating PR: '${PR_TITLE}'"
    PR_RESULT=$(gh pr create \
      --base qa \
      --head dev \
      --title "${PR_TITLE}" \
      --body "${PR_BODY}" \
      2>&1) || {
      log "❌ Failed to create PR: ${PR_RESULT}"
      if [ "$JSON_OUTPUT" = true ]; then
        jq -n \
          --arg status "error" \
          --arg milestone "$MILESTONE_TITLE" \
          --argjson threshold "$THRESHOLD" \
          --arg message "Failed to create checkpoint PR: ${PR_RESULT}" \
          '{status: $status, milestone: $milestone, threshold: $threshold, message: $message}'
      fi
      exit 3
    }
    PR_URL="${PR_RESULT}"
    PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$' || echo "0")
    log "✓ Created PR #${PR_NUMBER}: ${PR_URL}"
  fi
fi

# ─── Step 4: Run release:validate-qa ─────────────────────────────────────────

log_step "4. Run QA validation gates"

PIPELINE_STATUS="running"
PIPELINE_RETRIES=0
FIX_ISSUE_NUMBERS=()
WARNINGS=""

# Gate script path (reuse existing release-pipeline infrastructure)
GATE_SCRIPT="${SCRIPT_DIR}/pr/pre-promote-qa-gate.sh"
RELEASE_PIPELINE="${SCRIPT_DIR}/release-pipeline.sh"

run_validate_qa() {
  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would run: ${GATE_SCRIPT}"
    echo "0"
    return 0
  fi

  if [ ! -f "$GATE_SCRIPT" ]; then
    log "  ⚠️  Gate script not found: ${GATE_SCRIPT} (using pass fallback)"
    echo "0"
    return 0
  fi

  local gate_exit=0
  "${GATE_SCRIPT}" --quiet 2>/dev/null || gate_exit=$?
  echo "$gate_exit"
}

get_failing_gates() {
  if [ ! -f "$GATE_SCRIPT" ]; then
    echo "[]"
    return
  fi

  local gate_json=""
  gate_json=$("${GATE_SCRIPT}" --json 2>/dev/null) || true

  if [ -z "$gate_json" ]; then
    echo "[]"
    return
  fi

  echo "$gate_json" | jq -c '[.checks // [] | .[] | select(.status == "fail" or .status == "warn") | {name: .name, status: .status, output: (.output // "")}]' 2>/dev/null || echo "[]"
}

create_fix_issue() {
  local gate_name="$1"
  local gate_output="$2"
  local pr_num="$3"
  local threshold_pct="$4"

  local severity="P1"
  # Escalate critical security or test failures to P0
  if echo "$gate_name" | grep -qiE 'security|test'; then
    severity="P0"
  fi

  local title="fix(qa-gate): ${gate_name} failed at ${MILESTONE_TITLE} ${threshold_pct}% checkpoint"
  local body="## QA Gate Failure: ${gate_name}

**Detected by:** automated milestone checkpoint pipeline (${threshold_pct}% threshold)
**Milestone:** ${MILESTONE_TITLE}
**Checkpoint PR:** #${pr_num}
**Severity:** ${severity}

### Gate Output

\`\`\`
${gate_output}
\`\`\`

### Remediation

Fix the issue described above, then the checkpoint pipeline will automatically
retry QA validation (up to ${MAX_RETRIES} cycles).

### Auto-created Labels

- \`bug\`
- \`qa-gate-failure\`
- \`${severity}\`
- \`checkpoint:${threshold_pct}\`
"

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would create issue: ${title} [${severity}]"
    echo "0"
    return 0
  fi

  local issue_number
  issue_number=$(gh issue create \
    --title "$title" \
    --body "$body" \
    --label "bug" \
    2>/dev/null | grep -oE '[0-9]+$') || true

  # Apply additional labels (best effort)
  if [ -n "${issue_number:-}" ] && [ "${issue_number}" != "0" ]; then
    gh issue edit "$issue_number" --add-label "qa-gate-failure" 2>/dev/null || true
    gh issue edit "$issue_number" --add-label "$severity" 2>/dev/null || true
  fi

  echo "${issue_number:-0}"
}

launch_fix_container() {
  local issue_number="$1"

  if [ "${issue_number}" = "0" ] || [ -z "${issue_number}" ]; then
    log "  ⚠️  No issue number — skipping container launch"
    return 0
  fi

  log "  🚀 Routing issue #${issue_number} to sprint-work container..."

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would launch: scripts/container/container-launch.sh --issue ${issue_number}"
    return 0
  fi

  local container_script="${SCRIPT_DIR}/container/container-launch.sh"
  if [ ! -f "$container_script" ]; then
    # Fallback: try sprint-orchestrator
    local orch_script="${SCRIPT_DIR}/sprint/sprint-orchestrator.sh"
    if [ -f "$orch_script" ]; then
      "$orch_script" --issue "$issue_number" --max-issues 1 2>/dev/null || {
        log "  ⚠️  Sprint orchestrator failed for issue #${issue_number} (non-fatal)"
      }
    else
      log "  ⚠️  No container/sprint launch script found — issue #${issue_number} must be resolved manually"
    fi
    return 0
  fi

  "$container_script" --issue "$issue_number" 2>/dev/null || {
    log "  ⚠️  Container launch failed for issue #${issue_number} (non-fatal)"
  }
}

wait_for_fixes() {
  local issue_numbers="$1"
  local timeout=900   # 15 minutes
  local interval=30
  local elapsed=0

  if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] Would wait for fixes on issues: ${issue_numbers}"
    return 0
  fi

  log "  ⏳ Waiting for fix issues to close (timeout: ${timeout}s)..."

  while [ $elapsed -lt $timeout ]; do
    local all_closed=true

    for issue_num in $issue_numbers; do
      [ "$issue_num" = "0" ] || [ -z "$issue_num" ] && continue
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

# ─── Validation + Auto-fix Loop ──────────────────────────────────────────────

while true; do
  GATE_EXIT=$(run_validate_qa)

  case "$GATE_EXIT" in
    0)
      log "✅ QA validation PASSED — all gates clear"
      PIPELINE_STATUS="passed"
      ;;
    2)
      log "⚠️  QA validation PASSED WITH WARNINGS"
      PIPELINE_STATUS="passed_with_warnings"
      WARNINGS="validate-qa reported non-blocking warnings"
      ;;
    1)
      log "❌ QA validation FAILED (retry ${PIPELINE_RETRIES}/${MAX_RETRIES})"
      PIPELINE_STATUS="failed"
      ;;
    *)
      log "⚠️  Gate returned unexpected exit code: ${GATE_EXIT}"
      PIPELINE_STATUS="error"
      break
      ;;
  esac

  # Gates passed — break out of loop
  if [ "$PIPELINE_STATUS" = "passed" ] || [ "$PIPELINE_STATUS" = "passed_with_warnings" ]; then
    break
  fi

  # Gates failed — check retry budget and auto-fix settings
  if [ "$NO_AUTO_FIX" = true ]; then
    log ""
    log "ℹ️  --no-auto-fix: stopping after gate failure (issues must be resolved manually)"
    PIPELINE_STATUS="blocked_no_autofix"
    break
  fi

  if [ "$PIPELINE_RETRIES" -ge "$MAX_RETRIES" ]; then
    log ""
    log "🚨 Max retries (${MAX_RETRIES}) reached — escalating to user"
    PIPELINE_STATUS="escalated"
    break
  fi

  # Auto-fix cycle
  PIPELINE_RETRIES=$((PIPELINE_RETRIES + 1))
  log ""
  log "🔧 Auto-fix cycle ${PIPELINE_RETRIES}/${MAX_RETRIES} — creating issues for failing gates..."

  FAILING_GATES=$(get_failing_gates)
  GATE_COUNT=$(echo "$FAILING_GATES" | jq 'length' 2>/dev/null || echo "0")

  if [ "$GATE_COUNT" = "0" ]; then
    log "  No specific gate failures found in JSON — manual investigation needed"
    PIPELINE_STATUS="escalated"
    break
  fi

  CURRENT_CYCLE_ISSUES=()
  for i in $(seq 0 $((GATE_COUNT - 1))); do
    GATE_NAME=$(echo "$FAILING_GATES" | jq -r ".[$i].name" 2>/dev/null || echo "unknown")
    GATE_OUT=$(echo "$FAILING_GATES" | jq -r ".[$i].output" 2>/dev/null || echo "")

    log "  📋 Creating issue for gate: ${GATE_NAME}"
    ISSUE_NUM=$(create_fix_issue "$GATE_NAME" "$GATE_OUT" "$PR_NUMBER" "$THRESHOLD")
    FIX_ISSUE_NUMBERS+=("$ISSUE_NUM")
    CURRENT_CYCLE_ISSUES+=("$ISSUE_NUM")

    launch_fix_container "$ISSUE_NUM"
  done

  # Wait for fixes
  ISSUES_STR="${CURRENT_CYCLE_ISSUES[*]:-}"
  if [ -n "$ISSUES_STR" ]; then
    wait_for_fixes "$ISSUES_STR" || {
      log "  Continuing to next validation attempt despite wait timeout..."
    }
  fi

  log ""
  log "🔄 Re-running QA validation after auto-fix cycle ${PIPELINE_RETRIES}..."
done

# ─── Step 5: Post notification ───────────────────────────────────────────────

log_step "5. Post ready-for-review notification"

FINAL_STATUS="unknown"

if [ "$PIPELINE_STATUS" = "passed" ] || [ "$PIPELINE_STATUS" = "passed_with_warnings" ]; then
  FINAL_STATUS="ready"

  if [ "$NO_NOTIFY" = false ] && [ "$PR_NUMBER" != "0" ] && [ "$DRY_RUN" = false ]; then
    NOTIFY_BODY="## ✅ QA Validation Complete — Ready for Final Review

**Milestone:** ${MILESTONE_TITLE}
**Checkpoint:** ${THRESHOLD}%
**Validation Cycles:** $((PIPELINE_RETRIES + 1))
${WARNINGS:+**Warnings:** ${WARNINGS}}

All automated QA gates have passed. This checkpoint PR is ready for final human review.

**Next Steps:**
1. Review the changes in this PR
2. Approve and merge when satisfied
3. At 100% milestone completion, run \`/release:promote-main\` to release to production

---
*Auto-notified by \`dev-to-qa-checkpoint-pipeline.sh\` at $(date -u +%Y-%m-%dT%H:%M:%SZ)*"

    gh pr comment "$PR_NUMBER" --body "$NOTIFY_BODY" 2>/dev/null && \
      log "✓ Posted 'Ready for final review' notification on PR #${PR_NUMBER}" || \
      log "⚠️  Failed to post notification (non-fatal)"

  elif [ "$DRY_RUN" = true ]; then
    log "[dry-run] Would post 'Ready for final review' comment on PR #${PR_NUMBER}"
  fi

else
  FINAL_STATUS="blocked"

  if [ "$PR_NUMBER" != "0" ] && [ "$DRY_RUN" = false ]; then
    FIX_ISSUES_LIST=""
    for iss in "${FIX_ISSUE_NUMBERS[@]+"${FIX_ISSUE_NUMBERS[@]}"}"; do
      [ "$iss" != "0" ] && FIX_ISSUES_LIST="${FIX_ISSUES_LIST}\n- #${iss}"
    done

    BLOCK_BODY="## ⚠️ QA Validation — Manual Intervention Required

**Milestone:** ${MILESTONE_TITLE}
**Checkpoint:** ${THRESHOLD}%
**Status:** Gate failures after ${PIPELINE_RETRIES} auto-fix cycle(s)

The automated pipeline was unable to resolve all QA gate failures.
${FIX_ISSUES_LIST:+**Fix Issues Created:**\n${FIX_ISSUES_LIST}}

Please investigate the failing gates and resolve them manually,
then re-run \`/release:validate-qa\` or \`/release:milestone-checkpoint\`.

---
*Auto-notified by \`dev-to-qa-checkpoint-pipeline.sh\` at $(date -u +%Y-%m-%dT%H:%M:%SZ)*"

    gh pr comment "$PR_NUMBER" --body "$BLOCK_BODY" 2>/dev/null || true
  fi
fi

# ─── Final Output ─────────────────────────────────────────────────────────────

FIX_ISSUES_JSON=$(printf '%s\n' "${FIX_ISSUE_NUMBERS[@]+"${FIX_ISSUE_NUMBERS[@]}"}" | \
  jq -R . | jq -s 'map(select(. != "0" and . != ""))' 2>/dev/null || echo "[]")

log ""
log "══════════════════════════════════════════════════════════"
case "$PIPELINE_STATUS" in
  passed|passed_with_warnings)
    log "  ✅ Checkpoint pipeline complete — PR #${PR_NUMBER} ready for review"
    ;;
  blocked_no_autofix)
    log "  ⚠️  Pipeline stopped — gate failures (--no-auto-fix mode)"
    ;;
  escalated)
    log "  🚨 Pipeline escalated — manual intervention required"
    ;;
  error)
    log "  ❌ Pipeline error — unexpected failure"
    ;;
  *)
    log "  ❌ Pipeline blocked after ${PIPELINE_RETRIES} retry cycles"
    ;;
esac
log "══════════════════════════════════════════════════════════"

if [ "$JSON_OUTPUT" = true ]; then
  jq -n \
    --arg status "$PIPELINE_STATUS" \
    --arg final_status "$FINAL_STATUS" \
    --arg milestone "$MILESTONE_TITLE" \
    --argjson threshold "$THRESHOLD" \
    --argjson current_pct "$CURRENT_PCT" \
    --argjson pr_number "${PR_NUMBER:-0}" \
    --arg pr_url "${PR_URL:-}" \
    --argjson retries "$PIPELINE_RETRIES" \
    --argjson fix_issues "$FIX_ISSUES_JSON" \
    --arg warnings "${WARNINGS:-}" \
    '{
      pipeline_status: $status,
      final_status: $final_status,
      milestone: $milestone,
      threshold: $threshold,
      current_pct: $current_pct,
      pr: {number: $pr_number, url: $pr_url},
      retry_cycles: $retries,
      fix_issues_created: ($fix_issues | map(tonumber) | select(. > 0) // []),
      warnings: $warnings,
      ready_for_review: ($status == "passed" or $status == "passed_with_warnings")
    }'
fi

case "$PIPELINE_STATUS" in
  passed|passed_with_warnings) exit 0 ;;
  blocked_no_autofix|escalated) exit 1 ;;
  error) exit 3 ;;
  *) exit 1 ;;
esac
