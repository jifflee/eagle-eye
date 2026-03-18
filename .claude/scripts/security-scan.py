#!/usr/bin/env python3
"""
security-scan.py
Comprehensive security scanner for secrets, OWASP patterns, and dependency vulnerabilities.

Supports two modes:
  --lightweight   Staged files only, targets < 5 seconds (pre-commit)
  --full          Entire codebase + dependency tree (pre-PR)

USAGE:
  python scripts/security-scan.py [OPTIONS]

OPTIONS:
  --mode MODE           Scan mode: lightweight|full (default: full)
  --staged-files FILE   File containing staged file paths (one per line)
  --source-dir DIR      Source directory to scan (default: .)
  --output-file FILE    Write JSON report to FILE (default: security-report.json)
  --categories LIST     Comma-separated: secrets,owasp,dependencies (default: all)
  --severity-threshold  Minimum severity: critical|high|medium|low (default: low)
  --format json|summary Output format (default: json)
  --no-fail             Exit 0 even if findings are found
  --dry-run             Print scan plan without executing
  --verbose             Verbose output

OUTPUT:
  JSON report conforming to CI report format.
  Exit codes:
    0 = no findings (or --no-fail)
    1 = medium/low findings only
    2 = critical/high findings found
"""

import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

SCANNER_VERSION = "1.0.0"

# ─── Severity helpers ──────────────────────────────────────────────────────────

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1}

EXCLUDE_DIRS = {
    "node_modules", ".git", "__pycache__", "venv", ".venv",
    "dist", "build", ".next", "coverage", ".nyc_output",
    ".refactor", "migrations",
}

_finding_counter = 0


def next_finding_id() -> str:
    global _finding_counter
    _finding_counter += 1
    return f"SEC-{_finding_counter:03d}"


def now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def severity_meets_threshold(severity: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(severity, 0) >= SEVERITY_ORDER.get(threshold, 0)


def is_excluded(path: Path) -> bool:
    for part in path.parts:
        if part in EXCLUDE_DIRS:
            return True
    return False


def find_source_files(source_dir: Path, extensions: Optional[List[str]] = None) -> List[Path]:
    """Find source files, excluding common build/vendor dirs."""
    files = []
    if extensions is None:
        # All text-like files
        extensions = [
            ".py", ".js", ".ts", ".jsx", ".tsx", ".sh", ".bash",
            ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf",
            ".env", ".env.example", ".tf", ".hcl", ".rb", ".go",
            ".java", ".cs", ".php", ".rs", ".swift", ".kt",
            ".html", ".xml", ".properties", ".gradle",
        ]
    for ext in extensions:
        for f in source_dir.rglob(f"*{ext}"):
            if not is_excluded(f):
                files.append(f)
    return sorted(set(files))


def read_file_safe(path: Path) -> Optional[str]:
    """Read file content, returning None on error."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except (OSError, PermissionError):
        return None


# ─── Secrets Detection ─────────────────────────────────────────────────────────

# Patterns for detecting secrets in code and config files.
# Each entry: (pattern_name, regex, severity, description)
SECRET_PATTERNS: List[Tuple[str, str, str, str]] = [
    # API Keys - Generic
    (
        "generic-api-key",
        r'(?i)(?:api[_\-]?key|apikey)\s*[=:]\s*["\']?([A-Za-z0-9\-_]{20,})["\']?',
        "high",
        "Generic API key detected",
    ),
    # AWS Credentials
    (
        "aws-access-key-id",
        r'(?i)AKIA[0-9A-Z]{16}',
        "critical",
        "AWS Access Key ID detected",
    ),
    (
        "aws-secret-key",
        r'(?i)(?:aws[_\-]?secret[_\-]?access[_\-]?key|aws[_\-]?secret)\s*[=:]\s*["\']?([A-Za-z0-9/+]{40})["\']?',
        "critical",
        "AWS Secret Access Key detected",
    ),
    # GitHub Tokens
    (
        "github-token",
        r'(?i)(?:github[_\-]?token|gh[_\-]?token|ghp_[A-Za-z0-9_]{36}|github_pat_[A-Za-z0-9_]{82})',
        "critical",
        "GitHub token detected",
    ),
    # Slack Tokens
    (
        "slack-token",
        r'xox[baprs]-[0-9A-Za-z\-]{10,}',
        "high",
        "Slack token detected",
    ),
    # Stripe API Keys
    (
        "stripe-key",
        r'(?:sk|pk)_(?:test|live)_[0-9A-Za-z]{24,}',
        "critical",
        "Stripe API key detected",
    ),
    # Twilio
    (
        "twilio-account-sid",
        r'AC[a-z0-9]{32}',
        "high",
        "Twilio Account SID detected",
    ),
    (
        "twilio-auth-token",
        r'(?i)twilio.*["\']([a-z0-9]{32})["\']',
        "high",
        "Twilio Auth Token detected",
    ),
    # SendGrid
    (
        "sendgrid-key",
        r'SG\.[A-Za-z0-9\-_]{22,}\.[A-Za-z0-9\-_]{43,}',
        "high",
        "SendGrid API key detected",
    ),
    # Google API Keys
    (
        "google-api-key",
        r'AIza[0-9A-Za-z\-_]{35}',
        "high",
        "Google API key detected",
    ),
    # JWT Tokens (hardcoded)
    (
        "hardcoded-jwt",
        r'eyJ[A-Za-z0-9\-_]+\.eyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+',
        "high",
        "Hardcoded JWT token detected",
    ),
    # Private SSH Keys
    (
        "private-key",
        r'-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----',
        "critical",
        "Private key detected",
    ),
    # Passwords in assignments
    (
        "hardcoded-password",
        r'(?i)(?:password|passwd|pwd)\s*[=:]\s*["\']([^"\']{8,})["\']',
        "high",
        "Hardcoded password detected",
    ),
    # Database connection strings with credentials
    (
        "database-url-with-credentials",
        r'(?i)(?:postgres|mysql|mongodb|redis|amqp|jdbc)[+a-z]*://[^:@\s]+:[^@\s]{3,}@',
        "critical",
        "Database URL with embedded credentials detected",
    ),
    # Generic Bearer tokens
    (
        "bearer-token",
        r'(?i)bearer\s+[A-Za-z0-9\-_\.]{20,}',
        "medium",
        "Bearer token in code (may be hardcoded)",
    ),
    # Secret/token variable assignments
    (
        "generic-secret",
        r'(?i)(?:secret|token|auth_token|access_token)\s*[=:]\s*["\']([A-Za-z0-9\-_\.]{16,})["\']',
        "medium",
        "Potential secret in variable assignment",
    ),
    # OpenAI API Keys
    (
        "openai-key",
        r'sk-[A-Za-z0-9]{20,}',
        "critical",
        "OpenAI API key detected",
    ),
    # Anthropic API Keys
    (
        "anthropic-key",
        r'sk-ant-[A-Za-z0-9\-_]{20,}',
        "critical",
        "Anthropic API key detected",
    ),
]

# Lines/files to skip for secrets scanning (common false positives)
SECRET_ALLOWLIST_PATTERNS = [
    r'(?i)example',
    r'(?i)placeholder',
    r'(?i)your[_\-]?(?:api[_\-]?)?key',
    r'(?i)<[A-Z_]+>',          # <YOUR_KEY>
    r'(?i)\$\{[^}]+\}',        # ${ENV_VAR}
    r'(?i)\$[A-Z_][A-Z0-9_]*', # $ENV_VAR
    r'(?i)xxxx',
    r'(?i)0000',
    r'(?i)test[_\-]?(?:key|token|secret)',
    r'# noqa',
    r'# nosec',
    r'pragma: allowlist secret',
]


def is_allowlisted(line: str) -> bool:
    """Check if a line is likely a false positive (placeholder, example, env var)."""
    for pattern in SECRET_ALLOWLIST_PATTERNS:
        if re.search(pattern, line):
            return True
    return False


def scan_secrets(
    files: List[Path],
    source_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect secrets, API keys, tokens, and passwords in source files."""
    findings = []
    compiled = [(name, re.compile(pat), sev, desc) for name, pat, sev, desc in SECRET_PATTERNS]

    matches_by_pattern: Dict[str, List[dict]] = {}

    for file_path in files:
        # Skip binary-like and known-safe file types
        if file_path.suffix in {".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg",
                                 ".woff", ".woff2", ".ttf", ".eot", ".pdf",
                                 ".zip", ".tar", ".gz", ".map"}:
            continue

        content = read_file_safe(file_path)
        if content is None:
            continue

        for line_num, line in enumerate(content.splitlines(), 1):
            if is_allowlisted(line):
                continue

            for pattern_name, pattern, severity, description in compiled:
                if not severity_meets_threshold(severity, severity_threshold):
                    continue

                match = pattern.search(line)
                if match:
                    # Additional context: skip if it's clearly a comment with example
                    line_stripped = line.strip()
                    if line_stripped.startswith("#") and is_allowlisted(line_stripped):
                        continue

                    rel_path = str(file_path.relative_to(source_dir))

                    if pattern_name not in matches_by_pattern:
                        matches_by_pattern[pattern_name] = []

                    matches_by_pattern[pattern_name].append({
                        "file": rel_path,
                        "line": line_num,
                        "severity": severity,
                        "description": description,
                        "snippet": line_stripped[:120],
                    })

                    if verbose:
                        print(
                            f"[security-scan:verbose] SECRET {pattern_name} in {rel_path}:{line_num}",
                            file=sys.stderr,
                        )

    # Group by pattern_name into findings
    for pattern_name, occurrences in matches_by_pattern.items():
        if not occurrences:
            continue

        severity = occurrences[0]["severity"]
        description = occurrences[0]["description"]
        file_paths = list({occ["file"] for occ in occurrences})[:5]
        locations = [f"{occ['file']}:{occ['line']}" for occ in occurrences[:5]]

        finding = {
            "id": next_finding_id(),
            "dimension": "security",
            "category": "secrets",
            "pattern": pattern_name,
            "severity": severity,
            "owning_agent": "security-iam-prepr",
            "fallback_agent": "backend-developer",
            "file_paths": file_paths,
            "locations": locations,
            "description": (
                f"{description}: found {len(occurrences)} occurrence(s) in "
                f"{len(file_paths)} file(s). Locations: {', '.join(locations[:3])}."
                " Hardcoded secrets pose a critical security risk if the code is "
                "shared or pushed to a public repository."
            ),
            "suggested_fix": (
                f"Remove the hardcoded {pattern_name.replace('-', ' ')} and use "
                "environment variables or a secrets manager instead. "
                "1. Remove the secret from source code immediately. "
                "2. Rotate/revoke the exposed credential. "
                "3. Set the value via environment variable: `export MY_SECRET=...`. "
                "4. Reference via `os.environ['MY_SECRET']` or equivalent. "
                "5. Add the file to .gitignore if it must contain credentials. "
                "6. Consider using a secrets manager (HashiCorp Vault, AWS Secrets Manager)."
            ),
            "acceptance_criteria": [
                "No hardcoded secrets in source code",
                "Exposed credentials have been rotated/revoked",
                "Secrets loaded from environment variables or secrets manager",
                "CI pipeline fails on secret detection",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["secrets", "security", pattern_name],
                "effort_estimate": "s",
                "occurrences": len(occurrences),
                "details": occurrences[:10],
            },
        }
        findings.append(finding)

    return findings


# ─── OWASP Pattern Detection ───────────────────────────────────────────────────

# OWASP Top 10 and common insecure coding patterns.
# Each entry: (check_name, file_extensions, pattern, severity, description, fix)
OWASP_PATTERNS: List[Tuple[str, Set[str], str, str, str, str]] = [
    # A01: Broken Access Control
    (
        "path-traversal",
        {".py", ".js", ".ts", ".php", ".rb", ".go", ".java"},
        r'(?i)(?:open|read|write|include|require)\s*\([^)]*\.\.[/\\]',
        "high",
        "A01 - Potential path traversal: '../' in file operation",
        "Validate and sanitize file paths. Use os.path.realpath() and verify the result is within an allowed base directory.",
    ),
    # A02: Cryptographic Failures
    (
        "weak-hash-md5",
        {".py", ".js", ".ts", ".php", ".rb", ".java", ".go"},
        r'(?i)\b(?:md5|md4|sha1|sha-1)\b\s*\(',
        "high",
        "A02 - Weak cryptographic hash: MD5/SHA1 is cryptographically broken",
        "Replace MD5/SHA1 with SHA-256 or stronger (SHA-3, bcrypt for passwords).",
    ),
    (
        "hardcoded-iv",
        {".py", ".js", ".ts", ".java", ".go"},
        r'(?i)(?:iv|nonce|salt)\s*=\s*b?["\'][0-9a-fA-F]{16,}["\']',
        "high",
        "A02 - Hardcoded IV/nonce/salt detected: reduces cryptographic strength",
        "Generate a random IV/nonce/salt for each encryption operation using a cryptographically secure random number generator.",
    ),
    (
        "weak-random",
        {".py", ".js", ".ts", ".java", ".go", ".php", ".rb"},
        r'(?i)\b(?:random\.random|Math\.random|rand\(\)|srand\()\b',
        "medium",
        "A02 - Weak random number generator used for potential security context",
        "Use cryptographically secure random: Python: secrets.token_bytes(), JS: crypto.randomBytes(), Java: SecureRandom.",
    ),
    # A03: Injection
    (
        "sql-injection-risk",
        {".py", ".js", ".ts", ".php", ".rb", ".java", ".go"},
        r'(?i)(?:execute|query|cursor\.execute)\s*\([^)]*\+[^)]*\)',
        "critical",
        "A03 - Potential SQL injection: string concatenation in database query",
        "Use parameterized queries or prepared statements. Never concatenate user input into SQL strings.",
    ),
    (
        "sql-format-injection",
        {".py", ".js", ".ts"},
        r'(?i)(?:execute|query)\s*\([^)]*%[^)]*\)',
        "critical",
        "A03 - Potential SQL injection: format string in database query",
        "Use parameterized queries. Replace `query % (user_input,)` with `query, (user_input,)`.",
    ),
    (
        "shell-injection",
        {".py", ".js", ".ts", ".rb", ".go"},
        r'(?i)(?:os\.system|subprocess\.call|exec|eval|shell=True)\s*\(',
        "high",
        "A03 - Potential shell injection: user input may reach shell command",
        "Use subprocess with list arguments (no shell=True). Validate/escape any user input used in commands.",
    ),
    (
        "eval-usage",
        {".py", ".js", ".ts", ".php", ".rb"},
        r'\beval\s*\(',
        "high",
        "A03 - Use of eval(): dangerous if input is not fully controlled",
        "Avoid eval(). Use ast.literal_eval() for Python data, JSON.parse() for JSON, or a safe expression evaluator.",
    ),
    (
        "template-injection",
        {".py", ".js", ".ts", ".php", ".rb"},
        r'(?i)(?:render_template_string|Markup\(|\.render\([^)]*user|jinja2\.Template\()',
        "high",
        "A03 - Potential Server-Side Template Injection (SSTI)",
        "Never render user-supplied strings as templates. Validate input and use template sandboxing.",
    ),
    # A04: Insecure Design - XML external entities
    (
        "xxe-risk",
        {".py", ".java", ".php", ".js", ".ts"},
        r'(?i)(?:xml\.etree|lxml|minidom|SAXParser|DocumentBuilder).*(?:parse|load)',
        "medium",
        "A04 - Potential XML External Entity (XXE): XML parsing without entity resolution disabled",
        "Disable external entity processing. In Python lxml: use defusedxml. In Java: disable features on DocumentBuilderFactory.",
    ),
    # A05: Security Misconfiguration
    (
        "debug-mode-enabled",
        {".py", ".js", ".ts", ".env", ".cfg", ".conf", ".json", ".yaml", ".yml"},
        r'(?i)(?:debug\s*=\s*(?:true|1|yes)|DEBUG\s*=\s*True|app\.run\(.*debug\s*=\s*True)',
        "medium",
        "A05 - Debug mode enabled in configuration: may expose sensitive information",
        "Disable debug mode in production. Use environment-specific configuration.",
    ),
    (
        "cors-wildcard",
        {".py", ".js", ".ts", ".json", ".yaml", ".yml"},
        r'(?i)(?:Access-Control-Allow-Origin|allow_origins|cors_origins)\s*[=:]\s*["\']?\*["\']?',
        "medium",
        "A05 - CORS wildcard: allows any origin to access the resource",
        "Restrict CORS to specific trusted origins. Never use '*' in production for authenticated endpoints.",
    ),
    (
        "ssl-verification-disabled",
        {".py", ".js", ".ts", ".rb", ".go"},
        r'(?i)(?:verify\s*=\s*False|rejectUnauthorized\s*:\s*false|InsecureRequestWarning|ssl_verify\s*=\s*(?:false|0))',
        "high",
        "A05 - SSL/TLS verification disabled: vulnerable to MITM attacks",
        "Enable SSL verification. Never set verify=False in production. Fix certificate issues instead.",
    ),
    # A06: Vulnerable Components - handled by dependency scanner
    # A07: Authentication Failures
    (
        "weak-session-secret",
        {".py", ".js", ".ts", ".rb"},
        r'(?i)(?:secret_key|session_secret|cookie_secret)\s*[=:]\s*["\']([^"\']{1,15})["\']',
        "high",
        "A07 - Weak session secret: short secrets are vulnerable to brute force",
        "Use a cryptographically random secret of at least 32 bytes: secrets.token_hex(32).",
    ),
    (
        "hardcoded-credentials",
        {".py", ".js", ".ts", ".rb", ".go", ".java", ".php"},
        r'(?i)(?:username|user|login)\s*[=:]\s*["\'](?:admin|root|administrator|test|demo)["\']',
        "medium",
        "A07 - Hardcoded default credentials: admin/root usernames in code",
        "Remove hardcoded credentials. Use environment variables or a secrets manager.",
    ),
    # A08: Software and Data Integrity Failures
    (
        "pickle-deserialization",
        {".py"},
        r'\bpickle\.(?:load|loads|Unpickler)\b',
        "high",
        "A08 - Insecure deserialization: pickle can execute arbitrary code",
        "Avoid pickle for untrusted data. Use JSON, msgpack, or other safe serialization formats.",
    ),
    (
        "yaml-unsafe-load",
        {".py"},
        r'\byaml\.load\s*\([^,)]+\)',
        "high",
        "A08 - Unsafe YAML load: yaml.load() executes arbitrary Python",
        "Use yaml.safe_load() instead of yaml.load(). Always specify Loader=yaml.SafeLoader.",
    ),
    # A09: Logging Failures
    (
        "sensitive-data-in-logs",
        {".py", ".js", ".ts", ".java", ".go", ".rb"},
        r'(?i)(?:log|logger|print|console\.log)\s*\([^)]*(?:password|secret|token|key|auth)[^)]*\)',
        "medium",
        "A09 - Potential sensitive data in logs: passwords/secrets may be logged",
        "Never log sensitive data. Mask or omit passwords, tokens, and secrets from log output.",
    ),
    # A10: Server-Side Request Forgery
    (
        "ssrf-risk",
        {".py", ".js", ".ts", ".php", ".rb", ".go"},
        r'(?i)(?:requests?\.get|fetch|urllib\.request|http\.get)\s*\([^)]*(?:user|request|input|param)',
        "medium",
        "A10 - Potential SSRF: user-controlled URL in HTTP request",
        "Validate URLs before making requests. Whitelist allowed hosts/schemes. Block private IP ranges.",
    ),
]


def scan_owasp(
    files: List[Path],
    source_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect OWASP Top 10 insecure coding patterns."""
    findings = []

    # Group by check_name to avoid duplicate findings
    matches_by_check: Dict[str, List[dict]] = {}

    # Compile patterns
    compiled_patterns = []
    for check_name, extensions, pattern, severity, description, fix in OWASP_PATTERNS:
        compiled_patterns.append(
            (check_name, extensions, re.compile(pattern), severity, description, fix)
        )

    for file_path in files:
        if file_path.suffix not in {
            ".py", ".js", ".ts", ".jsx", ".tsx", ".php", ".rb", ".go",
            ".java", ".cs", ".env", ".cfg", ".conf", ".json", ".yaml",
            ".yml", ".toml", ".ini", ".properties",
        }:
            continue

        content = read_file_safe(file_path)
        if content is None:
            continue

        for line_num, line in enumerate(content.splitlines(), 1):
            # Skip comment lines for some checks (reduce false positives)
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith("//") or stripped.startswith("*"):
                continue

            for check_name, extensions, pattern, severity, description, fix in compiled_patterns:
                if not severity_meets_threshold(severity, severity_threshold):
                    continue

                if extensions and file_path.suffix not in extensions:
                    continue

                if pattern.search(line):
                    rel_path = str(file_path.relative_to(source_dir))

                    if check_name not in matches_by_check:
                        matches_by_check[check_name] = []

                    matches_by_check[check_name].append({
                        "file": rel_path,
                        "line": line_num,
                        "severity": severity,
                        "description": description,
                        "fix": fix,
                        "snippet": stripped[:120],
                    })

                    if verbose:
                        print(
                            f"[security-scan:verbose] OWASP {check_name} in {rel_path}:{line_num}",
                            file=sys.stderr,
                        )

    # Build findings from grouped matches
    for check_name, occurrences in matches_by_check.items():
        if not occurrences:
            continue

        severity = occurrences[0]["severity"]
        description = occurrences[0]["description"]
        fix = occurrences[0]["fix"]
        file_paths = list({occ["file"] for occ in occurrences})[:5]
        locations = [f"{occ['file']}:{occ['line']}" for occ in occurrences[:5]]

        finding = {
            "id": next_finding_id(),
            "dimension": "security",
            "category": "owasp",
            "check": check_name,
            "severity": severity,
            "owning_agent": "security-iam-prepr",
            "fallback_agent": "backend-developer",
            "file_paths": file_paths,
            "locations": locations,
            "description": (
                f"{description}. Found {len(occurrences)} occurrence(s) in "
                f"{len(file_paths)} file(s). Locations: {', '.join(locations[:3])}."
            ),
            "suggested_fix": fix,
            "acceptance_criteria": [
                f"No {check_name} patterns in codebase",
                "Security review completed for affected code",
                "Tests verify secure behavior",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["owasp", "security", check_name],
                "effort_estimate": "m",
                "occurrences": len(occurrences),
                "details": occurrences[:10],
            },
        }
        findings.append(finding)

    return findings


# ─── Dependency Vulnerability Audit ───────────────────────────────────────────

# Known CVEs and vulnerability patterns in popular packages.
# Format: (package_name, affected_versions_pattern, severity, cve, description, fix)
# NOTE: This is a static baseline; for production use, integrate with an advisory DB.
KNOWN_VULNERABLE_PACKAGES = {
    "python": [
        # (package, version_constraint_pattern, severity, cve_or_id, description, fix)
        ("pyyaml", r"^[0-3]\.|^4\.[0-9](\.|$)|^5\.[0-2](\.|$)", "high", "CVE-2020-14343",
         "PyYAML < 5.4 is vulnerable to arbitrary code execution via yaml.load()",
         "Upgrade to PyYAML >= 5.4 and use yaml.safe_load()"),
        ("pillow", r"^[0-8]\.|^9\.[0-2](\.|$)", "high", "CVE-2022-22817",
         "Pillow < 9.3 has multiple vulnerabilities including buffer overflow",
         "Upgrade to Pillow >= 9.3.0"),
        ("requests", r"^[01]\.|^2\.[0-9](\.|$)|^2\.[12][0-9](\.|$)|^2\.2[0-7](\.|$)", "medium",
         "CVE-2023-32681",
         "requests < 2.31.0 may leak authentication headers to redirected hosts",
         "Upgrade to requests >= 2.31.0"),
        ("django", r"^[0-2]\.|^3\.[01](\.|$)|^3\.2\.[0-9]$|^3\.2\.1[0-7](\.|$)", "high",
         "CVE-2023-23969",
         "Django < 3.2.18, < 4.0.10, < 4.1.7 is vulnerable to potential bypass of validation",
         "Upgrade to Django >= 3.2.18 or >= 4.1.7"),
        ("flask", r"^[01]\.|^2\.0(\.|$)|^2\.1(\.|$)|^2\.2(\.|$)", "medium", "CVE-2023-30861",
         "Flask < 2.3.2 may have cookie security issues in some configurations",
         "Upgrade to Flask >= 2.3.2"),
        ("cryptography", r"^[0-2][0-9]\.", "medium", "CVE-2023-49083",
         "cryptography < 41.0.6 has potential vulnerability in X.509 parsing",
         "Upgrade to cryptography >= 41.0.6"),
        ("paramiko", r"^[01]\.|^2\.[0-6](\.|$)", "high", "CVE-2022-24302",
         "paramiko < 2.10.1 is vulnerable to a directory traversal attack",
         "Upgrade to paramiko >= 2.10.1"),
        ("urllib3", r"^1\.[0-9](\.|$)|^1\.[12][0-9](\.|$)|^1\.2[0-5](\.|$)", "high",
         "CVE-2023-43804",
         "urllib3 < 1.26.17 or < 2.0.5 may leak cookie headers to redirected HTTP requests",
         "Upgrade to urllib3 >= 1.26.17 or >= 2.0.5"),
        ("setuptools", r"^[0-5][0-9]\.", "high", "CVE-2022-40897",
         "setuptools < 65.5.1 is vulnerable to Regular Expression Denial of Service (ReDoS)",
         "Upgrade to setuptools >= 65.5.1"),
        ("aiohttp", r"^[0-2]\.|^3\.[0-8](\.|$)", "high", "CVE-2023-49082",
         "aiohttp < 3.9.0 has multiple security vulnerabilities",
         "Upgrade to aiohttp >= 3.9.0"),
    ],
    "nodejs": [
        ("axios", r"^0\.|^1\.0(\.|$)|^1\.1(\.|$)|^1\.2(\.|$)|^1\.3(\.|$)|^1\.4(\.|$)|^1\.5(\.|$)|^1\.6\.0$",
         "high", "CVE-2023-45857",
         "axios < 1.6.1 has a CSRF vulnerability via credential leakage",
         "Upgrade to axios >= 1.6.1"),
        ("lodash", r"^[0-3]\.|^4\.[0-9](\.|$)|^4\.[12][0-9](\.|$)|^4\.1[0-6](\.|$)", "high",
         "CVE-2021-23337",
         "lodash < 4.17.21 is vulnerable to command injection via template function",
         "Upgrade to lodash >= 4.17.21"),
        ("node-fetch", r"^[01]\.|^2\.[0-5](\.|$)|^3\.0\.0$", "high", "CVE-2022-0235",
         "node-fetch < 2.6.7 or < 3.1.1 has an exposure of sensitive information vulnerability",
         "Upgrade to node-fetch >= 2.6.7 or >= 3.1.1"),
        ("minimist", r"^[0]\.|^1\.[01](\.|$)|^1\.2\.[0-5](\.|$)", "high", "CVE-2021-44906",
         "minimist < 1.2.6 is vulnerable to prototype pollution",
         "Upgrade to minimist >= 1.2.6"),
        ("qs", r"^[0-5]\.|^6\.[0-5](\.|$)|^6\.[789](\.|$)|^6\.10(\.|$)", "high",
         "CVE-2022-24999",
         "qs < 6.11.0 is vulnerable to prototype pollution",
         "Upgrade to qs >= 6.11.0"),
        ("jsonwebtoken", r"^[0-8]\.", "high", "CVE-2022-23539",
         "jsonwebtoken < 9.0.0 has multiple security vulnerabilities",
         "Upgrade to jsonwebtoken >= 9.0.0"),
        ("semver", r"^[0-6]\.|^7\.[0-4](\.|$)|^7\.5\.[0-2](\.|$)", "medium", "CVE-2022-25883",
         "semver < 7.5.2 is vulnerable to Regular Expression Denial of Service (ReDoS)",
         "Upgrade to semver >= 7.5.2"),
        ("tough-cookie", r"^[0-3]\.|^4\.[0-9](\.|$)", "medium", "CVE-2023-26136",
         "tough-cookie < 4.1.3 is vulnerable to prototype pollution",
         "Upgrade to tough-cookie >= 4.1.3"),
        ("word-wrap", r"^1\.[0-2](\.|$)|^1\.2\.[0-5](\.|$)", "medium", "CVE-2023-26115",
         "word-wrap < 1.2.4 is vulnerable to ReDoS",
         "Upgrade to word-wrap >= 1.2.4"),
    ],
}


def parse_version_from_spec(version_spec: str) -> Optional[str]:
    """Extract a version number from a version specifier like '==1.2.3' or '^1.2.3'."""
    m = re.search(r"[\^~>=!]*\s*([0-9]+(?:\.[0-9]+)*)", version_spec.strip())
    if m:
        return m.group(1)
    return None


def scan_dependency_vulnerabilities(
    source_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Check dependencies for known CVEs and security vulnerabilities."""
    findings = []

    # Detect project type
    is_python = (source_dir / "requirements.txt").exists() or (source_dir / "pyproject.toml").exists()
    is_node = (source_dir / "package.json").exists()

    def check_packages(declared_packages: List[Tuple[str, str]], vuln_db: list, dep_file: str):
        """Check declared packages against vulnerability database."""
        for vuln_pkg, version_pattern, severity, cve_id, description, fix in vuln_db:
            if not severity_meets_threshold(severity, severity_threshold):
                continue

            for pkg_name, version_spec in declared_packages:
                norm_name = pkg_name.lower().replace("_", "-")
                if norm_name != vuln_pkg.lower():
                    continue

                version = parse_version_from_spec(version_spec)
                is_vulnerable = False

                if version is None:
                    # No version pinned - assume potentially vulnerable
                    is_vulnerable = True
                    version_info = "unpinned (assume vulnerable)"
                else:
                    # Check if version matches vulnerable pattern
                    if re.match(version_pattern, version):
                        is_vulnerable = True
                        version_info = f"version {version} (matches vulnerable pattern)"
                    else:
                        version_info = f"version {version} (may be patched)"

                if is_vulnerable:
                    if verbose:
                        print(
                            f"[security-scan:verbose] VULN {cve_id} in {pkg_name} {version_info}",
                            file=sys.stderr,
                        )

                    finding = {
                        "id": next_finding_id(),
                        "dimension": "security",
                        "category": "dependency-vulnerability",
                        "cve": cve_id,
                        "package": pkg_name,
                        "version": version_spec or "unpinned",
                        "severity": severity,
                        "owning_agent": "dependency-manager",
                        "fallback_agent": "security-iam-prepr",
                        "file_paths": [dep_file],
                        "description": (
                            f"{cve_id}: {description}. "
                            f"Affected package: `{pkg_name}` ({version_info}) in {dep_file}."
                        ),
                        "suggested_fix": fix,
                        "acceptance_criteria": [
                            f"`{pkg_name}` is upgraded to the patched version",
                            "Lock file is regenerated after upgrade",
                            "Tests pass after the upgrade",
                            "No new vulnerabilities introduced by the upgrade",
                        ],
                        "status": "open",
                        "metadata": {
                            "created_at": now_iso(),
                            "scanner_version": SCANNER_VERSION,
                            "tags": ["cve", "dependency-vulnerability", cve_id, pkg_name],
                            "effort_estimate": "s",
                        },
                    }
                    findings.append(finding)

    if is_python:
        declared = []
        dep_file = ""
        req_file = source_dir / "requirements.txt"
        pyproject_file = source_dir / "pyproject.toml"

        if req_file.exists():
            declared = _parse_requirements_txt(req_file)
            dep_file = "requirements.txt"
        elif pyproject_file.exists():
            declared = _parse_pyproject_toml(pyproject_file)
            dep_file = "pyproject.toml"

        if declared and dep_file:
            check_packages(declared, KNOWN_VULNERABLE_PACKAGES["python"], dep_file)

    if is_node:
        pkg_file = source_dir / "package.json"
        if pkg_file.exists():
            try:
                data = json.loads(pkg_file.read_text(encoding="utf-8", errors="replace"))
            except (json.JSONDecodeError, OSError):
                data = {}

            deps = data.get("dependencies", {})
            dev_deps = data.get("devDependencies", {})
            all_deps = [(k, v) for k, v in {**deps, **dev_deps}.items()]
            check_packages(all_deps, KNOWN_VULNERABLE_PACKAGES["nodejs"], "package.json")

    return findings


def _parse_requirements_txt(req_file: Path) -> List[Tuple[str, str]]:
    """Parse requirements.txt into (name, version_spec) pairs."""
    packages = []
    try:
        content = req_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return packages

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("-"):
            continue
        line = line.split("#")[0].strip()
        if not line:
            continue
        m = re.match(r"^([A-Za-z0-9_.\-]+)(\[.*?\])?(.*)?$", line)
        if m:
            pkg_name = m.group(1).lower().replace("_", "-")
            version_spec = (m.group(3) or "").strip()
            packages.append((pkg_name, version_spec))
    return packages


def _parse_pyproject_toml(pyproject_file: Path) -> List[Tuple[str, str]]:
    """Parse pyproject.toml for dependency entries."""
    packages = []
    try:
        content = pyproject_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return packages

    dep_section = re.search(
        r"\[(?:tool\.poetry\.dependencies|project\.dependencies)\](.*?)(?:\[|$)",
        content,
        re.DOTALL,
    )
    if not dep_section:
        return packages

    section_text = dep_section.group(1)
    for m in re.finditer(r"^([A-Za-z0-9_.\-]+)\s*=\s*(.+)$", section_text, re.MULTILINE):
        pkg = m.group(1).lower().replace("_", "-")
        spec = m.group(2).strip().strip("\"'").strip()
        if pkg not in ("python", "pip"):
            packages.append((pkg, spec))
    return packages


# ─── Report Generation ─────────────────────────────────────────────────────────

def build_report(
    mode: str,
    findings: List[dict],
    scan_start: float,
    scan_end: float,
    categories_scanned: List[str],
    files_scanned: int,
) -> dict:
    """Build the CI-compatible JSON report."""
    import time

    duration = scan_end - scan_start

    by_severity = {"critical": 0, "high": 0, "medium": 0, "low": 0}
    by_category: Dict[str, int] = {}
    for f in findings:
        sev = f.get("severity", "low")
        by_severity[sev] = by_severity.get(sev, 0) + 1
        cat = f.get("category", "unknown")
        by_category[cat] = by_category.get(cat, 0) + 1

    critical_or_high = by_severity["critical"] + by_severity["high"]

    return {
        "timestamp": now_iso(),
        "mode": mode,
        "scanner": "security-scan",
        "scanner_version": SCANNER_VERSION,
        "duration_seconds": round(duration, 2),
        "passed": len(findings) == 0,
        "files_scanned": files_scanned,
        "categories_scanned": categories_scanned,
        "summary": {
            "total": len(findings),
            "critical": by_severity["critical"],
            "high": by_severity["high"],
            "medium": by_severity["medium"],
            "low": by_severity["low"],
            "critical_or_high": critical_or_high,
            "by_category": by_category,
        },
        "findings": findings,
    }


def print_summary(report: dict) -> None:
    """Print a human-readable summary to stderr."""
    summary = report["summary"]
    print("", file=sys.stderr)
    print("┌─────────────────────────────────────────────┐", file=sys.stderr)
    print("│       Security Scan Summary                 │", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    print(f"│  Mode:            {report['mode']:<26}│", file=sys.stderr)
    print(f"│  Files scanned:   {report['files_scanned']:<26}│", file=sys.stderr)
    print(f"│  Duration:        {report['duration_seconds']:.1f}s{'':<23}│", file=sys.stderr)
    print(f"│  Total findings:  {summary['total']:<26}│", file=sys.stderr)
    print(f"│  🔴 Critical:     {summary['critical']:<26}│", file=sys.stderr)
    print(f"│  🟠 High:         {summary['high']:<26}│", file=sys.stderr)
    print(f"│  🟡 Medium:       {summary['medium']:<26}│", file=sys.stderr)
    print(f"│  🟢 Low:          {summary['low']:<26}│", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    if summary["by_category"]:
        print("│  By category:                               │", file=sys.stderr)
        for cat, count in sorted(summary["by_category"].items()):
            print(f"│    {cat:<20} {count:<22}│", file=sys.stderr)
    print("└─────────────────────────────────────────────┘", file=sys.stderr)

    if summary["total"] == 0:
        print("[security-scan] ✓ No security findings.", file=sys.stderr)
    else:
        print(
            f"[security-scan] {'✗' if summary['critical_or_high'] > 0 else '!'} "
            f"{summary['total']} finding(s), "
            f"{summary['critical_or_high']} critical/high.",
            file=sys.stderr,
        )


# ─── Main ──────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Comprehensive security scanner: secrets, OWASP patterns, dependency CVEs"
    )
    parser.add_argument(
        "--mode",
        choices=["lightweight", "full"],
        default="full",
        help="Scan mode: lightweight (staged files, fast) or full (entire codebase)",
    )
    parser.add_argument(
        "--staged-files",
        help="File containing list of staged files (one per line) for lightweight mode",
    )
    parser.add_argument(
        "--source-dir",
        default=".",
        help="Source directory to scan (default: .)",
    )
    parser.add_argument(
        "--output-file",
        default="security-report.json",
        help="Output JSON report file (default: security-report.json)",
    )
    parser.add_argument(
        "--categories",
        default="secrets,owasp,dependencies",
        help="Comma-separated categories: secrets,owasp,dependencies",
    )
    parser.add_argument(
        "--severity-threshold",
        default="low",
        choices=["critical", "high", "medium", "low"],
        help="Minimum severity to report (default: low)",
    )
    parser.add_argument(
        "--format",
        choices=["json", "summary"],
        default="json",
        help="Output format (default: json)",
    )
    parser.add_argument(
        "--no-fail",
        action="store_true",
        help="Exit 0 even if findings are detected",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print scan plan without running")
    parser.add_argument("--verbose", action="store_true", help="Verbose debug output")
    return parser.parse_args()


def main() -> None:
    import time

    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    categories = set(c.strip() for c in args.categories.split(",") if c.strip())

    print(f"[security-scan] Security Scanner v{SCANNER_VERSION}", file=sys.stderr)
    print(f"[security-scan]   Mode:       {args.mode}", file=sys.stderr)
    print(f"[security-scan]   Source dir: {source_dir}", file=sys.stderr)
    print(f"[security-scan]   Categories: {', '.join(sorted(categories))}", file=sys.stderr)
    print(f"[security-scan]   Threshold:  {args.severity_threshold}", file=sys.stderr)

    if args.dry_run:
        print(f"[security-scan] DRY-RUN: would scan {source_dir}", file=sys.stderr)
        print(f"[security-scan] DRY-RUN: categories = {categories}", file=sys.stderr)
        print(f"[security-scan] DRY-RUN: output → {args.output_file}", file=sys.stderr)
        sys.exit(0)

    scan_start = time.time()

    # Determine files to scan
    if args.mode == "lightweight" and args.staged_files:
        # Lightweight mode: scan staged files only
        staged_path = Path(args.staged_files)
        if staged_path.exists():
            staged_lines = staged_path.read_text(encoding="utf-8").splitlines()
            files = [
                Path(line.strip())
                for line in staged_lines
                if line.strip() and Path(line.strip()).is_file()
            ]
        else:
            files = []
        print(f"[security-scan]   Scanning {len(files)} staged file(s)", file=sys.stderr)
    else:
        # Full mode: scan entire codebase
        files = find_source_files(source_dir)
        print(f"[security-scan]   Scanning {len(files)} file(s)", file=sys.stderr)

    all_findings: List[dict] = []
    categories_scanned = []

    # Run requested scan categories
    if "secrets" in categories:
        print("[security-scan] Scanning for secrets...", file=sys.stderr)
        findings = scan_secrets(files, source_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        categories_scanned.append("secrets")
        print(f"[security-scan]   secrets: {len(findings)} finding(s)", file=sys.stderr)

    if "owasp" in categories:
        print("[security-scan] Scanning for OWASP patterns...", file=sys.stderr)
        findings = scan_owasp(files, source_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        categories_scanned.append("owasp")
        print(f"[security-scan]   owasp: {len(findings)} finding(s)", file=sys.stderr)

    if "dependencies" in categories:
        print("[security-scan] Scanning for dependency vulnerabilities...", file=sys.stderr)
        findings = scan_dependency_vulnerabilities(
            source_dir, args.severity_threshold, args.verbose
        )
        all_findings.extend(findings)
        categories_scanned.append("dependencies")
        print(f"[security-scan]   dependencies: {len(findings)} finding(s)", file=sys.stderr)

    # Re-index finding IDs
    for i, finding in enumerate(all_findings):
        finding["id"] = f"SEC-{i + 1:03d}"

    scan_end = time.time()

    # Build report
    report = build_report(
        mode=args.mode,
        findings=all_findings,
        scan_start=scan_start,
        scan_end=scan_end,
        categories_scanned=categories_scanned,
        files_scanned=len(files),
    )

    # Write report
    output_file = Path(args.output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"[security-scan] Report written to: {output_file}", file=sys.stderr)

    # Print summary
    print_summary(report)

    # Determine exit code
    if args.no_fail:
        sys.exit(0)

    critical_or_high = report["summary"]["critical_or_high"]
    total = report["summary"]["total"]

    if critical_or_high > 0:
        sys.exit(2)  # Critical/high findings
    elif total > 0:
        sys.exit(1)  # Medium/low findings only
    else:
        sys.exit(0)  # Clean


if __name__ == "__main__":
    main()
