"""Celery application configuration for background task processing."""

from celery import Celery

from app.config import settings

celery_app = Celery(
    "eagle_eye",
    broker=settings.redis_url,
    backend=settings.redis_url,
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    task_track_started=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
    # Soft time limit: 10 minutes per task, hard limit: 12 minutes
    task_soft_time_limit=600,
    task_time_limit=720,
    # Result expiry: 1 hour
    result_expires=3600,
)

# Auto-discover tasks from the enrichment module
celery_app.autodiscover_tasks(["app.enrichment"])
