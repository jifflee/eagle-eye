#!/bin/bash
set -euo pipefail
# check-resource-capacity.sh
# Resource availability check for container scheduling (CPU/memory)
# Part of feature #619: resource-based container scheduling
# Part of feature #775: resource-aware container scaling rules
#
# Usage:
#   ./scripts/check-resource-capacity.sh [OPTIONS]
#
# Output: JSON with capacity decision and metrics
# {
#   "has_capacity": true/false,
#   "reason": "explanation",
#   "resources": {
#     "cpu": { "usage_pct": 45, "available_pct": 55 },
#     "memory": { "usage_pct": 60, "available_pct": 40 }
#   },
#   "thresholds": { ... },
#   "environment": "local|proxmox",
#   "max_containers": 2|3,
#   "running_containers": 1
# }
#
# Exit codes:
#   0 - Success (check completed)
#   1 - Error (command unavailable, parse failure, etc.)

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/framework-config.sh"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="."

# Thresholds (configurable via environment)
CPU_MAX_THRESHOLD="${CONTAINER_CPU_MAX_THRESHOLD:-80}"       # Don't spawn if CPU > 80%
MEMORY_MAX_THRESHOLD="${CONTAINER_MEMORY_MAX_THRESHOLD:-85}" # Don't spawn if Memory > 85%
CONTAINER_CPU_OVERHEAD="${CONTAINER_CPU_OVERHEAD:-10}"       # Reserve 10% CPU per container
CONTAINER_MEMORY_OVERHEAD="${CONTAINER_MEMORY_OVERHEAD:-5}"  # Reserve 5% memory per container (~400MB on 8GB)

# Detect OS
OS_TYPE="$(uname -s)"

# Detect environment (local vs proxmox) for scaling limits
# Feature #775: resource-aware container scaling rules
detect_environment() {
  # Check for Proxmox-specific indicators
  if [ -f "/etc/pve/.version" ] || [ -f "/etc/pve/datacenter.cfg" ]; then
    echo "proxmox"
    return 0
  fi

  # Check for Proxmox hostname pattern (pve, proxmox, etc.)
  if hostname | grep -qiE '^(pve|proxmox)'; then
    echo "proxmox"
    return 0
  fi

  # Check if running as VM on Proxmox (virtio driver, qemu guest agent)
  if [ -e "/dev/vd" ] || pgrep -x qemu-ga > /dev/null 2>&1; then
    echo "proxmox"
    return 0
  fi

  # Default: local development (macOS, Linux workstation, etc.)
  echo "local"
}

# Get max container limit based on environment
# Feature #775: 2 concurrent for local, 3 for Proxmox
get_max_containers() {
  local env="$1"
  case "$env" in
    proxmox)
      echo "${MAX_CONTAINERS_PROXMOX:-3}"
      ;;
    local)
      echo "${MAX_CONTAINERS_LOCAL:-2}"
      ;;
    *)
      echo "2"  # Default to local limit
      ;;
  esac
}

# Function to get CPU usage percentage
get_cpu_usage() {
  case "$OS_TYPE" in
    Darwin)
      # macOS: parse "CPU usage" line from top (user% + sys% = total usage)
      # Example output: "CPU usage: 17.7% user, 23.78% sys, 59.14% idle"
      top -l 1 -n 0 | grep "CPU usage" | awk -F'[:,]' '{
        gsub(/%/, "", $2); gsub(/%/, "", $3);
        user = $2 + 0; sys = $3 + 0;
        print int(user + sys)
      }'
      ;;
    Linux)
      # Linux: use mpstat if available, fallback to /proc/stat
      if command -v mpstat &> /dev/null; then
        mpstat 1 1 | awk '/Average:/ {print int(100 - $NF)}'
      else
        # Fallback: parse /proc/stat with delta sampling
        # Take two samples 1 second apart to calculate actual CPU usage
        read cpu user1 nice1 system1 idle1 iowait1 irq1 softirq1 < <(grep '^cpu ' /proc/stat)
        sleep 1
        read cpu user2 nice2 system2 idle2 iowait2 irq2 softirq2 < <(grep '^cpu ' /proc/stat)

        # Calculate deltas
        user=$((user2 - user1))
        nice=$((nice2 - nice1))
        system=$((system2 - system1))
        idle=$((idle2 - idle1))
        iowait=$((iowait2 - iowait1))
        irq=$((irq2 - irq1))
        softirq=$((softirq2 - softirq1))

        # Total time = all CPU time slices
        total=$((user + nice + system + idle + iowait + irq + softirq))
        # Active time = everything except idle
        active=$((user + nice + system + iowait + irq + softirq))

        # Calculate percentage and cap at 100
        if [ "$total" -gt 0 ]; then
          usage=$((active * 100 / total))
          if [ "$usage" -gt 100 ]; then
            usage=100
          fi
          echo "$usage"
        else
          echo "0"
        fi
      fi
      ;;
    *)
      echo "50"  # Default fallback
      ;;
  esac
}

# Function to get memory usage percentage
get_memory_usage() {
  case "$OS_TYPE" in
    Darwin)
      # macOS: use physical memory from sysctl as total, vm_stat for used
      # vm_stat pages: active (in use), inactive (reclaimable), wired (kernel),
      # compressed (compressor), free, speculative
      # Bug fix: previously summed only active+wired+compressed+free as total,
      # missing inactive+speculative pages, which inflated usage to ~99%
      local page_size total_pages
      page_size=$(sysctl -n vm.pagesize 2>/dev/null || echo 16384)
      total_pages=$(( $(sysctl -n hw.memsize) / page_size ))
      vm_stat | awk -v total="$total_pages" '
        /Pages active:/ {active=$3+0}
        /Pages wired down:/ {wired=$4+0}
        /Pages occupied by compressor:/ {compressed=$5+0}
        END {
          used = active + wired + compressed
          if (total > 0) print int(used * 100 / total)
          else print 0
        }'
      ;;
    Linux)
      # Linux: parse /proc/meminfo
      awk '
        /MemTotal:/ {total=$2}
        /MemAvailable:/ {available=$2}
        END {
          used = total - available
          if (total > 0) print int(used * 100 / total)
          else print 0
        }' /proc/meminfo
      ;;
    *)
      echo "50"  # Default fallback
      ;;
  esac
}

# Sprint container prefix (must match container-launch.sh)
SPRINT_CONTAINER_PREFIX="${CONTAINER_PREFIX}"

# Function to get running sprint container count
# Only counts sprint-work containers (claude-tastic-issue-*) to avoid
# false capacity failures from unrelated containers (n8n, postgres, redis, etc.)
# Fix for bug #823: capacity check was counting ALL Docker containers
get_container_count() {
  if command -v docker &> /dev/null; then
    docker ps --filter "name=${SPRINT_CONTAINER_PREFIX}" --format '{{.Names}}' 2>/dev/null | \
      grep -c "^${SPRINT_CONTAINER_PREFIX}" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

# Get current resource metrics
CPU_USAGE=$(get_cpu_usage)
MEMORY_USAGE=$(get_memory_usage)
CONTAINER_COUNT=$(get_container_count)

# Detect environment and get max container limit (Feature #775)
ENVIRONMENT=$(detect_environment)
MAX_CONTAINERS=$(get_max_containers "$ENVIRONMENT")

# Calculate available percentages
CPU_AVAILABLE=$((100 - CPU_USAGE))
MEMORY_AVAILABLE=$((100 - MEMORY_USAGE))

# Calculate projected usage with new container
PROJECTED_CPU=$((CPU_USAGE + CONTAINER_CPU_OVERHEAD))
PROJECTED_MEMORY=$((MEMORY_USAGE + CONTAINER_MEMORY_OVERHEAD))

# Decision logic
HAS_CAPACITY="false"
REASON=""

# Check 0: Max container limit reached? (Feature #775)
if [ "$CONTAINER_COUNT" -ge "$MAX_CONTAINERS" ]; then
  REASON="Max concurrent sprint container limit reached (${CONTAINER_COUNT}/${MAX_CONTAINERS} on ${ENVIRONMENT})"
# Check 1: Current CPU too high?
elif [ "$CPU_USAGE" -ge "$CPU_MAX_THRESHOLD" ]; then
  REASON="CPU usage too high (${CPU_USAGE}% >= ${CPU_MAX_THRESHOLD}% threshold)"
# Check 2: Current memory too high?
elif [ "$MEMORY_USAGE" -ge "$MEMORY_MAX_THRESHOLD" ]; then
  REASON="Memory usage too high (${MEMORY_USAGE}% >= ${MEMORY_MAX_THRESHOLD}% threshold)"
# Check 3: Projected CPU would exceed threshold?
elif [ "$PROJECTED_CPU" -ge "$CPU_MAX_THRESHOLD" ]; then
  REASON="Projected CPU with new container would exceed threshold (${PROJECTED_CPU}% >= ${CPU_MAX_THRESHOLD}%)"
# Check 4: Projected memory would exceed threshold?
elif [ "$PROJECTED_MEMORY" -ge "$MEMORY_MAX_THRESHOLD" ]; then
  REASON="Projected memory with new container would exceed threshold (${PROJECTED_MEMORY}% >= ${MEMORY_MAX_THRESHOLD}%)"
# All checks passed
else
  HAS_CAPACITY="true"
  REASON="Resource capacity available (CPU: ${CPU_AVAILABLE}% free, Memory: ${MEMORY_AVAILABLE}% free, Containers: ${CONTAINER_COUNT}/${MAX_CONTAINERS})"
fi

# Build output JSON
jq -cn \
  --arg has_capacity "$HAS_CAPACITY" \
  --arg reason "$REASON" \
  --arg cpu_usage "$CPU_USAGE" \
  --arg cpu_available "$CPU_AVAILABLE" \
  --arg memory_usage "$MEMORY_USAGE" \
  --arg memory_available "$MEMORY_AVAILABLE" \
  --arg projected_cpu "$PROJECTED_CPU" \
  --arg projected_memory "$PROJECTED_MEMORY" \
  --arg container_count "$CONTAINER_COUNT" \
  --arg max_containers "$MAX_CONTAINERS" \
  --arg cpu_max "$CPU_MAX_THRESHOLD" \
  --arg memory_max "$MEMORY_MAX_THRESHOLD" \
  --arg cpu_overhead "$CONTAINER_CPU_OVERHEAD" \
  --arg memory_overhead "$CONTAINER_MEMORY_OVERHEAD" \
  --arg os_type "$OS_TYPE" \
  --arg environment "$ENVIRONMENT" \
  '{
    has_capacity: ($has_capacity == "true"),
    reason: $reason,
    resources: {
      cpu: {
        usage_pct: ($cpu_usage | tonumber),
        available_pct: ($cpu_available | tonumber),
        projected_with_new_container: ($projected_cpu | tonumber)
      },
      memory: {
        usage_pct: ($memory_usage | tonumber),
        available_pct: ($memory_available | tonumber),
        projected_with_new_container: ($projected_memory | tonumber)
      },
      containers: {
        running_count: ($container_count | tonumber),
        max_allowed: ($max_containers | tonumber)
      }
    },
    thresholds: {
      cpu_max_pct: ($cpu_max | tonumber),
      memory_max_pct: ($memory_max | tonumber),
      cpu_overhead_per_container: ($cpu_overhead | tonumber),
      memory_overhead_per_container: ($memory_overhead | tonumber)
    },
    scaling: {
      environment: $environment,
      max_containers: ($max_containers | tonumber)
    },
    metadata: {
      os_type: $os_type,
      timestamp: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }
  }'

exit 0
