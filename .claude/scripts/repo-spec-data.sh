#!/usr/bin/env bash
# repo-spec-data.sh
# Tier: T0 (read-only)
# Description: Generate comprehensive technical specification of the claude-agents repository

set -euo pipefail

# Get repository root
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
cd "$REPO_ROOT"

# Output file (default to stdout)
OUTPUT_FILE="${1:-/dev/stdout}"

# Helper function to safely read file content
read_file_safe() {
    local file="$1"
    local max_lines="${2:-50}"
    if [[ -f "$file" ]]; then
        head -n "$max_lines" "$file" | jq -Rs . 2>/dev/null || echo '""'
    else
        echo '""'
    fi
}

# Helper function to count items
count_items() {
    local pattern="$1"
    find . -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

# Start JSON output
exec 3>&1 1>"$OUTPUT_FILE"

cat <<'EOF_START'
{
  "metadata": {
EOF_START

# Repository metadata
cat <<EOF_META
    "name": "claude-agents",
    "description": "Multi-agent orchestration framework for Claude Code",
    "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "git_branch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")",
    "git_commit": "$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  },
  "architecture": {
    "overview": "PM-centric multi-agent orchestration framework with specialized agents for each SDLC phase",
    "core_principles": [
      "PM Orchestrator coordinates all work - users interact with PM, not specialist agents directly",
      "Specialized agents for each role (design, implementation, review, governance)",
      "Container-based isolation for parallel execution",
      "Haiku-first model selection (90%+ tasks) for cost optimization",
      "Micro-task pattern - break work into smallest executable units",
      "Defense-in-depth with multiple review stages"
    ],
    "agent_orchestration": {
      "model": "hub-and-spoke",
      "coordinator": "pm-orchestrator",
      "delegation_pattern": "PM receives user requests → analyzes requirements → delegates to specialist agents → aggregates results",
      "communication": "agents communicate through PM, not peer-to-peer",
      "escalation": "unclear requirements → PM, architecture decisions → architect, security concerns → security agents"
    },
    "agent_count": $(find core/agents -name "*.md" 2>/dev/null | wc -l | tr -d ' '),
    "skill_count": $(find core/skills -name "SKILL.md" 2>/dev/null | wc -l | tr -d ' '),
    "script_count": $(find scripts -name "*.sh" 2>/dev/null | wc -l | tr -d ' ')
  },
  "sdlc": {
    "overview": "Five-phase SDLC with mandatory gates and agent handoffs",
    "phases": [
      {
        "name": "Phase 1: Planning & Design",
        "sequence": ["pm-orchestrator", "product-spec-ux", "architect", "security-iam-design", "data-storage"],
        "gates": ["spec complete", "architecture approved", "security reviewed", "schema defined"],
        "outputs": ["requirements doc", "system design", "security requirements", "database schema"]
      },
      {
        "name": "Phase 2: Implementation",
        "sequence": ["backend-developer | frontend-developer", "code-reviewer", "bug-agent (as needed)"],
        "gates": ["code written", "code review passed"],
        "outputs": ["feature code", "unit tests", "code review feedback"]
      },
      {
        "name": "Phase 3: Pre-PR Quality",
        "sequence": ["test-qa", "security-iam-prepr", "documentation", "performance-engineering (optional)"],
        "gates": ["tests written", "security check passed", "docs updated"],
        "outputs": ["test suite", "security report", "documentation updates"]
      },
      {
        "name": "Phase 4: PR Review",
        "sequence": ["pr-code-reviewer", "pr-security-iam", "pr-test", "pr-documentation", "cicd-workflow (if applicable)"],
        "gates": ["code review passed", "security passed", "tests passed", "docs passed", "CI/CD passed"],
        "outputs": ["code review findings", "security audit", "test validation", "docs validation"]
      },
      {
        "name": "Phase 5: Governance & Merge",
        "sequence": ["guardrails-policy", "repo-workflow", "deployment (optional)"],
        "gates": ["standards check passed", "all approvals received"],
        "outputs": ["merge approval", "issue closure", "deployment plan"]
      }
    ],
    "branching_strategy": {
      "model": "dev → qa → main",
      "dev": "Integration branch for all feature work",
      "qa": "QA validation and testing branch",
      "main": "Production-ready code only",
      "feature_branches": "feat/issue-N created from dev",
      "promotion": "dev → qa (via /pr-to-qa), qa → main (via /pr-to-main)"
    },
    "workflow_patterns": {
      "standard_issue": "checkout issue → create feature branch → implement → test → PR → review → merge → close issue",
      "epic_mode": "decompose epic → create child issues → parallel containers → aggregate results",
      "hotfix": "emergency branch from main → fix → fast-track review → merge to main+qa+dev"
    }
  },
  "agents": {
EOF_META

# List all agents
echo '    "catalog": ['
first=true
for agent_file in core/agents/*.md core/agents/decision-framework/*.md; do
    if [[ -f "$agent_file" ]]; then
        agent_name=$(basename "$agent_file" .md)
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        # Extract description from file (first line after title)
        description=$(grep -A1 "^# " "$agent_file" 2>/dev/null | tail -1 | sed 's/^[*#[:space:]]*//' || echo "")
        cat <<EOF_AGENT
      {
        "name": "$agent_name",
        "file": "$agent_file",
        "description": $(echo "$description" | jq -Rs .)
      }
EOF_AGENT
    fi
done
echo '    ]'

cat <<'EOF_AGENTS'
  },
  "skills": {
    "overview": "Skills are slash commands that Claude can invoke automatically based on user intent",
    "dispatch_pattern": "User request → Claude matches intent to skill → Skill invoked with permissions → Script executes → Results returned",
    "permission_model": "Skills declare required permission tier (T0-T3) and scripts in manifest",
EOF_AGENTS

echo '    "catalog": ['
first=true
for skill_file in core/skills/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_dir=$(dirname "$skill_file")
        skill_name=$(basename "$skill_dir")
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        # Extract name and description from YAML frontmatter
        name=$(grep "^name:" "$skill_file" 2>/dev/null | sed 's/^name:[[:space:]]*//' || echo "$skill_name")
        description=$(grep "^description:" "$skill_file" 2>/dev/null | sed 's/^description:[[:space:]]*//' || echo "")
        max_tier=$(grep "max_tier:" "$skill_file" 2>/dev/null | sed 's/^[[:space:]]*max_tier:[[:space:]]*//' || echo "T0")
        cat <<EOF_SKILL
      {
        "name": $(echo "$name" | jq -Rs .),
        "description": $(echo "$description" | jq -Rs .),
        "max_tier": $(echo "$max_tier" | jq -Rs .),
        "manifest": "$skill_file"
      }
EOF_SKILL
    fi
done
echo '    ]'
echo '  },'

# Count n8n workflows
n8n_workflow_count=$(find n8n-workflows -name "*.json" 2>/dev/null | wc -l | tr -d " ")

# Hooks system
cat <<EOF_HOOKS
  "hooks": {
    "git_hooks": {
      "pre_commit": {
        "purpose": "Enforce code quality and security standards before commit",
        "checks": ["large files (>500 lines)", "secrets/credentials", "script sizes", "naming conventions", ".env staging", "shellcheck"],
        "action": "Block commit on errors, warn on warnings",
        "implementation": ".husky/pre-commit or .git/hooks/pre-commit"
      },
      "post_commit": {
        "purpose": "Metrics collection after successful commit",
        "implementation": ".git/hooks/post-commit"
      }
    },
    "claude_hooks": {
      "UserPromptSubmit": {
        "purpose": "Execute logic when user submits a prompt to Claude",
        "use_cases": ["validation", "context injection", "permission checking"]
      },
      "PostToolUse": {
        "purpose": "Execute logic after Claude uses a tool",
        "use_cases": ["audit logging", "metrics collection", "side effects"]
      }
    },
    "n8n_webhooks": {
      "purpose": "Automated workflows triggered by GitHub events",
      "workflows": ["container queue management", "PR automation", "issue triage", "deployment automation"],
      "count": $n8n_workflow_count
    }
  },
  "infrastructure": {
    "containers": {
      "overview": "Docker containers for isolated, parallel agent execution",
      "dockerfile": "docker/Dockerfile.sprint-worker",
      "roles": ["orchestrator (read-only)", "implementation (write-full)", "code_review (read-only)", "documentation (write-docs)", "security_review (read-only)"],
      "lifecycle": "validate tokens → generate sprint state → launch container → clone repo → create feature branch → work → push → create PR → exit",
      "orchestration": "Sequential queue prevents merge conflicts, parallel execution for independent work"
    },
    "worktrees": {
      "overview": "Git worktrees for local iterative development",
      "pattern": "Main repo + separate worktree per issue",
      "use_case": "Quick fixes, interactive debugging, local development without Docker",
      "isolation": "Filesystem-level isolation, shared git history"
    },
    "execution_modes": {
      "docker": "Container-based (reproducible, team consistency)",
      "worktree": "Git worktrees (fast, no Docker required)",
      "n8n": "Webhook automation (complex workflows)",
      "hybrid": "Auto-detect best available mode"
    }
  },
  "scripts": {
    "overview": "271 shell scripts organized by function and permission tier",
    "categories": {
EOF_HOOKS

# Count scripts by category
ci_count=$( (ls scripts/ci/*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
container_count=$( (ls scripts/container-*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
audit_count=$( (ls scripts/audit*.sh scripts/audit/*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
data_count=$( (ls scripts/*-data.sh 2>/dev/null || true) | wc -l | tr -d ' ')
composition_count=$( (ls scripts/composition/*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
dev_count=$( (ls scripts/dev/*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
lib_count=$( (ls scripts/lib/*.sh 2>/dev/null || true) | wc -l | tr -d ' ')
doc_count=$(find docs -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

echo "      \"ci\": $ci_count,"
echo "      \"container\": $container_count,"
echo "      \"audit\": $audit_count,"
echo "      \"data\": $data_count,"
echo "      \"composition\": $composition_count,"
echo "      \"dev\": $dev_count,"
echo "      \"lib\": $lib_count"

cat <<EOF_SCRIPTS
    },
    "permission_tiers": {
      "T0": "Read-only operations, no state change (auto-allowed)",
      "T1": "Safe writes, trivially reversible (auto-allowed)",
      "T2": "Reversible writes requiring effort (session-once prompt)",
      "T3": "Destructive or irreversible operations (always prompt)"
    },
    "naming_conventions": {
      "data_scripts": "*-data.sh - Read-only data gathering scripts",
      "action_scripts": "action-*.sh - State-changing operations",
      "check_scripts": "check-*.sh - Validation and health checks",
      "container_scripts": "container-*.sh - Container lifecycle management"
    }
  },
  "configuration": {
    "claude_md": {
      "overview": "Defense-in-depth configuration with multiple layers",
      "layers": [
        {
          "level": "global",
          "file": "core/CLAUDE.md",
          "scope": "All projects, security gatekeeper",
          "purpose": "NEVER rules - secrets, credentials, force push"
        },
        {
          "level": "repository",
          "file": "claude.md",
          "scope": "This repository",
          "purpose": "Agent definitions, SDLC workflow, routing rules"
        },
        {
          "level": "domain",
          "file": "domains/{domain}/CLAUDE.md",
          "scope": "Domain-specific",
          "purpose": "Domain rules and constraints (optional)"
        }
      ],
      "load_order": "global → repository → domain"
    },
    "manifests": {
      "agent_manifests": {
        "location": "core/agents/*.md",
        "format": "Markdown with YAML frontmatter",
        "contents": "Agent name, role, capabilities, model preference, tools"
      },
      "skill_manifests": {
        "location": "core/skills/*/SKILL.md",
        "format": "Markdown with YAML frontmatter",
        "contents": "Skill name, description, permissions, scripts"
      }
    },
    "sprint_state": {
      "file": ".sprint-state.json",
      "purpose": "Track active milestone, issues in progress, container state",
      "updated_by": "sprint-work, container-launch, issue-checkout",
      "schema": "milestone, issues[], containers[], worktrees[]"
    }
  },
  "strategy": {
    "model_selection": {
      "default": "haiku",
      "rationale": "90%+ of tasks can be completed by Haiku at 1/10th the cost",
      "haiku_use_cases": ["data gathering", "simple transformations", "read-only analysis", "standard CRUD"],
      "sonnet_use_cases": ["complex reasoning", "architecture decisions", "security reviews", "multi-step planning"],
      "opus_use_cases": ["critical decisions", "complex refactoring", "novel problems"]
    },
    "optimization_patterns": {
      "micro_tasks": "Break work into smallest executable units for parallelization",
      "parallel_execution": "Run independent containers simultaneously",
      "token_efficiency": "Structured output (JSON), concise prompts, context pruning",
      "caching": "Reuse data scripts output, cache API responses (15min)",
      "progressive_disclosure": "Start with minimal detail, drill down only when needed"
    },
    "review_stages": {
      "count": 4,
      "stages": ["code review (pre-PR)", "code review (PR)", "security review (pre-PR)", "security review (PR)", "test validation (pre-PR)", "test validation (PR)", "documentation review (pre-PR)", "documentation review (PR)"],
      "rationale": "Defense-in-depth prevents issues from reaching production"
    }
  },
  "integrations": {
    "github": {
      "cli": "gh CLI for all GitHub operations (issues, PRs, releases)",
      "api": "GitHub REST API via gh api for advanced operations",
      "webhooks": "n8n workflows triggered by GitHub events"
    },
    "n8n": {
      "purpose": "Workflow automation and orchestration",
      "workflows": "Sequential container queue, PR automation, issue triage",
      "mcp_integration": "n8n MCP server for workflow management from Claude"
    },
    "mcp_servers": {
      "n8n": "n8n workflow manager - create, validate, deploy n8n workflows",
      "context7": "Context7 API for enhanced context management (optional)"
    },
    "docker": {
      "registry": "Local builds, no external registry",
      "image": "claude-dev-env:latest",
      "base": "Ubuntu with Claude Code, git, gh CLI, node, python"
    }
  },
  "documentation": {
    "primary": "claude.md - Complete agent definitions and SDLC workflow",
    "architecture": "docs/MULTI_CONTAINER_ARCHITECTURE.md, docs/CONTAINERIZED_WORKFLOW.md",
    "workflows": "WORKFLOW.md, docs/PR_REVIEW_WORKFLOW.md, docs/BATCH_BRANCH_WORKFLOW.md",
    "guides": "CONTRIBUTING.md, docs/QUICKSTART.md, docs/DEPLOYMENT_GUIDE.md",
    "skills": "skills/README-*.md for each skill",
    "total_docs": $doc_count
  }
}
EOF_SCRIPTS

# Restore stdout
exec 1>&3 3>&-

# If output was to a file, print success message
if [[ "$OUTPUT_FILE" != "/dev/stdout" ]]; then
    echo "Technical specification generated: $OUTPUT_FILE" >&2
fi
