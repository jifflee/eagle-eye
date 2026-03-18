# scripts/lib/

Shared library scripts sourced by other scripts in this repository. These are **not** run directly — they are `source`d to provide reusable functions.

## Usage Pattern

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
```

## Libraries

### common.sh
Core utilities: logging (`log_info`, `log_warn`, `log_error`, `log_success`), error handling (`die`, `die_with_code`), and dependency checks (`require_command`, `require_file`).

Used by: nearly all scripts.

### config.sh
Project configuration management for `.claude/project-config.json`. Functions: `get_project_config`, `get_config_value`, `set_config_value`, `set_config_values`, `validate_github_repo`, `validate_boolean`.

Used by: `init-deployment-config.sh`, gate scripts, validation scripts.

### structured-logging.sh
Structured JSON log output for machine-readable audit trails. Writes to `logs/` in a consistent schema compatible with `scripts/metrics-query.sh` and `scripts/compliance-query.sh`.

Used by: container scripts, PR lifecycle scripts, orchestrator scripts.

### api-rate-limit.sh
GitHub API rate limit monitoring and throttling. Functions: `check_rate_limit`, `wait_for_rate_limit`, `gh_api_safe`.

Environment variables:
- `RATE_LIMIT_WARN_THRESHOLD` (default: `0.8`) — warn at 80% usage
- `RATE_LIMIT_BLOCK_THRESHOLD` (default: `0.95`) — block at 95% usage
- `RATE_LIMIT_CACHE_TTL` (default: `60`) — cache TTL in seconds

Used by: bulk PR/issue scripts, sprint orchestrator.

### gate-common.sh
Shared logic for promotion gates (dev→qa, qa→main). Provides standard pass/fail output, gate result formatting, and common pre-flight checks.

Used by: `pr-validation-gate.sh`, `pre-promote-main-gate.sh`, `pre-promote-qa-gate.sh`, `qa-gate.sh`.

### changelog-cache.sh
Caching layer for PR metadata and changelogs during promotion pipelines. Reduces redundant API calls by capturing data at dev→qa and reusing it at qa→main.

Used by: `auto-promote-to-qa.sh`, `milestone-complete-promotion.sh`.

### cleanup-tracking.sh
Tracks auto-cleanup intent for PRs using local JSON storage. Records which PRs should be automatically cleaned up after merge.

Used by: `auto-cleanup-merged.sh`, `worktree-cleanup.sh`.

### corporate-enforcement.sh
Feature #686: Corporate mode enforcement library. Provides functions to check and enforce corporate mode restrictions. Philosophy: deny by default; minimal surface; skills can extend.

Used by: `validate-corporate-mode.sh`, permission-tier scripts.

### doc-parser.sh
Documentation parsing utilities for extracting structured metadata from Markdown files (frontmatter, sections, skill contracts).

Used by: `scan-docs.sh`, validation scripts, `audit-regression.sh`.

### script-analyzer.sh
Analysis functions for scripts: extract metadata, find usage patterns, detect similarity between scripts.

Used by: `scripts/ci/validators/` audit runners, `audit-regression.sh`.

### net-gateway.sh
Central egress control for all outbound network calls. Routes network traffic through approval and audit mechanisms.

Configuration:
- `GATEWAY_LOG` (default: `logs/network-audit.log`)
- `NETWORK_MANIFESTS_DIR` (default: `scripts/network-manifests`)
- `APPROVED_HOSTS_CONFIG` (default: `.config/approved-hosts.json`)

Used by: any script making external HTTP calls in corporate mode.

### watchdog-heartbeat.sh
Helper functions for updating the watchdog heartbeat from long-running scripts. Functions: `watchdog_heartbeat <message>`, `watchdog_phase <phase>`.

Used by: `claude-watchdog.sh`, container lifecycle scripts.

## Adding a New Library

1. Name it `<purpose>.sh` (lowercase, hyphen-separated)
2. Add `set -euo pipefail` and a header comment block
3. Document all exported functions with usage examples
4. Source `common.sh` if you need logging
5. Add an entry to this README
