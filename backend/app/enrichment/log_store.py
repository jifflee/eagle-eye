"""In-memory enrichment log store for real-time UI streaming.

Stores the last N log entries per investigation so the frontend
can poll for live enrichment activity without checking Docker logs.
"""

from __future__ import annotations

import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any

MAX_ENTRIES_PER_INVESTIGATION = 200

_logs: dict[str, deque] = {}


@dataclass
class LogEntry:
    timestamp: float
    level: str
    connector: str
    message: str
    entities_found: int = 0
    duration_ms: int = 0

    def to_dict(self) -> dict[str, Any]:
        return {
            "timestamp": self.timestamp,
            "time": time.strftime("%H:%M:%S", time.localtime(self.timestamp)),
            "level": self.level,
            "connector": self.connector,
            "message": self.message,
            "entities_found": self.entities_found,
            "duration_ms": self.duration_ms,
        }


def log(investigation_id: str, level: str, connector: str, message: str, **kwargs: Any) -> None:
    """Add a log entry for an investigation."""
    if investigation_id not in _logs:
        _logs[investigation_id] = deque(maxlen=MAX_ENTRIES_PER_INVESTIGATION)

    _logs[investigation_id].append(
        LogEntry(
            timestamp=time.time(),
            level=level,
            connector=connector,
            message=message,
            **kwargs,
        )
    )


def get_logs(investigation_id: str, since: float = 0, limit: int = 50) -> list[dict[str, Any]]:
    """Get log entries for an investigation, optionally filtered by timestamp."""
    entries = _logs.get(investigation_id, deque())
    filtered = [e for e in entries if e.timestamp > since]
    return [e.to_dict() for e in filtered[-limit:]]


def clear_logs(investigation_id: str) -> None:
    """Clear logs for an investigation."""
    _logs.pop(investigation_id, None)
