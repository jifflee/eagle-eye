#!/bin/bash
set -euo pipefail
# auto-escalate-infra.sh
# Convenience wrapper: detect whether an error message is infra-related and, if
# so, automatically escalate it to jifflee/homelab-proxmox via escalate-infra-blocker.sh.
#
# Feature: #1338 — Auto-create cross-repo issues to proxmox-infra for infra dependencies
#
# Usage:
#   ./scripts/infra/auto-escalate-infra.sh --issue <N> --error "error message" [OPTIONS]
#   echo "error text" | ./scripts/infra/auto-escalate-infra.sh --issue <N> --stdin [OPTIONS]
#
# Options:
#   --issue <N>          Originating issue number (required)
#   --error <text>       Error / blocker message (required unless --stdin)
#   --stdin              Read error message from stdin
#   --context <text>     Additional context to include in the infra issue
#   --source-repo <r>    Source repo (default: jifflee/claude-tastic)
#   --target-repo <r>    Target infra repo (default: jifflee/homelab-proxmox)
#   --threshold <level>  Minimum confidence to escalate: high|medium|low (default: medium)
#   --dry-run            Preview without creating issue
#   --no-label           Skip labelling originating issue
#   --json               Output JSON result
#   --help               Show this help
#
# Integration points:
#   - sprint-work-preflight.sh (Proxmox health check failures)
#   - detect-execution-mode.sh (Proxmox unavailable fallback)
#   - check-container-capacity.sh (capacity exceeded scenarios)
#   - container-launch.sh / container-sprint-workflow.sh (blocker self-reporting)
#
# Exit codes:
#   0 - Completed (escalated, skipped-not-infra, or dry-run)
#   1 - Usage error
#   2 - Escalation failure

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
ERROR_MESSAGE=""
EXTRA_CONTEXT=""
SOURCE_REPO="${SOURCE_REPO:-jifflee/claude-tastic}"
TARGET_REPO="${TARGET_REPO:-jifflee/homelab-proxmox}"
MIN_CONFIDENCE="medium"   # minimum confidence level to trigger escalation
DRY_RUN=false
NO_LABEL=false
JSON_OUTPUT=false
READ_STDIN=false

# ─── Argument Parsing ──────────────────────────────────────────────────────────

usage() {
    cat << EOF
auto-escalate-infra.sh - Auto-detect and escalate infrastructure blockers

USAGE:
    auto-escalate-infra.sh --issue <N> --error "message" [OPTIONS]
    echo "error" | auto-escalate-infra.sh --issue <N> --stdin [OPTIONS]

REQUIRED:
    --issue <N>          Originating issue number
    --error <text>       Error/blocker message (or use --stdin)

OPTIONAL:
    --stdin              Read error message from stdin
    --context <text>     Additional context for the infra issue
    --source-repo <r>    Source repo (default: ${SOURCE_REPO})
    --target-repo <r>    Target infra repo (default: ${TARGET_REPO})
    --threshold <level>  Min confidence to escalate: high|medium|low (default: ${MIN_CONFIDENCE})
    --dry-run            Preview without creating issue
    --no-label           Skip labelling originating issue
    --json               Output JSON
    --help               Show this help

EXAMPLES:
    # From a preflight script that detected Proxmox is unreachable:
    auto-escalate-infra.sh \\
        --issue 42 \\
        --error "SSH connection timeout to docker-workers (10.69.5.11)" \\
        --context "sprint-work-preflight failed at Proxmox health check"

    # From capacity check failure:
    auto-escalate-infra.sh \\
        --issue 100 \\
        --error "Capacity exceeded: no free CPUs on docker-workers" \\
        --threshold high

    # Pipe error from another script:
    ./scripts/sprint/sprint-work-preflight.sh 2>&1 | \\
        auto-escalate-infra.sh --issue 55 --stdin
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --error)
            ERROR_MESSAGE="$2"
            shift 2
            ;;
        --stdin)
            READ_STDIN=true
            shift
            ;;
        --context)
            EXTRA_CONTEXT="$2"
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
        --threshold)
            MIN_CONFIDENCE="$2"
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

# Read from stdin if requested
if [ "$READ_STDIN" = "true" ]; then
    ERROR_MESSAGE=$(cat)
fi

if [ -z "$ISSUE_NUMBER" ]; then
    log_error "--issue is required"
    usage
fi

if [ -z "$ERROR_MESSAGE" ]; then
    log_error "--error (or --stdin) is required"
    usage
fi

# ─── Confidence Threshold Helper ───────────────────────────────────────────────

confidence_rank() {
    case "$1" in
        high)   echo 3 ;;
        medium) echo 2 ;;
        low)    echo 1 ;;
        *)      echo 0 ;;
    esac
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    local detect_script="${SCRIPT_DIR}/detect-infra-blocker.sh"
    local escalate_script="${SCRIPT_DIR}/escalate-infra-blocker.sh"

    if [ ! -x "$detect_script" ]; then
        log_error "detect-infra-blocker.sh not found or not executable: ${detect_script}"
        exit 2
    fi
    if [ ! -x "$escalate_script" ]; then
        log_error "escalate-infra-blocker.sh not found or not executable: ${escalate_script}"
        exit 2
    fi

    # Step 1: Detect if this is an infra blocker
    log_info "Analysing error for infrastructure patterns..."
    local detection_result
    detection_result=$("$detect_script" --message "$ERROR_MESSAGE" --json 2>/dev/null) || {
        log_error "detect-infra-blocker.sh failed"
        exit 2
    }

    local is_infra confidence blocker_type summary
    is_infra=$(echo "$detection_result" | jq -r '.is_infra_blocker')
    confidence=$(echo "$detection_result" | jq -r '.confidence')
    blocker_type=$(echo "$detection_result" | jq -r '.blocker_type')
    summary=$(echo "$detection_result" | jq -r '.summary')

    if [ "$is_infra" != "true" ]; then
        log_info "Not an infrastructure blocker — no escalation needed"
        if [ "$JSON_OUTPUT" = "true" ]; then
            jq -n \
                --arg status "skipped" \
                --arg reason "Not classified as an infrastructure blocker" \
                --arg message "$ERROR_MESSAGE" \
                --argjson detection "$detection_result" \
                '{
                    status: $status,
                    reason: $reason,
                    message: $message,
                    detection: $detection
                }'
        fi
        exit 0
    fi

    # Step 2: Check confidence threshold
    local detected_rank min_rank
    detected_rank=$(confidence_rank "$confidence")
    min_rank=$(confidence_rank "$MIN_CONFIDENCE")

    if [ "$detected_rank" -lt "$min_rank" ]; then
        log_info "Infrastructure blocker detected but confidence '${confidence}' is below threshold '${MIN_CONFIDENCE}' — skipping escalation"
        if [ "$JSON_OUTPUT" = "true" ]; then
            jq -n \
                --arg status "below_threshold" \
                --arg confidence "$confidence" \
                --arg threshold "$MIN_CONFIDENCE" \
                --argjson detection "$detection_result" \
                '{
                    status: $status,
                    confidence: $confidence,
                    threshold: $threshold,
                    message: "Confidence below threshold — escalation skipped",
                    detection: $detection
                }'
        fi
        exit 0
    fi

    log_warn "Infrastructure blocker detected: ${summary} (confidence: ${confidence}, type: ${blocker_type})"

    # Step 3: Build escalation arguments from detection context
    local problem missing resolution

    # Build problem, missing, and resolution from blocker type
    case "$blocker_type" in
        host_unreachable)
            problem="The Proxmox/docker-workers host is unreachable. ${ERROR_MESSAGE}"
            missing="Network connectivity to the Proxmox host or docker-workers VM"
            resolution="Verify the Proxmox host and docker-workers VM are online and reachable. Check network routing, firewall rules, and the VM's network configuration."
            ;;
        capacity_exceeded)
            problem="Infrastructure capacity is exceeded and cannot spawn new containers. ${ERROR_MESSAGE}"
            missing="Additional compute or storage capacity on Proxmox docker-workers"
            resolution="Increase available CPU/RAM/disk on the docker-workers VM, or provision a new worker VM. Clean up stopped containers if applicable."
            ;;
        vm_not_provisioned)
            problem="A required VM or LXC container is not provisioned in Proxmox. ${ERROR_MESSAGE}"
            missing="The specific VM/LXC container referenced in the error needs to be created and started"
            resolution="Provision the missing VM or LXC container on Proxmox. Ensure it has the required software stack (Docker, SSH access, credentials)."
            ;;
        network_config)
            problem="Proxmox networking is misconfigured and blocking container operation. ${ERROR_MESSAGE}"
            missing="Correct VLAN, bridge, IP, or NAT configuration in Proxmox"
            resolution="Review and fix the Proxmox network configuration. Ensure the required VLAN, bridge, and IP assignments are correct and the docker-workers VM can reach the internet and internal services."
            ;;
        storage)
            problem="A Proxmox storage resource is unavailable or misconfigured. ${ERROR_MESSAGE}"
            missing="The referenced storage pool, datastore, or NFS mount must be available"
            resolution="Check Proxmox storage configuration. Ensure the relevant pool/datastore/NFS mount is mounted, healthy, and has sufficient free space."
            ;;
        authentication)
            problem="Authentication to Proxmox failed, blocking container operations. ${ERROR_MESSAGE}"
            missing="Valid SSH keys or API credentials for Proxmox access"
            resolution="Rotate or re-provision SSH keys and/or Proxmox API tokens. Ensure credentials are deployed to the correct locations on both the orchestrator and docker-workers."
            ;;
        *)
            problem="An infrastructure-related blocker was detected. ${ERROR_MESSAGE}"
            missing="Infrastructure resource or configuration (see problem description)"
            resolution="Investigate the Proxmox infrastructure based on the problem description and resolve the underlying issue."
            ;;
    esac

    # Step 4: Build escalation command
    local escalate_args=(
        "--issue" "$ISSUE_NUMBER"
        "--problem" "$problem"
        "--missing" "$missing"
        "--resolution" "$resolution"
        "--blocker-type" "$blocker_type"
        "--source-repo" "$SOURCE_REPO"
        "--target-repo" "$TARGET_REPO"
    )

    # Add context if provided or build from error
    local full_context="${EXTRA_CONTEXT}"
    if [ -z "$full_context" ]; then
        full_context="Original error message:\n\`\`\`\n${ERROR_MESSAGE}\n\`\`\`\n\nDetection confidence: ${confidence}\nDetected blocker type: ${blocker_type}"
    else
        full_context="${full_context}\n\nOriginal error:\n\`\`\`\n${ERROR_MESSAGE}\n\`\`\`"
    fi

    escalate_args+=("--context" "$full_context")

    [ "$DRY_RUN" = "true" ]  && escalate_args+=("--dry-run")
    [ "$NO_LABEL" = "true" ] && escalate_args+=("--no-label")
    [ "$JSON_OUTPUT" = "true" ] && escalate_args+=("--json")

    # Step 5: Escalate
    log_info "Escalating to ${TARGET_REPO}..."
    "$escalate_script" "${escalate_args[@]}"
}

main "$@"
