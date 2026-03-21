"""Shared async HTTP client with retries, timeouts, and User-Agent management."""

from __future__ import annotations

import logging
import random
from typing import Any

import httpx

logger = logging.getLogger(__name__)

USER_AGENT = "EagleEye/0.1.0 (OSINT Platform; https://github.com/jifflee/eagle-eye)"

# Rotating browser-like User-Agents for scraping connectors that block bots.
BROWSER_USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
]


def get_browser_headers(referer: str | None = None) -> dict[str, str]:
    """Return browser-like headers to avoid anti-scraping 403 blocks."""
    headers = {
        "User-Agent": random.choice(BROWSER_USER_AGENTS),
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9",
        "Accept-Encoding": "gzip, deflate, br",
        "Connection": "keep-alive",
        "Upgrade-Insecure-Requests": "1",
    }
    if referer:
        headers["Referer"] = referer
    return headers

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
    retries: int = 3,
    backoff_base: float = 1.0,
) -> str:
    """Fetch raw text from a URL (for HTML scraping) with retries.

    Args:
        url: The URL to fetch.
        params: Query parameters.
        headers: Additional headers.
        retries: Number of retry attempts.
        backoff_base: Base delay for exponential backoff (seconds).

    Returns:
        Raw text response.

    Raises:
        httpx.HTTPStatusError: If all retries fail.
    """
    import asyncio

    client = get_client()
    last_error: Exception | None = None

    for attempt in range(retries):
        try:
            response = await client.get(url, params=params, headers=headers)
            response.raise_for_status()
            return response.text

        except httpx.HTTPStatusError as e:
            last_error = e
            status = e.response.status_code

            if 400 <= status < 500 and status not in (403, 429):
                raise

            # 403 may be anti-bot — retry with different headers
            if status == 403:
                wait = backoff_base * (2**attempt)
                logger.warning(
                    "Blocked (403) by %s (attempt %d/%d), retrying in %.1fs",
                    url, attempt + 1, retries, wait,
                )
                if headers and "User-Agent" in headers:
                    headers = {**headers, "User-Agent": random.choice(BROWSER_USER_AGENTS)}
                await asyncio.sleep(wait)
                continue

            if status == 429:
                retry_after = e.response.headers.get("Retry-After")
                wait = float(retry_after) if retry_after else backoff_base * (2**attempt)
                logger.info("Rate limited by %s, waiting %.1fs", url, wait)
                await asyncio.sleep(wait)
                continue

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

    if last_error:
        raise last_error
    raise httpx.ConnectError(f"Failed to fetch {url} after {retries} retries")
