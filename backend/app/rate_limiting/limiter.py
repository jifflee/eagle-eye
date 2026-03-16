"""Rate limiter — token bucket per connector with circuit breaker."""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)


@dataclass
class TokenBucket:
    """Token bucket rate limiter."""

    rate: float  # tokens per second
    max_tokens: float  # burst capacity
    tokens: float = 0.0
    last_refill: float = field(default_factory=time.monotonic)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock, repr=False)

    def __post_init__(self) -> None:
        self.tokens = self.max_tokens

    async def acquire(self, timeout: float = 30.0) -> bool:
        """Wait until a token is available, up to timeout seconds."""
        deadline = time.monotonic() + timeout

        while True:
            async with self._lock:
                self._refill()
                if self.tokens >= 1.0:
                    self.tokens -= 1.0
                    return True

            # Calculate wait time for next token
            wait = (1.0 - self.tokens) / self.rate if self.rate > 0 else 1.0
            if time.monotonic() + wait > deadline:
                return False
            await asyncio.sleep(min(wait, 0.5))

    def _refill(self) -> None:
        now = time.monotonic()
        elapsed = now - self.last_refill
        self.tokens = min(self.max_tokens, self.tokens + elapsed * self.rate)
        self.last_refill = now


@dataclass
class CircuitBreaker:
    """Circuit breaker — disables a connector after consecutive failures."""

    failure_threshold: int = 5
    reset_timeout: float = 300.0  # 5 minutes
    failure_count: int = 0
    last_failure: float = 0.0
    state: str = "closed"  # closed (ok), open (disabled), half_open (testing)

    def record_success(self) -> None:
        self.failure_count = 0
        self.state = "closed"

    def record_failure(self) -> None:
        self.failure_count += 1
        self.last_failure = time.monotonic()
        if self.failure_count >= self.failure_threshold:
            self.state = "open"
            logger.warning(
                "Circuit breaker OPEN after %d failures", self.failure_count
            )

    def is_available(self) -> bool:
        if self.state == "closed":
            return True
        if self.state == "open":
            elapsed = time.monotonic() - self.last_failure
            if elapsed >= self.reset_timeout:
                self.state = "half_open"
                return True
            return False
        # half_open — allow one request to test
        return True


class RateLimiter:
    """Manages rate limits and circuit breakers for all connectors."""

    def __init__(self) -> None:
        self._buckets: dict[str, TokenBucket] = {}
        self._breakers: dict[str, CircuitBreaker] = {}

    def configure(
        self,
        connector_name: str,
        requests_per_second: float = 1.0,
        burst_size: int = 5,
        failure_threshold: int = 5,
        reset_timeout: float = 300.0,
    ) -> None:
        """Configure rate limiting for a connector."""
        self._buckets[connector_name] = TokenBucket(
            rate=requests_per_second,
            max_tokens=float(burst_size),
        )
        self._breakers[connector_name] = CircuitBreaker(
            failure_threshold=failure_threshold,
            reset_timeout=reset_timeout,
        )

    async def acquire(self, connector_name: str, timeout: float = 30.0) -> bool:
        """Acquire permission to make a request.

        Returns False if rate limited or circuit breaker is open.
        """
        # Check circuit breaker
        breaker = self._breakers.get(connector_name)
        if breaker and not breaker.is_available():
            logger.debug("Circuit breaker open for %s", connector_name)
            return False

        # Check rate limit
        bucket = self._buckets.get(connector_name)
        if bucket:
            return await bucket.acquire(timeout)

        return True

    def record_success(self, connector_name: str) -> None:
        breaker = self._breakers.get(connector_name)
        if breaker:
            breaker.record_success()

    def record_failure(self, connector_name: str) -> None:
        breaker = self._breakers.get(connector_name)
        if breaker:
            breaker.record_failure()

    def is_available(self, connector_name: str) -> bool:
        breaker = self._breakers.get(connector_name)
        return breaker.is_available() if breaker else True

    def get_status(self, connector_name: str) -> dict:
        breaker = self._breakers.get(connector_name)
        bucket = self._buckets.get(connector_name)
        return {
            "circuit_breaker": breaker.state if breaker else "unknown",
            "failure_count": breaker.failure_count if breaker else 0,
            "tokens_available": bucket.tokens if bucket else 0,
        }


# Global rate limiter instance
rate_limiter = RateLimiter()
