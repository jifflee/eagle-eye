#!/usr/bin/env python3
"""
dep-scan.py
Dependency scanner: unused, deprecated, unpinned, and duplicate-purpose packages.

READ-ONLY analysis. Produces findings in refactor-finding.schema.json format.

USAGE:
  python scripts/dep-scan.py [OPTIONS]

OPTIONS:
  --source-dir DIR          Source directory to scan (default: .)
  --output-file FILE        Output findings JSON (default: .refactor/dep-findings.json)
  --categories LIST         Comma-separated: unused,deprecated,unpinned,duplicate
  --severity-threshold LVL  Minimum severity: critical|high|medium|low (default: low)
  --format json|summary     Output format (default: json)
  --project-type TYPE       Force project type: python|nodejs|auto (default: auto)
  --dry-run                 Print scan plan, do not execute
  --verbose                 Verbose output

OUTPUT:
  JSON array of findings conforming to refactor-finding.schema.json
  Exit codes: 0=no findings, 1=medium/low only, 2=critical/high found
"""

import ast
import json
import os
import re
import sys
import argparse
import datetime
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Set, Optional, Tuple

SCANNER_VERSION = "1.0.0"

# ─── Severity helpers ─────────────────────────────────────────────────────────

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1}

EXCLUDE_DIRS = {
    "node_modules", ".git", "__pycache__", "venv", ".venv",
    "dist", "build", ".next", "coverage", ".nyc_output",
    ".refactor", ".claude", "migrations",
}

_finding_counter = 0


def next_finding_id() -> str:
    global _finding_counter
    _finding_counter += 1
    return f"RF-{_finding_counter:03d}"


def now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def severity_meets_threshold(severity: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(severity, 0) >= SEVERITY_ORDER.get(threshold, 0)


def is_excluded(path: Path) -> bool:
    for part in path.parts:
        if part in EXCLUDE_DIRS:
            return True
    return False


def find_source_files(source_dir: Path, extensions: List[str]) -> List[Path]:
    files = []
    for ext in extensions:
        for f in source_dir.rglob(f"*{ext}"):
            if not is_excluded(f):
                files.append(f)
    return sorted(files)


def detect_project_type(source_dir: Path) -> str:
    if (source_dir / "pyproject.toml").exists() or (source_dir / "requirements.txt").exists():
        return "python"
    if (source_dir / "package.json").exists():
        return "nodejs"
    py_count = len(list(source_dir.rglob("*.py")))
    ts_count = len(list(source_dir.rglob("*.ts")))
    return "python" if py_count >= ts_count else "nodejs"


# ─── Python dependency helpers ────────────────────────────────────────────────

# Known deprecated Python packages → suggested replacement
DEPRECATED_PYTHON_PACKAGES = {
    "imp": "importlib",
    "optparse": "argparse",
    "distutils": "setuptools",
    "cgi": "html.escape / urllib",
    "cgitb": "traceback / logging",
    "aifc": "(removed in 3.13)",
    "chunk": "(removed in 3.13)",
    "crypt": "bcrypt / hashlib",
    "imghdr": "filetype / magic",
    "mailcap": "(removed in 3.13)",
    "msilib": "(Windows only - removed in 3.13)",
    "nis": "(removed in 3.13)",
    "nntplib": "(removed in 3.13)",
    "ossaudiodev": "(removed in 3.13)",
    "pipes": "subprocess",
    "sndhdr": "(removed in 3.13)",
    "spwd": "(removed in 3.13)",
    "sunau": "(removed in 3.13)",
    "telnetlib": "telnetlib3",
    "uu": "base64",
    "xdrlib": "(removed in 3.13)",
    "nose": "pytest",
    "mock": "unittest.mock",
    "six": "(use Python 3 directly)",
    "future": "(use Python 3 directly)",
    "2to3": "(Python 2 migration tool)",
    "pep8": "pycodestyle / ruff",
    "pyflakes": "ruff",
    "pylint": "ruff (for linting) / mypy (for types)",
    "flake8": "ruff",
    "autopep8": "ruff --fix",
    "isort": "ruff (isort built-in)",
    "bandit": "ruff-security or semgrep",
    "requests": None,  # Not deprecated, just common
    "boto": "boto3",
    "MySQLdb": "mysqlclient or PyMySQL",
    "pymongo": None,  # Not deprecated
    "django-rest-framework": None,
}

# Packages with known deprecation notes in PyPI
DEPRECATED_THIRD_PARTY = {
    "nose": "pytest",
    "nose2": "pytest",
    "unittest2": "unittest (stdlib)",
    "mock": "unittest.mock (stdlib)",
    "six": "use Python 3 native code",
    "future": "use Python 3 native code",
    "py2": "use Python 3",
    "pep8": "pycodestyle or ruff",
    "pyflakes": "ruff",
    "flake8": "ruff",
    "autopep8": "ruff --fix",
    "isort": "ruff (built-in I rules)",
    "boto": "boto3",
    "django-extensions": None,  # Active
    "celery": None,  # Active
}

# Packages serving the same purpose (duplicate-purpose detection)
DUPLICATE_PURPOSE_GROUPS_PYTHON = [
    {
        "purpose": "HTTP client",
        "packages": ["requests", "httpx", "urllib3", "aiohttp", "httplib2", "treq", "pycurl"],
    },
    {
        "purpose": "JSON parsing",
        "packages": ["ujson", "orjson", "simplejson", "rapidjson", "demjson"],
    },
    {
        "purpose": "async framework",
        "packages": ["asyncio", "twisted", "tornado", "gevent", "trio"],
    },
    {
        "purpose": "task queue",
        "packages": ["celery", "rq", "dramatiq", "huey", "arq"],
    },
    {
        "purpose": "testing framework",
        "packages": ["pytest", "unittest", "nose", "nose2"],
    },
    {
        "purpose": "linting/formatting",
        "packages": ["flake8", "pylint", "pyflakes", "pep8", "pycodestyle", "ruff", "autopep8", "black", "isort"],
    },
    {
        "purpose": "ORM / database",
        "packages": ["sqlalchemy", "django", "peewee", "pony", "tortoise-orm"],
    },
    {
        "purpose": "CLI framework",
        "packages": ["click", "argparse", "typer", "docopt", "fire", "plumbum"],
    },
    {
        "purpose": "logging",
        "packages": ["loguru", "structlog", "logging", "logbook"],
    },
    {
        "purpose": "data validation",
        "packages": ["pydantic", "cerberus", "marshmallow", "voluptuous", "jsonschema"],
    },
    {
        "purpose": "date/time",
        "packages": ["arrow", "pendulum", "dateutil", "dateparser", "moment"],
    },
    {
        "purpose": "YAML parsing",
        "packages": ["pyyaml", "ruamel.yaml", "strictyaml", "oyaml"],
    },
    {
        "purpose": "env/config loading",
        "packages": ["python-dotenv", "decouple", "environs", "dynaconf", "python-decouple"],
    },
    {
        "purpose": "template engine",
        "packages": ["jinja2", "mako", "chameleon", "genshi"],
    },
    {
        "purpose": "web framework",
        "packages": ["flask", "django", "fastapi", "tornado", "bottle", "falcon", "starlette", "sanic"],
    },
    {
        "purpose": "mock/stub",
        "packages": ["mock", "unittest.mock", "responses", "httpretty", "respx", "pytest-mock"],
    },
    {
        "purpose": "retry logic",
        "packages": ["tenacity", "retrying", "backoff", "retry"],
    },
    {
        "purpose": "type checking",
        "packages": ["mypy", "pyright", "pytype", "pyre-check"],
    },
]

# Node/npm duplicate-purpose groups
DUPLICATE_PURPOSE_GROUPS_NODE = [
    {
        "purpose": "HTTP client",
        "packages": ["axios", "node-fetch", "got", "superagent", "ky", "undici", "cross-fetch"],
    },
    {
        "purpose": "testing framework",
        "packages": ["jest", "mocha", "jasmine", "vitest", "ava", "tap"],
    },
    {
        "purpose": "assertion library",
        "packages": ["chai", "expect", "should", "assert"],
    },
    {
        "purpose": "date/time",
        "packages": ["moment", "dayjs", "date-fns", "luxon"],
    },
    {
        "purpose": "utility library",
        "packages": ["lodash", "underscore", "ramda"],
    },
    {
        "purpose": "logging",
        "packages": ["winston", "pino", "bunyan", "morgan", "log4js"],
    },
    {
        "purpose": "validation",
        "packages": ["joi", "yup", "zod", "ajv", "validator"],
    },
    {
        "purpose": "ORM / database",
        "packages": ["sequelize", "typeorm", "prisma", "mongoose", "knex"],
    },
    {
        "purpose": "CLI framework",
        "packages": ["commander", "yargs", "minimist", "meow", "oclif"],
    },
    {
        "purpose": "bundler",
        "packages": ["webpack", "rollup", "parcel", "esbuild", "vite"],
    },
    {
        "purpose": "formatting",
        "packages": ["prettier", "eslint", "standardjs"],
    },
    {
        "purpose": "env loading",
        "packages": ["dotenv", "dotenv-expand", "env-var"],
    },
    {
        "purpose": "crypto",
        "packages": ["bcrypt", "bcryptjs", "argon2", "crypto-js"],
    },
    {
        "purpose": "queue/jobs",
        "packages": ["bull", "bullmq", "bee-queue", "agenda", "kue"],
    },
    {
        "purpose": "mock/stub",
        "packages": ["sinon", "nock", "msw", "jest-mock"],
    },
    {
        "purpose": "retry",
        "packages": ["retry", "p-retry", "async-retry"],
    },
    {
        "purpose": "promise utilities",
        "packages": ["bluebird", "p-map", "p-limit", "p-queue"],
    },
]


# ─── Python dependency parsing ────────────────────────────────────────────────

def parse_requirements_txt(req_file: Path) -> List[Tuple[str, str]]:
    """
    Parse requirements.txt. Returns [(package_name, version_spec), ...].
    Handles: pkg==1.0, pkg>=1.0, pkg~=1.0, pkg (no version), pkg[extra]>=1.0
    Skips: comments, -r includes, -e editable installs, blank lines.
    """
    packages = []
    try:
        content = req_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return packages

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("-"):
            continue
        # Strip inline comments
        line = line.split("#")[0].strip()
        if not line:
            continue
        # Match package[extras]version_spec
        m = re.match(r"^([A-Za-z0-9_.\-]+)(\[.*?\])?(.*)?$", line)
        if m:
            pkg_name = m.group(1).lower().replace("_", "-").replace(".", "-")
            version_spec = (m.group(3) or "").strip()
            packages.append((pkg_name, version_spec))
    return packages


def parse_pyproject_toml(pyproject_file: Path) -> List[Tuple[str, str]]:
    """
    Parse pyproject.toml for dependencies (PEP 517/518).
    Returns [(package_name, version_spec), ...].
    Uses regex to avoid needing tomllib (Python < 3.11).
    """
    packages = []
    try:
        content = pyproject_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return packages

    # Find [tool.poetry.dependencies] or [project.dependencies]
    dep_section = re.search(
        r"\[(?:tool\.poetry\.dependencies|project\.dependencies)\](.*?)(?:\[|$)",
        content,
        re.DOTALL,
    )
    if not dep_section:
        return packages

    section_text = dep_section.group(1)
    # Match: package = ">=1.0" or package = {version = ">=1.0", ...}
    for m in re.finditer(r'^([A-Za-z0-9_.\-]+)\s*=\s*(.+)$', section_text, re.MULTILINE):
        pkg = m.group(1).lower().replace("_", "-").replace(".", "-")
        spec = m.group(2).strip().strip('"\'').strip()
        if pkg not in ("python", "pip"):
            packages.append((pkg, spec))
    return packages


def get_python_imports_from_source(source_dir: Path) -> Set[str]:
    """
    Collect all top-level import names used across Python source files.
    Excludes test files and __init__.py stubs.
    Returns set of package names (lowercase, normalized).
    """
    imported = set()
    py_files = find_source_files(source_dir, [".py"])

    for f in py_files:
        # Skip test files
        if re.search(r"(test_|_test\.)", f.name.lower()):
            continue
        try:
            source = f.read_text(encoding="utf-8", errors="replace")
            tree = ast.parse(source, filename=str(f))
        except (SyntaxError, UnicodeDecodeError):
            continue

        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    top_level = alias.name.split(".")[0].lower()
                    imported.add(top_level)
            elif isinstance(node, ast.ImportFrom):
                if node.module and node.level == 0:
                    top_level = node.module.split(".")[0].lower()
                    imported.add(top_level)

    return imported


def normalize_package_name(name: str) -> str:
    """Normalize package name for comparison."""
    return name.lower().replace("_", "-").replace(".", "-")


# ─── Node dependency parsing ──────────────────────────────────────────────────

def parse_package_json(pkg_file: Path) -> Tuple[Dict[str, str], Dict[str, str]]:
    """
    Parse package.json. Returns (dependencies, devDependencies) as {name: version}.
    """
    try:
        data = json.loads(pkg_file.read_text(encoding="utf-8", errors="replace"))
    except (json.JSONDecodeError, OSError):
        return {}, {}
    deps = data.get("dependencies", {})
    dev_deps = data.get("devDependencies", {})
    return deps, dev_deps


def get_node_imports_from_source(source_dir: Path) -> Set[str]:
    """
    Collect all external package imports from TS/JS source files.
    Excludes relative imports (./), node built-ins, and test files.
    Returns set of package names.
    """
    imported = set()
    extensions = [".ts", ".tsx", ".js", ".jsx"]
    files = find_source_files(source_dir, extensions)

    # Node.js built-in modules
    builtins = {
        "assert", "buffer", "child_process", "cluster", "console", "constants",
        "crypto", "dgram", "dns", "domain", "events", "fs", "http", "https",
        "module", "net", "os", "path", "process", "punycode", "querystring",
        "readline", "repl", "stream", "string_decoder", "sys", "timers",
        "tls", "tty", "url", "util", "v8", "vm", "zlib",
    }

    import_pattern = re.compile(
        r"""(?:import|export)\s+(?:[\w\s{},*]+\s+from\s+)?['"]([^'"]+)['"]|"""
        r"""require\s*\(\s*['"]([^'"]+)['"]\s*\)""",
        re.MULTILINE,
    )

    for f in files:
        if re.search(r"(\.test\.|\.spec\.|__tests__)", str(f)):
            continue
        try:
            content = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        for m in import_pattern.finditer(content):
            imp = m.group(1) or m.group(2)
            if not imp or imp.startswith(".") or imp.startswith("/"):
                continue
            # Scoped package: @org/pkg → @org/pkg
            if imp.startswith("@"):
                parts = imp.split("/")
                pkg = "/".join(parts[:2]) if len(parts) >= 2 else imp
            else:
                pkg = imp.split("/")[0]

            if pkg not in builtins and not pkg.startswith("node:"):
                imported.add(pkg)

    return imported


def check_lock_file(source_dir: Path, project_type: str) -> bool:
    """Return True if a lock file exists."""
    if project_type == "python":
        return (
            (source_dir / "poetry.lock").exists()
            or (source_dir / "Pipfile.lock").exists()
            or (source_dir / "requirements.lock").exists()
        )
    else:
        return (
            (source_dir / "package-lock.json").exists()
            or (source_dir / "yarn.lock").exists()
            or (source_dir / "pnpm-lock.yaml").exists()
        )


# ─── Scan Functions ───────────────────────────────────────────────────────────

def scan_unused_deps(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect packages declared but never imported in source code."""
    findings = []

    if project_type == "python":
        # Gather declared packages
        declared = []
        req_file = source_dir / "requirements.txt"
        pyproject_file = source_dir / "pyproject.toml"

        if req_file.exists():
            declared.extend(parse_requirements_txt(req_file))
            dep_file = "requirements.txt"
        elif pyproject_file.exists():
            declared.extend(parse_pyproject_toml(pyproject_file))
            dep_file = "pyproject.toml"
        else:
            if verbose:
                print("[dep-scan:verbose] No Python dependency file found", file=sys.stderr)
            return findings

        if not declared:
            return findings

        # Gather actual imports from source
        actually_imported = get_python_imports_from_source(source_dir)
        if verbose:
            print(f"[dep-scan:verbose] Python imports found: {sorted(actually_imported)}", file=sys.stderr)

        # Standard library modules to exclude from "unused" detection
        stdlib_names = {
            "os", "sys", "re", "json", "ast", "io", "abc", "copy", "math",
            "time", "datetime", "pathlib", "typing", "collections", "itertools",
            "functools", "operator", "string", "struct", "hashlib", "hmac",
            "base64", "codecs", "urllib", "http", "email", "html", "xml",
            "csv", "sqlite3", "threading", "multiprocessing", "subprocess",
            "logging", "warnings", "traceback", "inspect", "importlib",
            "contextlib", "dataclasses", "enum", "uuid", "random", "secrets",
            "shutil", "tempfile", "glob", "fnmatch", "signal", "socket",
            "ssl", "select", "queue", "unittest", "argparse", "configparser",
            "pickle", "shelve", "dbm", "zlib", "gzip", "bz2", "lzma",
            "zipfile", "tarfile", "atexit", "gc", "weakref", "array", "bisect",
            "heapq", "decimal", "fractions", "statistics", "platform",
            "pprint", "textwrap", "difflib", "readline", "rlcompleter",
            "getpass", "getopt", "curses", "tokenize", "token", "keyword",
            "builtins", "__future__",
        }

        # Known build/test-only packages that appear in requirements but not code
        meta_packages = {
            "setuptools", "wheel", "pip", "build", "twine",
            "pytest", "pytest-asyncio", "pytest-cov", "pytest-mock",
            "coverage", "tox", "nox", "pre-commit", "mypy", "ruff",
            "black", "isort", "flake8", "pylint", "pycodestyle",
            "bandit", "safety", "semgrep",
        }

        unused = []
        for pkg_name, version_spec in declared:
            # Skip meta packages
            norm = normalize_package_name(pkg_name)
            if norm in meta_packages:
                continue
            # Check if the package or a plausible alias is imported
            # Handle common name mismatches: pillow→PIL, scikit-learn→sklearn, etc.
            name_variants = {
                norm,
                norm.replace("-", "_"),
                norm.replace("-", ""),
                pkg_name.split("-")[-1],  # e.g., python-dotenv → dotenv
            }
            common_aliases = {
                "pillow": "pil",
                "scikit-learn": "sklearn",
                "python-dateutil": "dateutil",
                "python-dotenv": "dotenv",
                "beautifulsoup4": "bs4",
                "pyyaml": "yaml",
                "typing-extensions": "typing_extensions",
                "openai": "openai",
                "anthropic": "anthropic",
                "claude-agent-sdk": "claude_agent_sdk",
            }
            alias = common_aliases.get(norm, None)
            if alias:
                name_variants.add(alias)

            found = any(v in actually_imported for v in name_variants)
            if not found:
                unused.append((pkg_name, version_spec))

        if verbose:
            print(f"[dep-scan:verbose] Unused Python deps: {[p for p, _ in unused]}", file=sys.stderr)

        if unused and severity_meets_threshold("medium", severity_threshold):
            pkg_list = ", ".join(p for p, _ in unused[:10])
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "unused-dep",
                "severity": "medium",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": [dep_file],
                "description": (
                    f"Unused dependencies detected: {len(unused)} package(s) declared in "
                    f"{dep_file} but never imported in source code: {pkg_list}. "
                    "Unused dependencies increase install time, attack surface, and cognitive overhead."
                ),
                "suggested_fix": (
                    f"Remove unused packages from {dep_file}: "
                    + "; ".join(f"`{p}`" for p, _ in unused[:5])
                    + ". Verify with `pip show <package>` and search imports before removing. "
                    "Consider using `pipreqs` or `pip-check` to auto-detect unused dependencies."
                ),
                "acceptance_criteria": [
                    f"All packages in {dep_file} are imported somewhere in the source code",
                    "Dependencies only needed for testing are in a separate requirements-dev.txt",
                    "Lock file is regenerated after removal",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["unused-dep", "dependencies"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    elif project_type == "nodejs":
        pkg_file = source_dir / "package.json"
        if not pkg_file.exists():
            return findings

        deps, dev_deps = parse_package_json(pkg_file)
        actually_imported = get_node_imports_from_source(source_dir)

        if verbose:
            print(f"[dep-scan:verbose] Node imports found: {sorted(actually_imported)}", file=sys.stderr)

        # Check prod deps that are never imported
        unused_prod = [
            pkg for pkg in deps
            if pkg not in actually_imported
            # Exclude lifecycle/meta packages
            and not pkg.startswith("@types/")
            and pkg not in {"husky", "lint-staged", "cross-env", "npm-run-all", "concurrently"}
        ]

        if verbose:
            print(f"[dep-scan:verbose] Unused Node prod deps: {unused_prod}", file=sys.stderr)

        if unused_prod and severity_meets_threshold("medium", severity_threshold):
            pkg_list = ", ".join(f"`{p}`" for p in unused_prod[:10])
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "unused-dep",
                "severity": "medium",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": ["package.json"],
                "description": (
                    f"Unused production dependencies: {len(unused_prod)} package(s) in "
                    f"package.json `dependencies` are never imported in source: {pkg_list}. "
                    "Unused production deps inflate bundle size and increase attack surface."
                ),
                "suggested_fix": (
                    "Remove unused packages: `npm uninstall " + " ".join(unused_prod[:5]) + "`. "
                    "If a package is only needed at build time, move it to devDependencies. "
                    "Use `npx depcheck` to auto-detect unused dependencies."
                ),
                "acceptance_criteria": [
                    "All packages in dependencies are imported in non-test source files",
                    "Build-only packages are in devDependencies",
                    "package-lock.json is regenerated",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["unused-dep", "dependencies", "nodejs"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    return findings


def scan_deprecated_deps(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect packages with known deprecation notices."""
    findings = []

    if project_type == "python":
        declared = []
        req_file = source_dir / "requirements.txt"
        pyproject_file = source_dir / "pyproject.toml"

        if req_file.exists():
            declared = parse_requirements_txt(req_file)
            dep_file = "requirements.txt"
        elif pyproject_file.exists():
            declared = parse_pyproject_toml(pyproject_file)
            dep_file = "pyproject.toml"
        else:
            return findings

        deprecated_found = []
        for pkg_name, version_spec in declared:
            norm = normalize_package_name(pkg_name)
            replacement = DEPRECATED_THIRD_PARTY.get(norm)
            if replacement is not None:
                deprecated_found.append((pkg_name, replacement))

        if verbose:
            print(f"[dep-scan:verbose] Deprecated Python deps: {deprecated_found}", file=sys.stderr)

        if deprecated_found and severity_meets_threshold("high", severity_threshold):
            for pkg_name, replacement in deprecated_found[:5]:
                sev = "high" if replacement else "medium"
                if not severity_meets_threshold(sev, severity_threshold):
                    continue
                finding = {
                    "id": next_finding_id(),
                    "dimension": "dependencies",
                    "category": "outdated-dep",
                    "severity": sev,
                    "owning_agent": "dependency-manager",
                    "fallback_agent": "backend-developer",
                    "file_paths": [dep_file],
                    "description": (
                        f"Deprecated package: `{pkg_name}` is deprecated and may be "
                        "unmaintained, removed from PyPI, or incompatible with Python 3.x. "
                        + (f"Replacement: `{replacement}`." if replacement else "No maintained replacement identified.")
                    ),
                    "suggested_fix": (
                        f"Replace `{pkg_name}` with `{replacement}`. " if replacement else
                        f"Remove `{pkg_name}` and find an alternative. "
                    ) + (
                        "Update all import statements, run tests, and remove the old package from "
                        f"{dep_file}."
                    ),
                    "acceptance_criteria": [
                        f"`{pkg_name}` is removed from {dep_file}",
                        f"All usages of `{pkg_name}` replaced with `{replacement or 'alternative'}`",
                        "All tests pass after migration",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["deprecated", "outdated-dep"],
                        "effort_estimate": "m",
                    },
                }
                findings.append(finding)

        # Also scan source files for deprecated stdlib usage
        deprecated_stdlib_usage = []
        py_files = find_source_files(source_dir, [".py"])
        for f in py_files:
            if is_excluded(f):
                continue
            try:
                source = f.read_text(encoding="utf-8", errors="replace")
                tree = ast.parse(source, filename=str(f))
            except (SyntaxError, UnicodeDecodeError):
                continue

            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        mod = alias.name.split(".")[0]
                        if mod in DEPRECATED_PYTHON_PACKAGES:
                            replacement = DEPRECATED_PYTHON_PACKAGES[mod]
                            deprecated_stdlib_usage.append((str(f.relative_to(source_dir)), mod, replacement))
                elif isinstance(node, ast.ImportFrom):
                    if node.module and node.level == 0:
                        mod = node.module.split(".")[0]
                        if mod in DEPRECATED_PYTHON_PACKAGES:
                            replacement = DEPRECATED_PYTHON_PACKAGES[mod]
                            deprecated_stdlib_usage.append((str(f.relative_to(source_dir)), mod, replacement))

        if verbose:
            print(f"[dep-scan:verbose] Deprecated stdlib usage: {deprecated_stdlib_usage}", file=sys.stderr)

        if deprecated_stdlib_usage and severity_meets_threshold("medium", severity_threshold):
            files = sorted({fp for fp, _, _ in deprecated_stdlib_usage})[:5]
            examples = "; ".join(
                f"`{mod}` in {fp}" + (f" → use `{repl}`" if repl else "")
                for fp, mod, repl in deprecated_stdlib_usage[:3]
            )
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "outdated-dep",
                "severity": "medium",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": files if files else ["(scanned source)"],
                "description": (
                    f"Deprecated stdlib modules used: {len(deprecated_stdlib_usage)} import(s) "
                    f"of deprecated Python standard library modules. Examples: {examples}. "
                    "These modules may be removed in future Python versions."
                ),
                "suggested_fix": (
                    "Replace deprecated stdlib imports with their modern equivalents. "
                    "Run `python -W all <file>` to surface DeprecationWarning from imports. "
                    "See Python docs for migration guides on each deprecated module."
                ),
                "acceptance_criteria": [
                    "No imports of deprecated stdlib modules",
                    "Code runs without DeprecationWarning",
                    "All tests pass after migration",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["deprecated", "stdlib", "outdated-dep"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    elif project_type == "nodejs":
        # TODO: could check npm deprecation notices via npm view, but that requires network access
        # For now, check package.json for known deprecated packages
        pkg_file = source_dir / "package.json"
        if not pkg_file.exists():
            return findings

        # Known deprecated node packages
        DEPRECATED_NODE_PACKAGES = {
            "request": "got or axios (request is deprecated since 2020)",
            "node-uuid": "uuid",
            "moment": "date-fns or dayjs (moment is in maintenance mode)",
            "uglify-js": "terser",
            "babel-preset-es2015": "@babel/preset-env",
            "babel-preset-latest": "@babel/preset-env",
            "babel-preset-react": "@babel/preset-react",
            "babel-preset-stage-0": "@babel/preset-stage-0 (removed)",
            "grunt": "consider npm scripts or webpack",
            "bower": "npm or yarn",
            "karma": "jest or vitest",
            "protractor": "playwright or cypress",
            "node-sass": "sass (dart-sass)",
            "fibers": "(deprecated, not maintained)",
            "v8-compile-cache": "native v8 caching",
            "express-jwt": "jsonwebtoken + express middleware",
        }

        deps, dev_deps = parse_package_json(pkg_file)
        all_deps = {**deps, **dev_deps}

        for pkg_name, reason in DEPRECATED_NODE_PACKAGES.items():
            if pkg_name in all_deps:
                if not severity_meets_threshold("high", severity_threshold):
                    continue
                finding = {
                    "id": next_finding_id(),
                    "dimension": "dependencies",
                    "category": "outdated-dep",
                    "severity": "high",
                    "owning_agent": "dependency-manager",
                    "fallback_agent": "backend-developer",
                    "file_paths": ["package.json"],
                    "description": (
                        f"Deprecated npm package: `{pkg_name}` — {reason}. "
                        "Deprecated packages receive no security patches and may break with Node.js updates."
                    ),
                    "suggested_fix": (
                        f"Replace `{pkg_name}` with the recommended alternative: {reason}. "
                        "Update all imports/requires, test the replacement, then uninstall the old package."
                    ),
                    "acceptance_criteria": [
                        f"`{pkg_name}` is removed from package.json",
                        "Replacement package is installed and tested",
                        "All tests pass after migration",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["deprecated", "outdated-dep", "nodejs"],
                        "effort_estimate": "m",
                    },
                }
                findings.append(finding)

    return findings


def scan_unpinned_versions(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect unpinned/wildcard version specifiers and missing lock files."""
    findings = []

    if project_type == "python":
        req_file = source_dir / "requirements.txt"
        pyproject_file = source_dir / "pyproject.toml"

        dep_file = None
        declared = []
        if req_file.exists():
            declared = parse_requirements_txt(req_file)
            dep_file = "requirements.txt"
        elif pyproject_file.exists():
            declared = parse_pyproject_toml(pyproject_file)
            dep_file = "pyproject.toml"

        if dep_file and declared:
            unpinned = []
            for pkg_name, version_spec in declared:
                spec = version_spec.strip()
                if not spec:
                    unpinned.append((pkg_name, "no version specified"))
                elif spec in ("*", "latest", "any"):
                    unpinned.append((pkg_name, f"wildcard: {spec}"))
                elif re.match(r"^[>~^]", spec) and "==" not in spec:
                    # Range specifier without exact pin
                    unpinned.append((pkg_name, f"range: {spec}"))

            if verbose:
                print(f"[dep-scan:verbose] Unpinned Python deps: {[p for p, _ in unpinned]}", file=sys.stderr)

            if unpinned and severity_meets_threshold("medium", severity_threshold):
                pkg_list = ", ".join(f"`{p}` ({spec})" for p, spec in unpinned[:8])
                finding = {
                    "id": next_finding_id(),
                    "dimension": "dependencies",
                    "category": "missing-dep",
                    "severity": "medium",
                    "owning_agent": "dependency-manager",
                    "fallback_agent": "backend-developer",
                    "file_paths": [dep_file],
                    "description": (
                        f"Unpinned production dependencies: {len(unpinned)} package(s) in "
                        f"{dep_file} use range or wildcard version specifiers: {pkg_list}. "
                        "Unpinned versions cause non-reproducible builds and silent breakage "
                        "when a transitive dependency releases a breaking change."
                    ),
                    "suggested_fix": (
                        "Pin exact versions in production dependency files using `==`. "
                        "Use `pip freeze > requirements.txt` to capture current pinned versions, "
                        "or add a `poetry.lock` / `Pipfile.lock` for reproducible installs. "
                        "Use range specifiers only in library packages, not applications."
                    ),
                    "acceptance_criteria": [
                        "All production dependencies use `==` exact version pins or a lock file",
                        "A lock file (poetry.lock, Pipfile.lock, or requirements.lock) is committed",
                        "CI installs from the lock file, not from loosely-specified versions",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["unpinned", "dependencies", "reproducibility"],
                        "effort_estimate": "s",
                    },
                }
                findings.append(finding)

        # Check for missing lock file
        has_lock = check_lock_file(source_dir, "python")
        if not has_lock and dep_file and severity_meets_threshold("medium", severity_threshold):
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "missing-dep",
                "severity": "medium",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": [dep_file],
                "description": (
                    "Missing lock file: no poetry.lock, Pipfile.lock, or requirements.lock found. "
                    "Without a lock file, `pip install` resolves to the latest compatible versions "
                    "at install time, causing non-reproducible builds and CI/CD flakiness."
                ),
                "suggested_fix": (
                    "Generate and commit a lock file: "
                    "`pip freeze > requirements.lock` (simple), "
                    "`poetry lock` (Poetry), or "
                    "`pipenv lock` (Pipenv). "
                    "Add the lock file to version control and use it in CI: `pip install -r requirements.lock`."
                ),
                "acceptance_criteria": [
                    "A lock file is committed to version control",
                    "CI uses the lock file for reproducible installs",
                    "Lock file is updated when dependencies change",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["lock-file", "dependencies", "reproducibility"],
                    "effort_estimate": "xs",
                },
            }
            findings.append(finding)

    elif project_type == "nodejs":
        pkg_file = source_dir / "package.json"
        if not pkg_file.exists():
            return findings

        deps, dev_deps = parse_package_json(pkg_file)
        unpinned = []

        for pkg_name, version_spec in {**deps, **dev_deps}.items():
            spec = version_spec.strip()
            if not spec or spec in ("*", "latest", "x"):
                unpinned.append((pkg_name, f"unpinned: {spec!r}"))
            elif spec.startswith("^") or spec.startswith("~"):
                unpinned.append((pkg_name, f"range: {spec}"))

        if verbose:
            print(f"[dep-scan:verbose] Unpinned Node deps: {[p for p, _ in unpinned]}", file=sys.stderr)

        if unpinned and severity_meets_threshold("low", severity_threshold):
            # For npm, ^ is common and low severity; only warn if many or in production
            prod_unpinned = [(p, s) for p, s in unpinned if p in deps]
            sev = "medium" if prod_unpinned else "low"
            if severity_meets_threshold(sev, severity_threshold):
                pkg_list = ", ".join(f"`{p}` ({spec})" for p, spec in unpinned[:8])
                finding = {
                    "id": next_finding_id(),
                    "dimension": "dependencies",
                    "category": "missing-dep",
                    "severity": sev,
                    "owning_agent": "dependency-manager",
                    "fallback_agent": "backend-developer",
                    "file_paths": ["package.json"],
                    "description": (
                        f"Unpinned npm dependencies: {len(unpinned)} package(s) use range/wildcard "
                        f"version specifiers: {pkg_list}. "
                        "Range specifiers (`^`, `~`) allow automatic minor/patch upgrades "
                        "that can introduce breaking changes silently."
                    ),
                    "suggested_fix": (
                        "Ensure a lock file (package-lock.json, yarn.lock, or pnpm-lock.yaml) "
                        "is committed and used in CI. "
                        "For critical production packages, consider pinning exact versions. "
                        "Run `npm ci` in CI (not `npm install`) to use the lock file."
                    ),
                    "acceptance_criteria": [
                        "A lock file is committed and up to date",
                        "CI uses `npm ci` for reproducible installs",
                        "Version bumps are intentional (via Dependabot or manual PRs)",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["unpinned", "dependencies", "nodejs"],
                        "effort_estimate": "xs",
                    },
                }
                findings.append(finding)

        # Check for missing lock file
        has_lock = check_lock_file(source_dir, "nodejs")
        if not has_lock and severity_meets_threshold("high", severity_threshold):
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "missing-dep",
                "severity": "high",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": ["package.json"],
                "description": (
                    "Missing Node.js lock file: no package-lock.json, yarn.lock, or pnpm-lock.yaml "
                    "found. Without a lock file, `npm install` resolves to different versions "
                    "on different machines/CI runs, causing non-reproducible builds."
                ),
                "suggested_fix": (
                    "Generate and commit a lock file: "
                    "`npm install` (creates package-lock.json), "
                    "`yarn install` (creates yarn.lock), or "
                    "`pnpm install` (creates pnpm-lock.yaml). "
                    "Add the lock file to .gitignore exclusion (ensure it is NOT ignored)."
                ),
                "acceptance_criteria": [
                    "A lock file is present and committed",
                    "CI uses `npm ci` / `yarn install --frozen-lockfile` for reproducible installs",
                    "Lock file is updated in PRs when package.json changes",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["lock-file", "dependencies", "nodejs"],
                    "effort_estimate": "xs",
                },
            }
            findings.append(finding)

    return findings


def scan_duplicate_purpose_deps(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect multiple packages serving the same function."""
    findings = []

    if project_type == "python":
        req_file = source_dir / "requirements.txt"
        pyproject_file = source_dir / "pyproject.toml"

        declared = []
        dep_file = None
        if req_file.exists():
            declared = parse_requirements_txt(req_file)
            dep_file = "requirements.txt"
        elif pyproject_file.exists():
            declared = parse_pyproject_toml(pyproject_file)
            dep_file = "pyproject.toml"

        if not declared or not dep_file:
            return findings

        declared_names = {normalize_package_name(p) for p, _ in declared}
        groups = DUPLICATE_PURPOSE_GROUPS_PYTHON

    elif project_type == "nodejs":
        pkg_file = source_dir / "package.json"
        if not pkg_file.exists():
            return findings

        deps, dev_deps = parse_package_json(pkg_file)
        declared_names = set({**deps, **dev_deps}.keys())
        dep_file = "package.json"
        groups = DUPLICATE_PURPOSE_GROUPS_NODE
    else:
        return findings

    for group in groups:
        purpose = group["purpose"]
        packages = group["packages"]
        present = [p for p in packages if p in declared_names]

        if len(present) >= 2:
            if verbose:
                print(f"[dep-scan:verbose] Duplicate {purpose}: {present}", file=sys.stderr)

            if not severity_meets_threshold("medium", severity_threshold):
                continue

            pkg_list = ", ".join(f"`{p}`" for p in present)
            finding = {
                "id": next_finding_id(),
                "dimension": "dependencies",
                "category": "unused-dep",
                "severity": "medium",
                "owning_agent": "dependency-manager",
                "fallback_agent": "backend-developer",
                "file_paths": [dep_file],
                "description": (
                    f"Duplicate-purpose dependencies: {len(present)} packages serving as "
                    f"'{purpose}': {pkg_list}. "
                    "Multiple packages for the same purpose increase bundle size, create "
                    "inconsistent patterns in the codebase, and complicate maintenance."
                ),
                "suggested_fix": (
                    f"Standardize on one '{purpose}' package. "
                    "Audit usage of each: grep the codebase to see which is used more, "
                    "then migrate all usages to the chosen package and remove the others. "
                    f"Choices: {pkg_list}."
                ),
                "acceptance_criteria": [
                    f"Only one '{purpose}' package remains in {dep_file}",
                    "All usages in source code use the chosen package consistently",
                    "Removed packages are uninstalled and lock file updated",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["duplicate", "dependencies", "dedup"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    return findings


# ─── Report ───────────────────────────────────────────────────────────────────

def print_summary(findings: List[dict]) -> None:
    """Print a human-readable summary to stderr."""
    total = len(findings)
    by_severity = defaultdict(int)
    by_category = defaultdict(int)
    for f in findings:
        by_severity[f["severity"]] += 1
        by_category[f["category"]] += 1

    print("", file=sys.stderr)
    print("┌─────────────────────────────────────────────┐", file=sys.stderr)
    print("│         Dependency Scan Summary             │", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    print(f"│  Total findings:  {total:<26}│", file=sys.stderr)
    print(f"│  🔴 Critical:     {by_severity['critical']:<26}│", file=sys.stderr)
    print(f"│  🟠 High:         {by_severity['high']:<26}│", file=sys.stderr)
    print(f"│  🟡 Medium:       {by_severity['medium']:<26}│", file=sys.stderr)
    print(f"│  🟢 Low:          {by_severity['low']:<26}│", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    print("│  By category:                               │", file=sys.stderr)
    for cat, count in sorted(by_category.items()):
        print(f"│    {cat:<20} {count:<22}│", file=sys.stderr)
    print("└─────────────────────────────────────────────┘", file=sys.stderr)


# ─── Main ────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Dependency scanner: unused, deprecated, unpinned, duplicate-purpose packages"
    )
    parser.add_argument("--source-dir", default=".", help="Source directory to scan")
    parser.add_argument("--output-file", default=".refactor/dep-findings.json")
    parser.add_argument(
        "--categories",
        default="unused,deprecated,unpinned,duplicate",
        help="Comma-separated list of categories to scan",
    )
    parser.add_argument(
        "--severity-threshold",
        default="low",
        choices=["critical", "high", "medium", "low"],
    )
    parser.add_argument("--format", default="json", choices=["json", "summary"])
    parser.add_argument(
        "--project-type",
        default="auto",
        choices=["python", "nodejs", "auto"],
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    categories = set(args.categories.split(","))

    print(f"[dep-scan] Dependency scanner v{SCANNER_VERSION}", file=sys.stderr)
    print(f"[dep-scan]   Source dir: {source_dir}", file=sys.stderr)
    print(f"[dep-scan]   Categories: {args.categories}", file=sys.stderr)

    if args.dry_run:
        print(f"[dep-scan] DRY-RUN: would scan {source_dir}", file=sys.stderr)
        print(f"[dep-scan] DRY-RUN: output → {args.output_file}", file=sys.stderr)
        sys.exit(0)

    # Detect project type
    project_type = args.project_type
    if project_type == "auto":
        project_type = detect_project_type(source_dir)
    print(f"[dep-scan]   Project type: {project_type}", file=sys.stderr)

    all_findings: List[dict] = []

    if "unused" in categories:
        print("[dep-scan] Scanning unused dependencies...", file=sys.stderr)
        findings = scan_unused_deps(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[dep-scan]   unused: {len(findings)} finding(s)", file=sys.stderr)

    if "deprecated" in categories:
        print("[dep-scan] Scanning deprecated dependencies...", file=sys.stderr)
        findings = scan_deprecated_deps(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[dep-scan]   deprecated: {len(findings)} finding(s)", file=sys.stderr)

    if "unpinned" in categories:
        print("[dep-scan] Scanning unpinned versions...", file=sys.stderr)
        findings = scan_unpinned_versions(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[dep-scan]   unpinned: {len(findings)} finding(s)", file=sys.stderr)

    if "duplicate" in categories:
        print("[dep-scan] Scanning duplicate-purpose dependencies...", file=sys.stderr)
        findings = scan_duplicate_purpose_deps(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[dep-scan]   duplicate: {len(findings)} finding(s)", file=sys.stderr)

    # Re-index finding IDs sequentially
    for i, finding in enumerate(all_findings):
        finding["id"] = f"RF-{i + 1:03d}"

    # Output
    output_json = json.dumps(all_findings, indent=2)

    if args.format == "summary":
        print_summary(all_findings)

    output_file = Path(args.output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(output_json + "\n", encoding="utf-8")
    print(f"[dep-scan] Findings written to: {output_file}", file=sys.stderr)

    print_summary(all_findings)

    # Exit codes
    critical_count = sum(1 for f in all_findings if f["severity"] == "critical")
    high_count = sum(1 for f in all_findings if f["severity"] == "high")

    if critical_count > 0 or high_count > 0:
        sys.exit(2)
    elif all_findings:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
