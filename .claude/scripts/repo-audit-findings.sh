#!/usr/bin/env bash
#
# repo-audit-findings.sh
# Manage repo audit findings with status tracking
# size-ok: multi-command findings manager with init/add/list/resolve/report modes
#
# Usage:
#   ./repo-audit-findings.sh init                    # Initialize .repo-audit directory
#   ./repo-audit-findings.sh add <type> <severity> <title> <description>
#   ./repo-audit-findings.sh list [--status open|resolved|all]
#   ./repo-audit-findings.sh resolve <id>            # Mark finding as resolved
#   ./repo-audit-findings.sh wontfix <id>            # Mark as won't fix
#   ./repo-audit-findings.sh link-issue <id> <issue_number>
#   ./repo-audit-findings.sh get <id>                # Get finding details
#   ./repo-audit-findings.sh cleanup                 # Remove resolved/wontfix findings
#   ./repo-audit-findings.sh summary                 # Show summary stats
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Finding not found
#   3 - File system error

set -euo pipefail

AUDIT_DIR=".repo-audit"
FINDINGS_FILE="$AUDIT_DIR/findings.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Initialize .repo-audit directory
init_audit_dir() {
    if [[ -d "$AUDIT_DIR" ]]; then
        info "Audit directory already exists: $AUDIT_DIR"
    else
        mkdir -p "$AUDIT_DIR"
        success "Created audit directory: $AUDIT_DIR"
    fi

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        echo '{
  "schema_version": "1.0",
  "last_run": null,
  "findings": []
}' > "$FINDINGS_FILE"
        success "Created findings file: $FINDINGS_FILE"
    else
        info "Findings file already exists"
    fi

    # Add to .gitignore if not already there
    if [[ -f ".gitignore" ]]; then
        if ! grep -q "^\.repo-audit/$" .gitignore 2>/dev/null; then
            echo ".repo-audit/" >> .gitignore
            info "Added .repo-audit/ to .gitignore"
        fi
    fi
}

# Generate unique finding ID
generate_id() {
    local type="$1"
    local prefix
    case "$type" in
        structure) prefix="struct" ;;
        code) prefix="code" ;;
        security) prefix="sec" ;;
        docs) prefix="docs" ;;
        tests) prefix="test" ;;
        *) prefix="audit" ;;
    esac

    # Get next sequence number
    local count
    count=$(jq "[.findings[] | select(.id | startswith(\"$prefix-\"))] | length" "$FINDINGS_FILE" 2>/dev/null || echo "0")
    printf "%s-%03d" "$prefix" $((count + 1))
}

# Add a new finding
add_finding() {
    local type="$1"
    local severity="$2"
    local title="$3"
    local description="$4"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found. Run 'init' first."
        exit 3
    fi

    local id
    id=$(generate_id "$type")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Create new finding object
    local finding
    finding=$(jq -n \
        --arg id "$id" \
        --arg type "$type" \
        --arg severity "$severity" \
        --arg title "$title" \
        --arg description "$description" \
        --arg found_at "$timestamp" \
        '{
            id: $id,
            type: $type,
            severity: $severity,
            title: $title,
            description: $description,
            status: "open",
            issue_number: null,
            found_at: $found_at,
            resolved_at: null
        }')

    # Add to findings array
    jq --argjson finding "$finding" \
       --arg timestamp "$timestamp" \
       '.findings += [$finding] | .last_run = $timestamp' \
       "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp" && mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"

    success "Added finding: $id - $title"
    echo "$id"
}

# List findings
list_findings() {
    local status_filter="${1:-all}"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found. Run 'init' first."
        exit 3
    fi

    local filter
    case "$status_filter" in
        open) filter='select(.status == "open")' ;;
        resolved) filter='select(.status == "resolved")' ;;
        issue_created) filter='select(.status == "issue_created")' ;;
        wont_fix) filter='select(.status == "wont_fix")' ;;
        all) filter='.' ;;
        *) error "Invalid status filter: $status_filter"; exit 1 ;;
    esac

    echo ""
    echo "## Findings (status: $status_filter)"
    echo ""

    local count
    count=$(jq "[.findings[] | $filter] | length" "$FINDINGS_FILE")

    if [[ "$count" -eq 0 ]]; then
        info "No findings found"
        return
    fi

    echo "| ID | Type | Severity | Title | Status | Issue |"
    echo "|-----|------|----------|-------|--------|-------|"

    jq -r ".findings[] | $filter | \"| \(.id) | \(.type) | \(.severity) | \(.title) | \(.status) | \(.issue_number // \"-\") |\"" "$FINDINGS_FILE"

    echo ""
    echo "Total: $count findings"
}

# Update finding status
update_status() {
    local id="$1"
    local new_status="$2"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found"
        exit 3
    fi

    # Check if finding exists
    local exists
    exists=$(jq --arg id "$id" '[.findings[] | select(.id == $id)] | length' "$FINDINGS_FILE")

    if [[ "$exists" -eq 0 ]]; then
        error "Finding not found: $id"
        exit 2
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local resolved_at="null"
    if [[ "$new_status" == "resolved" || "$new_status" == "wont_fix" ]]; then
        resolved_at="\"$timestamp\""
    fi

    jq --arg id "$id" \
       --arg status "$new_status" \
       --argjson resolved_at "$resolved_at" \
       '(.findings[] | select(.id == $id)) |= . + {status: $status, resolved_at: $resolved_at}' \
       "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp" && mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"

    success "Updated $id: status → $new_status"
}

# Link finding to GitHub issue
link_issue() {
    local id="$1"
    local issue_number="$2"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found"
        exit 3
    fi

    # Check if finding exists
    local exists
    exists=$(jq --arg id "$id" '[.findings[] | select(.id == $id)] | length' "$FINDINGS_FILE")

    if [[ "$exists" -eq 0 ]]; then
        error "Finding not found: $id"
        exit 2
    fi

    jq --arg id "$id" \
       --argjson issue "$issue_number" \
       '(.findings[] | select(.id == $id)) |= . + {issue_number: $issue, status: "issue_created"}' \
       "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp" && mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"

    success "Linked $id to issue #$issue_number"
}

# Get finding details
get_finding() {
    local id="$1"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found"
        exit 3
    fi

    local finding
    finding=$(jq --arg id "$id" '.findings[] | select(.id == $id)' "$FINDINGS_FILE")

    if [[ -z "$finding" || "$finding" == "null" ]]; then
        error "Finding not found: $id"
        exit 2
    fi

    echo "$finding" | jq .
}

# Cleanup resolved findings
cleanup_findings() {
    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found"
        exit 3
    fi

    local before_count
    before_count=$(jq '.findings | length' "$FINDINGS_FILE")

    jq '.findings |= [.[] | select(.status != "resolved" and .status != "wont_fix")]' \
       "$FINDINGS_FILE" > "$FINDINGS_FILE.tmp" && mv "$FINDINGS_FILE.tmp" "$FINDINGS_FILE"

    local after_count
    after_count=$(jq '.findings | length' "$FINDINGS_FILE")

    local removed=$((before_count - after_count))
    success "Removed $removed resolved/wont_fix findings"
    info "Remaining: $after_count findings"
}

# Show summary stats
show_summary() {
    if [[ ! -f "$FINDINGS_FILE" ]]; then
        error "Findings file not found"
        exit 3
    fi

    echo ""
    echo "## Findings Summary"
    echo ""

    local last_run
    last_run=$(jq -r '.last_run // "never"' "$FINDINGS_FILE")
    echo "Last run: $last_run"
    echo ""

    echo "### By Status"
    echo "| Status | Count |"
    echo "|--------|-------|"
    jq -r '.findings | group_by(.status) | .[] | "| \(.[0].status) | \(length) |"' "$FINDINGS_FILE"

    echo ""
    echo "### By Type"
    echo "| Type | Count |"
    echo "|------|-------|"
    jq -r '.findings | group_by(.type) | .[] | "| \(.[0].type) | \(length) |"' "$FINDINGS_FILE"

    echo ""
    echo "### By Severity"
    echo "| Severity | Count |"
    echo "|----------|-------|"
    jq -r '.findings | group_by(.severity) | .[] | "| \(.[0].severity) | \(length) |"' "$FINDINGS_FILE"

    local total
    total=$(jq '.findings | length' "$FINDINGS_FILE")
    echo ""
    echo "**Total findings:** $total"
}

# Check if finding exists (for deduplication)
finding_exists() {
    local type="$1"
    local title="$2"

    if [[ ! -f "$FINDINGS_FILE" ]]; then
        echo "false"
        return
    fi

    local exists
    exists=$(jq --arg type "$type" --arg title "$title" \
        '[.findings[] | select(.type == $type and .title == $title and .status == "open")] | length' \
        "$FINDINGS_FILE")

    if [[ "$exists" -gt 0 ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Main command router
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        init)
            init_audit_dir
            ;;
        add)
            if [[ $# -lt 4 ]]; then
                error "Usage: $0 add <type> <severity> <title> <description>"
                exit 1
            fi
            add_finding "$1" "$2" "$3" "$4"
            ;;
        list)
            list_findings "${1:-all}"
            ;;
        resolve)
            if [[ $# -lt 1 ]]; then
                error "Usage: $0 resolve <id>"
                exit 1
            fi
            update_status "$1" "resolved"
            ;;
        wontfix)
            if [[ $# -lt 1 ]]; then
                error "Usage: $0 wontfix <id>"
                exit 1
            fi
            update_status "$1" "wont_fix"
            ;;
        link-issue)
            if [[ $# -lt 2 ]]; then
                error "Usage: $0 link-issue <id> <issue_number>"
                exit 1
            fi
            link_issue "$1" "$2"
            ;;
        get)
            if [[ $# -lt 1 ]]; then
                error "Usage: $0 get <id>"
                exit 1
            fi
            get_finding "$1"
            ;;
        cleanup)
            cleanup_findings
            ;;
        summary)
            show_summary
            ;;
        exists)
            if [[ $# -lt 2 ]]; then
                error "Usage: $0 exists <type> <title>"
                exit 1
            fi
            finding_exists "$1" "$2"
            ;;
        help|--help|-h)
            echo "repo-audit-findings.sh - Manage repo audit findings"
            echo ""
            echo "Usage:"
            echo "  $0 init                              Initialize .repo-audit directory"
            echo "  $0 add <type> <severity> <title> <description>"
            echo "  $0 list [--status open|resolved|all]"
            echo "  $0 resolve <id>                      Mark finding as resolved"
            echo "  $0 wontfix <id>                      Mark as won't fix"
            echo "  $0 link-issue <id> <issue_number>    Link to GitHub issue"
            echo "  $0 get <id>                          Get finding details"
            echo "  $0 cleanup                           Remove resolved/wontfix findings"
            echo "  $0 summary                           Show summary stats"
            echo "  $0 exists <type> <title>             Check if finding exists"
            echo ""
            echo "Types: structure, code, security, docs, tests"
            echo "Severities: critical, high, medium, low, info"
            ;;
        *)
            error "Unknown command: $command"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
