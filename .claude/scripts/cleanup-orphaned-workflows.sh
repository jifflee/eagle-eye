#!/usr/bin/env bash
#
# cleanup-orphaned-workflows.sh - Clean up orphaned GitHub Actions workflow registrations
#
# When workflow YAML files are deleted from a repo, the workflow registration remains
# in GitHub Actions. This script identifies and disables these orphaned registrations.
#
# Usage:
#   ./scripts/cleanup-orphaned-workflows.sh --list           # List orphaned workflows
#   ./scripts/cleanup-orphaned-workflows.sh --disable        # Disable orphaned workflows
#   ./scripts/cleanup-orphaned-workflows.sh --disable --dry-run  # Preview what would be disabled
#   ./scripts/cleanup-orphaned-workflows.sh --pending        # Show what will be orphaned after dev→main merge
#
# Options:
#   --list      List all orphaned workflow registrations (vs default branch)
#   --pending   Show workflows that will become orphaned when dev merges to main
#   --disable   Disable orphaned workflow registrations
#   --branch B  Specify branch to check against (default: repo's default branch)
#   --dry-run   Preview actions without executing (use with --disable)
#   --json      Output in JSON format
#   --help      Show this help message
#
# Related:
#   - docs/GITHUB_ACTIONS_DEPRECATION.md
#   - Issue #369

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
ACTION="list"
DRY_RUN=false
JSON_OUTPUT=false
BRANCH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --list)
            ACTION="list"
            shift
            ;;
        --pending)
            ACTION="pending"
            shift
            ;;
        --disable)
            ACTION="disable"
            shift
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            head -32 "$0" | tail -27 | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check for required tools
if ! command -v gh &> /dev/null; then
    echo -e "${RED}Error: gh CLI is required but not installed${NC}" >&2
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is required but not installed${NC}" >&2
    exit 1
fi

# Get repository info
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
if [[ -z "$REPO" ]]; then
    echo -e "${RED}Error: Not in a GitHub repository${NC}" >&2
    exit 1
fi

# Get default branch
DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || echo "main")

# Use specified branch or default
CHECK_BRANCH="${BRANCH:-$DEFAULT_BRANCH}"

# Function to check if a workflow file exists in the repo on a specific branch
file_exists_in_branch() {
    local path="$1"
    local branch="$2"
    git cat-file -e "origin/${branch}:${path}" 2>/dev/null
}

# Function to check if a workflow file exists in the repo
file_exists_in_repo() {
    local path="$1"
    file_exists_in_branch "$path" "$CHECK_BRANCH"
}

# Function to get all workflows and their status
get_workflows() {
    gh api repos/:owner/:repo/actions/workflows --jq '.workflows[] | {id: .id, name: .name, path: .path, state: .state}'
}

# Function to check if workflow is orphaned
is_orphaned() {
    local path="$1"
    # Only check workflows in .github/workflows/ (not template repos)
    if [[ "$path" != .github/workflows/* ]]; then
        return 1  # Not orphaned (template workflow)
    fi
    ! file_exists_in_repo "$path"
}

# Function to disable a workflow
disable_workflow() {
    local workflow_id="$1"
    local workflow_name="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would disable: $workflow_name (ID: $workflow_id)"
        return 0
    fi

    if gh api -X PUT "repos/:owner/:repo/actions/workflows/${workflow_id}/disable" 2>/dev/null; then
        echo -e "${GREEN}Disabled:${NC} $workflow_name"
        return 0
    else
        echo -e "${RED}Failed to disable:${NC} $workflow_name" >&2
        return 1
    fi
}

# Main logic
main() {
    local orphaned_workflows=()
    local active_workflows=()
    local template_workflows=()

    # Fetch and categorize workflows
    while IFS= read -r workflow_json; do
        local id=$(echo "$workflow_json" | jq -r '.id')
        local name=$(echo "$workflow_json" | jq -r '.name')
        local path=$(echo "$workflow_json" | jq -r '.path')
        local state=$(echo "$workflow_json" | jq -r '.state')

        # Skip template workflows
        if [[ "$path" != .github/workflows/* ]]; then
            template_workflows+=("$workflow_json")
            continue
        fi

        if is_orphaned "$path"; then
            orphaned_workflows+=("$workflow_json")
        else
            active_workflows+=("$workflow_json")
        fi
    done < <(get_workflows)

    # Output based on action
    case "$ACTION" in
        pending)
            # Show workflows that will become orphaned when dev merges to main
            echo -e "${BLUE}=== Pending Deprecations (dev→main merge) ===${NC}"
            echo -e "Checking what will be orphaned when 'dev' merges to '${DEFAULT_BRANCH}'..."
            echo ""

            local pending_orphan=()
            local will_remain=()

            for wf in "${active_workflows[@]}"; do
                local name=$(echo "$wf" | jq -r '.name')
                local path=$(echo "$wf" | jq -r '.path')

                # Check if file exists on dev
                if file_exists_in_branch "$path" "dev"; then
                    will_remain+=("$wf")
                else
                    pending_orphan+=("$wf")
                fi
            done

            echo -e "${YELLOW}Workflows that will become ORPHANED after merge (${#pending_orphan[@]}):${NC}"
            if [[ ${#pending_orphan[@]} -eq 0 ]]; then
                echo "  (none)"
            else
                for wf in "${pending_orphan[@]}"; do
                    local name=$(echo "$wf" | jq -r '.name')
                    local path=$(echo "$wf" | jq -r '.path')
                    echo -e "  ${YELLOW}*${NC} $name"
                    echo "    Path: $path"
                done
            fi
            echo ""
            echo -e "${GREEN}Workflows that will REMAIN after merge (${#will_remain[@]}):${NC}"
            if [[ ${#will_remain[@]} -eq 0 ]]; then
                echo "  (none)"
            else
                for wf in "${will_remain[@]}"; do
                    local name=$(echo "$wf" | jq -r '.name')
                    local path=$(echo "$wf" | jq -r '.path')
                    echo -e "  ${GREEN}*${NC} $name"
                    echo "    Path: $path"
                done
            fi
            echo ""
            echo -e "${BLUE}Currently orphaned (${#orphaned_workflows[@]}):${NC}"
            echo "  These will remain orphaned: ${#orphaned_workflows[@]} workflows"
            echo ""
            echo -e "${BLUE}Total orphaned after merge:${NC} $((${#orphaned_workflows[@]} + ${#pending_orphan[@]}))"
            echo ""
            echo "Run './scripts/cleanup-orphaned-workflows.sh --disable' after merge to clean up."
            ;;
        list)
            if [[ "$JSON_OUTPUT" == "true" ]]; then
                jq -n \
                    --argjson orphaned "$(printf '%s\n' "${orphaned_workflows[@]}" | jq -s '.')" \
                    --argjson active "$(printf '%s\n' "${active_workflows[@]}" | jq -s '.')" \
                    --argjson template "$(printf '%s\n' "${template_workflows[@]}" | jq -s '.')" \
                    '{
                        summary: {
                            orphaned: ($orphaned | length),
                            active: ($active | length),
                            template: ($template | length)
                        },
                        orphaned: $orphaned,
                        active: $active,
                        template: $template
                    }'
            else
                echo -e "${BLUE}=== GitHub Actions Workflow Status ===${NC}"
                echo ""
                echo -e "${RED}Orphaned Workflows (${#orphaned_workflows[@]}):${NC}"
                if [[ ${#orphaned_workflows[@]} -eq 0 ]]; then
                    echo "  (none)"
                else
                    for wf in "${orphaned_workflows[@]}"; do
                        local name=$(echo "$wf" | jq -r '.name')
                        local path=$(echo "$wf" | jq -r '.path')
                        local state=$(echo "$wf" | jq -r '.state')
                        echo -e "  ${RED}*${NC} $name"
                        echo "    Path: $path"
                        echo "    State: $state"
                    done
                fi
                echo ""
                echo -e "${GREEN}Active Workflows (${#active_workflows[@]}):${NC}"
                if [[ ${#active_workflows[@]} -eq 0 ]]; then
                    echo "  (none)"
                else
                    for wf in "${active_workflows[@]}"; do
                        local name=$(echo "$wf" | jq -r '.name')
                        local path=$(echo "$wf" | jq -r '.path')
                        echo -e "  ${GREEN}*${NC} $name"
                        echo "    Path: $path"
                    done
                fi
                echo ""
                echo -e "${BLUE}Template Workflows (${#template_workflows[@]}):${NC}"
                echo "  (skipped - these are from repo-template/)"
            fi
            ;;
        disable)
            if [[ ${#orphaned_workflows[@]} -eq 0 ]]; then
                echo -e "${GREEN}No orphaned workflows to disable${NC}"
                exit 0
            fi

            echo -e "${BLUE}=== Disabling Orphaned Workflows ===${NC}"
            if [[ "$DRY_RUN" == "true" ]]; then
                echo -e "${YELLOW}(Dry run mode - no changes will be made)${NC}"
            fi
            echo ""

            local success_count=0
            local fail_count=0

            for wf in "${orphaned_workflows[@]}"; do
                local id=$(echo "$wf" | jq -r '.id')
                local name=$(echo "$wf" | jq -r '.name')
                local state=$(echo "$wf" | jq -r '.state')

                # Skip already disabled workflows
                if [[ "$state" == "disabled_manually" ]]; then
                    echo -e "${YELLOW}Already disabled:${NC} $name"
                    continue
                fi

                if disable_workflow "$id" "$name"; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
            done

            echo ""
            if [[ "$DRY_RUN" == "true" ]]; then
                echo -e "${BLUE}Summary:${NC} Would disable $success_count workflows"
            else
                echo -e "${BLUE}Summary:${NC} Disabled $success_count workflows, $fail_count failed"
            fi
            ;;
    esac
}

main
