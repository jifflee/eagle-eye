#!/usr/bin/env bash
# Script Analyzer Library
# Provides functions for analyzing script contracts, usage patterns, and similarities
#
# Usage: Source this file in other scripts
#   source scripts/lib/script-analyzer.sh

set -euo pipefail

# Extract comprehensive script metadata
extract_script_metadata() {
    local script="$1"
    local metadata=""

    if [[ ! -f "$script" ]]; then
        echo "ERROR: Script not found: $script" >&2
        return 1
    fi

    # Extract shebang
    local shebang=$(head -1 "$script" | grep '^#!' || echo "")

    # Extract description (first non-shebang comment block)
    local description=$(grep -E '^#' "$script" | grep -v '^#!/' | head -5 | sed 's/^# *//' | tr '\n' ' ')

    # Extract usage pattern
    local usage=$(grep -A 20 "^# Usage:" "$script" 2>/dev/null | grep '^#' | sed 's/^# *//' || echo "")

    # Extract options/flags
    local options=$(grep -A 50 "^# Options:" "$script" 2>/dev/null | grep '^#' | sed 's/^# *//' || echo "")

    # Extract exit codes
    local exit_codes=$(grep -A 20 "^# Exit codes:" "$script" 2>/dev/null | grep '^#' | sed 's/^# *//' || echo "")

    # Build metadata object
    cat <<EOF
{
  "path": "$script",
  "name": "$(basename "$script")",
  "shebang": "$shebang",
  "description": "$description",
  "usage": $(echo "$usage" | jq -Rs .),
  "options": $(echo "$options" | jq -Rs .),
  "exit_codes": $(echo "$exit_codes" | jq -Rs .)
}
EOF
}

# Extract all flags/arguments from script
extract_flags() {
    local script="$1"

    # Method 1: From header documentation
    local doc_flags=$(grep -A 50 "^# Options:" "$script" 2>/dev/null | grep -oE '^\s*(--?[a-zA-Z0-9-]+)' | tr -d ' ' || true)

    # Method 2: From getopts/case statements
    local code_flags=$(grep -oE '\-\-[a-zA-Z0-9-]+|\-[a-zA-Z]' "$script" | sort -u || true)

    # Combine and deduplicate
    echo -e "$doc_flags\n$code_flags" | grep -v '^$' | sort -u
}

# Parse script arguments structure
parse_argument_structure() {
    local script="$1"

    # Look for argument parsing patterns
    local has_getopts=$(grep -c "getopts" "$script" || echo 0)
    local has_case=$(grep -c "case.*in" "$script" || echo 0)
    local has_shift=$(grep -c "shift" "$script" || echo 0)

    # Detect positional arguments
    local positional_args=$(grep -oE '\$[0-9]+' "$script" | sort -u | wc -l)

    cat <<EOF
{
  "uses_getopts": $([[ $has_getopts -gt 0 ]] && echo "true" || echo "false"),
  "uses_case": $([[ $has_case -gt 0 ]] && echo "true" || echo "false"),
  "uses_shift": $([[ $has_shift -gt 0 ]] && echo "true" || echo "false"),
  "positional_args_count": $positional_args
}
EOF
}

# Calculate script complexity metrics
calculate_complexity() {
    local script="$1"

    local total_lines=$(wc -l < "$script")
    local code_lines=$(grep -cvE '^\s*#|^\s*$' "$script" || echo 0)
    local comment_lines=$(grep -cE '^\s*#' "$script" || echo 0)
    local function_count=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)' "$script" || echo 0)
    local if_count=$(grep -cE '^\s*if\s+' "$script" || echo 0)
    local loop_count=$(grep -cE '^\s*(for|while)\s+' "$script" || echo 0)

    cat <<EOF
{
  "total_lines": $total_lines,
  "code_lines": $code_lines,
  "comment_lines": $comment_lines,
  "function_count": $function_count,
  "if_statements": $if_count,
  "loops": $loop_count,
  "complexity_score": $(( (if_count + loop_count + function_count) * 100 / (code_lines + 1) ))
}
EOF
}

# Find all invocations of a script in the codebase
find_script_invocations() {
    local script_name="$1"
    local search_root="${2:-.}"

    # Search patterns for script invocations
    local patterns=(
        "$script_name"
        "./scripts/$script_name"
        "bash.*$script_name"
        "sh.*$script_name"
    )

    local results=()

    for pattern in "${patterns[@]}"; do
        # Search in common locations
        local matches=$(grep -r -n --include="*.md" --include="*.sh" --include="*.yml" --include="*.yaml" \
            -e "$pattern" "$search_root" 2>/dev/null || true)

        if [[ -n "$matches" ]]; then
            results+=("$matches")
        fi
    done

    # Output unique results
    printf '%s\n' "${results[@]}" | sort -u
}

# Compare two scripts for similarity
compare_scripts() {
    local script1="$1"
    local script2="$2"

    # Extract key components
    local desc1=$(extract_script_metadata "$script1" | jq -r .description)
    local desc2=$(extract_script_metadata "$script2" | jq -r .description)

    local flags1=$(extract_flags "$script1" | sort)
    local flags2=$(extract_flags "$script2" | sort)

    # Calculate name similarity
    local name1=$(basename "$script1" .sh)
    local name2=$(basename "$script2" .sh)
    local name_sim=$(calculate_string_similarity "$name1" "$name2")

    # Calculate description similarity
    local desc_sim=$(calculate_string_similarity "$desc1" "$desc2")

    # Calculate flag overlap
    local common_flags=$(comm -12 <(echo "$flags1") <(echo "$flags2") | wc -l)
    local total_flags=$(comm -3 <(echo "$flags1") <(echo "$flags2") | wc -l)
    local flag_similarity=0
    if [[ $((common_flags + total_flags)) -gt 0 ]]; then
        flag_similarity=$(( common_flags * 100 / (common_flags + total_flags) ))
    fi

    # Overall similarity score
    local overall=$(( (name_sim + desc_sim + flag_similarity) / 3 ))

    cat <<EOF
{
  "name_similarity": $name_sim,
  "description_similarity": $desc_sim,
  "flag_similarity": $flag_similarity,
  "overall_similarity": $overall
}
EOF
}

# Calculate string similarity (simple approach)
calculate_string_similarity() {
    local str1="$1"
    local str2="$2"

    # Convert to lowercase and split into words
    local words1=$(echo "$str1" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)
    local words2=$(echo "$str2" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | sort -u)

    # Count common words
    local common=$(comm -12 <(echo "$words1") <(echo "$words2") | wc -l)
    local unique=$(comm -3 <(echo "$words1") <(echo "$words2") | wc -l)

    if [[ $((common + unique)) -eq 0 ]]; then
        echo 0
    else
        echo $(( common * 100 / (common + unique) ))
    fi
}

# Validate script against best practices
validate_script_quality() {
    local script="$1"
    local issues=()

    # Check shebang
    if ! head -1 "$script" | grep -q '^#!/'; then
        issues+=("Missing shebang")
    fi

    # Check for usage documentation
    if ! grep -q "^# Usage:" "$script"; then
        issues+=("Missing usage documentation")
    fi

    # Check for set -e or set -euo pipefail
    if ! grep -qE '^set -[euo]+' "$script"; then
        issues+=("Missing error handling (set -e)")
    fi

    # Check for exit code documentation
    if ! grep -q "^# Exit codes:" "$script"; then
        issues+=("Missing exit code documentation")
    fi

    # Check for help option
    if ! grep -qE '\-\-help|\-h' "$script"; then
        issues+=("No help option detected")
    fi

    # Output results
    if [[ ${#issues[@]} -eq 0 ]]; then
        echo '{"valid": true, "issues": []}'
    else
        local issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
        echo "{\"valid\": false, \"issues\": $issues_json}"
    fi
}

# Export functions for use in other scripts
export -f extract_script_metadata
export -f extract_flags
export -f parse_argument_structure
export -f calculate_complexity
export -f find_script_invocations
export -f compare_scripts
export -f calculate_string_similarity
export -f validate_script_quality
