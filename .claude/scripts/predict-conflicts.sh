#!/bin/bash
set -euo pipefail
# predict-conflicts.sh
# Smart conflict prediction before container launch
# size-ok: conflict prediction using label-based, historical, and static analysis strategies
#
# PURPOSE:
#   Predicts file overlap between issues to avoid launching containers
#   that will likely conflict with currently running work.
#
# USAGE:
#   ./scripts/predict-conflicts.sh --issue <N> [OPTIONS]
#
# OPTIONS:
#   --issue <N>        Issue number to check for conflicts
#   --json             Output JSON only (for scripting)
#   --threshold <N>    Conflict score threshold (0-100, default: 30)
#   --record           Record prediction for accuracy tracking
#
# OUTPUT (JSON):
#   {
#     "issue": 123,
#     "conflicts": [
#       {
#         "issue": 124,
#         "score": 75,
#         "reasons": ["same labels: scripts", "container running"],
#         "strategy": "label-based"
#       }
#     ],
#     "action": "warn|block|continue",
#     "recommendation": "...",
#     "prediction_id": "..."
#   }
#
# PREDICTION STRATEGIES:
#   1. Label-based: Issues with same labels likely touch same files
#      - scripts → scripts/*.sh
#      - docs → docs/*.md
#      - container → Dockerfile, container-*.sh
#      - frontend → src/components/*
#      - backend → src/api/*
#   2. Historical: Track which files each issue type modifies (future)
#   3. Static Analysis: Parse issue body for file references
#
# EXIT CODES:
#   0 - No conflicts predicted
#   1 - Conflicts predicted
#   2 - Error

set -e

# Script metadata
SCRIPT_NAME="predict-conflicts.sh"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Configuration
DEFAULT_THRESHOLD=30  # Score threshold for conflict warning
PREDICTIONS_DIR="${SCRIPT_DIR}/../.predictions"  # Directory for tracking predictions

# Usage
usage() {
    cat << EOF >&2
$SCRIPT_NAME v$VERSION - Smart conflict prediction before container launch

USAGE:
    $SCRIPT_NAME --issue <N> [OPTIONS]

OPTIONS:
    --issue <N>        Issue number to check for conflicts
    --json             Output JSON only
    --threshold <N>    Conflict score threshold (0-100, default: $DEFAULT_THRESHOLD)
    --record           Record prediction for accuracy tracking
    --debug            Enable debug logging

EXAMPLES:
    # Check for conflicts with issue 132
    $SCRIPT_NAME --issue 132

    # Use custom threshold
    $SCRIPT_NAME --issue 132 --threshold 50

    # Record prediction for tracking accuracy
    $SCRIPT_NAME --issue 132 --record
EOF
    exit 2
}

# Parse arguments
ISSUE_NUMBER=""
JSON_ONLY=false
THRESHOLD=$DEFAULT_THRESHOLD
RECORD_PREDICTION=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --json)
            JSON_ONLY=true
            shift
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --record)
            RECORD_PREDICTION=true
            shift
            ;;
        --debug)
            DEBUG=1
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

# Validate arguments
if [[ -z "$ISSUE_NUMBER" ]]; then
    log_error "--issue is required"
    usage
fi

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Map labels to likely file paths
get_file_patterns_for_label() {
    local label="$1"

    case "$label" in
        scripts)
            echo "scripts/*.sh"
            ;;
        docs)
            echo "docs/*.md"
            ;;
        container)
            echo "Dockerfile container-*.sh scripts/container-*.sh"
            ;;
        frontend)
            echo "src/components/* src/pages/* src/app/*"
            ;;
        backend)
            echo "src/api/* src/server/* api/*"
            ;;
        ci|github-actions)
            echo ".github/workflows/*"
            ;;
        testing)
            echo "tests/* *.test.* *.spec.*"
            ;;
        config)
            echo "*.json *.yaml *.yml .env*"
            ;;
        infra|infrastructure)
            echo "terraform/* k8s/* infrastructure/*"
            ;;
        database|db)
            echo "migrations/* schema/* db/*"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Extract file references from issue body
extract_file_references() {
    local body="$1"

    # Look for common file path patterns:
    # - /path/to/file
    # - path/to/file.ext
    # - `file.ext`
    # - file.ext (with common extensions)

    echo "$body" | grep -oE '`[^`]+\.(sh|js|ts|jsx|tsx|py|md|json|yaml|yml)`' | sed 's/`//g' || true
    echo "$body" | grep -oE '[a-zA-Z0-9_/-]+\.(sh|js|ts|jsx|tsx|py|md|json|yaml|yml|go|rb)' || true
    echo "$body" | grep -oE '(scripts|docs|src|tests|api|lib)/[a-zA-Z0-9_/-]+' || true
}

# Get running containers and their issues
get_running_issues() {
    # Get all running claude-agents containers
    docker ps --filter "name=claude-agents-issue-" --format '{{.Names}}' 2>/dev/null | \
        grep -oE 'issue-[0-9]+' | \
        sed 's/issue-//' || true
}

# Get issues with in-progress or checked-out labels
get_active_issues() {
    local in_progress=$(gh issue list --label "in-progress" --state open --json number --jq '.[].number' 2>/dev/null || true)
    local checked_out=$(gh issue list --label "wip:checked-out" --state open --json number --jq '.[].number' 2>/dev/null || true)

    # Combine and dedupe
    echo -e "$in_progress\n$checked_out" | sort -u | grep -v '^$' || true
}

# Calculate conflict score between two issues
calculate_conflict_score() {
    local issue1="$1"
    local issue2="$2"
    local issue1_data="$3"
    local issue2_data="$4"

    local score=0
    local reasons=()

    # Get labels for both issues
    local labels1=$(echo "$issue1_data" | jq -r '.labels[].name' 2>/dev/null | sort)
    local labels2=$(echo "$issue2_data" | jq -r '.labels[].name' 2>/dev/null | sort)

    # Check for common labels (excluding generic ones)
    local common_labels=$(comm -12 <(echo "$labels1") <(echo "$labels2") | grep -v -E '^(P[0-3]|bug|feature|enhancement|tech-debt)$' || true)

    if [[ -n "$common_labels" ]]; then
        local label_count=$(echo "$common_labels" | wc -l | tr -d ' ')
        score=$((score + label_count * 20))

        for label in $common_labels; do
            reasons+=("same label: $label")
        done

        log_debug "Common labels: $common_labels (score: +$((label_count * 20)))"
    fi

    # Check for file references in issue bodies
    local body1=$(echo "$issue1_data" | jq -r '.body // ""')
    local body2=$(echo "$issue2_data" | jq -r '.body // ""')

    local files1=$(extract_file_references "$body1" | sort -u)
    local files2=$(extract_file_references "$body2" | sort -u)

    if [[ -n "$files1" ]] && [[ -n "$files2" ]]; then
        local common_files=$(comm -12 <(echo "$files1") <(echo "$files2") || true)

        if [[ -n "$common_files" ]]; then
            local file_count=$(echo "$common_files" | wc -l | tr -d ' ')
            score=$((score + file_count * 30))

            for file in $common_files; do
                reasons+=("same file referenced: $file")
            done

            log_debug "Common files: $file_count (score: +$((file_count * 30)))"
        fi
    fi

    # Check if they are in the same epic (parent: label)
    local parent1=$(echo "$labels1" | grep '^parent:' || true)
    local parent2=$(echo "$labels2" | grep '^parent:' || true)

    if [[ -n "$parent1" ]] && [[ "$parent1" == "$parent2" ]]; then
        score=$((score + 15))
        reasons+=("same epic: $parent1")
        log_debug "Same epic: $parent1 (score: +15)"
    fi

    # Check for dependency relationship
    if [[ -x "$SCRIPT_DIR/issue-dependencies.sh" ]]; then
        local deps=$(bash "$SCRIPT_DIR/issue-dependencies.sh" "$issue1" 2>/dev/null | jq -r '.dependencies.depends_on[]?.number // empty, .dependencies.related_to[]?.number // empty' || true)

        if echo "$deps" | grep -qw "$issue2"; then
            score=$((score + 25))
            reasons+=("dependency relationship")
            log_debug "Dependency relationship (score: +25)"
        fi
    fi

    # Output score and reasons as JSON
    local reasons_json=$(printf '%s\n' "${reasons[@]}" | jq -R . | jq -s '.')
    jq -n \
        --argjson score "$score" \
        --argjson reasons "$reasons_json" \
        '{score: $score, reasons: $reasons}'
}

# Generate prediction ID for tracking
generate_prediction_id() {
    echo "pred-${ISSUE_NUMBER}-$(date +%s)"
}

# Record prediction for accuracy tracking
record_prediction() {
    local prediction_id="$1"
    local prediction_data="$2"

    mkdir -p "$PREDICTIONS_DIR"

    local prediction_file="${PREDICTIONS_DIR}/${prediction_id}.json"
    echo "$prediction_data" > "$prediction_file"

    log_debug "Recorded prediction: $prediction_file"
}

# ============================================================================
# MAIN PREDICTION LOGIC
# ============================================================================

[[ "$JSON_ONLY" != "true" ]] && log_info "Checking for potential conflicts with issue #$ISSUE_NUMBER..."

# Get issue data
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json number,title,body,labels 2>/dev/null) || {
    log_error "Issue #$ISSUE_NUMBER not found"
    jq -n --arg issue "$ISSUE_NUMBER" '{
        action: "error",
        error: "Issue not found",
        issue: $issue
    }'
    exit 2
}

[[ "$JSON_ONLY" != "true" ]] && log_debug "Issue data retrieved"

# Get running containers
RUNNING_ISSUES=$(get_running_issues)
[[ "$JSON_ONLY" != "true" ]] && [[ -n "$RUNNING_ISSUES" ]] && log_info "Found $(echo "$RUNNING_ISSUES" | wc -l | tr -d ' ') running container(s)"

# Get active issues (labeled as in-progress or checked-out)
ACTIVE_ISSUES=$(get_active_issues)
[[ "$JSON_ONLY" != "true" ]] && [[ -n "$ACTIVE_ISSUES" ]] && log_info "Found $(echo "$ACTIVE_ISSUES" | wc -l | tr -d ' ') active issue(s)"

# Combine all potentially conflicting issues
ALL_CANDIDATES=$(echo -e "$RUNNING_ISSUES\n$ACTIVE_ISSUES" | sort -u | grep -v '^$' | grep -v "^${ISSUE_NUMBER}$" || true)

if [[ -z "$ALL_CANDIDATES" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "No active work to check for conflicts"

    RESULT=$(jq -n \
        --argjson issue "$ISSUE_NUMBER" \
        '{
            issue: $issue,
            conflicts: [],
            action: "continue",
            recommendation: "No active work detected - safe to proceed"
        }')

    echo "$RESULT"
    exit 0
fi

[[ "$JSON_ONLY" != "true" ]] && log_info "Analyzing $(echo "$ALL_CANDIDATES" | wc -l | tr -d ' ') candidate(s) for conflicts..."

# Calculate conflict scores for each candidate
CONFLICTS=()
MAX_SCORE=0

for candidate in $ALL_CANDIDATES; do
    log_debug "Checking conflict with issue #$candidate..."

    # Get candidate issue data
    CANDIDATE_DATA=$(gh issue view "$candidate" --json number,title,body,labels 2>/dev/null || echo '{}')

    if [[ "$CANDIDATE_DATA" == "{}" ]]; then
        log_debug "Could not retrieve data for issue #$candidate, skipping"
        continue
    fi

    # Calculate conflict score
    CONFLICT_RESULT=$(calculate_conflict_score "$ISSUE_NUMBER" "$candidate" "$ISSUE_DATA" "$CANDIDATE_DATA")

    CONFLICT_SCORE=$(echo "$CONFLICT_RESULT" | jq -r '.score')
    CONFLICT_REASONS=$(echo "$CONFLICT_RESULT" | jq -r '.reasons')

    log_debug "Issue #$candidate: score=$CONFLICT_SCORE"

    # Check if score exceeds threshold
    if [[ $CONFLICT_SCORE -ge $THRESHOLD ]]; then
        # Check if container is running
        IS_RUNNING=false
        if echo "$RUNNING_ISSUES" | grep -qw "$candidate"; then
            IS_RUNNING=true
            CONFLICT_SCORE=$((CONFLICT_SCORE + 10))  # Boost score if container running
            CONFLICT_REASONS=$(echo "$CONFLICT_REASONS" | jq '. + ["container is running"]')
        fi

        CANDIDATE_TITLE=$(echo "$CANDIDATE_DATA" | jq -r '.title')

        CONFLICT=$(jq -n \
            --argjson issue "$candidate" \
            --arg title "$CANDIDATE_TITLE" \
            --argjson score "$CONFLICT_SCORE" \
            --argjson reasons "$CONFLICT_REASONS" \
            --arg strategy "label-based" \
            --argjson running "$IS_RUNNING" \
            '{
                issue: $issue,
                title: $title,
                score: $score,
                reasons: $reasons,
                strategy: $strategy,
                running: $running
            }')

        CONFLICTS+=("$CONFLICT")

        if [[ $CONFLICT_SCORE -gt $MAX_SCORE ]]; then
            MAX_SCORE=$CONFLICT_SCORE
        fi

        [[ "$JSON_ONLY" != "true" ]] && log_warn "Potential conflict with #$candidate (score: $CONFLICT_SCORE)"
    fi
done

# Determine action based on max score
ACTION="continue"
RECOMMENDATION=""

if [[ $MAX_SCORE -ge 60 ]]; then
    ACTION="block"
    RECOMMENDATION="High conflict risk detected. Consider waiting for conflicting work to complete or coordinate with other issues."
elif [[ $MAX_SCORE -ge $THRESHOLD ]]; then
    ACTION="warn"
    RECOMMENDATION="Moderate conflict risk detected. Proceed with caution and monitor for merge conflicts."
else
    ACTION="continue"
    RECOMMENDATION="Low conflict risk - safe to proceed"
fi

# Build conflicts array
CONFLICTS_JSON="[]"
if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
    CONFLICTS_JSON=$(printf '%s\n' "${CONFLICTS[@]}" | jq -s '.')
fi

# Generate prediction ID
PREDICTION_ID=$(generate_prediction_id)

# Build final result
RESULT=$(jq -n \
    --argjson issue "$ISSUE_NUMBER" \
    --argjson conflicts "$CONFLICTS_JSON" \
    --arg action "$ACTION" \
    --arg recommendation "$RECOMMENDATION" \
    --arg prediction_id "$PREDICTION_ID" \
    --argjson threshold "$THRESHOLD" \
    --argjson max_score "$MAX_SCORE" \
    '{
        issue: $issue,
        conflicts: $conflicts,
        action: $action,
        recommendation: $recommendation,
        prediction_id: $prediction_id,
        threshold: $threshold,
        max_score: $max_score,
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }')

# Record prediction if requested
if [[ "$RECORD_PREDICTION" == "true" ]]; then
    record_prediction "$PREDICTION_ID" "$RESULT"
fi

# Output result
echo "$RESULT"

# User-friendly output if not JSON-only
if [[ "$JSON_ONLY" != "true" ]]; then
    echo "" >&2

    if [[ ${#CONFLICTS[@]} -gt 0 ]]; then
        log_warn "Detected ${#CONFLICTS[@]} potential conflict(s):"
        echo "" >&2

        for conflict in "${CONFLICTS[@]}"; do
            local c_issue=$(echo "$conflict" | jq -r '.issue')
            local c_score=$(echo "$conflict" | jq -r '.score')
            local c_title=$(echo "$conflict" | jq -r '.title')
            local c_reasons=$(echo "$conflict" | jq -r '.reasons | join(", ")')

            echo -e "  ${YELLOW}#$c_issue${NC}: $c_title" >&2
            echo -e "    Score: $c_score | Reasons: $c_reasons" >&2
        done

        echo "" >&2
    fi

    case "$ACTION" in
        block)
            log_error "CONFLICT PREDICTION: $RECOMMENDATION"
            exit 1
            ;;
        warn)
            log_warn "CONFLICT PREDICTION: $RECOMMENDATION"
            ;;
        *)
            log_success "CONFLICT PREDICTION: $RECOMMENDATION"
            ;;
    esac
fi

# Exit with code based on action
[[ "$ACTION" == "block" ]] && exit 1
exit 0
