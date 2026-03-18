# Scripts Directory

This directory contains all automation scripts for the project.

## Quick Start

### Initial Setup

Run the deployment configuration setup:

```bash
./scripts/init-deployment-config.sh
```

This will guide you through configuring:
- Corporate vs flexible mode
- GitHub repository for issue/PR management
- Framework feedback repository

See [docs/deployment-config.md](../docs/deployment-config.md) for detailed documentation.

## Directory Structure

```
scripts/
├── lib/                    # Shared libraries (source-only, see lib/README.md)
│   ├── api-rate-limit.sh  # GitHub API rate limiting and throttling
│   ├── changelog-cache.sh # Changelog caching for promotion pipelines
│   ├── cleanup-tracking.sh# PR auto-cleanup tracking
│   ├── common.sh          # Core utilities (logging, validation, error handling)
│   ├── config.sh          # Project configuration reading/writing
│   ├── corporate-enforcement.sh # Corporate mode restriction enforcement
│   ├── doc-parser.sh      # Documentation/Markdown parsing
│   ├── gate-common.sh     # Shared logic for promotion gates
│   ├── net-gateway.sh     # Central egress control for network calls
│   ├── script-analyzer.sh # Script contract and similarity analysis
│   ├── structured-logging.sh # Structured JSON audit logging
│   └── watchdog-heartbeat.sh # Watchdog heartbeat helper functions
├── ci/                    # CI/CD scripts and validators
├── hooks/                 # Git hooks
├── dev/                   # Development utilities
├── permissions/           # Permission management (tier classification, policy)
├── pr-lifecycle/          # PR lifecycle automation
├── maintenance/           # DB fixture and maintenance scripts
├── security/              # Security scanning and auditing
├── audit/                 # Repository health and capability audits
├── composition/           # Skill composition and permission aggregation
├── graph/                 # Agent dependency graph generation
├── headless/              # Headless (background) automation scripts
├── network-manifests/     # Approved network call manifests (JSON)
└── archive/               # Completed one-time migration scripts (do not run)
```

## Script Conventions

### Script Header Template

All scripts should follow this template:

```bash
#!/usr/bin/env bash
# ============================================================
# Script: script-name.sh
# Purpose: Brief description of what the script does
# Usage: ./script-name.sh [arguments]
# Dependencies: List required tools (jq, gh, etc.)
# ============================================================

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Your script logic here
```

### Error Handling

- Use `set -euo pipefail` at the top of all scripts
- Use `die` or `die_with_code` for fatal errors
- Use `log_error` for non-fatal errors
- Always validate inputs and dependencies

### Testing

- Create corresponding test files in `scripts/ci/test-*.sh`
- Test both success and failure cases
- Validate error handling

## Key Scripts

### Deployment & Configuration

- `init-deployment-config.sh` - Initial deployment configuration setup
- `init-deployment.sh` - Deployment initialization (initializes `~/.claude-tastic/` dir)
- `init-repo.sh` / `onboard-existing-repo.sh` - Repository onboarding

### Issue & PR Management

- `issue-*.sh` - Issue lifecycle management
- `pr-*.sh` - PR lifecycle management
- `milestone-*.sh` - Milestone management
- `validate-milestone-name.sh` - Validate and generate milestone names following sprint-MMYY-N convention

### Container Management

- `container-launch.sh` - Full container launch with multi-mode support, error recovery, and security enforcement
- `container-*.sh` - Container lifecycle (health checks, metrics, cleanup, entrypoint, etc.)
- `cloud-container-launch.sh` - Cloud container deployment (GCP Cloud Run / GitHub Actions)
- `remote-container-launch.sh` - Remote container launch via external runner

### Orchestration & Scheduling

- `llm-orchestrator.sh` - Multi-LLM task orchestrator (Epic #263)
- `orchestrator-schedule.sh` - Install/manage automatic scheduling (Feature #752)
- `sprint-orchestrator.sh` - Autonomous sprint execution

### n8n Workflow Automation

- `n8n-*.sh` - n8n instance management (start/stop, health, import/export workflows, redundancy)
- `sync-n8n-workflows.sh` - Sync workflow definitions to/from n8n instance

### Canary Deployments

- `canary-health-check.sh` - Monitor canary deployment health and trigger rollback
- `canary-promote.sh` - Promote canary to full production
- `canary-rollback.sh` - Roll back a canary deployment
- `canary-status.sh` - Reporting dashboard for canary state

> **Note**: These scripts are functional but the corresponding workflow (`workflows-disabled/canary-deploy.yml`) is disabled.

### Worktree Management

- `worktree-*.sh` - Git worktree operations (create, archive, merge, cleanup, validate)
- `spawn-parallel-worktrees.sh` - Spawn multiple worktrees for parallel issue work

### CI/CD & Validation

- Scripts in `ci/` directory
- Validation and testing scripts
- `validate-loop.sh` - Autonomous validation loop for test-gated deployments (Feature #1016)
  - Enables Claude to self-validate and self-correct iteratively
  - See [docs/autonomous-validation-pattern.md](../docs/autonomous-validation-pattern.md) for usage guide

## Shared Libraries

See [lib/README.md](lib/README.md) for full documentation of all shared library scripts.

Quick reference:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"   # logging, error handling
source "$SCRIPT_DIR/lib/config.sh"   # project configuration
```

## Archive

`scripts/archive/` contains completed one-time migration scripts preserved for historical reference. **Do not run these** — they have already been applied. See [archive/README.md](archive/README.md) for details.

## Contributing

When adding new scripts:

1. Follow the script header template
2. Use shared libraries for common functionality
3. Add appropriate error handling
4. Create tests in `scripts/ci/`
5. Update this README if adding new categories
6. Ensure scripts are executable: `chmod +x script-name.sh`

## Configuration

Project configuration is stored in `.claude/project-config.json`. Use the config library functions to read/write configuration values. See [docs/deployment-config.md](../docs/deployment-config.md) for details.
