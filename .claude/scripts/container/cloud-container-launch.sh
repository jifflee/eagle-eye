#!/bin/bash
set -euo pipefail
# cloud-container-launch.sh
# Cloud container launcher for Claude agent sessions
# Supports GCP Cloud Run and GitHub Actions runners
# SECURITY: Tokens passed via secrets manager, not environment inspection
# size-ok: multi-cloud provider abstraction with GCP and GitHub Actions support

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="cloud-container-launch.sh"
VERSION="1.0.0"
DEFAULT_IMAGE="claude-dev-env:latest"

# Cloud defaults
DEFAULT_REGION="us-central1"
DEFAULT_PROJECT_ID=""  # Must be set or detected
DEFAULT_MEMORY="2Gi"
DEFAULT_CPU="2"
DEFAULT_TIMEOUT="3600"  # 1 hour max

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Cloud container launcher for Claude agent sessions

USAGE:
    $SCRIPT_NAME --provider <provider> --issue <N> --repo <owner/repo> [OPTIONS]

PROVIDERS:
    gcp-cloudrun    Google Cloud Run (serverless containers)
    github-actions  GitHub Actions self-hosted runner

COMMANDS:
    --issue <N>           Launch container for issue number N
    --list                List running cloud jobs
    --stop <job-id>       Stop a running job
    --logs <job-id>       Stream logs from a job

OPTIONS:
    --provider <name>     Cloud provider (required)
    --repo <owner/repo>   Repository to clone (required with --issue)
    --branch <branch>     Branch to checkout (default: dev)
    --image <image>       Container image (default: $DEFAULT_IMAGE)
    --project <id>        GCP project ID (for gcp-cloudrun)
    --region <region>     GCP region (default: $DEFAULT_REGION)
    --memory <size>       Memory allocation (default: $DEFAULT_MEMORY)
    --cpu <count>         CPU allocation (default: $DEFAULT_CPU)
    --timeout <seconds>   Max execution time (default: $DEFAULT_TIMEOUT)
    --dry-run             Show what would be executed
    --debug               Enable debug logging

ENVIRONMENT VARIABLES (Secrets):
    GITHUB_TOKEN              GitHub authentication token (required)
    CLAUDE_CODE_OAUTH_TOKEN   Claude Code OAuth token
    GCP_SERVICE_ACCOUNT_KEY   GCP service account JSON (for gcp-cloudrun)

SECURITY:
    - Tokens are stored in GCP Secret Manager (not environment variables)
    - GitHub Actions uses repository secrets
    - No tokens visible in cloud console or logs

EXAMPLES:
    # Launch on GCP Cloud Run
    $SCRIPT_NAME --provider gcp-cloudrun --issue 107 --repo owner/repo --project my-project

    # Launch with custom resources
    $SCRIPT_NAME --provider gcp-cloudrun --issue 107 --repo owner/repo \\
        --memory 4Gi --cpu 4 --timeout 7200

    # Dry run to see what would be executed
    $SCRIPT_NAME --provider gcp-cloudrun --issue 107 --repo owner/repo --dry-run

    # List running jobs
    $SCRIPT_NAME --provider gcp-cloudrun --list --project my-project

COST ESTIMATION:
    GCP Cloud Run (per hour, us-central1):
    - 2 vCPU, 2GB RAM: ~\$0.14/hour
    - 4 vCPU, 4GB RAM: ~\$0.28/hour
    - First 180,000 vCPU-seconds/month free tier

    GitHub Actions:
    - Public repos: Free
    - Private repos: 2,000 minutes/month free, then \$0.008/min (Linux)

EOF
}

# Check GCP prerequisites
check_gcp_prereqs() {
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud CLI is not installed"
        log_error "Install: https://cloud.google.com/sdk/docs/install"
        return 1
    fi

    # Check authentication
    if ! gcloud auth print-identity-token &> /dev/null; then
        log_error "Not authenticated with GCP"
        log_error "Run: gcloud auth login"
        return 1
    fi

    log_debug "GCP prerequisites met"
    return 0
}

# Detect or validate GCP project
get_gcp_project() {
    local project="$1"

    if [ -n "$project" ]; then
        echo "$project"
        return 0
    fi

    # Try to detect from gcloud config
    project=$(gcloud config get-value project 2>/dev/null)
    if [ -n "$project" ] && [ "$project" != "(unset)" ]; then
        log_info "Using detected GCP project: $project"
        echo "$project"
        return 0
    fi

    log_error "GCP project not specified and cannot be detected"
    log_error "Use --project <project-id> or run: gcloud config set project <project-id>"
    return 1
}

# Setup secrets in GCP Secret Manager
setup_gcp_secrets() {
    local project="$1"
    local issue="$2"
    local secret_prefix="claude-tastic-$issue"

    log_info "Setting up secrets in GCP Secret Manager..."

    # Store GITHUB_TOKEN
    if [ -n "$GITHUB_TOKEN" ]; then
        echo -n "$GITHUB_TOKEN" | gcloud secrets create "${secret_prefix}-github-token" \
            --project="$project" \
            --data-file=- \
            --replication-policy="automatic" 2>/dev/null || \
        echo -n "$GITHUB_TOKEN" | gcloud secrets versions add "${secret_prefix}-github-token" \
            --project="$project" \
            --data-file=- 2>/dev/null
        log_debug "GITHUB_TOKEN stored in Secret Manager"
    fi

    # Store CLAUDE_CODE_OAUTH_TOKEN
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        echo -n "$CLAUDE_CODE_OAUTH_TOKEN" | gcloud secrets create "${secret_prefix}-claude-token" \
            --project="$project" \
            --data-file=- \
            --replication-policy="automatic" 2>/dev/null || \
        echo -n "$CLAUDE_CODE_OAUTH_TOKEN" | gcloud secrets versions add "${secret_prefix}-claude-token" \
            --project="$project" \
            --data-file=- 2>/dev/null
        log_debug "CLAUDE_CODE_OAUTH_TOKEN stored in Secret Manager"
    fi

    echo "$secret_prefix"
}

# Cleanup GCP secrets after job completes
cleanup_gcp_secrets() {
    local project="$1"
    local secret_prefix="$2"

    log_info "Cleaning up secrets from Secret Manager..."

    gcloud secrets delete "${secret_prefix}-github-token" \
        --project="$project" \
        --quiet 2>/dev/null || true

    gcloud secrets delete "${secret_prefix}-claude-token" \
        --project="$project" \
        --quiet 2>/dev/null || true

    log_debug "Secrets cleaned up"
}

# Launch on GCP Cloud Run Jobs
launch_gcp_cloudrun() {
    local issue="$1"
    local repo="$2"
    local branch="${3:-dev}"
    local image="${4:-$DEFAULT_IMAGE}"
    local project="$5"
    local region="${6:-$DEFAULT_REGION}"
    local memory="${7:-$DEFAULT_MEMORY}"
    local cpu="${8:-$DEFAULT_CPU}"
    local timeout="${9:-$DEFAULT_TIMEOUT}"
    local dry_run="${10:-false}"

    local job_name="${CONTAINER_PREFIX}-${issue}"

    log_info "Launching GCP Cloud Run Job: $job_name"

    check_gcp_prereqs || return 1

    project=$(get_gcp_project "$project") || return 1

    # Validate tokens
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN is required"
        return 1
    fi

    # Check if image exists in Artifact Registry or needs pushing
    local registry_image="$region-docker.pkg.dev/$project/claude-tastic/$image"

    # Check if local image exists
    if docker image inspect "$image" &> /dev/null; then
        log_info "Found local image: $image"

        # Check if we need to push to Artifact Registry
        if ! gcloud artifacts docker images describe "$registry_image" --project="$project" &> /dev/null; then
            log_info "Pushing image to Artifact Registry..."

            # Ensure Artifact Registry repository exists
            gcloud artifacts repositories describe claude-tastic \
                --location="$region" \
                --project="$project" 2>/dev/null || \
            gcloud artifacts repositories create claude-tastic \
                --repository-format=docker \
                --location="$region" \
                --project="$project" \
                --description="Claude agent container images" 2>/dev/null

            # Tag and push
            docker tag "$image" "$registry_image"
            docker push "$registry_image"
            log_info "Image pushed to: $registry_image"
        fi
    else
        log_warn "Local image not found, assuming image exists in registry: $registry_image"
    fi

    # Setup secrets
    local secret_prefix
    secret_prefix=$(setup_gcp_secrets "$project" "$issue")

    # Build job spec
    local job_args=(
        "run" "jobs" "create" "$job_name"
        "--project=$project"
        "--region=$region"
        "--image=$registry_image"
        "--memory=$memory"
        "--cpu=$cpu"
        "--max-retries=0"
        "--task-timeout=${timeout}s"
        "--set-env-vars=REPO_FULL_NAME=$repo,BRANCH=$branch,ISSUE=$issue"
        "--set-secrets=GITHUB_TOKEN=${secret_prefix}-github-token:latest"
    )

    # Add Claude token if available
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        job_args+=("--set-secrets=CLAUDE_CODE_OAUTH_TOKEN=${secret_prefix}-claude-token:latest")
    fi

    if [ "$dry_run" = "true" ]; then
        echo ""
        echo "DRY RUN - Would execute:"
        echo "gcloud ${job_args[*]}"
        echo ""
        echo "Then execute job with:"
        echo "gcloud run jobs execute $job_name --project=$project --region=$region"
        return 0
    fi

    # Create the job
    log_info "Creating Cloud Run job..."
    if ! gcloud "${job_args[@]}" 2>/dev/null; then
        # Job might already exist, try to update
        job_args[2]="update"
        gcloud "${job_args[@]}" || {
            log_error "Failed to create/update Cloud Run job"
            return 1
        }
    fi

    # Execute the job
    log_info "Executing Cloud Run job..."
    local execution_id
    execution_id=$(gcloud run jobs execute "$job_name" \
        --project="$project" \
        --region="$region" \
        --format='value(metadata.name)' 2>/dev/null)

    if [ -z "$execution_id" ]; then
        log_error "Failed to execute Cloud Run job"
        return 1
    fi

    log_info "Job execution started: $execution_id"
    log_info ""
    log_info "Monitor progress:"
    log_info "  gcloud run jobs executions describe $execution_id --project=$project --region=$region"
    log_info ""
    log_info "Stream logs:"
    log_info "  gcloud logging read \"resource.type=cloud_run_job AND resource.labels.job_name=$job_name\" --project=$project --format='value(textPayload)'"
    log_info ""
    log_info "Cancel job:"
    log_info "  $SCRIPT_NAME --provider gcp-cloudrun --stop $job_name --project $project"

    # Return execution info
    echo ""
    echo "Job ID: $job_name"
    echo "Execution: $execution_id"
    echo "Project: $project"
    echo "Region: $region"

    # Setup cleanup hook (optional - could be triggered by job completion)
    log_warn "Remember to clean up secrets after job completes:"
    log_warn "  $SCRIPT_NAME --cleanup-secrets $issue --project $project"
}

# List GCP Cloud Run jobs
list_gcp_jobs() {
    local project="$1"
    local region="${2:-$DEFAULT_REGION}"

    check_gcp_prereqs || return 1
    project=$(get_gcp_project "$project") || return 1

    log_info "Listing Cloud Run jobs in $project ($region):"
    echo ""

    gcloud run jobs list \
        --project="$project" \
        --region="$region" \
        --filter="metadata.name~^${CONTAINER_PREFIX}" \
        --format="table(metadata.name,status.conditions[0].status,metadata.creationTimestamp)" 2>/dev/null

    echo ""
    log_info "For job details: gcloud run jobs describe <job-name> --project=$project --region=$region"
}

# Stop GCP Cloud Run job
stop_gcp_job() {
    local job_name="$1"
    local project="$2"
    local region="${3:-$DEFAULT_REGION}"

    check_gcp_prereqs || return 1
    project=$(get_gcp_project "$project") || return 1

    log_info "Stopping Cloud Run job: $job_name"

    # Get latest execution
    local execution
    execution=$(gcloud run jobs executions list \
        --job="$job_name" \
        --project="$project" \
        --region="$region" \
        --filter="status.conditions[0].status!=True" \
        --format="value(metadata.name)" \
        --limit=1 2>/dev/null)

    if [ -n "$execution" ]; then
        log_info "Cancelling execution: $execution"
        gcloud run jobs executions cancel "$execution" \
            --project="$project" \
            --region="$region" 2>/dev/null || true
    fi

    # Delete the job
    log_info "Deleting job: $job_name"
    gcloud run jobs delete "$job_name" \
        --project="$project" \
        --region="$region" \
        --quiet 2>/dev/null || log_warn "Job may already be deleted"

    # Extract issue number from job name and cleanup secrets
    local issue="${job_name#$CONTAINER_PREFIX-}"
    cleanup_gcp_secrets "$project" "claude-tastic-$issue"

    log_info "Job stopped and cleaned up"
}

# Stream logs from GCP Cloud Run job
stream_gcp_logs() {
    local job_name="$1"
    local project="$2"
    local region="${3:-$DEFAULT_REGION}"

    check_gcp_prereqs || return 1
    project=$(get_gcp_project "$project") || return 1

    log_info "Streaming logs for: $job_name"
    echo ""

    gcloud logging read \
        "resource.type=cloud_run_job AND resource.labels.job_name=$job_name" \
        --project="$project" \
        --format='value(textPayload)' \
        --limit=100 \
        --freshness=1h 2>/dev/null
}

# Generate GitHub Actions workflow file
generate_github_actions_workflow() {
    local issue="$1"
    local repo="$2"
    local branch="${3:-dev}"

    cat << 'WORKFLOW_EOF'
# .github/workflows/claude-agent-issue-N.yml
# Auto-generated workflow for running Claude agent in GitHub Actions
# Replace 'N' with your issue number

name: Claude Agent - Issue N

on:
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'Issue number to work on'
        required: true
        type: number
      branch:
        description: 'Base branch'
        required: false
        default: 'dev'
        type: string

jobs:
  claude-agent:
    runs-on: ubuntu-latest
    timeout-minutes: 60

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          ref: ${{ inputs.branch }}
          fetch-depth: 1

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Install Claude CLI
        run: |
          npm install -g @anthropic-ai/claude-code

      - name: Create feature branch
        run: |
          git checkout -b feat/issue-${{ inputs.issue_number }}

      - name: Run Claude sprint-work
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
        run: |
          claude /sprint-work --issue ${{ inputs.issue_number }}

      - name: Push changes
        if: success()
        run: |
          git push -u origin feat/issue-${{ inputs.issue_number }}

      - name: Create PR
        if: success()
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh pr create \
            --base ${{ inputs.branch }} \
            --title "[CI] Issue #${{ inputs.issue_number }}" \
            --body "Automated PR from Claude Agent workflow.

            Fixes #${{ inputs.issue_number }}

            🤖 Generated by GitHub Actions Claude Agent workflow"
WORKFLOW_EOF
}

# Show cost estimation
show_cost_estimation() {
    cat << 'COST_EOF'

## Cloud Execution Cost Estimation

### GCP Cloud Run Jobs

Cloud Run charges for:
- vCPU time (per second)
- Memory time (per second)
- Requests (negligible for jobs)

**Pricing (us-central1, as of 2024):**

| Resource | Price | Free Tier |
|----------|-------|-----------|
| vCPU | $0.00002400/vCPU-second | 180,000 vCPU-seconds/month |
| Memory | $0.00000250/GiB-second | 360,000 GiB-seconds/month |

**Example Costs (per hour):**

| Configuration | vCPU Cost | Memory Cost | Total/Hour |
|---------------|-----------|-------------|------------|
| 2 vCPU, 2GB | $0.0864 | $0.018 | ~$0.10/hour |
| 2 vCPU, 4GB | $0.0864 | $0.036 | ~$0.12/hour |
| 4 vCPU, 4GB | $0.1728 | $0.036 | ~$0.21/hour |
| 4 vCPU, 8GB | $0.1728 | $0.072 | ~$0.24/hour |

**Typical Claude Agent Session:**
- Duration: 15-45 minutes
- Config: 2 vCPU, 4GB
- Cost: $0.03 - $0.09 per session

**Monthly Estimate (100 sessions):**
- Low usage: $3-5/month
- Medium usage: $5-10/month
- Heavy usage: $10-25/month

### GitHub Actions

**Pricing:**

| Repo Type | Free Tier | Overage |
|-----------|-----------|---------|
| Public | Unlimited | N/A |
| Private (Free) | 2,000 min/month | $0.008/min |
| Private (Team) | 3,000 min/month | $0.008/min |
| Private (Enterprise) | 50,000 min/month | $0.008/min |

**Typical Claude Agent Session:**
- Duration: 15-45 minutes
- Cost (private): $0.12 - $0.36 per session

**Monthly Estimate (100 sessions, private repo):**
- Within free tier: $0
- Exceeding free tier: $12-36/month

### Recommendation

1. **For personal/small teams:** GitHub Actions (free for public, reasonable for private)
2. **For larger scale:** GCP Cloud Run (lower cost at scale, more control)
3. **For maximum isolation:** GCP Cloud Run (containers isolated per-job)

COST_EOF
}

# Main function
main() {
    local action=""
    local provider=""
    local issue=""
    local repo=""
    local branch="dev"
    local image="$DEFAULT_IMAGE"
    local project=""
    local region="$DEFAULT_REGION"
    local memory="$DEFAULT_MEMORY"
    local cpu="$DEFAULT_CPU"
    local timeout="$DEFAULT_TIMEOUT"
    local dry_run="false"
    local job_id=""

    # Get script directory
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --provider)
                provider="$2"
                shift 2
                ;;
            --issue)
                action="launch"
                issue="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            --branch)
                branch="$2"
                shift 2
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            --project)
                project="$2"
                shift 2
                ;;
            --region)
                region="$2"
                shift 2
                ;;
            --memory)
                memory="$2"
                shift 2
                ;;
            --cpu)
                cpu="$2"
                shift 2
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --list)
                action="list"
                shift
                ;;
            --stop)
                action="stop"
                job_id="$2"
                shift 2
                ;;
            --logs)
                action="logs"
                job_id="$2"
                shift 2
                ;;
            --cleanup-secrets)
                action="cleanup-secrets"
                issue="$2"
                shift 2
                ;;
            --generate-workflow)
                action="generate-workflow"
                shift
                ;;
            --cost-estimate)
                action="cost-estimate"
                shift
                ;;
            --debug)
                DEBUG="1"
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-v)
                echo "$SCRIPT_NAME v$VERSION"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Execute action
    case "$action" in
        launch)
            if [ -z "$provider" ]; then
                log_error "--provider is required"
                usage
                exit 1
            fi
            if [ -z "$issue" ]; then
                log_error "--issue is required"
                usage
                exit 1
            fi

            case "$provider" in
                gcp-cloudrun)
                    launch_gcp_cloudrun "$issue" "$repo" "$branch" "$image" "$project" "$region" "$memory" "$cpu" "$timeout" "$dry_run"
                    ;;
                github-actions)
                    log_info "GitHub Actions workflow generation:"
                    generate_github_actions_workflow "$issue" "$repo" "$branch"
                    log_info ""
                    log_info "Copy the above workflow to .github/workflows/claude-agent.yml"
                    log_info "Then trigger via: gh workflow run claude-agent.yml -f issue_number=$issue"
                    ;;
                *)
                    log_error "Unknown provider: $provider"
                    log_error "Supported: gcp-cloudrun, github-actions"
                    exit 1
                    ;;
            esac
            ;;
        list)
            if [ -z "$provider" ]; then
                log_error "--provider is required for --list"
                exit 1
            fi
            case "$provider" in
                gcp-cloudrun)
                    list_gcp_jobs "$project" "$region"
                    ;;
                github-actions)
                    log_info "List GitHub Actions runs with: gh run list --workflow=claude-agent.yml"
                    ;;
            esac
            ;;
        stop)
            if [ -z "$provider" ]; then
                log_error "--provider is required for --stop"
                exit 1
            fi
            if [ -z "$job_id" ]; then
                log_error "Job ID required for --stop"
                exit 1
            fi
            case "$provider" in
                gcp-cloudrun)
                    stop_gcp_job "$job_id" "$project" "$region"
                    ;;
                github-actions)
                    log_info "Cancel GitHub Actions run with: gh run cancel $job_id"
                    ;;
            esac
            ;;
        logs)
            if [ -z "$provider" ]; then
                log_error "--provider is required for --logs"
                exit 1
            fi
            if [ -z "$job_id" ]; then
                log_error "Job ID required for --logs"
                exit 1
            fi
            case "$provider" in
                gcp-cloudrun)
                    stream_gcp_logs "$job_id" "$project" "$region"
                    ;;
                github-actions)
                    log_info "View GitHub Actions logs with: gh run view $job_id --log"
                    ;;
            esac
            ;;
        cleanup-secrets)
            if [ -z "$issue" ]; then
                log_error "Issue number required for --cleanup-secrets"
                exit 1
            fi
            cleanup_gcp_secrets "$project" "claude-tastic-$issue"
            ;;
        generate-workflow)
            generate_github_actions_workflow "$issue" "$repo" "$branch"
            ;;
        cost-estimate)
            show_cost_estimation
            ;;
        *)
            log_error "No action specified"
            usage
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
