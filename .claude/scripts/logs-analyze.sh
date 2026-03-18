#!/usr/bin/env bash
# logs-analyze.sh - Analyze CLI session logs
# Provides tools to view, search, and analyze session logs

set -euo pipefail

LOG_DIR="${CLAUDE_AGENTS_HOME:-$HOME/.claude-agents}/logs"
SESSION_LOG_DIR="$LOG_DIR/sessions"
ERROR_LOG_DIR="$LOG_DIR/errors"
SNAPSHOT_LOG_DIR="$LOG_DIR/snapshots"

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Show recent sessions
show_sessions() {
    local limit="${1:-10}"

    echo -e "${BLUE}Recent Sessions:${NC}"
    echo ""

    if [[ ! -d "$SESSION_LOG_DIR" ]]; then
        echo "No session logs found."
        return
    fi

    # List recent session files
    find "$SESSION_LOG_DIR" -type f -name "*.jsonl" | sort -r | head -n "$limit" | while read -r logfile; do
        local filename
        filename=$(basename "$logfile")
        local session_id
        session_id=$(echo "$filename" | sed -E 's/.*session-(.*)\.jsonl/\1/')
        local date
        date=$(echo "$filename" | sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/')

        # Get first and last event
        local first_event
        first_event=$(head -n 1 "$logfile" 2>/dev/null || echo "{}")
        local last_event
        last_event=$(tail -n 1 "$logfile" 2>/dev/null || echo "{}")

        local start_time
        start_time=$(echo "$first_event" | jq -r '.timestamp // "unknown"' 2>/dev/null || echo "unknown")
        local end_time
        end_time=$(echo "$last_event" | jq -r '.timestamp // "unknown"' 2>/dev/null || echo "unknown")
        local repo
        repo=$(echo "$first_event" | jq -r '.repo_info.repo // "unknown"' 2>/dev/null || echo "unknown")
        local branch
        branch=$(echo "$first_event" | jq -r '.repo_info.branch // "unknown"' 2>/dev/null || echo "unknown")

        # Count events
        local event_count
        event_count=$(wc -l < "$logfile" 2>/dev/null || echo 0)

        echo -e "${GREEN}Session ID:${NC} $session_id"
        echo -e "  Date: $date"
        echo -e "  Start: $start_time"
        echo -e "  End: $end_time"
        echo -e "  Repo: $repo"
        echo -e "  Branch: $branch"
        echo -e "  Events: $event_count"
        echo ""
    done
}

# Show recent errors
show_errors() {
    local limit="${1:-10}"

    echo -e "${RED}Recent Errors:${NC}"
    echo ""

    if [[ ! -d "$ERROR_LOG_DIR" ]]; then
        echo "No error logs found."
        return
    fi

    # List recent error files
    find "$ERROR_LOG_DIR" -type f -name "*.json" | sort -r | head -n "$limit" | while read -r errorfile; do
        local error_data
        error_data=$(cat "$errorfile")

        local timestamp
        timestamp=$(echo "$error_data" | jq -r '.timestamp // "unknown"')
        local command
        command=$(echo "$error_data" | jq -r '.command // "unknown"')
        local exit_code
        exit_code=$(echo "$error_data" | jq -r '.exit_code // "unknown"')
        local stderr
        stderr=$(echo "$error_data" | jq -r '.stderr // ""' | head -c 200)
        local repo
        repo=$(echo "$error_data" | jq -r '.repo_info.repo // "unknown"')
        local branch
        branch=$(echo "$error_data" | jq -r '.repo_info.branch // "unknown"')

        echo -e "${YELLOW}Error at $timestamp${NC}"
        echo -e "  Repo: $repo"
        echo -e "  Branch: $branch"
        echo -e "  Command: $command"
        echo -e "  Exit Code: $exit_code"
        if [[ -n "$stderr" ]]; then
            echo -e "  Error: ${stderr:0:200}..."
        fi
        echo -e "  Full details: $errorfile"
        echo ""
    done
}

# Analyze specific session
analyze_session() {
    local session_id="$1"

    echo -e "${BLUE}Analyzing Session: $session_id${NC}"
    echo ""

    # Find session log file
    local logfile
    logfile=$(find "$SESSION_LOG_DIR" -type f -name "*-session-$session_id.jsonl" | head -n 1)

    if [[ -z "$logfile" ]]; then
        echo "Session not found: $session_id"
        return 1
    fi

    echo -e "${GREEN}Session Log: $logfile${NC}"
    echo ""

    # Parse and display events
    local event_count=0
    local error_count=0
    local command_count=0

    while IFS= read -r line; do
        event_count=$((event_count + 1))

        local event_type
        event_type=$(echo "$line" | jq -r '.event // "unknown"')
        local timestamp
        timestamp=$(echo "$line" | jq -r '.timestamp // "unknown"')

        case "$event_type" in
            session_start)
                echo -e "${GREEN}[$timestamp] Session started${NC}"
                ;;
            session_end)
                echo -e "${GREEN}[$timestamp] Session ended${NC}"
                ;;
            command_executed)
                command_count=$((command_count + 1))
                local cmd
                cmd=$(echo "$line" | jq -r '.data.command // "unknown"')
                echo -e "${BLUE}[$timestamp] Command: $cmd${NC}"
                ;;
            command_failed)
                error_count=$((error_count + 1))
                local cmd
                cmd=$(echo "$line" | jq -r '.data.command // "unknown"')
                local exit_code
                exit_code=$(echo "$line" | jq -r '.data.exit_code // "unknown"')
                echo -e "${RED}[$timestamp] FAILED (exit $exit_code): $cmd${NC}"
                ;;
            *)
                echo -e "[$timestamp] $event_type"
                ;;
        esac
    done < "$logfile"

    echo ""
    echo -e "${YELLOW}Summary:${NC}"
    echo "  Total events: $event_count"
    echo "  Commands executed: $command_count"
    echo "  Errors: $error_count"
}

# Search logs for pattern
search_logs() {
    local pattern="$1"
    local limit="${2:-50}"

    echo -e "${BLUE}Searching logs for: $pattern${NC}"
    echo ""

    if [[ ! -d "$SESSION_LOG_DIR" ]]; then
        echo "No session logs found."
        return
    fi

    # Search all session logs
    local match_count=0
    find "$SESSION_LOG_DIR" -type f -name "*.jsonl" | sort -r | while read -r logfile; do
        local filename
        filename=$(basename "$logfile")

        # Search for pattern in log file
        if grep -q "$pattern" "$logfile" 2>/dev/null; then
            echo -e "${GREEN}Found in: $filename${NC}"
            grep "$pattern" "$logfile" | head -n 5 | while IFS= read -r line; do
                local timestamp
                timestamp=$(echo "$line" | jq -r '.timestamp // "unknown"')
                local event_type
                event_type=$(echo "$line" | jq -r '.event // "unknown"')
                echo -e "  [$timestamp] $event_type"
            done
            echo ""
            match_count=$((match_count + 1))

            if [[ $match_count -ge $limit ]]; then
                break
            fi
        fi
    done
}

# Show statistics
show_stats() {
    echo -e "${BLUE}Log Statistics:${NC}"
    echo ""

    # Count files
    local session_count=0
    local error_count=0
    local snapshot_count=0

    if [[ -d "$SESSION_LOG_DIR" ]]; then
        session_count=$(find "$SESSION_LOG_DIR" -type f -name "*.jsonl" | wc -l)
    fi

    if [[ -d "$ERROR_LOG_DIR" ]]; then
        error_count=$(find "$ERROR_LOG_DIR" -type f -name "*.json" | wc -l)
    fi

    if [[ -d "$SNAPSHOT_LOG_DIR" ]]; then
        snapshot_count=$(find "$SNAPSHOT_LOG_DIR" -type f -name "*.json" | wc -l)
    fi

    # Calculate total size
    local total_size=0
    if [[ -d "$LOG_DIR" ]]; then
        total_size=$(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo "0")
    fi

    echo "  Session logs: $session_count"
    echo "  Error logs: $error_count"
    echo "  Snapshots: $snapshot_count"
    echo "  Total size: $total_size"
    echo ""

    # Show error frequency
    if [[ $error_count -gt 0 ]]; then
        echo -e "${YELLOW}Most common errors:${NC}"
        find "$ERROR_LOG_DIR" -type f -name "*.json" -exec jq -r '.command // "unknown"' {} \; 2>/dev/null | \
            sort | uniq -c | sort -rn | head -n 5
    fi
}

# Main command dispatcher
case "${1:-}" in
    sessions|--sessions)
        show_sessions "${2:-10}"
        ;;
    errors|--errors)
        show_errors "${2:-10}"
        ;;
    analyze|--analyze)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 analyze <session-id>"
            exit 1
        fi
        analyze_session "$2"
        ;;
    search|--search)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 search <pattern>"
            exit 1
        fi
        search_logs "$2" "${3:-50}"
        ;;
    stats|--stats)
        show_stats
        ;;
    *)
        echo "Usage: $0 {sessions|errors|analyze|search|stats} [options]"
        echo ""
        echo "Commands:"
        echo "  sessions [limit]        Show recent sessions (default: 10)"
        echo "  errors [limit]          Show recent errors (default: 10)"
        echo "  analyze <session-id>    Analyze specific session"
        echo "  search <pattern>        Search logs for pattern"
        echo "  stats                   Show log statistics"
        exit 1
        ;;
esac
