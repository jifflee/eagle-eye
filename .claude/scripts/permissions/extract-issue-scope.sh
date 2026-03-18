#!/bin/bash
# extract-issue-scope.sh
# Extract file/directory patterns from issue body for context-aware risk assessment
# Part of Issue #597: Context-aware risk assessment for Permission Decision Engine
#
# Usage:
#   ./scripts/permissions/extract-issue-scope.sh --issue-number <num>
#   echo '{"issue_body":"..."}' | ./scripts/permissions/extract-issue-scope.sh
#
# Output: JSON with file patterns and keywords

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$SCRIPT_DIR/../..}"

# Parse input
ISSUE_NUMBER=""
ISSUE_BODY=""

if [ -t 0 ]; then
    # Interactive - parse args
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue-number) ISSUE_NUMBER="$2"; shift 2 ;;
            --issue-body) ISSUE_BODY="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
else
    # Piped input
    INPUT=$(cat)
    ISSUE_NUMBER=$(echo "$INPUT" | jq -r '.issue_number // ""' 2>/dev/null || echo "")
    ISSUE_BODY=$(echo "$INPUT" | jq -r '.issue_body // ""' 2>/dev/null || echo "")
fi

# Fetch issue body if number provided
if [ -n "$ISSUE_NUMBER" ] && [ -z "$ISSUE_BODY" ]; then
    if command -v gh &> /dev/null; then
        ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body -q .body 2>/dev/null || echo "")
    fi
fi

# If still no issue body, return empty scope without error
if [ -z "$ISSUE_BODY" ]; then
    # Try to get from branch if no issue number yet
    if [ -z "$ISSUE_NUMBER" ]; then
        BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ "$BRANCH" =~ (feat|fix|issue)[/-]([0-9]+) ]]; then
            ISSUE_NUMBER="${BASH_REMATCH[2]}"
            if command -v gh &> /dev/null; then
                ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --json body -q .body 2>/dev/null || echo "")
            fi
        fi
    fi
fi

# Extract file patterns from issue body
extract_file_patterns() {
    local body="$1"
    local patterns=()

    # Pattern 1: Explicit file paths (e.g., scripts/sync-configs.sh)
    # Match patterns like: path/to/file.ext or path/to/dir/
    while IFS= read -r line; do
        # Look for markdown code blocks or inline code
        if [[ "$line" =~ \`([a-zA-Z0-9/_.-]+\.(sh|py|js|ts|yaml|yml|json|md))\` ]]; then
            patterns+=("${BASH_REMATCH[1]}")
        fi
        # Look for file paths in plain text
        if [[ "$line" =~ ([a-zA-Z0-9/_-]+/[a-zA-Z0-9/_.-]+\.(sh|py|js|ts|yaml|yml|json|md)) ]]; then
            patterns+=("${BASH_REMATCH[1]}")
        fi
        # Look for directory patterns (e.g., user-configs/*)
        if [[ "$line" =~ ([a-zA-Z0-9/_-]+/\*) ]]; then
            patterns+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$body"

    # Pattern 2: Component/module mentions (convert to directory patterns)
    if [[ "$body" =~ sync-config ]]; then
        patterns+=("scripts/sync-*.sh" "config/*sync*")
    fi
    if [[ "$body" =~ permission ]]; then
        patterns+=("scripts/permissions/*" "config/*permission*")
    fi
    if [[ "$body" =~ container ]]; then
        patterns+=("scripts/container-*" "tests/container/*")
    fi

    # Pattern 3: Test file patterns
    if [[ "$body" =~ test|testing ]]; then
        patterns+=("tests/*" "**/test-*")
    fi

    # Remove duplicates and output as JSON array
    printf '%s\n' "${patterns[@]}" | sort -u | jq -R . | jq -s .
}

# Extract keywords for context matching
extract_keywords() {
    local body="$1"
    local keywords=()

    # Extract words from headers and bold text
    while IFS= read -r line; do
        # Markdown headers
        if [[ "$line" =~ ^#+[[:space:]]*(.+)$ ]]; then
            keywords+=("${BASH_REMATCH[1]}")
        fi
        # Bold text
        if [[ "$line" =~ \*\*([^*]+)\*\* ]]; then
            keywords+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$body"

    # Common technical keywords
    local tech_keywords=(
        "auth" "authentication" "permission" "container"
        "sync" "config" "test" "deployment" "ci/cd"
        "webhook" "api" "database" "security"
    )

    for keyword in "${tech_keywords[@]}"; do
        if [[ "$body" =~ $keyword ]]; then
            keywords+=("$keyword")
        fi
    done

    # Remove duplicates and lowercase
    printf '%s\n' "${keywords[@]}" | tr '[:upper:]' '[:lower:]' | sort -u | jq -R . | jq -s .
}

# Extract acceptance criteria files
extract_acceptance_files() {
    local body="$1"
    local files=()

    # Look for acceptance criteria section
    local in_acceptance=false
    while IFS= read -r line; do
        if [[ "$line" =~ [Aa]cceptance[[:space:]]+[Cc]riteria ]]; then
            in_acceptance=true
            continue
        fi

        # Stop at next major section
        if [[ "$line" =~ ^##[[:space:]] ]] && [ "$in_acceptance" = true ]; then
            break
        fi

        if [ "$in_acceptance" = true ]; then
            # Extract file patterns from acceptance criteria
            if [[ "$line" =~ ([a-zA-Z0-9/_-]+\.(sh|py|js|ts|yaml|yml|json|md)) ]]; then
                files+=("${BASH_REMATCH[1]}")
            fi
        fi
    done <<< "$body"

    printf '%s\n' "${files[@]}" | sort -u | jq -R . | jq -s .
}

# Main extraction
if [ -n "$ISSUE_BODY" ]; then
    FILE_PATTERNS=$(extract_file_patterns "$ISSUE_BODY")
    KEYWORDS=$(extract_keywords "$ISSUE_BODY")
    ACCEPTANCE_FILES=$(extract_acceptance_files "$ISSUE_BODY")

    jq -n \
        --argjson patterns "$FILE_PATTERNS" \
        --argjson keywords "$KEYWORDS" \
        --argjson acceptance "$ACCEPTANCE_FILES" \
        --arg issue "$ISSUE_NUMBER" \
        '{
            issue_number: $issue,
            file_patterns: $patterns,
            keywords: $keywords,
            acceptance_files: $acceptance,
            pattern_count: ($patterns | length),
            has_scope: (($patterns | length) > 0 or ($keywords | length) > 0)
        }'
else
    # No issue body - return empty scope
    jq -n '{
        issue_number: "",
        file_patterns: [],
        keywords: [],
        acceptance_files: [],
        pattern_count: 0,
        has_scope: false,
        error: "no issue body available"
    }'
fi
