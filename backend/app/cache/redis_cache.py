"""Cache layer — Redis-backed with TTL per source, local fallback."""

from __future__ import annotations

import hashlib
import json
import logging
from typing import Any

import redis.asyncio as redis

from app.config import settings

logger = logging.getLogger(__name__)

_redis: redis.Redis | None = None

# TTL per connector (seconds)
DEFAULT_TTLS: dict[str, int] = {
    "census_geocoder": 86400 * 30,   # 30 days — addresses don't move
    "census_data": 86400 * 30,       # 30 days — census data is annual
    "fbi_crime": 86400,              # 1 day — crime data updates daily
    "epa_echo": 86400 * 7,           # 7 days
    "sec_edgar": 86400 * 7,          # 7 days
    "courtlistener": 86400 * 3,      # 3 days
    "openfema": 86400 * 30,          # 30 days
    "nominatim": 86400 * 30,         # 30 days
    "nhtsa_vpic": 86400 * 30,        # 30 days — VIN data is static
    "gwinnett_parcel": 86400 * 7,    # 7 days
    "ga_secretary_state": 86400 * 7, # 7 days
    "gwinnett_courts": 86400,        # 1 day
    "qpublic": 86400 * 7,            # 7 days
    "gsccca_deeds": 86400 * 7,       # 7 days
    "gbi_sex_offender": 86400,       # 1 day
    "gwinnett_sheriff_jail": 3600,   # 1 hour — inmate data changes frequently
}

DEFAULT_TTL = 86400  # 1 day fallback


async def get_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        _redis = redis.from_url(settings.redis_url, decode_responses=True)
    return _redis


async def close_redis() -> None:
    global _redis
    if _redis is not None:
        await _redis.aclose()
        _redis = None


def _cache_key(connector_name: str, query_params: dict[str, Any]) -> str:
    """Generate a deterministic cache key."""
    param_str = json.dumps(query_params, sort_keys=True, default=str)
    param_hash = hashlib.sha256(param_str.encode()).hexdigest()[:16]
    return f"eagle_eye:cache:{connector_name}:{param_hash}"


async def get_cached(
    connector_name: str,
    query_params: dict[str, Any],
) -> dict[str, Any] | None:
    """Get cached response for a connector query.

    Returns None on cache miss or if Redis is unavailable.
    """
    try:
        r = await get_redis()
        key = _cache_key(connector_name, query_params)
        data = await r.get(key)
        if data:
            logger.debug("Cache HIT: %s", key)
            return json.loads(data)
        logger.debug("Cache MISS: %s", key)
        return None
    except Exception:
        logger.debug("Redis unavailable for cache read")
        return None


async def set_cached(
    connector_name: str,
    query_params: dict[str, Any],
    response_data: dict[str, Any],
    ttl: int | None = None,
) -> None:
    """Cache a connector response with TTL.

    Silently fails if Redis is unavailable.
    """
    try:
        r = await get_redis()
        key = _cache_key(connector_name, query_params)
        if ttl is None:
            ttl = DEFAULT_TTLS.get(connector_name, DEFAULT_TTL)
        await r.setex(key, ttl, json.dumps(response_data, default=str))
        logger.debug("Cache SET: %s (TTL=%ds)", key, ttl)
    except Exception:
        logger.debug("Redis unavailable for cache write")


async def invalidate(
    connector_name: str,
    query_params: dict[str, Any] | None = None,
) -> None:
    """Invalidate cached data for a connector.

    If query_params is None, invalidates all cached data for the connector.
    """
    try:
        r = await get_redis()
        if query_params:
            key = _cache_key(connector_name, query_params)
            await r.delete(key)
        else:
            # Delete all keys for this connector
            pattern = f"eagle_eye:cache:{connector_name}:*"
            async for key in r.scan_iter(match=pattern, count=100):
                await r.delete(key)
    except Exception:
        logger.debug("Redis unavailable for cache invalidation")


async def get_cache_stats() -> dict[str, Any]:
    """Get cache statistics."""
    try:
        r = await get_redis()
        info = await r.info("memory")
        key_count = 0
        async for _ in r.scan_iter(match="eagle_eye:cache:*", count=100):
            key_count += 1
        return {
            "total_keys": key_count,
            "memory_used": info.get("used_memory_human", "unknown"),
        }
    except Exception:
        return {"total_keys": 0, "memory_used": "unavailable"}
