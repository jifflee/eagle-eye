"""Connector registry — auto-discovers and manages connector plugins."""

from __future__ import annotations

import importlib
import inspect
import logging
import pkgutil
from typing import Any

from app.connectors.base import BaseConnector
from app.models.entities import EntityType

logger = logging.getLogger(__name__)

# Global registry of connector instances
_connectors: dict[str, BaseConnector] = {}
_initialized = False


def discover_connectors() -> dict[str, BaseConnector]:
    """Auto-discover all connector classes in tier1/, tier2/, tier3/ directories."""
    global _connectors, _initialized

    if _initialized:
        return _connectors

    tier_packages = [
        "app.connectors.tier1",
        "app.connectors.tier2",
        "app.connectors.tier3",
    ]

    for package_name in tier_packages:
        try:
            package = importlib.import_module(package_name)
        except ImportError:
            logger.debug("Package %s not found, skipping", package_name)
            continue

        if not hasattr(package, "__path__"):
            continue

        for _importer, module_name, _is_pkg in pkgutil.iter_modules(package.__path__):
            full_module_name = f"{package_name}.{module_name}"
            try:
                module = importlib.import_module(full_module_name)
            except Exception:
                logger.warning("Failed to import connector module: %s", full_module_name)
                continue

            # Find all BaseConnector subclasses in the module
            for _name, obj in inspect.getmembers(module, inspect.isclass):
                if (
                    issubclass(obj, BaseConnector)
                    and obj is not BaseConnector
                    and obj.name  # Must have a name set
                ):
                    try:
                        instance = obj()
                        _connectors[instance.name] = instance
                        logger.info(
                            "Registered connector: %s (tier %d)",
                            instance.name,
                            instance.tier,
                        )
                    except Exception:
                        logger.warning("Failed to instantiate connector: %s", obj.name)

    _initialized = True
    logger.info("Discovered %d connectors", len(_connectors))
    return _connectors


def get_connector(name: str) -> BaseConnector | None:
    """Get a connector by name."""
    connectors = discover_connectors()
    return connectors.get(name)


def get_all_connectors() -> dict[str, BaseConnector]:
    """Get all registered connectors."""
    return discover_connectors()


def get_connectors_for_entity(entity_type: EntityType) -> list[BaseConnector]:
    """Get all connectors that can discover from a given entity type."""
    connectors = discover_connectors()
    return [c for c in connectors.values() if c.can_discover_from(entity_type)]


def get_connectors_by_tier(tier: int) -> list[BaseConnector]:
    """Get all connectors in a specific tier."""
    connectors = discover_connectors()
    return [c for c in connectors.values() if c.tier == tier]


def reset_registry() -> None:
    """Reset the registry (for testing)."""
    global _connectors, _initialized
    _connectors = {}
    _initialized = False
