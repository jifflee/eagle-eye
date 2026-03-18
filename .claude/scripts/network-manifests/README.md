# Network Manifests

This directory contains network manifests for scripts and skills that make outbound network calls.

## Purpose

Network manifests provide transparency and auditability by declaring:
- What external hosts each script contacts
- Why the connection is needed
- Whether the connection is required for operation

## Manifest Format

Each manifest is a JSON file named after the script (e.g., `sprint-orchestrator.json` for `sprint-orchestrator.sh`):

```json
{
  "script": "sprint-orchestrator.sh",
  "description": "Brief description of what the script does",
  "network_calls": [
    {
      "host": "api.github.com",
      "purpose": "Issue and PR management via GitHub API",
      "required": true
    },
    {
      "host": "api.anthropic.com",
      "purpose": "LLM API calls for AI-assisted operations",
      "required": true
    }
  ]
}
```

## Fields

- `script`: Name of the script file
- `description`: Brief description of script purpose
- `network_calls`: Array of network call declarations
  - `host`: Target hostname (e.g., "api.github.com")
  - `purpose`: Why this connection is needed
  - `required`: Boolean indicating if script can function without this connection

## Usage

The `--network-audit` flag uses these manifests to preview network activity:

```bash
./scripts/sprint/sprint-orchestrator.sh --network-audit
```

This displays all planned network calls and their approval status before execution.

## Creating Manifests

When creating a new script that makes network calls:

1. Create a JSON manifest in this directory
2. Name it matching your script (script.sh → script.json)
3. Declare all network hosts the script will contact
4. Document the purpose of each connection
5. Mark required vs optional connections

## Validation

Use the lint script to ensure all network-capable scripts have manifests:

```bash
./scripts/lint-network-calls.sh
```

This will detect any unwrapped direct network calls in the codebase.
