from __future__ import annotations

from app.models.connector import Connector
from app.services.playbook_step_dispatch import _operational_config as playbook_config
from app.services.siem_writeback import _operational_config as writeback_config


def test_sentinel_nonsecret_config_reaches_both_action_dispatch_paths() -> None:
    connector = Connector()
    connector.connector_config = {
        "auth_mode": "managed_identity",
        "subscription_id": "sub",
        "resource_group": "sentinel-rg",
        "workspace": "drydock-law",
        "poll_interval_seconds": 300,
    }
    expected = {
        "auth_mode": "managed_identity",
        "subscription_id": "sub",
        "resource_group": "sentinel-rg",
        "workspace": "drydock-law",
    }

    assert writeback_config(connector) == expected
    assert playbook_config(connector) == expected


def test_client_secret_mode_forwards_nonsecret_entra_ids() -> None:
    connector = Connector()
    connector.connector_config = {
        "auth_mode": "client_secret",
        "tenant_id": "tenant",
        "client_id": "application",
        "subscription_id": "sub",
        "resource_group": "sentinel-rg",
        "workspace": "drydock-law",
    }

    assert writeback_config(connector)["tenant_id"] == "tenant"
    assert writeback_config(connector)["client_id"] == "application"
