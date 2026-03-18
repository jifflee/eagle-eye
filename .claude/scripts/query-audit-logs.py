#!/usr/bin/env python3
"""
CLI utility for querying MCP audit logs.

Usage:
    python scripts/query-audit-logs.py --help
    python scripts/query-audit-logs.py --agent agent-name
    python scripts/query-audit-logs.py --risk-level high
    python scripts/query-audit-logs.py --decision deny
    python scripts/query-audit-logs.py --stats
"""

import argparse
import json
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent))

from src.mcp.audit_logger import AuditLogger, LogRotationPolicy


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Query MCP Security Server audit logs"
    )

    parser.add_argument(
        "--log-dir",
        type=str,
        default="~/.claude-agent/security-audit",
        help="Path to audit log directory (default: ~/.claude-agent/security-audit)"
    )

    parser.add_argument(
        "--agent",
        type=str,
        help="Filter by agent name"
    )

    parser.add_argument(
        "--risk-level",
        type=str,
        choices=["low", "medium", "high", "critical"],
        help="Filter by risk level"
    )

    parser.add_argument(
        "--decision",
        type=str,
        choices=["approve", "deny"],
        help="Filter by decision"
    )

    parser.add_argument(
        "--policy",
        type=str,
        help="Filter by policy ID"
    )

    parser.add_argument(
        "--limit",
        type=int,
        help="Maximum number of results to return"
    )

    parser.add_argument(
        "--days",
        type=int,
        help="Only show logs from the last N days"
    )

    parser.add_argument(
        "--stats",
        action="store_true",
        help="Show audit log statistics instead of entries"
    )

    parser.add_argument(
        "--json",
        action="store_true",
        help="Output in JSON format"
    )

    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Show detailed information"
    )

    return parser.parse_args()


def format_entry(entry: dict, verbose: bool = False) -> str:
    """Format a log entry for display."""
    timestamp = entry.get("timestamp", "")
    agent = entry.get("agent_name", "unknown")
    action = entry.get("action", "")
    decision = entry.get("decision", "")
    risk = entry.get("risk_level", "")
    policy = entry.get("policy_id", "")

    # Color coding for decisions
    decision_color = "\033[92m" if decision == "approve" else "\033[91m"  # Green/Red
    reset_color = "\033[0m"

    if verbose:
        reason = entry.get("reason", "")
        exec_time = entry.get("execution_time_ms", "N/A")
        return (
            f"\n{timestamp}\n"
            f"  Agent:     {agent}\n"
            f"  Action:    {action}\n"
            f"  Decision:  {decision_color}{decision}{reset_color}\n"
            f"  Risk:      {risk}\n"
            f"  Policy:    {policy}\n"
            f"  Exec Time: {exec_time} ms\n"
            f"  Reason:    {reason}\n"
        )
    else:
        return (
            f"{timestamp[:19]} | {agent:15} | {decision_color}{decision:7}{reset_color} | "
            f"{risk:8} | {action[:50]}"
        )


def format_statistics(stats: dict) -> str:
    """Format statistics for display."""
    output = []

    output.append("\n=== Audit Log Statistics ===\n")
    output.append(f"Total Events: {stats['total_events']}\n")

    if stats.get("time_range"):
        output.append(f"Time Range: {stats['time_range'].get('start')} to {stats['time_range'].get('end')}\n")

    output.append("\n--- Decisions ---")
    for decision, count in stats.get("by_decision", {}).items():
        percentage = (count / stats["total_events"] * 100) if stats["total_events"] > 0 else 0
        output.append(f"  {decision:10}: {count:5} ({percentage:.1f}%)")

    output.append("\n--- Risk Levels ---")
    for risk, count in stats.get("by_risk_level", {}).items():
        percentage = (count / stats["total_events"] * 100) if stats["total_events"] > 0 else 0
        output.append(f"  {risk:10}: {count:5} ({percentage:.1f}%)")

    output.append("\n--- Top Agents ---")
    agents = sorted(
        stats.get("by_agent", {}).items(),
        key=lambda x: x[1],
        reverse=True
    )[:10]
    for agent, count in agents:
        percentage = (count / stats["total_events"] * 100) if stats["total_events"] > 0 else 0
        output.append(f"  {agent:20}: {count:5} ({percentage:.1f}%)")

    output.append("\n--- Top Policies ---")
    policies = sorted(
        stats.get("by_policy", {}).items(),
        key=lambda x: x[1],
        reverse=True
    )[:10]
    for policy, count in policies:
        percentage = (count / stats["total_events"] * 100) if stats["total_events"] > 0 else 0
        output.append(f"  {policy:20}: {count:5} ({percentage:.1f}%)")

    output.append("")

    return "\n".join(output)


def main():
    """Main entry point."""
    args = parse_args()

    # Initialize audit logger (read-only mode)
    log_dir = Path(args.log_dir).expanduser()

    if not log_dir.exists():
        print(f"Error: Audit log directory not found: {log_dir}", file=sys.stderr)
        sys.exit(1)

    audit_logger = AuditLogger(
        log_dir=log_dir,
        rotation_policy=LogRotationPolicy.SIZE_BASED
    )

    # Show statistics
    if args.stats:
        start_time = None
        if args.days:
            start_time = datetime.now() - timedelta(days=args.days)

        stats = audit_logger.get_statistics(start_time=start_time)

        if args.json:
            print(json.dumps(stats, indent=2))
        else:
            print(format_statistics(stats))

        return

    # Query logs
    start_time = None
    if args.days:
        start_time = datetime.now() - timedelta(days=args.days)

    results = audit_logger.query_logs(
        start_time=start_time,
        agent_name=args.agent,
        risk_level=args.risk_level,
        decision=args.decision,
        policy_id=args.policy,
        limit=args.limit
    )

    # Output results
    if args.json:
        print(json.dumps(results, indent=2))
    else:
        if not results:
            print("No matching audit log entries found.")
            return

        print(f"\nFound {len(results)} matching entries:\n")

        if not args.verbose:
            # Print header
            print(f"{'Timestamp':19} | {'Agent':15} | {'Decision':7} | {'Risk':8} | {'Action'}")
            print("-" * 100)

        for entry in results:
            print(format_entry(entry, verbose=args.verbose))


if __name__ == "__main__":
    main()
