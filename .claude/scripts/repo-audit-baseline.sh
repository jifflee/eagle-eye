#!/usr/bin/env bash
#
# repo-audit-baseline.sh
# Manage repository health baselines for drift tracking
# size-ok: multi-command baseline manager with init/update/compare/reset modes
#
# Usage:
#   ./scripts/repo-audit-baseline.sh init                    # Create baseline from current state
#   ./scripts/repo-audit-baseline.sh update                  # Update baseline to current state
#   ./scripts/repo-audit-baseline.sh compare                 # Compare current vs baseline
#   ./scripts/repo-audit-baseline.sh reset                   # Reset to default thresholds
#   ./scripts/repo-audit-baseline.sh set-threshold <metric> <field> <value>
#   ./scripts/repo-audit-baseline.sh show                    # Display current baseline
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - Baseline not found
#   3 - File system error

set -euo pipefail

AUDIT_DIR=".repo-audit"
BASELINE_FILE="$AUDIT_DIR/baseline.json"
METRICS_FILE="$AUDIT_DIR/metrics.jsonl"
SCHEMA_VERSION="1.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

success() {
    echo -e "${GREEN}OK${NC} $1"
}

info() {
    echo -e "${BLUE}--${NC} $1"
}

warn() {
    echo -e "${YELLOW}!!${NC} $1"
}

# Get current git commit SHA
get_commit_sha() {
    git rev-parse --short HEAD 2>/dev/null || echo "unknown"
}

# Count files matching pattern
count_files() {
    local pattern="$1"
    find . -type f -name "$pattern" ! -path "./node_modules/*" ! -path "./.git/*" ! -path "./vendor/*" ! -path "./.venv/*" 2>/dev/null | wc -l | tr -d ' '
}

# Count source files (excluding tests)
count_source_files() {
    local count=0
    for ext in js ts jsx tsx py rb go rs java c cpp h hpp cs php; do
        local files
        files=$(find . -type f -name "*.$ext" ! -name "*.test.*" ! -name "*.spec.*" ! -name "*_test.*" ! -path "./node_modules/*" ! -path "./.git/*" ! -path "./vendor/*" ! -path "./.venv/*" ! -path "*/__pycache__/*" ! -path "./test/*" ! -path "./tests/*" ! -path "./**/test/*" ! -path "./**/tests/*" 2>/dev/null | wc -l | tr -d ' ')
        count=$((count + files))
    done
    echo "$count"
}

# Count test files
count_test_files() {
    local count=0
    # Match test file patterns
    for ext in js ts jsx tsx py rb go rs java; do
        local files
        files=$(find . -type f \( -name "*.test.$ext" -o -name "*.spec.$ext" -o -name "*_test.$ext" -o -name "test_*.$ext" \) ! -path "./node_modules/*" ! -path "./.git/*" ! -path "./vendor/*" ! -path "./.venv/*" 2>/dev/null | wc -l | tr -d ' ')
        count=$((count + files))
    done
    # Also count files in test directories
    local test_dir_files
    test_dir_files=$(find . -type f \( -path "./test/*" -o -path "./tests/*" -o -path "./__tests__/*" \) -name "*.js" -o -name "*.ts" -o -name "*.py" 2>/dev/null | wc -l | tr -d ' ')
    count=$((count + test_dir_files))
    echo "$count"
}

# Count TODO comments
count_todos() {
    grep -r "TODO" --include="*.js" --include="*.ts" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" --include="*.rb" . 2>/dev/null | grep -v "node_modules" | grep -v ".git" | wc -l | tr -d ' '
}

# Count FIXME comments
count_fixmes() {
    grep -r "FIXME" --include="*.js" --include="*.ts" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" --include="*.rb" . 2>/dev/null | grep -v "node_modules" | grep -v ".git" | wc -l | tr -d ' '
}

# Count large files (over threshold LOC)
count_large_files() {
    local threshold="${1:-500}"
    local count=0
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local lines
            lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
            if [[ "$lines" -gt "$threshold" ]]; then
                count=$((count + 1))
            fi
        fi
    done < <(find . -type f \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) ! -path "./node_modules/*" ! -path "./.git/*" ! -path "./vendor/*" 2>/dev/null)
    echo "$count"
}

# Get max file LOC
get_max_file_loc() {
    local max=0
    while IFS= read -r file; do
        if [[ -n "$file" ]]; then
            local lines
            lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
            if [[ "$lines" -gt "$max" ]]; then
                max="$lines"
            fi
        fi
    done < <(find . -type f \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" -o -name "*.java" \) ! -path "./node_modules/*" ! -path "./.git/*" ! -path "./vendor/*" 2>/dev/null)
    echo "$max"
}

# Collect current metrics
collect_metrics() {
    local file_count
    local test_file_count
    local test_ratio
    local todo_count
    local fixme_count
    local large_files
    local max_file_loc

    info "Collecting metrics..." >&2

    file_count=$(count_source_files)
    test_file_count=$(count_test_files)

    if [[ "$file_count" -gt 0 ]]; then
        test_ratio=$(echo "scale=2; $test_file_count / $file_count" | bc)
    else
        test_ratio="0.00"
    fi

    todo_count=$(count_todos)
    fixme_count=$(count_fixmes)
    large_files=$(count_large_files 500)
    max_file_loc=$(get_max_file_loc)

    jq -n \
        --argjson file_count "$file_count" \
        --argjson test_file_count "$test_file_count" \
        --arg test_ratio "$test_ratio" \
        --argjson todo_count "$todo_count" \
        --argjson fixme_count "$fixme_count" \
        --argjson large_files "$large_files" \
        --argjson max_file_loc "$max_file_loc" \
        '{
            file_count: $file_count,
            test_file_count: $test_file_count,
            test_ratio: ($test_ratio | tonumber),
            todo_count: $todo_count,
            fixme_count: $fixme_count,
            large_files: $large_files,
            max_file_loc: $max_file_loc
        }'
}

# Get default thresholds
get_default_thresholds() {
    cat <<'EOF'
{
    "test_ratio": { "min": 0.25, "target": 0.40 },
    "todo_count": { "warn": 20, "critical": 50 },
    "large_file_count": { "warn": 5, "critical": 10 },
    "max_file_loc": { "warn": 500, "critical": 1000 }
}
EOF
}

# Initialize baseline
init_baseline() {
    # Create audit directory if needed
    if [[ ! -d "$AUDIT_DIR" ]]; then
        mkdir -p "$AUDIT_DIR"
        info "Created audit directory: $AUDIT_DIR"
    fi

    if [[ -f "$BASELINE_FILE" ]]; then
        warn "Baseline already exists. Use 'update' to refresh metrics or 'reset' to restore defaults."
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local commit_sha
    commit_sha=$(get_commit_sha)
    local metrics
    metrics=$(collect_metrics)
    local thresholds
    thresholds=$(get_default_thresholds)

    jq -n \
        --arg schema_version "$SCHEMA_VERSION" \
        --arg created_at "$timestamp" \
        --arg updated_at "$timestamp" \
        --arg baseline_commit "$commit_sha" \
        --argjson thresholds "$thresholds" \
        --argjson baseline_metrics "$metrics" \
        '{
            schema_version: $schema_version,
            created_at: $created_at,
            updated_at: $updated_at,
            baseline_commit: $baseline_commit,
            thresholds: $thresholds,
            baseline_metrics: $baseline_metrics
        }' > "$BASELINE_FILE"

    success "Created baseline at commit $commit_sha"
    echo ""
    show_baseline
}

# Update baseline metrics
update_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run 'init' first."
        exit 2
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local commit_sha
    commit_sha=$(get_commit_sha)
    local metrics
    metrics=$(collect_metrics)

    # Preserve existing thresholds
    jq \
        --arg updated_at "$timestamp" \
        --arg baseline_commit "$commit_sha" \
        --argjson baseline_metrics "$metrics" \
        '.updated_at = $updated_at | .baseline_commit = $baseline_commit | .baseline_metrics = $baseline_metrics' \
        "$BASELINE_FILE" > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"

    # Append to metrics history
    local history_entry
    history_entry=$(jq -n \
        --arg commit "$commit_sha" \
        --arg timestamp "$timestamp" \
        --argjson metrics "$metrics" \
        '{commit: $commit, timestamp: $timestamp, metrics: $metrics}')
    echo "$history_entry" >> "$METRICS_FILE"

    success "Updated baseline to commit $commit_sha"
    echo ""
    show_baseline
}

# Compare current state against baseline
compare_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run 'init' first."
        exit 2
    fi

    local current_metrics
    current_metrics=$(collect_metrics)
    local baseline_metrics
    baseline_metrics=$(jq '.baseline_metrics' "$BASELINE_FILE")
    local thresholds
    thresholds=$(jq '.thresholds' "$BASELINE_FILE")
    local baseline_commit
    baseline_commit=$(jq -r '.baseline_commit' "$BASELINE_FILE")
    local current_commit
    current_commit=$(get_commit_sha)

    echo ""
    echo "## Baseline Comparison"
    echo ""
    echo "Baseline commit: $baseline_commit"
    echo "Current commit:  $current_commit"
    echo ""
    echo "| Metric | Baseline | Current | Delta | Status |"
    echo "|--------|----------|---------|-------|--------|"

    # Compare each metric
    local metrics_list="file_count test_file_count test_ratio todo_count fixme_count large_files max_file_loc"

    for metric in $metrics_list; do
        local baseline_val
        baseline_val=$(echo "$baseline_metrics" | jq -r ".$metric // 0")
        local current_val
        current_val=$(echo "$current_metrics" | jq -r ".$metric // 0")

        local delta
        if [[ "$metric" == "test_ratio" ]]; then
            delta=$(echo "scale=2; $current_val - $baseline_val" | bc)
        else
            delta=$((current_val - baseline_val))
        fi

        local status
        status=$(get_metric_status "$metric" "$current_val" "$thresholds")

        local delta_display
        if [[ "${delta:0:1}" != "-" && "$delta" != "0" ]]; then
            delta_display="+$delta"
        else
            delta_display="$delta"
        fi

        echo "| $metric | $baseline_val | $current_val | $delta_display | $status |"
    done

    echo ""

    # Summary
    local improvements=0
    local regressions=0

    # Test ratio: higher is better
    local baseline_ratio
    baseline_ratio=$(echo "$baseline_metrics" | jq -r '.test_ratio // 0')
    local current_ratio
    current_ratio=$(echo "$current_metrics" | jq -r '.test_ratio // 0')
    if (( $(echo "$current_ratio > $baseline_ratio" | bc -l) )); then
        improvements=$((improvements + 1))
    elif (( $(echo "$current_ratio < $baseline_ratio" | bc -l) )); then
        regressions=$((regressions + 1))
    fi

    # TODOs: lower is better
    local baseline_todos
    baseline_todos=$(echo "$baseline_metrics" | jq -r '.todo_count // 0')
    local current_todos
    current_todos=$(echo "$current_metrics" | jq -r '.todo_count // 0')
    if [[ "$current_todos" -lt "$baseline_todos" ]]; then
        improvements=$((improvements + 1))
    elif [[ "$current_todos" -gt "$baseline_todos" ]]; then
        regressions=$((regressions + 1))
    fi

    # Large files: lower is better
    local baseline_large
    baseline_large=$(echo "$baseline_metrics" | jq -r '.large_files // 0')
    local current_large
    current_large=$(echo "$current_metrics" | jq -r '.large_files // 0')
    if [[ "$current_large" -lt "$baseline_large" ]]; then
        improvements=$((improvements + 1))
    elif [[ "$current_large" -gt "$baseline_large" ]]; then
        regressions=$((regressions + 1))
    fi

    echo "**Summary:** $improvements improvements, $regressions regressions"
}

# Get status indicator for a metric
get_metric_status() {
    local metric="$1"
    local value="$2"
    local thresholds="$3"

    case "$metric" in
        test_ratio)
            local min_threshold
            min_threshold=$(echo "$thresholds" | jq -r '.test_ratio.min // 0.25')
            local target_threshold
            target_threshold=$(echo "$thresholds" | jq -r '.test_ratio.target // 0.40')
            if (( $(echo "$value >= $target_threshold" | bc -l) )); then
                echo -e "${GREEN}GOOD${NC}"
            elif (( $(echo "$value >= $min_threshold" | bc -l) )); then
                echo -e "${YELLOW}WARN${NC}"
            else
                echo -e "${RED}LOW${NC}"
            fi
            ;;
        todo_count)
            local warn_threshold
            warn_threshold=$(echo "$thresholds" | jq -r '.todo_count.warn // 20')
            local crit_threshold
            crit_threshold=$(echo "$thresholds" | jq -r '.todo_count.critical // 50')
            if [[ "$value" -le "$warn_threshold" ]]; then
                echo -e "${GREEN}GOOD${NC}"
            elif [[ "$value" -le "$crit_threshold" ]]; then
                echo -e "${YELLOW}WARN${NC}"
            else
                echo -e "${RED}CRIT${NC}"
            fi
            ;;
        large_files)
            local warn_threshold
            warn_threshold=$(echo "$thresholds" | jq -r '.large_file_count.warn // 5')
            local crit_threshold
            crit_threshold=$(echo "$thresholds" | jq -r '.large_file_count.critical // 10')
            if [[ "$value" -le "$warn_threshold" ]]; then
                echo -e "${GREEN}GOOD${NC}"
            elif [[ "$value" -le "$crit_threshold" ]]; then
                echo -e "${YELLOW}WARN${NC}"
            else
                echo -e "${RED}CRIT${NC}"
            fi
            ;;
        max_file_loc)
            local warn_threshold
            warn_threshold=$(echo "$thresholds" | jq -r '.max_file_loc.warn // 500')
            local crit_threshold
            crit_threshold=$(echo "$thresholds" | jq -r '.max_file_loc.critical // 1000')
            if [[ "$value" -le "$warn_threshold" ]]; then
                echo -e "${GREEN}GOOD${NC}"
            elif [[ "$value" -le "$crit_threshold" ]]; then
                echo -e "${YELLOW}WARN${NC}"
            else
                echo -e "${RED}CRIT${NC}"
            fi
            ;;
        *)
            echo "-"
            ;;
    esac
}

# Reset thresholds to defaults
reset_thresholds() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run 'init' first."
        exit 2
    fi

    local thresholds
    thresholds=$(get_default_thresholds)

    jq --argjson thresholds "$thresholds" '.thresholds = $thresholds' \
        "$BASELINE_FILE" > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"

    success "Reset thresholds to defaults"
}

# Set a specific threshold
set_threshold() {
    local metric="$1"
    local field="$2"
    local value="$3"

    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run 'init' first."
        exit 2
    fi

    # Validate metric exists
    local valid_metrics="test_ratio todo_count large_file_count max_file_loc"
    if [[ ! " $valid_metrics " =~ " $metric " ]]; then
        error "Invalid metric: $metric. Valid: $valid_metrics"
        exit 1
    fi

    jq --arg metric "$metric" --arg field "$field" --argjson value "$value" \
        '.thresholds[$metric][$field] = $value' \
        "$BASELINE_FILE" > "$BASELINE_FILE.tmp" && mv "$BASELINE_FILE.tmp" "$BASELINE_FILE"

    success "Set $metric.$field = $value"
}

# Show current baseline
show_baseline() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        error "Baseline not found. Run 'init' first."
        exit 2
    fi

    echo ""
    echo "## Current Baseline"
    echo ""
    jq -r '"Schema version: \(.schema_version)\nCreated: \(.created_at)\nUpdated: \(.updated_at)\nCommit: \(.baseline_commit)"' "$BASELINE_FILE"
    echo ""
    echo "### Metrics"
    jq -r '.baseline_metrics | to_entries[] | "  \(.key): \(.value)"' "$BASELINE_FILE"
    echo ""
    echo "### Thresholds"
    jq -r '.thresholds | to_entries[] | "  \(.key): \(.value)"' "$BASELINE_FILE"
}

# Main command router
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        init)
            init_baseline
            ;;
        update)
            update_baseline
            ;;
        compare)
            compare_baseline
            ;;
        reset)
            reset_thresholds
            ;;
        set-threshold)
            if [[ $# -lt 3 ]]; then
                error "Usage: $0 set-threshold <metric> <field> <value>"
                exit 1
            fi
            set_threshold "$1" "$2" "$3"
            ;;
        show)
            show_baseline
            ;;
        help|--help|-h)
            echo "repo-audit-baseline.sh - Manage repository health baselines"
            echo ""
            echo "Usage:"
            echo "  $0 init                              Create baseline from current state"
            echo "  $0 update                            Update baseline to current state"
            echo "  $0 compare                           Compare current vs baseline"
            echo "  $0 reset                             Reset to default thresholds"
            echo "  $0 set-threshold <metric> <f> <val>  Set specific threshold"
            echo "  $0 show                              Display current baseline"
            echo ""
            echo "Metrics: file_count, test_file_count, test_ratio, todo_count,"
            echo "         fixme_count, large_files, max_file_loc"
            echo ""
            echo "Threshold metrics: test_ratio, todo_count, large_file_count, max_file_loc"
            ;;
        *)
            error "Unknown command: $command"
            echo "Run '$0 help' for usage"
            exit 1
            ;;
    esac
}

main "$@"
