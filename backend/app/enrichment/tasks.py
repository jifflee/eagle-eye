"""Celery tasks for enrichment pipeline.

Wraps the async orchestrator in synchronous Celery tasks with
proper state tracking for pause/resume/cancel.
"""

from __future__ import annotations

import asyncio
import logging
from uuid import UUID

from celery import shared_task
from celery.exceptions import SoftTimeLimitExceeded

logger = logging.getLogger(__name__)

# Track Celery task IDs per investigation for control
_investigation_tasks: dict[str, str] = {}


def get_task_id(investigation_id: str) -> str | None:
    """Get the Celery task ID for an investigation."""
    return _investigation_tasks.get(investigation_id)


@shared_task(bind=True, name="enrichment.run_pipeline", max_retries=1)
def run_enrichment_task(
    self,
    investigation_id: str,
    address: dict[str, str],
    root_entity_id: str,
    tier1_only: bool = False,
) -> dict[str, str]:
    """Celery task that runs the full enrichment pipeline.

    This wraps the async orchestrator in a sync Celery task context.
    """
    # Register task ID for control
    _investigation_tasks[investigation_id] = self.request.id

    logger.info(
        "Celery task %s starting enrichment for %s",
        self.request.id, investigation_id,
    )

    try:
        # Run the async enrichment in a new event loop
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            from app.enrichment.orchestrator import _do_enrichment
            loop.run_until_complete(
                _do_enrichment(
                    UUID(investigation_id), address, root_entity_id, tier1_only
                )
            )
        finally:
            loop.close()

        logger.info("Celery task completed for %s", investigation_id)
        return {"status": "complete", "investigation_id": investigation_id}

    except SoftTimeLimitExceeded:
        logger.warning("Enrichment task timed out for %s", investigation_id)
        _mark_failed(investigation_id, "Task timed out after 10 minutes")
        return {"status": "timeout", "investigation_id": investigation_id}

    except Exception as e:
        logger.exception("Enrichment task failed for %s", investigation_id)
        _mark_failed(investigation_id, str(e))
        raise  # Let Celery handle retry

    finally:
        _investigation_tasks.pop(investigation_id, None)


def _mark_failed(investigation_id: str, error: str) -> None:
    """Mark investigation as failed in PostgreSQL."""
    try:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        from app.database import postgres_client
        loop.run_until_complete(
            postgres_client.update_investigation(UUID(investigation_id), status="failed")
        )
        loop.close()
    except Exception:
        pass
