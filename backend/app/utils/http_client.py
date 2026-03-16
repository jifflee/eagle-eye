"""Shared async HTTP client with retries, timeouts, and User-Agent management."""

from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)

USER_AGENT = "EagleEye/0.1.0 (OSINT Platform; https://github.com/jifflee/eagle-eye)"

_client: httpx.AsyncClient | None = None


def get_client() -> httpx.AsyncClient:
    """Get or create the shared HTTP client."""
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient(
            timeout=httpx.Timeout(30.0, connect=10.0),
            follow_redirects=True,
            headers={"User-Agent": USER_AGENT},
            limits=httpx.Limits(max_connections=50, max_keepalive_connections=20),
        )
    return _client


async def close_client() -> None:
    """Close the HTTP client."""
    global _client
    if _client is not None and not _client.is_closed:
        await _client.aclose()
        _client = None


async def fetch_json(
    url: str,
    params: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    method: str = "GET",
    json_body: dict | None = None,
    retries: int = 3,
    backoff_base: float = 1.0,
) -> dict[str, Any]:
    """Fetch JSON from a URL with automatic retries and backoff.

    Args:
        url: The URL to fetch.
        params: Query parameters.
        headers: Additional headers.
        method: HTTP method (GET, POST).
        json_body: JSON body for POST requests.
        retries: Number of retry attempts.
        backoff_base: Base delay for exponential backoff (seconds).

    Returns:
        Parsed JSON response as dict.

    Raises:
        httpx.HTTPStatusError: If all retries fail.
    """
    import asyncio

    client = get_client()
    last_error: Exception | None = None

    for attempt in range(retries):
        try:
            if method.upper() == "GET":
                response = await client.get(url, params=params, headers=headers)
            else:
                response = await client.post(
                    url, params=params, headers=headers, json=json_body
                )

            response.raise_for_status()
            return response.json()

        except httpx.HTTPStatusError as e:
            last_error = e
            status = e.response.status_code

            # Don't retry client errors (except 429)
            if 400 <= status < 500 and status != 429:
                logger.warning("Client error %d from %s: %s", status, url, e)
                raise

            # Rate limited — respect Retry-After header
            if status == 429:
                retry_after = e.response.headers.get("Retry-After")
                wait = float(retry_after) if retry_after else backoff_base * (2**attempt)
                logger.info("Rate limited by %s, waiting %.1fs", url, wait)
                await asyncio.sleep(wait)
                continue

            # Server error — retry with backoff
            wait = backoff_base * (2**attempt)
            logger.warning(
                "Server error %d from %s (attempt %d/%d), retrying in %.1fs",
                status, url, attempt + 1, retries, wait,
            )
            await asyncio.sleep(wait)

        except (httpx.ConnectError, httpx.ReadTimeout) as e:
            last_error = e
            wait = backoff_base * (2**attempt)
            logger.warning(
                "Connection error from %s (attempt %d/%d): %s, retrying in %.1fs",
                url, attempt + 1, retries, e, wait,
            )
            await asyncio.sleep(wait)

    # All retries exhausted
    if last_error:
        raise last_error
    raise httpx.ConnectError(f"Failed to fetch {url} after {retries} retries")


async def fetch_text(
    url: str,
    params: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> str:
    """Fetch raw text from a URL (for HTML scraping)."""
    client = get_client()
    response = await client.get(url, params=params, headers=headers)
    response.raise_for_status()
    return response.text
