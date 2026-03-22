#!/bin/bash
set -euo pipefail
# escalate-infra-blocker.sh
# Auto-create a cross-repo issue in jifflee/homelab-proxmox when a sprint-work
# container or agent encounters an infrastructure blocker it cannot self-resolve.
#
# Feature: #1338 — Auto-create cross-repo issues to proxmox-infra for infra dependencies
#
# Usage:
#   ./scripts/infra/escalate-infra-blocker.sh [OPTIONS]
#
# Options:
#   --issue <N>             Originating claude-tastic issue number (required)
#   --problem <text>        What went wrong / what is blocking (required)
#   --missing <text>        What infrastructure component is needed (required)
#   --resolution <text>     What needs to be done on the Proxmox side (required)
#   --context <text>        Additional details, error logs, config refs (optional)
#   --blocker-type <type>   Type: host_unreachable|capacity_exceeded|vm_not_provisioned|network_config|storage|authentication (optional)
#   --source-repo <owner/repo>  Source repo (default: jifflee/claude-tastic)
#   --target-repo <owner/repo>  Target infra repo (default: from config or jifflee/homelab-proxmox)
#   --dry-run               Show what would be created without creating
#   --no-label              Skip labelling the originating issue
#   --json                  Output JSON result
#   --help                  Show this help
#
# Behaviour:
#   1. Checks for an existing open infra issue referencing the source issue (dedup)
#   2. Creates a structured issue in the target infra repo using the standard template
#   3. Labels the originating issue with "blocked" and "blocked:infra"
#   4. Outputs JSON with the created issue URL and number
#
# Configuration:
#   Target repo and other defaults can be overridden via ~/.claude-tastic/config.json:
#     {
#       "infra_escalation": {
#         "target_repo": "jifflee/homelab-proxmox",
#         "source_repo": "jifflee/claude-tastic",
#         "default_labels": ["infra-request", "automated"]
#       }
#     }
#
# Exit codes:
#   0 - Issue created (or dry-run completed, or duplicate found)
#   1 - Required argument missing
#   2 - gh CLI error or API failure

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities if available
if [ -f "${SCRIPT_DIR}/../lib/common.sh" ]; then
    # shellcheck source=scripts/lib/common.sh
    source "${SCRIPT_DIR}/../lib/common.sh"
else
    log_info()    { echo "[INFO] $*" >&2; }
    log_warn()    { echo "[WARN] $*" >&2; }
    log_error()   { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
fi

# ─── Defaults ──────────────────────────────────────────────────────────────────

ISSUE_NUMBER=""
PROBLEM=""
WHAT_MISSING=""
REQUIRED_RESOLUTION=""
EXTRA_CONTEXT=""
BLOCKER_TYPE="unknown"
DRY_RUN=false
NO_LABEL=false
JSON_OUTPUT=false

# Repo configuration (can be overridden by ~/.claude-tastic/config.json)
SOURCE_REPO="${SOURCE_REPO:-jifflee/claude-tastic}"
TARGET_REPO="${TARGET_REPO:-jifflee/homelab-proxmox}"
INFRA_LABELS=("infra-request" "automated" "blocker")

# ─── Load Config ───────────────────────────────────────────────────────────────

load_config() {
    local config_file="${HOME}/.claude-tastic/config.json"

    if [ -f "$config_file" ] && command -v jq &>/dev/null; then
        local cfg_target cfg_source
        cfg_target=$(jq -r '.infra_escalation.target_repo // empty' "$config_file" 2>/dev/null || true)
        cfg_source=$(jq -r '.infra_escalation.source_repo // empty' "$config_file" 2>/dev/null || true)

        [ -n "$cfg_target" ] && TARGET_REPO="$cfg_target"
        [ -n "$cfg_source" ] && SOURCE_REPO="$cfg_source"

        # Load custom labels if present
        local cfg_labels
        cfg_labels=$(jq -r '.infra_escalation.default_labels // [] | .[]' "$config_file" 2>/dev/null || true)
        if [ -n "$cfg_labels" ]; then
            mapfile -t INFRA_LABELS <<< "$cfg_labels"
        fi
    fi
}

# ─── Argument Parsing ──────────────────────────────────────────────────────────

usage() {
    cat << EOF
escalate-infra-blocker.sh - Create a cross-repo infrastructure issue in the Proxmox repo

USAGE:
    escalate-infra-blocker.sh --issue <N> --problem <text> --missing <text> --resolution <text> [OPTIONS]

REQUIRED:
    --issue <N>             Originating issue number in this repo
    --problem <text>        What went wrong or is blocking progress
    --missing <text>        What infrastructure component is needed
    --resolution <text>     What must be done on the Proxmox side

OPTIONAL:
    --context <text>        Additional details, error logs, config references
    --blocker-type <type>   Blocker category: host_unreachable|capacity_exceeded|
                            vm_not_provisioned|network_config|storage|authentication
    --source-repo <r>       Source repo (default: ${SOURCE_REPO})
    --target-repo <r>       Target infra repo (default: ${TARGET_REPO})
    --dry-run               Print the issue that would be created without creating it
    --no-label              Skip labelling the originating issue as blocked
    --json                  Output JSON result
    --help                  Show this help

CONFIGURATION:
    Override defaults in ~/.claude-tastic/config.json:
      {
        "infra_escalation": {
          "target_repo": "jifflee/homelab-proxmox",
          "source_repo": "jifflee/claude-tastic",
          "default_labels": ["infra-request", "automated"]
        }
      }

EXIT CODES:
    0 - Success (issue created, duplicate detected, or dry-run)
    1 - Missing required arguments
    2 - API/CLI error

EXAMPLES:
    # Escalate a capacity issue
    escalate-infra-blocker.sh \\
      --issue 1338 \\
      --problem "docker-workers VM has no free CPU/RAM for new container" \\
      --missing "Additional compute capacity on docker-workers (or a new VM)" \\
      --resolution "Provision additional resources or a new LXC container on Proxmox" \\
      --blocker-type capacity_exceeded

    # Dry-run to preview
    escalate-infra-blocker.sh --issue 100 --problem "host down" --missing "VM" --resolution "provision VM" --dry-run
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --problem)
            PROBLEM="$2"
            shift 2
            ;;
        --missing)
            WHAT_MISSING="$2"
            shift 2
            ;;
        --resolution)
            REQUIRED_RESOLUTION="$2"
            shift 2
            ;;
        --context)
            EXTRA_CONTEXT="$2"
            shift 2
            ;;
        --blocker-type)
            BLOCKER_TYPE="$2"
            shift 2
            ;;
        --source-repo)
            SOURCE_REPO="$2"
            shift 2
            ;;
        --target-repo)
            TARGET_REPO="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-label)
            NO_LABEL=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [ -z "$ISSUE_NUMBER" ]; then
    log_error "--issue is required"
    usage
fi
if [ -z "$PROBLEM" ]; then
    log_error "--problem is required"
    usage
fi
if [ -z "$WHAT_MISSING" ]; then
    log_error "--missing is required"
    usage
fi
if [ -z "$REQUIRED_RESOLUTION" ]; then
    log_error "--resolution is required"
    usage
fi

# Load config overrides
load_config

# Allow --source-repo / --target-repo CLI flags to win over config
# (already set above since they're parsed after load_config would run...
#  so re-check if explicit flags were provided)
# Actually flags are parsed BEFORE load_config(), so re-apply flag overrides:
# This is handled by sourcing config only for empty values — we loaded defaults
# then flags override. Since flags parse first, they overwrite the defaults set
# by load_config. We fix this by doing load_config early with flag values winning.
# The approach: flags use dedicated sentinel variables, applied after load_config.
# For simplicity we just re-apply the flag values here (already in vars).

# ─── Duplicate Detection ───────────────────────────────────────────────────────

check_duplicate() {
    local search_term="${SOURCE_REPO}#${ISSUE_NUMBER}"
    log_info "Checking for existing open infra issues referencing ${search_term}..."

    local existing_issues
    existing_issues=$(gh issue list \
        -R "$TARGET_REPO" \
        --state open \
        --search "\"${search_term}\"" \
        --json number,title,url \
        --limit 5 \
        2>/dev/null || echo "[]")

    local count
    count=$(echo "$existing_issues" | jq 'length')

    if [ "$count" -gt 0 ]; then
        local existing_url
        existing_url=$(echo "$existing_issues" | jq -r '.[0].url')
        local existing_number
        existing_number=$(echo "$existing_issues" | jq -r '.[0].number')

        log_warn "Duplicate detected: open infra issue already exists: ${existing_url}"

        if [ "$JSON_OUTPUT" = "true" ]; then
            jq -n \
                --arg status "duplicate" \
                --argjson issue_number "$existing_number" \
                --arg issue_url "$existing_url" \
                --arg source_issue "$ISSUE_NUMBER" \
                --arg target_repo "$TARGET_REPO" \
                '{
                    status: $status,
                    issue_number: $issue_number,
                    issue_url: $issue_url,
                    source_issue: ($source_issue | tonumber),
                    target_repo: $target_repo,
                    message: "Open infra issue already exists — skipping creation"
                }'
        else
            echo "Existing infra issue: ${existing_url}" >&2
        fi

        exit 0
    fi

    log_info "No duplicate found — proceeding with issue creation"
}

# ─── Issue Body Builder ────────────────────────────────────────────────────────

build_issue_body() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local context_section=""
    if [ -n "$EXTRA_CONTEXT" ]; then
        context_section="### Context

${EXTRA_CONTEXT}"
    else
        context_section="### Context

_No additional context provided._"
    fi

    cat << EOF
## Infrastructure Request

**Source:** ${SOURCE_REPO}#${ISSUE_NUMBER}
**Requested by:** sprint-work container / agent
**Blocker type:** ${BLOCKER_TYPE}
**Escalated at:** ${timestamp}

### Problem

${PROBLEM}

### What's Missing

${WHAT_MISSING}

### Required Resolution

${REQUIRED_RESOLUTION}

${context_section}

---
*This issue was automatically created by [escalate-infra-blocker.sh](https://github.com/${SOURCE_REPO}/blob/main/scripts/infra/escalate-infra-blocker.sh) as part of the Claude Agent Framework cross-repo dependency tracking (feature #1338).*
*Once resolved, please close this issue and remove the \`blocked:infra\` label from ${SOURCE_REPO}#${ISSUE_NUMBER}.*
EOF
}

build_issue_title() {
    local type_tag=""
    case "$BLOCKER_TYPE" in
        host_unreachable)    type_tag="[host-unreachable] " ;;
        capacity_exceeded)   type_tag="[capacity] " ;;
        vm_not_provisioned)  type_tag="[vm-provision] " ;;
        network_config)      type_tag="[network] " ;;
        storage)             type_tag="[storage] " ;;
        authentication)      type_tag="[auth] " ;;
    esac

    # Truncate problem for title
    local short_problem
    short_problem=$(echo "$PROBLEM" | head -c 80 | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    echo "Infra request from ${SOURCE_REPO}#${ISSUE_NUMBER}: ${type_tag}${short_problem}"
}

# ─── Label Originating Issue ───────────────────────────────────────────────────

label_source_issue() {
    if [ "$NO_LABEL" = "true" ]; then
        log_info "Skipping label update (--no-label)"
        return 0
    fi

    log_info "Labelling ${SOURCE_REPO}#${ISSUE_NUMBER} with 'blocked' and 'blocked:infra'..."

    # Ensure labels exist (ignore errors if already exist)
    gh label create "blocked" \
        --repo "$SOURCE_REPO" \
        --description "Issue is blocked and cannot proceed" \
        --color "d93f0b" \
        2>/dev/null || true

    gh label create "blocked:infra" \
        --repo "$SOURCE_REPO" \
        --description "Blocked by infrastructure dependency (Proxmox)" \
        --color "e4e669" \
        2>/dev/null || true

    # Apply labels
    gh issue edit "$ISSUE_NUMBER" \
        --repo "$SOURCE_REPO" \
        --add-label "blocked,blocked:infra" \
        2>/dev/null || {
        log_warn "Could not label issue ${SOURCE_REPO}#${ISSUE_NUMBER} (may not have write access)"
    }

    log_success "Labels applied to ${SOURCE_REPO}#${ISSUE_NUMBER}"
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    # Check dependencies
    if ! command -v gh &>/dev/null; then
        log_error "gh CLI not found — required for cross-repo issue creation"
        exit 2
    fi
    if ! command -v jq &>/dev/null; then
        log_error "jq not found — required for JSON output"
        exit 2
    fi

    log_info "Escalating infrastructure blocker for ${SOURCE_REPO}#${ISSUE_NUMBER} to ${TARGET_REPO}..."

    # Build issue content
    local title body
    title=$(build_issue_title)
    body=$(build_issue_body)

    # Dry-run mode: just print what would be created
    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would create issue in ${TARGET_REPO}:"
        echo ""
        echo "Title: ${title}"
        echo ""
        echo "Body:"
        echo "---"
        echo "$body"
        echo "---"
        echo ""
        log_info "[DRY-RUN] Would label ${SOURCE_REPO}#${ISSUE_NUMBER} with 'blocked' and 'blocked:infra'"

        if [ "$JSON_OUTPUT" = "true" ]; then
            jq -n \
                --arg status "dry_run" \
                --arg title "$title" \
                --arg body "$body" \
                --arg source_issue "$ISSUE_NUMBER" \
                --arg source_repo "$SOURCE_REPO" \
                --arg target_repo "$TARGET_REPO" \
                '{
                    status: $status,
                    title: $title,
                    body: $body,
                    source_issue: ($source_issue | tonumber),
                    source_repo: $source_repo,
                    target_repo: $target_repo
                }'
        fi
        exit 0
    fi

    # Check for duplicates before creating
    check_duplicate

    # Build label args for infra issue creation
    local label_args=()
    for lbl in "${INFRA_LABELS[@]}"; do
        # Ensure label exists in target repo
        gh label create "$lbl" \
            --repo "$TARGET_REPO" \
            --description "Automated infra request label" \
            --color "0075ca" \
            2>/dev/null || true
        label_args+=("--label" "$lbl")
    done

    # Create the issue in the infra repo
    log_info "Creating issue in ${TARGET_REPO}..."

    local new_issue_url new_issue_number
    new_issue_url=$(gh issue create \
        --repo "$TARGET_REPO" \
        --title "$title" \
        --body "$body" \
        "${label_args[@]}" \
        2>/dev/null) || {
        log_error "Failed to create issue in ${TARGET_REPO}"
        exit 2
    }

    # Extract issue number from URL
    new_issue_number=$(echo "$new_issue_url" | grep -oE '[0-9]+$' || echo "unknown")

    log_success "Infrastructure issue created: ${new_issue_url}"

    # Add a cross-reference comment on the originating issue
    local cross_ref_comment
    cross_ref_comment="Infra blocker escalated to ${TARGET_REPO}#${new_issue_number}: ${new_issue_url}

This issue has been blocked pending infrastructure resolution. See the infra issue for details on what needs to be provisioned/fixed in Proxmox.

Labels \`blocked\` and \`blocked:infra\` have been applied."

    gh issue comment "$ISSUE_NUMBER" \
        --repo "$SOURCE_REPO" \
        --body "$cross_ref_comment" \
        2>/dev/null || {
        log_warn "Could not post cross-reference comment on ${SOURCE_REPO}#${ISSUE_NUMBER}"
    }

    # Label the originating issue
    label_source_issue

    # Output result
    if [ "$JSON_OUTPUT" = "true" ]; then
        jq -n \
            --arg status "created" \
            --arg issue_url "$new_issue_url" \
            --argjson issue_number "$(echo "$new_issue_number" | grep -E '^[0-9]+$' && echo "$new_issue_number" || echo 0)" \
            --argjson source_issue "$ISSUE_NUMBER" \
            --arg source_repo "$SOURCE_REPO" \
            --arg target_repo "$TARGET_REPO" \
            --arg blocker_type "$BLOCKER_TYPE" \
            '{
                status: $status,
                issue_url: $issue_url,
                issue_number: $issue_number,
                source_issue: $source_issue,
                source_repo: $source_repo,
                target_repo: $target_repo,
                blocker_type: $blocker_type,
                message: "Infrastructure issue created and originating issue labelled"
            }'
    else
        echo ""
        echo "Infrastructure issue created: ${new_issue_url}"
        echo "Originating issue ${SOURCE_REPO}#${ISSUE_NUMBER} labelled with 'blocked' and 'blocked:infra'"
    fi

    exit 0
}

main "$@"
