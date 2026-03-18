"""Per-user API rate limiting middleware using Redis."""

from __future__ import annotations

import logging
import time
from typing import Callable

from fastapi import Request, Response
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import JSONResponse

logger = logging.getLogger(__name__)

# Rate limit config
DEFAULT_RATE_LIMIT = 100  # requests per minute
INVESTIGATION_RATE_LIMIT = 10  # investigations per minute

# Paths with stricter limits
STRICT_PATHS = {"/api/v1/investigation": INVESTIGATION_RATE_LIMIT}


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Redis-backed per-IP rate limiter.

    Uses a sliding window counter stored in Redis.
    Falls back to no limiting if Redis is unavailable.
    """

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        # Skip rate limiting for health checks and docs
        if request.url.path in ("/health", "/docs", "/openapi.json", "/redoc"):
            return await call_next(request)

        # Determine rate limit for this path
        limit = DEFAULT_RATE_LIMIT
        for path_prefix, path_limit in STRICT_PATHS.items():
            if request.url.path.startswith(path_prefix) and request.method == "POST":
                limit = path_limit
                break

        # Get client identifier (IP or authenticated user)
        client_id = _get_client_id(request)
        window_key = f"eagle_eye:ratelimit:{client_id}:{int(time.time()) // 60}"

        try:
            import redis.asyncio as aioredis
            from app.config import settings

            r = aioredis.from_url(settings.redis_url, decode_responses=True)
            pipe = r.pipeline()
            pipe.incr(window_key)
            pipe.expire(window_key, 120)  # 2 minute TTL
            results = await pipe.execute()
            await r.aclose()

            current_count = results[0]

            if current_count > limit:
                retry_after = 60 - (int(time.time()) % 60)
                return JSONResponse(
                    status_code=429,
                    content={
                        "detail": "Rate limit exceeded",
                        "limit": limit,
                        "retry_after": retry_after,
                    },
                    headers={
                        "Retry-After": str(retry_after),
                        "X-RateLimit-Limit": str(limit),
                        "X-RateLimit-Remaining": "0",
                    },
                )

            response = await call_next(request)
            response.headers["X-RateLimit-Limit"] = str(limit)
            response.headers["X-RateLimit-Remaining"] = str(max(0, limit - current_count))
            return response

        except Exception:
            # Redis unavailable — allow request (fail open)
            return await call_next(request)


def _get_client_id(request: Request) -> str:
    """Get client identifier from auth token or IP address."""
    # Try JWT user ID from Authorization header
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Bearer "):
        try:
            import jwt
            from app.config import settings
            payload = jwt.decode(
                auth[7:], settings.jwt_secret, algorithms=["HS256"]
            )
            return f"user:{payload.get('sub', 'unknown')}"
        except Exception:
            pass

    # Fallback to IP address
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return f"ip:{forwarded.split(',')[0].strip()}"
    return f"ip:{request.client.host if request.client else 'unknown'}"
