"""Separate connector constructor inputs from service-owned runtime state."""

from __future__ import annotations

from typing import Any

# These values live beside a connector's vendor configuration in Postgres, but
# are consumed by the scheduler/API rather than by the connector constructor.
# Keeping one shared set prevents the live-test and polling paths from drifting
# and passing internal state as an unexpected keyword argument.
NON_CONSTRUCTOR_CONFIG_KEYS = frozenset(
    {
        "poll_interval_seconds",
        "checkpoint",
        "filter_rules",
        "managed_identity_verification",
    }
)


def connector_constructor_kwargs(connector_config: dict[str, Any]) -> dict[str, Any]:
    """Return only vendor/runtime arguments accepted by connector classes."""
    return {key: value for key, value in connector_config.items() if key not in NON_CONSTRUCTOR_CONFIG_KEYS}


__all__ = ["NON_CONSTRUCTOR_CONFIG_KEYS", "connector_constructor_kwargs"]
