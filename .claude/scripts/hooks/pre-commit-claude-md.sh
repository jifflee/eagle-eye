#!/usr/bin/env bash
# size-ok: CLAUDE.md guardrails enforcement with policy loading
#
# Pre-commit hook: Enforces CLAUDE.md change control guardrails
#
# Detects CLAUDE.md modifications and validates:
#   1. Modifier is authorized (agent role, CI flag, or human override)
#   2. Content passes validation rules (no secrets, required structure)
#   3. File size limits are respected
#
# Usage: Called by .husky/pre-commit or directly:
#   ./scripts/hooks/pre-commit-claude-md.sh
#
# Bypass: CLAUDE_MD_OVERRIDE=true git commit
# Full bypass (not recommended): git commit --no-verify
#
# Issue: #840 - Add CLAUDE.md update guardrails and enforcement
#

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY_FILE="${REPO_ROOT}/config/claude-md-policy.yaml"
AUDIT_LOG_DIR="${HOME}/.claude-tastic/claude-md-audit"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
WARNINGS=0
VIOLATION_DETAILS=""

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() { echo -e "${BLUE}[CLAUDE.md]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[CLAUDE.md]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[CLAUDE.md WARN]${NC} $*"; WARNINGS=$((WARNINGS + 1)); }
log_err()  { echo -e "${RED}[CLAUDE.md ERROR]${NC} $*"; ERRORS=$((ERRORS + 1)); VIOLATION_DETAILS="${VIOLATION_DETAILS}  - $*\n"; }

# Write to audit log (fire-and-forget, never blocks commit)
audit_log() {
  local action="$1"
  local file="$2"
  local details="${3:-}"
  if [ -n "${AUDIT_LOG_DIR}" ]; then
    mkdir -p "${AUDIT_LOG_DIR}" 2>/dev/null || true
    local log_file="${AUDIT_LOG_DIR}/$(date +%Y-%m-%d).log"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)"
    local author
    author="$(git config user.email 2>/dev/null || echo unknown)"
    local branch
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    printf '[%s] action=%s file=%s author=%s branch=%s %s\n' \
      "${timestamp}" "${action}" "${file}" "${author}" "${branch}" "${details}" \
      >> "${log_file}" 2>/dev/null || true
  fi
}

# =============================================================================
# DETECT STAGED CLAUDE.MD FILES
# =============================================================================

# Find all staged CLAUDE.md files (case-insensitive across platforms)
STAGED_CLAUDE_FILES=""
while IFS= read -r file; do
  filename="$(basename "${file}")"
  filename_lower="$(printf '%s' "${filename}" | tr '[:upper:]' '[:lower:]')"
  if [ "${filename_lower}" = "claude.md" ]; then
    STAGED_CLAUDE_FILES="${STAGED_CLAUDE_FILES}${file}"$'\n'
  fi
done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

# Trim trailing newline
STAGED_CLAUDE_FILES="${STAGED_CLAUDE_FILES%$'\n'}"

# Nothing to check - exit cleanly
if [ -z "${STAGED_CLAUDE_FILES}" ]; then
  exit 0
fi

log_info "Detected CLAUDE.md modification(s) - running guardrails check..."
echo ""

# =============================================================================
# AUTHORIZATION CHECK
# =============================================================================

check_authorization() {
  # Priority 1: Human operator explicit override
  if [ "${CLAUDE_MD_OVERRIDE:-}" = "true" ]; then
    log_warn "CLAUDE_MD_OVERRIDE=true: human operator override active"
    audit_log "human_override" "${STAGED_CLAUDE_FILES}" "CLAUDE_MD_OVERRIDE=true"
    return 0
  fi

  # Priority 2: CI/CD environment (GitHub Actions, etc.)
  if [ "${CI:-}" = "true" ] || [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    local ci_actor="${GITHUB_ACTOR:-ci}"
    log_info "CI environment detected (actor: ${ci_actor}) - authorized"
    audit_log "ci_approved" "${STAGED_CLAUDE_FILES}" "CI=true actor=${ci_actor}"
    return 0
  fi

  # Priority 3: Authorized agent role
  local agent_role="${CLAUDE_AGENT_ROLE:-}"
  local agent_skill="${CLAUDE_SKILL:-}"

  local authorized_roles="documentation-librarian guardrails-policy"
  local authorized_skills="repo-init framework-update"

  if [ -n "${agent_role}" ]; then
    for role in ${authorized_roles}; do
      if [ "${agent_role}" = "${role}" ]; then
        log_info "Authorized agent role detected: ${agent_role}"
        audit_log "agent_approved" "${STAGED_CLAUDE_FILES}" "CLAUDE_AGENT_ROLE=${agent_role}"
        return 0
      fi
    done
    log_err "Agent role '${agent_role}' is not authorized to modify CLAUDE.md"
    audit_log "agent_blocked" "${STAGED_CLAUDE_FILES}" "CLAUDE_AGENT_ROLE=${agent_role} UNAUTHORIZED"
    return 1
  fi

  if [ -n "${agent_skill}" ]; then
    for skill in ${authorized_skills}; do
      if [ "${agent_skill}" = "${skill}" ]; then
        log_info "Authorized skill detected: ${agent_skill}"
        audit_log "skill_approved" "${STAGED_CLAUDE_FILES}" "CLAUDE_SKILL=${agent_skill}"
        return 0
      fi
    done
    log_err "Skill '${agent_skill}' is not authorized to modify CLAUDE.md"
    audit_log "skill_blocked" "${STAGED_CLAUDE_FILES}" "CLAUDE_SKILL=${agent_skill} UNAUTHORIZED"
    return 1
  fi

  # Priority 4: Check git author against known patterns
  local git_author
  git_author="$(git config user.name 2>/dev/null || echo '')"
  local git_email
  git_email="$(git config user.email 2>/dev/null || echo '')"

  # Known authorized commit patterns (CI bots, framework accounts)
  local authorized_patterns="github-actions documentation-librarian repo-init framework-update guardrails-policy noreply@anthropic.com"
  for pattern in ${authorized_patterns}; do
    if echo "${git_author}${git_email}" | grep -qi "${pattern}" 2>/dev/null; then
      log_info "Authorized committer detected: ${git_author} <${git_email}>"
      audit_log "author_approved" "${STAGED_CLAUDE_FILES}" "author=${git_author} email=${git_email}"
      return 0
    fi
  done

  # Default: interactive session - treat as human operator, warn but allow
  # This preserves usability for developers working locally
  log_warn "CLAUDE.md modified by unrecognized process: ${git_author} <${git_email}>"
  log_warn "Set CLAUDE_MD_OVERRIDE=true to suppress this warning if this is intentional"
  log_warn "See: config/claude-md-policy.yaml for authorized modifiers"
  audit_log "human_unrecognized" "${STAGED_CLAUDE_FILES}" "author=${git_author} email=${git_email} WARNING_ONLY"

  # Warning only for unrecognized humans - not a hard block
  # Agents must set CLAUDE_AGENT_ROLE or CLAUDE_SKILL to pass without warning
  return 0
}

# =============================================================================
# CONTENT VALIDATION
# =============================================================================

validate_content() {
  local file="$1"

  # Read file content from staged index (not working tree)
  local content
  content="$(git show ":${file}" 2>/dev/null || true)"

  if [ -z "${content}" ]; then
    log_warn "Could not read staged content of ${file} - skipping content validation"
    return 0
  fi

  local line_count
  line_count="$(printf '%s\n' "${content}" | wc -l | tr -d ' ')"

  # ------------------------------------------------------------------
  # Rule 1: Must have at least one top-level markdown heading
  # ------------------------------------------------------------------
  if ! printf '%s\n' "${content}" | grep -qE '^# ' 2>/dev/null; then
    log_err "${file}: Must contain at least one top-level markdown heading (# Heading)"
  fi

  # ------------------------------------------------------------------
  # Rule 2: No hardcoded secrets
  # ------------------------------------------------------------------
  # Scan for patterns like: password = "realvalue", api_key: "realvalue"
  local secret_matches
  secret_matches="$(printf '%s\n' "${content}" | \
    grep -inE '(password|passwd|api[_-]?key|secret|auth[_-]?token|access[_-]?token)[[:space:]]*[=:][[:space:]]*["\047][a-zA-Z0-9+/._~\-]{8,}' \
    2>/dev/null || true)"

  if [ -n "${secret_matches}" ]; then
    # Filter out obvious placeholders
    local real_secrets
    real_secrets="$(printf '%s\n' "${secret_matches}" | \
      grep -ivE '(your-|placeholder|changeme|example|xxx|<|{|TODO|test-|fake-|mock-)' \
      2>/dev/null || true)"
    if [ -n "${real_secrets}" ]; then
      log_err "${file}: Contains potential hardcoded secrets - remove credentials from CLAUDE.md"
    fi
  fi

  # ------------------------------------------------------------------
  # Rule 3: No private keys
  # ------------------------------------------------------------------
  if printf '%s\n' "${content}" | grep -qE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' 2>/dev/null; then
    log_err "${file}: Contains private key - never store private keys in CLAUDE.md"
  fi

  # ------------------------------------------------------------------
  # Rule 4: Size limits
  # ------------------------------------------------------------------
  local warn_lines=1000
  local max_lines=2000

  if [ "${line_count}" -gt "${max_lines}" ]; then
    log_err "${file}: Exceeds maximum size (${line_count} lines, max ${max_lines}). Split into sections."
  elif [ "${line_count}" -gt "${warn_lines}" ]; then
    log_warn "${file}: Approaching size limit (${line_count} lines, warn at ${warn_lines})"
  fi

  # ------------------------------------------------------------------
  # Rule 5: Detect removal of critical guardrail sections
  # ------------------------------------------------------------------
  # Check if this is a modification (file existed before)
  if git show "HEAD:${file}" >/dev/null 2>&1; then
    local old_content
    old_content="$(git show "HEAD:${file}" 2>/dev/null || true)"

    # Check for removal of NEVER/prohibited sections
    local had_restrictions
    had_restrictions="$(printf '%s\n' "${old_content}" | \
      grep -ciE '(NEVER|prohibited|forbidden|blocked|restricted)' 2>/dev/null || echo 0)"

    local has_restrictions
    has_restrictions="$(printf '%s\n' "${content}" | \
      grep -ciE '(NEVER|prohibited|forbidden|blocked|restricted)' 2>/dev/null || echo 0)"

    if [ "${had_restrictions}" -gt 0 ] && [ "${has_restrictions}" -lt "${had_restrictions}" ]; then
      local removed=$((had_restrictions - has_restrictions))
      log_warn "${file}: ${removed} guardrail restriction(s) may have been removed"
      log_warn "  Review carefully: sections containing NEVER/prohibited/forbidden/blocked/restricted"
      log_warn "  Previous count: ${had_restrictions}, Current count: ${has_restrictions}"
    fi
  fi

  log_ok "${file}: Content validation passed (${line_count} lines)"
}

# =============================================================================
# DIFF SUMMARY
# =============================================================================

show_diff_summary() {
  local file="$1"
  local added=0
  local removed=0

  if git show "HEAD:${file}" >/dev/null 2>&1; then
    # File existed - show change stats
    local diff_stats
    diff_stats="$(git diff --cached --stat -- "${file}" 2>/dev/null || true)"
    if [ -n "${diff_stats}" ]; then
      echo "  ${diff_stats}"
    fi

    # Check if diff is large
    added="$(git diff --cached -- "${file}" 2>/dev/null | grep -c '^+' || echo 0)"
    removed="$(git diff --cached -- "${file}" 2>/dev/null | grep -c '^-' || echo 0)"
    local total_changes=$((added + removed))

    if [ "${total_changes}" -gt 50 ]; then
      log_warn "${file}: Large change (${total_changes} line delta) - consider opening a PR for review"
    fi
  else
    log_info "${file}: New CLAUDE.md file being created"
  fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  CLAUDE.md Guardrails Enforcement Check  ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# Step 1: Authorization check (single check for all CLAUDE.md files)
log_info "Step 1/3: Authorization check..."
if ! check_authorization; then
  echo ""
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${RED}${BOLD} CLAUDE.md modification BLOCKED - Unauthorized modifier${NC}"
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo "Only authorized agents/processes may modify CLAUDE.md files."
  echo "See: config/claude-md-policy.yaml"
  echo ""
  echo "To authorize:"
  echo "  export CLAUDE_AGENT_ROLE=documentation-librarian  # for agents"
  echo "  export CLAUDE_MD_OVERRIDE=true                    # for human operators"
  echo "  git commit --no-verify                            # bypass (not recommended)"
  echo ""
  exit 1
fi

echo ""

# Step 2: Content validation for each modified CLAUDE.md
log_info "Step 2/3: Content validation..."
while IFS= read -r claude_file; do
  [ -z "${claude_file}" ] && continue
  log_info "  Validating: ${claude_file}"
  show_diff_summary "${claude_file}"
  validate_content "${claude_file}"
done <<< "${STAGED_CLAUDE_FILES}"

echo ""

# Step 3: Audit logging
log_info "Step 3/3: Audit trail..."
audit_log "commit_validated" "${STAGED_CLAUDE_FILES}" "errors=${ERRORS} warnings=${WARNINGS}"
log_ok "Audit entry recorded to ${AUDIT_LOG_DIR}/$(date +%Y-%m-%d).log"

echo ""

# =============================================================================
# RESULTS
# =============================================================================

if [ "${ERRORS}" -gt 0 ]; then
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${RED}${BOLD} CLAUDE.md Guardrails Check FAILED (${ERRORS} error(s))${NC}"
  echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "Violations:\n${VIOLATION_DETAILS}"
  echo ""
  echo "Fix the issues above, or bypass with: git commit --no-verify"
  echo "See: docs/CLAUDE_MD_GUARDRAILS.md"
  exit 1
fi

if [ "${WARNINGS}" -gt 0 ]; then
  echo -e "${YELLOW}${BOLD}CLAUDE.md Guardrails Check PASSED with ${WARNINGS} warning(s)${NC}"
else
  echo -e "${GREEN}${BOLD}CLAUDE.md Guardrails Check PASSED${NC}"
fi

exit 0
