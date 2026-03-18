#!/usr/bin/env bash
# Documentation Parser Library
# Extracts script references and usage patterns from documentation files
#
# Usage: Source this file in other scripts
#   source scripts/lib/doc-parser.sh

set -euo pipefail

# Find all script references in a documentation file
find_doc_script_references() {
    local doc_file="$1"

    if [[ ! -f "$doc_file" ]]; then
        echo "ERROR: Documentation file not found: $doc_file" >&2
        return 1
    fi

    # Pattern 1: ./scripts/script-name.sh
    # Pattern 2: scripts/script-name.sh
    # Pattern 3: script-name.sh in code blocks
    # Pattern 4: Bash commands with script paths

    grep -oE '(\./)?scripts/[a-zA-Z0-9_-]+\.sh' "$doc_file" 2>/dev/null | sort -u || true
}

# Extract documented flags for a script from documentation
extract_documented_flags() {
    local doc_file="$1"
    local script_name="$2"

    # Find sections that reference the script
    local section=$(awk "/['\`]$script_name/,/^#|^\$/" "$doc_file" 2>/dev/null || true)

    # Extract flags mentioned in that section
    echo "$section" | grep -oE '\-\-[a-zA-Z0-9-]+|\-[a-zA-Z]' | sort -u || true
}

# Parse code blocks containing script invocations
parse_code_blocks() {
    local doc_file="$1"

    # Extract code blocks (markdown fenced blocks)
    awk '/```/,/```/' "$doc_file" 2>/dev/null | \
        grep -oE '(\./)?scripts/[a-zA-Z0-9_-]+\.sh[^\n]*' || true
}

# Extract expected output described in documentation
extract_expected_output() {
    local doc_file="$1"
    local script_name="$2"

    # Look for output examples after script mentions
    awk "/['\`]$script_name/,/Output:|Example:|Result:/" "$doc_file" 2>/dev/null | \
        awk '/Output:|Example:|Result:/,/^#/' || true
}

# Find all documentation files that reference scripts
find_docs_with_script_refs() {
    local docs_dir="${1:-.}"

    find "$docs_dir" -type f \( -name "*.md" -o -name "*.txt" \) -exec grep -l "scripts/.*\.sh" {} \; 2>/dev/null || true
}

# Extract script usage examples from documentation
extract_usage_examples() {
    local doc_file="$1"
    local script_name="$2"

    # Find lines with script invocations
    grep -n "$script_name" "$doc_file" 2>/dev/null | while IFS=: read -r line_num line_content; do
        # Check if it's in a code block or command
        if echo "$line_content" | grep -qE '^\s*(\$|```|`|bash)'; then
            echo "Line $line_num: $line_content"
        fi
    done
}

# Compare documented behavior with actual script
compare_doc_vs_script() {
    local doc_file="$1"
    local script_file="$2"
    local script_name="$(basename "$script_file")"

    # Extract flags from both sources
    local doc_flags=$(extract_documented_flags "$doc_file" "$script_name")
    local script_flags=$(grep -A 50 "^# Options:" "$script_file" 2>/dev/null | grep -oE '^\s*(--?[a-zA-Z0-9-]+)' | tr -d ' ' || true)

    # Find discrepancies
    local in_doc_not_script=$(comm -23 <(echo "$doc_flags" | sort) <(echo "$script_flags" | sort))
    local in_script_not_doc=$(comm -13 <(echo "$doc_flags" | sort) <(echo "$script_flags" | sort))

    local misalignments=()

    if [[ -n "$in_doc_not_script" ]]; then
        while IFS= read -r flag; do
            if [[ -n "$flag" ]]; then
                misalignments+=("Flag '$flag' documented but not in script")
            fi
        done <<< "$in_doc_not_script"
    fi

    if [[ -n "$in_script_not_doc" ]]; then
        while IFS= read -r flag; do
            if [[ -n "$flag" ]]; then
                misalignments+=("Flag '$flag' in script but not documented")
            fi
        done <<< "$in_script_not_doc"
    fi

    # Output results
    if [[ ${#misalignments[@]} -eq 0 ]]; then
        echo '{"aligned": true, "misalignments": []}'
    else
        local issues_json=$(printf '%s\n' "${misalignments[@]}" | jq -R . | jq -s .)
        echo "{\"aligned\": false, \"misalignments\": $issues_json}"
    fi
}

# Build documentation reference map
build_doc_reference_map() {
    local docs_dir="$1"

    echo "{"

    local first=true
    find "$docs_dir" -type f \( -name "*.md" -o -name "*.txt" \) 2>/dev/null | while read -r doc_file; do
        local refs=$(find_doc_script_references "$doc_file")

        if [[ -n "$refs" ]]; then
            if [[ "$first" == "false" ]]; then
                echo ","
            fi
            first=false

            local refs_json=$(echo "$refs" | jq -R . | jq -s .)
            echo -n "  \"$doc_file\": $refs_json"
        fi
    done

    echo ""
    echo "}"
}

# Validate documentation completeness
validate_doc_completeness() {
    local doc_file="$1"
    local script_file="$2"
    local issues=()

    local script_name=$(basename "$script_file")

    # Check if script is mentioned
    if ! grep -q "$script_name" "$doc_file"; then
        issues+=("Script not mentioned in documentation")
        echo "{\"complete\": false, \"issues\": $(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)}"
        return
    fi

    # Check for usage example
    local has_example=$(parse_code_blocks "$doc_file" | grep -c "$script_name" || echo 0)
    if [[ $has_example -eq 0 ]]; then
        issues+=("No usage example found")
    fi

    # Check for flag documentation
    local doc_flags=$(extract_documented_flags "$doc_file" "$script_name")
    local script_flags=$(grep -A 50 "^# Options:" "$script_file" 2>/dev/null | grep -oE '^\s*(--?[a-zA-Z0-9-]+)' | tr -d ' ' || true)

    local script_flag_count=$(echo "$script_flags" | grep -c . || echo 0)
    local doc_flag_count=$(echo "$doc_flags" | grep -c . || echo 0)

    if [[ $script_flag_count -gt 0 ]] && [[ $doc_flag_count -eq 0 ]]; then
        issues+=("Script has $script_flag_count flags but none are documented")
    fi

    # Output results
    if [[ ${#issues[@]} -eq 0 ]]; then
        echo '{"complete": true, "issues": []}'
    else
        local issues_json=$(printf '%s\n' "${issues[@]}" | jq -R . | jq -s .)
        echo "{\"complete\": false, \"issues\": $issues_json}"
    fi
}

# Export functions
export -f find_doc_script_references
export -f extract_documented_flags
export -f parse_code_blocks
export -f extract_expected_output
export -f find_docs_with_script_refs
export -f extract_usage_examples
export -f compare_doc_vs_script
export -f build_doc_reference_map
export -f validate_doc_completeness
