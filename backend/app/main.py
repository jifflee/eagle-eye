import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.v1 import address, enrichment, graph, search
from app.config import settings

logging.basicConfig(
    level=getattr(logging, settings.log_level),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Eagle Eye",
    description="Open Source Intelligence (OSINT) platform for address-based profiling",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.backend_cors_origins.split(","),
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(address.router, prefix="/api/v1", tags=["investigation"])
app.include_router(graph.router, prefix="/api/v1", tags=["graph"])
app.include_router(search.router, prefix="/api/v1", tags=["search"])
app.include_router(enrichment.router, prefix="/api/v1", tags=["enrichment"])


@app.get("/health")
async def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.exception_handler(404)
async def not_found_handler(request: Request, exc: Exception) -> JSONResponse:
    return JSONResponse(status_code=404, content={"detail": "Not found"})


@app.exception_handler(500)
async def internal_error_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.error("Internal server error", exc_info=exc)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})
