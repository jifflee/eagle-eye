#!/usr/bin/env bash
#
# discover-existing-repo.sh
# Phase 0: Discovery & Analysis for existing repo onboarding
# READ-ONLY - Never modifies files
#
# Usage:
#   ./scripts/discover-existing-repo.sh                 # Interactive discovery
#   ./scripts/discover-existing-repo.sh --json          # JSON output only
#   ./scripts/discover-existing-repo.sh --save FILE     # Save to file
#
# Output:
#   Generates .claude-tastic-discovery.json with:
#   - existing_assets: what's already present
#   - gaps: what the framework provides that's missing
#   - conflicts: files that need reconciliation
#
# Exit codes:
#   0 - Discovery complete (new or existing repo)
#   1 - Error during discovery

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Defaults
JSON_ONLY=false
OUTPUT_FILE=".claude-tastic-discovery.json"
VERBOSE=true

log_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[INFO]${NC} $*" >&2
    fi
}
log_success() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${GREEN}[OK]${NC} $*" >&2
    fi
}
log_warn() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}[WARN]${NC} $*" >&2
    fi
}
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            JSON_ONLY=true
            VERBOSE=false
            shift
            ;;
        --save)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'USAGE'
Usage: discover-existing-repo.sh [OPTIONS]

Discover existing repository assets and identify conflicts with framework.
This is Phase 0 of the existing repo onboarding flow (READ-ONLY).

Options:
  --json              Output JSON only (no log messages)
  --save FILE         Save discovery output to FILE (default: .claude-tastic-discovery.json)
  --help              Show this help

Examples:
  ./scripts/discover-existing-repo.sh
  ./scripts/discover-existing-repo.sh --json
  ./scripts/discover-existing-repo.sh --save /tmp/discovery.json
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Start discovery
if [ "$VERBOSE" = true ]; then
    echo ""
    echo "================================================"
    echo "  Existing Repo Discovery (READ-ONLY)"
    echo "================================================"
    echo ""
fi

log_info "Scanning repository for existing assets..."

# Initialize discovery data structure
EXISTING_REPO=false

# Detect existing code directories
HAS_SRC=false
HAS_LIB=false
HAS_APP=false
[ -d "src" ] && HAS_SRC=true && EXISTING_REPO=true
[ -d "lib" ] && HAS_LIB=true && EXISTING_REPO=true
[ -d "app" ] && HAS_APP=true && EXISTING_REPO=true

# Detect existing framework/config
HAS_CLAUDE_MD=false
HAS_AI_MD=false
HAS_CLAUDE_SETTINGS=false
HAS_CLAUDE_COMMANDS=false
HAS_CLAUDE_AGENTS=false

if [ -f "CLAUDE.md" ]; then
    HAS_CLAUDE_MD=true
    EXISTING_REPO=true
    CLAUDE_MD_LINES=$(wc -l < CLAUDE.md 2>/dev/null || echo 0)
else
    CLAUDE_MD_LINES=0
fi

[ -f "AI.md" ] && HAS_AI_MD=true
[ -f ".claude/settings.json" ] && HAS_CLAUDE_SETTINGS=true && EXISTING_REPO=true
[ -d ".claude/commands" ] && HAS_CLAUDE_COMMANDS=true && EXISTING_REPO=true
[ -d ".claude/agents" ] && HAS_CLAUDE_AGENTS=true && EXISTING_REPO=true

# Detect existing CI/CD
HAS_CI_SCRIPTS=false
HAS_HUSKY=false
HAS_GITHUB_WORKFLOWS=false
CI_SCRIPTS=()

if [ -d "scripts/ci" ]; then
    HAS_CI_SCRIPTS=true
    EXISTING_REPO=true
    # List CI scripts
    while IFS= read -r script; do
        CI_SCRIPTS+=("$(basename "$script")")
    done < <(find scripts/ci -name "*.sh" -type f 2>/dev/null || true)
fi

[ -d ".husky" ] && HAS_HUSKY=true && EXISTING_REPO=true
[ -d ".github/workflows" ] && HAS_GITHUB_WORKFLOWS=true && EXISTING_REPO=true

# Detect git hooks
GIT_HOOKS=()
if [ -d ".git/hooks" ]; then
    while IFS= read -r hook; do
        hookname=$(basename "$hook")
        # Skip sample hooks
        if [[ ! "$hookname" =~ \.sample$ ]]; then
            GIT_HOOKS+=("$hookname")
        fi
    done < <(find .git/hooks -type f 2>/dev/null || true)
fi

# Add husky hooks if present
if [ "$HAS_HUSKY" = true ] && [ -d ".husky" ]; then
    while IFS= read -r hook; do
        hookname=$(basename "$hook")
        # Skip husky internal files
        if [[ "$hookname" != "_" ]] && [[ "$hookname" != ".gitignore" ]]; then
            GIT_HOOKS+=("$hookname (husky)")
        fi
    done < <(find .husky -type f ! -name "_" ! -name ".gitignore" 2>/dev/null || true)
fi

# Detect existing tests
HAS_TESTS=false
TEST_DIRS=()
TEST_FRAMEWORK=""

if [ -d "tests" ] || [ -d "test" ] || [ -d "__tests__" ]; then
    HAS_TESTS=true
    EXISTING_REPO=true
    [ -d "tests" ] && TEST_DIRS+=("tests")
    [ -d "test" ] && TEST_DIRS+=("test")
    [ -d "__tests__" ] && TEST_DIRS+=("__tests__")

    # Detect test framework
    if [ -f "package.json" ]; then
        if grep -q '"jest"' package.json 2>/dev/null; then
            TEST_FRAMEWORK="jest"
        elif grep -q '"mocha"' package.json 2>/dev/null; then
            TEST_FRAMEWORK="mocha"
        elif grep -q '"vitest"' package.json 2>/dev/null; then
            TEST_FRAMEWORK="vitest"
        fi
    elif [ -f "pytest.ini" ] || grep -q "pytest" requirements*.txt 2>/dev/null; then
        TEST_FRAMEWORK="pytest"
    fi
fi

# Detect languages
LANGUAGES=()
[ -f "package.json" ] && LANGUAGES+=("javascript/typescript")
[ -f "requirements.txt" ] || [ -f "pyproject.toml" ] && LANGUAGES+=("python")
[ -f "Cargo.toml" ] && LANGUAGES+=("rust")
[ -f "go.mod" ] && LANGUAGES+=("go")
[ -f "Gemfile" ] && LANGUAGES+=("ruby")
[ -f "pom.xml" ] || [ -f "build.gradle" ] && LANGUAGES+=("java")

# Detect package manager
PACKAGE_MANAGER=""
if [ -f "package.json" ]; then
    if [ -f "package-lock.json" ]; then
        PACKAGE_MANAGER="npm"
    elif [ -f "yarn.lock" ]; then
        PACKAGE_MANAGER="yarn"
    elif [ -f "pnpm-lock.yaml" ]; then
        PACKAGE_MANAGER="pnpm"
    else
        PACKAGE_MANAGER="npm"
    fi
elif [ -f "requirements.txt" ]; then
    PACKAGE_MANAGER="pip"
elif [ -f "Cargo.toml" ]; then
    PACKAGE_MANAGER="cargo"
elif [ -f "go.mod" ]; then
    PACKAGE_MANAGER="go"
fi

# Detect branch strategy
BRANCHES=$(git branch -r 2>/dev/null | grep -v '\->' | sed 's/origin\///' | tr -d ' ' || echo "")
HAS_DEV_BRANCH=false
HAS_QA_BRANCH=false
HAS_MAIN_BRANCH=false

echo "$BRANCHES" | grep -q "^dev$" && HAS_DEV_BRANCH=true
echo "$BRANCHES" | grep -q "^qa$" && HAS_QA_BRANCH=true
echo "$BRANCHES" | grep -q "^main$" && HAS_MAIN_BRANCH=true
echo "$BRANCHES" | grep -q "^master$" && HAS_MAIN_BRANCH=true

if [ "$HAS_DEV_BRANCH" = true ] && [ "$HAS_QA_BRANCH" = true ] && [ "$HAS_MAIN_BRANCH" = true ]; then
    BRANCH_STRATEGY="dev-qa-main"
elif [ "$HAS_DEV_BRANCH" = true ] && [ "$HAS_MAIN_BRANCH" = true ]; then
    BRANCH_STRATEGY="dev-main"
else
    BRANCH_STRATEGY="main-only"
fi

# Identify gaps (what framework provides that's missing)
MISSING_AGENTS=false
MISSING_SDLC_WORKFLOW=false
MISSING_SECURITY_HOOKS=false
MISSING_PR_GATES=false

[ "$HAS_CLAUDE_AGENTS" = false ] && MISSING_AGENTS=true
[ "$HAS_CI_SCRIPTS" = false ] && MISSING_SDLC_WORKFLOW=true

# Check for security hooks
HAS_SECURITY_HOOK=false
for hook in "${GIT_HOOKS[@]}"; do
    if [[ "$hook" =~ pre-commit ]] || [[ "$hook" =~ pre-push ]]; then
        HAS_SECURITY_HOOK=true
        break
    fi
done
[ "$HAS_SECURITY_HOOK" = false ] && MISSING_SECURITY_HOOKS=true

# Check for PR validation gates
HAS_PR_GATES=false
if [ "$HAS_CI_SCRIPTS" = true ]; then
    for script in "${CI_SCRIPTS[@]}"; do
        if [[ "$script" =~ pr-validation ]] || [[ "$script" =~ check- ]]; then
            HAS_PR_GATES=true
            break
        fi
    done
fi
[ "$HAS_PR_GATES" = false ] && MISSING_PR_GATES=true

# Identify conflicts (files that need reconciliation)
CONFLICTS=()
if [ "$HAS_CLAUDE_MD" = true ]; then
    CONFLICTS+=("claude_md:exists — needs merge")
fi

if [ ${#GIT_HOOKS[@]} -gt 0 ]; then
    CONFLICTS+=("git_hooks:exists — needs merge")
fi

if [ "$HAS_CLAUDE_SETTINGS" = true ]; then
    CONFLICTS+=("claude_settings:exists — needs review")
fi

# Count test files
TEST_FILE_COUNT=0
if [ "$HAS_TESTS" = true ]; then
    for dir in "${TEST_DIRS[@]}"; do
        count=$(find "$dir" -type f \( -name "*.test.*" -o -name "*.spec.*" -o -name "test_*.py" \) 2>/dev/null | wc -l || echo 0)
        TEST_FILE_COUNT=$((TEST_FILE_COUNT + count))
    done
fi

# Build JSON output
log_info "Building discovery report..."

# Create JSON with proper escaping
cat > "$OUTPUT_FILE" <<EOF
{
  "discovery_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "is_existing_repo": $EXISTING_REPO,
  "existing_assets": {
    "code_directories": {
      "src": $HAS_SRC,
      "lib": $HAS_LIB,
      "app": $HAS_APP
    },
    "claude_md": $HAS_CLAUDE_MD,
    "claude_md_lines": $CLAUDE_MD_LINES,
    "ai_md": $HAS_AI_MD,
    "claude_settings": $HAS_CLAUDE_SETTINGS,
    "claude_commands": $HAS_CLAUDE_COMMANDS,
    "claude_agents": $HAS_CLAUDE_AGENTS,
    "hooks": $(printf '%s\n' "${GIT_HOOKS[@]}" | jq -R . | jq -s . || echo '[]'),
    "ci_scripts": $(printf '%s\n' "${CI_SCRIPTS[@]}" | jq -R . | jq -s . || echo '[]'),
    "has_ci_directory": $HAS_CI_SCRIPTS,
    "has_husky": $HAS_HUSKY,
    "has_github_workflows": $HAS_GITHUB_WORKFLOWS,
    "test_framework": $(echo "$TEST_FRAMEWORK" | jq -R .),
    "test_directories": $(printf '%s\n' "${TEST_DIRS[@]}" | jq -R . | jq -s . || echo '[]'),
    "test_file_count": $TEST_FILE_COUNT,
    "languages": $(printf '%s\n' "${LANGUAGES[@]}" | jq -R . | jq -s . || echo '[]'),
    "package_manager": $(echo "$PACKAGE_MANAGER" | jq -R .),
    "branch_strategy": "$BRANCH_STRATEGY"
  },
  "gaps": {
    "missing_agents": $MISSING_AGENTS,
    "missing_sdlc_workflow": $MISSING_SDLC_WORKFLOW,
    "missing_security_hooks": $MISSING_SECURITY_HOOKS,
    "missing_pr_gates": $MISSING_PR_GATES
  },
  "conflicts": $(printf '%s\n' "${CONFLICTS[@]}" | jq -R . | jq -s . || echo '[]')
}
EOF

log_success "Discovery saved to: $OUTPUT_FILE"

# Display summary if not JSON-only mode
if [ "$VERBOSE" = true ]; then
    echo ""
    echo "================================================"
    echo "  Discovery Summary"
    echo "================================================"
    echo ""

    if [ "$EXISTING_REPO" = true ]; then
        echo -e "${YELLOW}This appears to be an EXISTING repository${NC}"
        echo ""
        echo "Existing assets found:"

        # Code directories
        if [ "$HAS_SRC" = true ] || [ "$HAS_LIB" = true ] || [ "$HAS_APP" = true ]; then
            echo "  Code directories:"
            [ "$HAS_SRC" = true ] && echo "    - src/"
            [ "$HAS_LIB" = true ] && echo "    - lib/"
            [ "$HAS_APP" = true ] && echo "    - app/"
        fi

        # Framework files
        if [ "$HAS_CLAUDE_MD" = true ]; then
            echo "  CLAUDE.md ($CLAUDE_MD_LINES lines) — ${YELLOW}needs reconciliation${NC}"
        fi
        [ "$HAS_CLAUDE_SETTINGS" = true ] && echo "  .claude/settings.json — ${YELLOW}needs review${NC}"
        [ "$HAS_CLAUDE_COMMANDS" = true ] && echo "  .claude/commands/ — existing commands"
        [ "$HAS_CLAUDE_AGENTS" = true ] && echo "  .claude/agents/ — existing agents"

        # Git hooks
        if [ ${#GIT_HOOKS[@]} -gt 0 ]; then
            echo "  Git hooks: ${GIT_HOOKS[*]} — ${YELLOW}needs merge${NC}"
        fi

        # CI/CD
        if [ "$HAS_CI_SCRIPTS" = true ]; then
            echo "  scripts/ci/ (${#CI_SCRIPTS[@]} scripts)"
        fi
        [ "$HAS_HUSKY" = true ] && echo "  .husky/ — existing git hooks"
        [ "$HAS_GITHUB_WORKFLOWS" = true ] && echo "  .github/workflows/ — existing workflows"

        # Tests
        if [ "$HAS_TESTS" = true ]; then
            echo "  tests/ ($TEST_FILE_COUNT test files, $TEST_FRAMEWORK framework)"
        fi

        # Languages
        if [ ${#LANGUAGES[@]} -gt 0 ]; then
            echo "  Languages: ${LANGUAGES[*]}"
        fi

        echo ""
        echo "Gaps (what framework will add):"
        [ "$MISSING_AGENTS" = true ] && echo "  + Agent definitions"
        [ "$MISSING_SDLC_WORKFLOW" = true ] && echo "  + SDLC workflow scripts"
        [ "$MISSING_SECURITY_HOOKS" = true ] && echo "  + Security hooks"
        [ "$MISSING_PR_GATES" = true ] && echo "  + PR validation gates"

        if [ ${#CONFLICTS[@]} -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}Conflicts to resolve:${NC}"
            for conflict in "${CONFLICTS[@]}"; do
                echo "  ! $conflict"
            done
        fi
    else
        echo -e "${GREEN}This appears to be a NEW repository${NC}"
        echo ""
        echo "No existing framework assets detected."
        echo "Installation will proceed with default setup."
    fi

    echo ""
    echo "================================================"
    echo ""
    echo "Next steps:"
    echo "  1. Review discovery: cat $OUTPUT_FILE"
    echo "  2. Run onboarding: ./scripts/onboard-existing-repo.sh"
    echo ""
fi

# Output JSON if requested
if [ "$JSON_ONLY" = true ]; then
    cat "$OUTPUT_FILE"
fi

exit 0
