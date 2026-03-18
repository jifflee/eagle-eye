import logging
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.rate_limit import RateLimitMiddleware
from app.api.v1 import address, auth_routes, enrichment, graph, search
from app.config import settings
from app.database import neo4j_driver, postgres_client

logging.basicConfig(
    level=getattr(logging, settings.log_level),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Startup and shutdown events."""
    logger.info("Eagle Eye starting up...")
    yield
    logger.info("Eagle Eye shutting down...")
    await neo4j_driver.close_driver()
    await postgres_client.close_pool()


app = FastAPI(
    title="Eagle Eye",
    description="Open Source Intelligence (OSINT) platform for address-based profiling",
    version="0.1.0",
    lifespan=lifespan,
)

cors_origins = [o.strip() for o in settings.backend_cors_origins.split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=cors_origins,
    allow_origin_regex=r"^http://localhost:\d+$",  # Allow any localhost port
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_middleware(RateLimitMiddleware)

app.include_router(auth_routes.router, prefix="/api/v1", tags=["auth"])
app.include_router(address.router, prefix="/api/v1", tags=["investigation"])
app.include_router(graph.router, prefix="/api/v1", tags=["graph"])
app.include_router(search.router, prefix="/api/v1", tags=["search"])
app.include_router(enrichment.router, prefix="/api/v1", tags=["enrichment"])


@app.get("/health")
async def health_check() -> dict:
    """Check connectivity to all backing services."""
    neo4j_ok = await neo4j_driver.check_health()
    postgres_ok = await postgres_client.check_health()

    status = "ok" if (neo4j_ok and postgres_ok) else "degraded"

    return {
        "status": status,
        "services": {
            "neo4j": "connected" if neo4j_ok else "unavailable",
            "postgres": "connected" if postgres_ok else "unavailable",
        },
    }


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "Not found"})


@app.exception_handler(500)
async def internal_error_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.error("Internal server error", exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
