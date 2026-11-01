from __future__ import annotations

import importlib.util
from datetime import UTC, datetime
from time import time
from types import SimpleNamespace

import httpx
import pytest
import respx
from app.clients import sentinel_client as sentinel_module
from app.clients.sentinel_client import SentinelClient
from app.executors import siem


def _managed_client(**kwargs) -> SentinelClient:
    return SentinelClient(
        subscription_id="sub",
        resource_group="sentinel-rg",
        workspace_name="drydock-law",
        auth_mode="managed_identity",
        **kwargs,
    )


def test_async_identity_transport_is_packaged() -> None:
    assert importlib.util.find_spec("aiohttp") is not None


def test_factory_builds_managed_identity_client_from_deployment_env(monkeypatch) -> None:
    monkeypatch.setattr(sentinel_module, "_AZURE_IDENTITY_AVAILABLE", True)
    monkeypatch.setenv("AISOC_ACTIONS_IDENTITY_CLIENT_ID", "actions-client-id")

    client = siem._sentinel_client(
        {
            "sentinel_auth_mode": "managed_identity",
            "sentinel_subscription_id": "sub",
            "sentinel_resource_group": "sentinel-rg",
            "sentinel_workspace_name": "drydock-law",
        }
    )

    assert client is not None
    assert client._auth_mode == "managed_identity"
    assert client._mi_client_id == "actions-client-id"


def test_actions_identity_cannot_be_overridden(monkeypatch) -> None:
    monkeypatch.setattr(sentinel_module, "_AZURE_IDENTITY_AVAILABLE", True)
    monkeypatch.setenv("AISOC_ACTIONS_IDENTITY_CLIENT_ID", "assigned")
    with pytest.raises(ValueError, match="does not match"):
        _managed_client(managed_identity_client_id="unassigned")


@pytest.mark.asyncio
async def test_aks_uses_workload_identity_and_closes_it(monkeypatch) -> None:
    captured: dict[str, str] = {}

    class Credential:
        def __init__(self, **kwargs):
            captured.update(kwargs)

        async def get_token(self, scope: str):
            captured["scope"] = scope
            return SimpleNamespace(token="token", expires_on=int(time()) + 3600)

        async def close(self):
            captured["closed"] = "yes"

    monkeypatch.setattr(sentinel_module, "_AZURE_IDENTITY_AVAILABLE", True)
    monkeypatch.setattr(sentinel_module, "WorkloadIdentityCredential", Credential)
    monkeypatch.setenv("AZURE_FEDERATED_TOKEN_FILE", "/var/run/projected-token")
    monkeypatch.setenv("AZURE_TENANT_ID", "tenant")
    monkeypatch.setenv("AZURE_CLIENT_ID", "workload-client")
    client = _managed_client()

    async with httpx.AsyncClient() as http:
        assert await client._access_token(http) == "token"
    await client.close()

    assert captured["client_id"] == "workload-client"
    assert captured["token_file_path"] == "/var/run/projected-token"
    assert captured["closed"] == "yes"


@pytest.mark.asyncio
@respx.mock
async def test_rejects_next_link_outside_arm_before_forwarding_token(monkeypatch) -> None:
    monkeypatch.setattr(sentinel_module, "_AZURE_IDENTITY_AVAILABLE", True)
    monkeypatch.setenv("AISOC_ACTIONS_IDENTITY_CLIENT_ID", "actions-client-id")
    client = _managed_client()

    async def token(_http: httpx.AsyncClient) -> str:
        return "sensitive-token"

    monkeypatch.setattr(client, "_access_token", token)
    respx.get(url__regex=r".*/providers/Microsoft\.SecurityInsights/incidents\?.*").mock(
        return_value=httpx.Response(
            200,
            json={"value": [], "nextLink": "https://attacker.example/steal"},
        )
    )
    attacker = respx.get("https://attacker.example/steal").mock(return_value=httpx.Response(200, json={"value": []}))

    with pytest.raises(ValueError, match="management.azure.com"):
        await client.list_closed_incidents(
            datetime(2026, 11, 1, tzinfo=UTC),
            datetime(2026, 11, 2, tzinfo=UTC),
        )

    assert not attacker.called
