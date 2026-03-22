#!/bin/bash
set -euo pipefail
# detect-infra-blocker.sh
# Classifies whether a given error message or context indicates an infrastructure
# (Proxmox) blocker that requires cross-repo escalation.
#
# Usage:
#   ./scripts/infra/detect-infra-blocker.sh --message "error text" [OPTIONS]
#   echo "error text" | ./scripts/infra/detect-infra-blocker.sh --stdin [OPTIONS]
#
# Options:
#   --message <text>     Error message or blocker description to classify
#   --stdin              Read message from stdin
#   --context <json>     Optional additional context JSON
#   --json               Output JSON only
#   --help               Show this help
#
# Output (JSON):
#   {
#     "is_infra_blocker": true|false,
#     "blocker_type": "host_unreachable|capacity_exceeded|vm_not_provisioned|network_config|storage|unknown",
#     "confidence": "high|medium|low",
#     "category": "networking|compute|storage|authentication|unknown",
#     "matched_patterns": ["pattern1", "pattern2"],
#     "summary": "Human-readable classification"
#   }
#
# Exit codes:
#   0 - Detection completed (check is_infra_blocker in JSON)
#   1 - Usage error
#   2 - Classification error

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared utilities if available
if [ -f "${SCRIPT_DIR}/../lib/common.sh" ]; then
    # shellcheck source=scripts/lib/common.sh
    source "${SCRIPT_DIR}/../lib/common.sh"
else
    log_info()  { echo "[INFO] $*" >&2; }
    log_warn()  { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ─── Defaults ──────────────────────────────────────────────────────────────────

MESSAGE=""
CONTEXT_JSON="{}"
READ_STDIN=false
JSON_ONLY=false

# ─── Argument Parsing ──────────────────────────────────────────────────────────

usage() {
    cat << EOF
detect-infra-blocker.sh - Classify whether a blocker is infrastructure-related

USAGE:
    detect-infra-blocker.sh --message "error text" [OPTIONS]
    echo "error text" | detect-infra-blocker.sh --stdin [OPTIONS]

OPTIONS:
    --message <text>     Error/blocker text to classify
    --stdin              Read message from stdin
    --context <json>     Additional context JSON
    --json               Output JSON only (suppress human-readable output)
    --help               Show this help

EXIT CODES:
    0 - Completed (check is_infra_blocker field)
    1 - Usage error
    2 - Classification error

EXAMPLES:
    detect-infra-blocker.sh --message "Proxmox host unreachable: 10.69.5.11"
    detect-infra-blocker.sh --message "SSH connection timeout to docker-workers"
    detect-infra-blocker.sh --message "No capacity on docker-workers VM"
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --message)
            MESSAGE="$2"
            shift 2
            ;;
        --stdin)
            READ_STDIN=true
            shift
            ;;
        --context)
            CONTEXT_JSON="$2"
            shift 2
            ;;
        --json)
            JSON_ONLY=true
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
    MESSAGE=$(cat)
fi

if [ -z "$MESSAGE" ]; then
    log_error "No message provided (use --message or --stdin)"
    usage
fi

# ─── Pattern Definitions ───────────────────────────────────────────────────────
# Each pattern maps to a blocker type, category, and confidence level.
# Format: "pattern|blocker_type|category|confidence"

PATTERNS=(
    # Host connectivity
    "proxmox.*unreachable|host_unreachable|networking|high"
    "docker.workers.*unreachable|host_unreachable|networking|high"
    "ssh.*connection.*refused|host_unreachable|networking|high"
    "ssh.*connection.*timeout|host_unreachable|networking|high"
    "ssh.*timed.*out|host_unreachable|networking|high"
    "connection.*refused.*10\.69\.|host_unreachable|networking|high"
    "host.*not.*reachable|host_unreachable|networking|high"
    "no.*route.*to.*host|host_unreachable|networking|high"
    "network.*unreachable|host_unreachable|networking|high"
    "proxmox.*host.*down|host_unreachable|networking|high"
    "docker-workers.*offline|host_unreachable|networking|high"

    # VM provisioning
    "vm.*not.*found|vm_not_provisioned|compute|high"
    "vm.*not.*provisioned|vm_not_provisioned|compute|high"
    "container.*not.*provisioned|vm_not_provisioned|compute|high"
    "lxc.*not.*found|vm_not_provisioned|compute|high"
    "proxmox.*vm.*missing|vm_not_provisioned|compute|high"
    "node.*not.*exist|vm_not_provisioned|compute|medium"
    "resource.*not.*available.*proxmox|vm_not_provisioned|compute|medium"

    # Capacity
    "capacity.*exceeded|capacity_exceeded|compute|high"
    "no.*capacity|capacity_exceeded|compute|high"
    "resource.*exhausted|capacity_exceeded|compute|high"
    "out.*of.*memory.*proxmox|capacity_exceeded|compute|high"
    "out.*of.*memory.*docker.workers|capacity_exceeded|compute|high"
    "disk.*full.*proxmox|capacity_exceeded|storage|high"
    "no.*space.*left.*proxmox|capacity_exceeded|storage|high"
    "cpu.*limit.*exceeded|capacity_exceeded|compute|medium"
    "memory.*limit.*exceeded|capacity_exceeded|compute|medium"
    "max.*containers.*reached|capacity_exceeded|compute|high"
    "too.*many.*containers|capacity_exceeded|compute|medium"

    # Network configuration
    "vlan.*not.*configured|network_config|networking|high"
    "network.*bridge.*missing|network_config|networking|high"
    "ip.*address.*not.*assigned|network_config|networking|high"
    "dns.*resolution.*failed.*proxmox|network_config|networking|medium"
    "firewall.*rule.*missing|network_config|networking|medium"
    "nat.*not.*configured|network_config|networking|high"
    "subnet.*not.*found|network_config|networking|high"

    # Storage
    "storage.*pool.*not.*found|storage|storage|high"
    "datastore.*not.*available|storage|storage|high"
    "nfs.*mount.*failed|storage|storage|high"
    "pve.*storage.*error|storage|storage|high"
    "zfs.*pool.*unavailable|storage|storage|high"
    "volume.*not.*found.*proxmox|storage|storage|high"

    # Authentication / credentials
    "ssh.*key.*not.*found.*proxmox|authentication|authentication|high"
    "permission.*denied.*proxmox|authentication|authentication|high"
    "authentication.*failed.*proxmox|authentication|authentication|high"
    "proxmox.*api.*unauthorized|authentication|authentication|high"
    "proxmox.*token.*invalid|authentication|authentication|high"

    # Generic Proxmox indicators
    "proxmox|unknown|compute|low"
    "pve\b|unknown|compute|low"
    "docker.workers|unknown|compute|low"
    "10\.69\.5\.|unknown|networking|low"
)

# ─── Classification Logic ──────────────────────────────────────────────────────

IS_INFRA_BLOCKER=false
BLOCKER_TYPE="unknown"
CATEGORY="unknown"
CONFIDENCE="none"
MATCHED_PATTERNS=()

# Normalise message for matching (lowercase)
MSG_LOWER=$(echo "$MESSAGE" | tr '[:upper:]' '[:lower:]')

# Track best confidence: high > medium > low > none
confidence_rank() {
    case "$1" in
        high)   echo 3 ;;
        medium) echo 2 ;;
        low)    echo 1 ;;
        *)      echo 0 ;;
    esac
}

best_rank=0

for pattern_def in "${PATTERNS[@]}"; do
    IFS='|' read -r pat btype bcat bconf <<< "$pattern_def"

    if echo "$MSG_LOWER" | grep -qiE "$pat"; then
        IS_INFRA_BLOCKER=true
        MATCHED_PATTERNS+=("$pat")

        rank=$(confidence_rank "$bconf")
        if [ "$rank" -gt "$best_rank" ]; then
            best_rank="$rank"
            BLOCKER_TYPE="$btype"
            CATEGORY="$bcat"
            CONFIDENCE="$bconf"
        fi
    fi
done

# Build human-readable summary
if [ "$IS_INFRA_BLOCKER" = "true" ]; then
    case "$BLOCKER_TYPE" in
        host_unreachable)
            SUMMARY="Proxmox/docker-workers host is unreachable or offline"
            ;;
        capacity_exceeded)
            SUMMARY="Infrastructure capacity exceeded (compute/storage)"
            ;;
        vm_not_provisioned)
            SUMMARY="Required VM or container is not provisioned in Proxmox"
            ;;
        network_config)
            SUMMARY="Network configuration missing or misconfigured in Proxmox"
            ;;
        storage)
            SUMMARY="Storage resource unavailable or misconfigured in Proxmox"
            ;;
        authentication)
            SUMMARY="Authentication/credentials issue with Proxmox"
            ;;
        *)
            SUMMARY="Possible infrastructure issue detected (Proxmox-related keywords found)"
            ;;
    esac
else
    SUMMARY="No infrastructure blocker patterns detected"
fi

# ─── Output ───────────────────────────────────────────────────────────────────

# Convert matched patterns array to JSON (handle empty array gracefully)
if [ "${#MATCHED_PATTERNS[@]}" -eq 0 ]; then
    PATTERNS_JSON="[]"
else
    PATTERNS_JSON=$(printf '%s\n' "${MATCHED_PATTERNS[@]}" | jq -R . | jq -s '.')
fi

RESULT=$(jq -n \
    --argjson is_infra "$( [ "$IS_INFRA_BLOCKER" = "true" ] && echo true || echo false )" \
    --arg blocker_type "$BLOCKER_TYPE" \
    --arg category "$CATEGORY" \
    --arg confidence "$CONFIDENCE" \
    --argjson matched_patterns "$PATTERNS_JSON" \
    --arg summary "$SUMMARY" \
    --arg message "$MESSAGE" \
    '{
        is_infra_blocker: $is_infra,
        blocker_type: $blocker_type,
        category: $category,
        confidence: $confidence,
        matched_patterns: $matched_patterns,
        summary: $summary,
        message: $message
    }')

echo "$RESULT"

if [ "$JSON_ONLY" != "true" ]; then
    if [ "$IS_INFRA_BLOCKER" = "true" ]; then
        log_warn "Infrastructure blocker detected: $SUMMARY (confidence: $CONFIDENCE, type: $BLOCKER_TYPE)"
    else
        log_info "Not an infrastructure blocker: $SUMMARY"
    fi
fi

exit 0
