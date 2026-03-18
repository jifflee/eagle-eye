#!/bin/bash
set -euo pipefail
# usage-monitor.sh
# Monitor Claude Code usage limits and report availability status
# size-ok: multi-format usage reporting with session tracking and limit calculations
#
# Usage:
#   ./scripts/usage-monitor.sh                    # Default: JSON output
#   ./scripts/usage-monitor.sh --format json      # JSON output
#   ./scripts/usage-monitor.sh --format text      # Human-readable text
#   ./scripts/usage-monitor.sh --session-hours N  # Override session window (default: 5)
#   ./scripts/usage-monitor.sh --weekly-days N    # Override weekly window (default: 7)
#
# Environment Variables:
#   CLAUDE_SESSION_TOKEN_LIMIT     # Session window token limit (default: 500000)
#   CLAUDE_WEEKLY_TOKEN_LIMIT      # Weekly window token limit (default: 5000000)
#   CLAUDE_SESSION_HOURS           # Session window duration (default: 5)
#   CLAUDE_WEEKLY_DAYS             # Weekly window duration (default: 7)
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - No metrics file found
#   3 - Dependencies missing (jq, date)

set -e

# Configuration
get_main_repo() {
  local toplevel git_common main_git
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo "."

  if [ -f "$toplevel/.git" ]; then
    git_common=$(git rev-parse --git-common-dir 2>/dev/null)
    main_git="${git_common%/worktrees/*}"
    echo "${main_git%/.git}"
  else
    echo "$toplevel"
  fi
}

MAIN_REPO=$(get_main_repo)
METRICS_DIR="${CLAUDE_METRICS_DIR:-$MAIN_REPO/.claude}"
METRICS_FILE="${CLAUDE_METRICS_FILE:-$METRICS_DIR/metrics.jsonl}"

# Default limits (configurable via environment or args)
SESSION_HOURS="${CLAUDE_SESSION_HOURS:-5}"
WEEKLY_DAYS="${CLAUDE_WEEKLY_DAYS:-7}"
SESSION_TOKEN_LIMIT="${CLAUDE_SESSION_TOKEN_LIMIT:-500000}"
WEEKLY_TOKEN_LIMIT="${CLAUDE_WEEKLY_TOKEN_LIMIT:-5000000}"

# Output format
OUTPUT_FORMAT="json"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --format)
      OUTPUT_FORMAT="$2"
      if [[ "$OUTPUT_FORMAT" != "json" && "$OUTPUT_FORMAT" != "text" ]]; then
        echo "Error: --format must be 'json' or 'text'" >&2
        exit 1
      fi
      shift 2
      ;;
    --session-hours)
      SESSION_HOURS="$2"
      if ! [[ "$SESSION_HOURS" =~ ^[0-9]+$ ]] || [ "$SESSION_HOURS" -le 0 ]; then
        echo "Error: --session-hours must be a positive integer" >&2
        exit 1
      fi
      shift 2
      ;;
    --weekly-days)
      WEEKLY_DAYS="$2"
      if ! [[ "$WEEKLY_DAYS" =~ ^[0-9]+$ ]] || [ "$WEEKLY_DAYS" -le 0 ]; then
        echo "Error: --weekly-days must be a positive integer" >&2
        exit 1
      fi
      shift 2
      ;;
    --session-limit)
      SESSION_TOKEN_LIMIT="$2"
      if ! [[ "$SESSION_TOKEN_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: --session-limit must be a non-negative integer" >&2
        exit 1
      fi
      shift 2
      ;;
    --weekly-limit)
      WEEKLY_TOKEN_LIMIT="$2"
      if ! [[ "$WEEKLY_TOKEN_LIMIT" =~ ^[0-9]+$ ]]; then
        echo "Error: --weekly-limit must be a non-negative integer" >&2
        exit 1
      fi
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Monitor Claude Code usage limits and report availability status."
      echo ""
      echo "Options:"
      echo "  --format FORMAT       Output format: json|text (default: json)"
      echo "  --session-hours N     Session window duration in hours (default: 5)"
      echo "  --weekly-days N       Weekly window duration in days (default: 7)"
      echo "  --session-limit N     Session token limit (default: 500000)"
      echo "  --weekly-limit N      Weekly token limit (default: 5000000)"
      echo ""
      echo "Environment Variables:"
      echo "  CLAUDE_SESSION_TOKEN_LIMIT    Override session token limit"
      echo "  CLAUDE_WEEKLY_TOKEN_LIMIT     Override weekly token limit"
      echo "  CLAUDE_SESSION_HOURS          Override session window hours"
      echo "  CLAUDE_WEEKLY_DAYS            Override weekly window days"
      echo ""
      echo "Examples:"
      echo "  $0                                    # JSON output with defaults"
      echo "  $0 --format text                      # Human-readable output"
      echo "  $0 --session-hours 4 --weekly-days 7  # Custom windows"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run '$0 --help' for usage information." >&2
      exit 1
      ;;
  esac
done

# Check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed" >&2
  exit 3
fi

if ! command -v date &>/dev/null; then
  echo "Error: date command is required but not found" >&2
  exit 3
fi

# Check if metrics file exists
if [ ! -f "$METRICS_FILE" ]; then
  # No metrics yet - return available status
  if [ "$OUTPUT_FORMAT" = "json" ]; then
    jq -n \
      --argjson session_limit "$SESSION_TOKEN_LIMIT" \
      --argjson weekly_limit "$WEEKLY_TOKEN_LIMIT" \
      --argjson session_hours "$SESSION_HOURS" \
      --argjson weekly_days "$WEEKLY_DAYS" \
      '{
        status: "available",
        message: "No usage data found - Claude Code is available",
        session: {
          window_hours: $session_hours,
          tokens_used: 0,
          tokens_limit: $session_limit,
          tokens_remaining: $session_limit,
          percentage_used: 0,
          available: true
        },
        weekly: {
          window_days: $weekly_days,
          tokens_used: 0,
          tokens_limit: $weekly_limit,
          tokens_remaining: $weekly_limit,
          percentage_used: 0,
          available: true
        },
        overall_available: true
      }'
  else
    echo "Claude Code Usage Status"
    echo "========================"
    echo ""
    echo "Status: AVAILABLE"
    echo "Message: No usage data found - Claude Code is available"
    echo ""
    echo "Session Window ($SESSION_HOURS hours):"
    echo "  Tokens Used: 0 / $SESSION_TOKEN_LIMIT"
    echo "  Available: YES"
    echo ""
    echo "Weekly Window ($WEEKLY_DAYS days):"
    echo "  Tokens Used: 0 / $WEEKLY_TOKEN_LIMIT"
    echo "  Available: YES"
  fi
  exit 0
fi

# Get current time
CURRENT_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_EPOCH_MS=$(date -u +%s)000  # Convert to milliseconds

# Calculate window start times
SESSION_SECONDS=$((SESSION_HOURS * 3600))
WEEKLY_SECONDS=$((WEEKLY_DAYS * 86400))

SESSION_START_EPOCH=$((CURRENT_EPOCH_MS / 1000 - SESSION_SECONDS))
WEEKLY_START_EPOCH=$((CURRENT_EPOCH_MS / 1000 - WEEKLY_SECONDS))

SESSION_START_TIME=$(date -u -d "@$SESSION_START_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$SESSION_START_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
WEEKLY_START_TIME=$(date -u -d "@$WEEKLY_START_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$WEEKLY_START_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

# Query session window usage
SESSION_TOKENS=$(jq -s \
  --arg since "$SESSION_START_TIME" \
  '[.[] | select(.timestamp >= $since and .status == "completed") | .tokens_total // 0] | add // 0' \
  "$METRICS_FILE")

# Query weekly window usage
WEEKLY_TOKENS=$(jq -s \
  --arg since "$WEEKLY_START_TIME" \
  '[.[] | select(.timestamp >= $since and .status == "completed") | .tokens_total // 0] | add // 0' \
  "$METRICS_FILE")

# Calculate remaining and percentages
SESSION_REMAINING=$((SESSION_TOKEN_LIMIT - SESSION_TOKENS))
WEEKLY_REMAINING=$((WEEKLY_TOKEN_LIMIT - WEEKLY_TOKENS))

SESSION_PCT=$((SESSION_TOKENS * 100 / SESSION_TOKEN_LIMIT))
WEEKLY_PCT=$((WEEKLY_TOKENS * 100 / WEEKLY_TOKEN_LIMIT))

# Determine availability
SESSION_AVAILABLE=true
WEEKLY_AVAILABLE=true
OVERALL_AVAILABLE=true

if [ "$SESSION_TOKENS" -ge "$SESSION_TOKEN_LIMIT" ]; then
  SESSION_AVAILABLE=false
  OVERALL_AVAILABLE=false
fi

if [ "$WEEKLY_TOKENS" -ge "$WEEKLY_TOKEN_LIMIT" ]; then
  WEEKLY_AVAILABLE=false
  OVERALL_AVAILABLE=false
fi

# Determine status message
if [ "$OVERALL_AVAILABLE" = true ]; then
  STATUS="available"
  MESSAGE="Claude Code is available"
else
  STATUS="limited"
  if [ "$SESSION_AVAILABLE" = false ] && [ "$WEEKLY_AVAILABLE" = false ]; then
    MESSAGE="Both session and weekly limits reached"
  elif [ "$SESSION_AVAILABLE" = false ]; then
    MESSAGE="Session limit reached (resets in $SESSION_HOURS hours from last activity)"
  else
    MESSAGE="Weekly limit reached (resets in $WEEKLY_DAYS days from last activity)"
  fi
fi

# Output results
if [ "$OUTPUT_FORMAT" = "json" ]; then
  jq -n \
    --arg status "$STATUS" \
    --arg message "$MESSAGE" \
    --arg current_time "$CURRENT_TIME" \
    --argjson session_hours "$SESSION_HOURS" \
    --argjson weekly_days "$WEEKLY_DAYS" \
    --argjson session_tokens "$SESSION_TOKENS" \
    --argjson session_limit "$SESSION_TOKEN_LIMIT" \
    --argjson session_remaining "$SESSION_REMAINING" \
    --argjson session_pct "$SESSION_PCT" \
    --arg session_available "$SESSION_AVAILABLE" \
    --arg session_start "$SESSION_START_TIME" \
    --argjson weekly_tokens "$WEEKLY_TOKENS" \
    --argjson weekly_limit "$WEEKLY_TOKEN_LIMIT" \
    --argjson weekly_remaining "$WEEKLY_REMAINING" \
    --argjson weekly_pct "$WEEKLY_PCT" \
    --arg weekly_available "$WEEKLY_AVAILABLE" \
    --arg weekly_start "$WEEKLY_START_TIME" \
    --arg overall_available "$OVERALL_AVAILABLE" \
    '{
      status: $status,
      message: $message,
      timestamp: $current_time,
      session: {
        window_hours: $session_hours,
        window_start: $session_start,
        tokens_used: $session_tokens,
        tokens_limit: $session_limit,
        tokens_remaining: $session_remaining,
        percentage_used: $session_pct,
        available: ($session_available == "true")
      },
      weekly: {
        window_days: $weekly_days,
        window_start: $weekly_start,
        tokens_used: $weekly_tokens,
        tokens_limit: $weekly_limit,
        tokens_remaining: $weekly_remaining,
        percentage_used: $weekly_pct,
        available: ($weekly_available == "true")
      },
      overall_available: ($overall_available == "true")
    }'
else
  # Human-readable text output
  echo "Claude Code Usage Status"
  echo "========================"
  echo ""
  echo "Status: $(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
  echo "Message: $MESSAGE"
  echo "Checked at: $CURRENT_TIME"
  echo ""
  echo "Session Window ($SESSION_HOURS hours since $SESSION_START_TIME):"
  echo "  Tokens Used: $SESSION_TOKENS / $SESSION_TOKEN_LIMIT ($SESSION_PCT%)"
  echo "  Tokens Remaining: $SESSION_REMAINING"
  if [ "$SESSION_AVAILABLE" = true ]; then
    echo "  Available: YES"
  else
    echo "  Available: NO (limit reached)"
  fi
  echo ""
  echo "Weekly Window ($WEEKLY_DAYS days since $WEEKLY_START_TIME):"
  echo "  Tokens Used: $WEEKLY_TOKENS / $WEEKLY_TOKEN_LIMIT ($WEEKLY_PCT%)"
  echo "  Tokens Remaining: $WEEKLY_REMAINING"
  if [ "$WEEKLY_AVAILABLE" = true ]; then
    echo "  Available: YES"
  else
    echo "  Available: NO (limit reached)"
  fi
  echo ""
  if [ "$OVERALL_AVAILABLE" = true ]; then
    echo "Overall: AVAILABLE"
  else
    echo "Overall: UNAVAILABLE"
  fi
fi
