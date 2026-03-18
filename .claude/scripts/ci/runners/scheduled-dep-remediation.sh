#!/usr/bin/env bash
# ============================================================
# Script: scheduled-dep-remediation.sh
# Purpose: Scheduled runner for automated dependency remediation
#
# This script is designed to be run on a schedule (e.g., weekly cron job)
# to automatically apply safe dependency patches and create PRs for
# manual review when needed.
#
# Usage:
#   ./scripts/ci/runners/scheduled-dep-remediation.sh [OPTIONS]
#
# Options:
#   --auto-commit       Automatically commit safe patches (default: false)
#   --auto-pr           Automatically create PRs for all fixes (default: false)
#   --ecosystem SYSTEM  Target ecosystem: npm|python|all (default: all)
#   --notify EMAIL      Send notification email on completion
#   --slack-webhook URL Post notification to Slack webhook
#   --verbose           Show detailed output
#   --help              Show this help
#
# Environment Variables:
#   REMEDIATION_MODE         Override mode (auto|pr|dry-run)
#   REMEDIATION_ECOSYSTEM    Override ecosystem (npm|python|all)
#   REMEDIATION_SKIP_TESTS   Skip tests (true|false)
#   SLACK_WEBHOOK_URL        Slack webhook for notifications
#
# Exit codes:
#   0 - Remediation successful or no fixes needed
#   1 - Remediation failed
#   2 - Configuration error
#
# Scheduling Examples:
#
#   # Cron: Run every Monday at 2 AM
#   0 2 * * 1 /path/to/scheduled-dep-remediation.sh --auto-commit
#
#   # GitHub Actions: Weekly scheduled workflow
#   # (Note: This should be in a local script, not .github/workflows/)
#   schedule:
#     - cron: '0 2 * * 1'
#
# Integration:
#   - Can be run via cron, systemd timer, or CI scheduler
#   - Integrates with scripts/ci/dep-remediation.sh
#   - Sends notifications on completion/failure
#
# Related:
#   - scripts/ci/dep-remediation.sh - Main remediation script
#   - Issue #1041 - Automated remediation workflow
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REMEDIATION_SCRIPT="$SCRIPT_DIR/../dep-remediation.sh"

# ─── Defaults ─────────────────────────────────────────────────────────────────

AUTO_COMMIT=${REMEDIATION_AUTO_COMMIT:-false}
AUTO_PR=${REMEDIATION_AUTO_PR:-false}
ECOSYSTEM=${REMEDIATION_ECOSYSTEM:-"all"}
NOTIFY_EMAIL=""
SLACK_WEBHOOK=${SLACK_WEBHOOK_URL:-""}
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-commit)    AUTO_COMMIT=true; shift ;;
    --auto-pr)        AUTO_PR=true; shift ;;
    --ecosystem)      ECOSYSTEM="$2"; shift 2 ;;
    --notify)         NOTIFY_EMAIL="$2"; shift 2 ;;
    --slack-webhook)  SLACK_WEBHOOK="$2"; shift 2 ;;
    --verbose)        VERBOSE=true; shift ;;
    --help|-h)        show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_setup() {
  if [[ ! -x "$REMEDIATION_SCRIPT" ]]; then
    log_error "Remediation script not found or not executable: $REMEDIATION_SCRIPT"
    exit 2
  fi

  if [[ "$AUTO_COMMIT" == "true" && "$AUTO_PR" == "true" ]]; then
    log_error "Cannot use both --auto-commit and --auto-pr"
    exit 2
  fi
}

# ─── Notifications ────────────────────────────────────────────────────────────

send_slack_notification() {
  local status="$1"
  local message="$2"

  if [[ -z "$SLACK_WEBHOOK" ]]; then
    return 0
  fi

  local color="good"
  local emoji=":white_check_mark:"
  if [[ "$status" == "failure" ]]; then
    color="danger"
    emoji=":x:"
  elif [[ "$status" == "warning" ]]; then
    color="warning"
    emoji=":warning:"
  fi

  local payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "$color",
      "title": "$emoji Scheduled Dependency Remediation",
      "text": "$message",
      "footer": "Automated via scheduled-dep-remediation.sh",
      "ts": $(date +%s)
    }
  ]
}
EOF
)

  curl -s -X POST "$SLACK_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "$payload" &>/dev/null || true
}

send_email_notification() {
  local status="$1"
  local message="$2"

  if [[ -z "$NOTIFY_EMAIL" ]]; then
    return 0
  fi

  if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
    log_warn "mail/sendmail not available - skipping email notification"
    return 0
  fi

  local subject="[Dependency Remediation] $status"

  if command -v mail &>/dev/null; then
    echo "$message" | mail -s "$subject" "$NOTIFY_EMAIL" || true
  elif command -v sendmail &>/dev/null; then
    {
      echo "Subject: $subject"
      echo ""
      echo "$message"
    } | sendmail "$NOTIFY_EMAIL" || true
  fi
}

# ─── Main Execution ───────────────────────────────────────────────────────────

main() {
  validate_setup

  log_info "Starting scheduled dependency remediation"
  log_info "Ecosystem: $ECOSYSTEM"
  log_info "Mode: $([ "$AUTO_PR" == "true" ] && echo "pr" || [ "$AUTO_COMMIT" == "true" ] && echo "auto" || echo "manual")"

  local start_time
  start_time=$(date +%s)

  # Determine mode
  local mode="auto"
  if [[ "$AUTO_PR" == "true" ]]; then
    mode="pr"
  fi

  # Build remediation command
  local cmd_args=(
    "--mode" "$mode"
    "--ecosystem" "$ECOSYSTEM"
  )

  if [[ "$VERBOSE" == "true" ]]; then
    cmd_args+=("--verbose")
  fi

  # Run remediation
  local exit_code=0
  local output
  output=$("$REMEDIATION_SCRIPT" "${cmd_args[@]}" 2>&1) || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Generate report
  local status="success"
  local message="Dependency remediation completed successfully in ${duration}s"

  if [[ $exit_code -ne 0 ]]; then
    status="failure"
    message="Dependency remediation failed after ${duration}s\n\nOutput:\n$output"
    log_error "$message"
  else
    log_info "$message"

    # Auto-commit if enabled and in auto mode
    if [[ "$AUTO_COMMIT" == "true" && "$mode" == "auto" ]]; then
      cd "$REPO_ROOT"
      if ! git diff --quiet; then
        log_info "Auto-committing safe patches..."
        git add -A
        git commit -m "fix(deps): Automated safe dependency patches

Applied patch-level security fixes automatically via scheduled remediation.

Duration: ${duration}s
Ecosystem: $ECOSYSTEM

Related: Issue #1041
Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>" || {
          log_error "Failed to commit changes"
          status="warning"
          message="Remediation succeeded but commit failed"
        }
      fi
    fi
  fi

  # Send notifications
  send_slack_notification "$status" "$message"
  send_email_notification "$status" "$message"

  # Print summary
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Scheduled Remediation Summary${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Status:      $status"
  echo "  Duration:    ${duration}s"
  echo "  Ecosystem:   $ECOSYSTEM"
  echo "  Mode:        $mode"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  exit $exit_code
}

main "$@"
