from __future__ import annotations

from time import time
from types import SimpleNamespace

import httpx
import pytest
import respx
from app.connectors import microsoft_sentinel as sentinel_module
from app.connectors.microsoft_sentinel import MicrosoftSentinelConnector


def _client(**kwargs) -> MicrosoftSentinelConnector:
    return MicrosoftSentinelConnector(
        subscription_id="sub",
        resource_group="sentinel-rg",
        workspace="drydock-law",
        **kwargs,
    )


def test_schema_uses_supported_select_and_conditional_secret_fields() -> None:
    fields = {field.name: field for field in MicrosoftSentinelConnector.schema().fields}

    assert fields["auth_mode"].type == "select"
    assert fields["auth_mode"].options == [
        {"value": "client_secret", "label": "Client secret"},
        {"value": "managed_identity", "label": "Managed identity"},
    ]
    assert fields["client_secret"].visible_when == {"auth_mode": "client_secret"}
    assert fields["client_secret"].required is True
    assert "managed_identity_client_id" not in fields


def test_deployment_identity_cannot_be_overridden(monkeypatch) -> None:
    monkeypatch.setattr(sentinel_module, "_AZURE_IDENTITY_AVAILABLE", True)
    monkeypatch.setenv("AISOC_CONNECTORS_IDENTITY_CLIENT_ID", "assigned-client-id")

    with pytest.raises(ValueError, match="does not match"):
        _client(
            auth_mode="managed_identity",
            managed_identity_client_id="tenant-controlled-client-id",
        )


@pytest.mark.asyncio
async def test_aks_uses_workload_identity_credential(monkeypatch) -> None:
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

    connector = _client(auth_mode="managed_identity")
    assert await connector._get_token(sentinel_module._SCOPE_ARM) == "token"
    await connector.close()

    assert captured["tenant_id"] == "tenant"
    assert captured["client_id"] == "workload-client"
    assert captured["token_file_path"] == "/var/run/projected-token"
    assert captured["closed"] == "yes"


@pytest.mark.asyncio
@respx.mock
async def test_budget_checkpoint_resumes_from_next_link(monkeypatch) -> None:
    monkeypatch.setattr(sentinel_module, "_POLL_BUDGET", 2)

    async def token(_scope: str) -> str:
        return "token"

    first = _client(
        tenant_id="tenant",
        client_id="client",
        client_secret="secret",
    )
    monkeypatch.setattr(first, "_get_token", token)
    base = respx.get(url__regex=r".*/providers/Microsoft\.SecurityInsights/incidents\?.*").mock(
        return_value=httpx.Response(
            200,
            json={
                "value": [
                    {"name": "1", "properties": {"lastModifiedTimeUtc": "2026-11-01T10:00:00Z"}},
                    {"name": "2", "properties": {"lastModifiedTimeUtc": "2026-11-01T10:01:00Z"}},
                ],
                "nextLink": "https://management.azure.com/next-page",
            },
        )
    )

    rows = await first.fetch_alerts()
    checkpoint = first.get_checkpoint()
    assert base.called
    assert [row["external_id"] for row in rows] == ["1", "2"]
    assert checkpoint == {
        "time": "2026-11-01T10:01:00Z",
        "id": "2",
        "sentinel_next_link": "https://management.azure.com/next-page",
    }

    second = _client(
        tenant_id="tenant",
        client_id="client",
        client_secret="secret",
    )
    second.set_checkpoint(checkpoint)
    monkeypatch.setattr(second, "_get_token", token)
    resumed = respx.get("https://management.azure.com/next-page").mock(
        return_value=httpx.Response(
            200,
            json={
                "value": [
                    {"name": "3", "properties": {"lastModifiedTimeUtc": "2026-11-01T10:02:00Z"}},
                ]
            },
        )
    )

    rows = await second.fetch_alerts()
    assert resumed.called
    assert [row["external_id"] for row in rows] == ["3"]
    assert second.get_checkpoint() == {"time": "2026-11-01T10:02:00Z", "id": "3"}


@pytest.mark.asyncio
@respx.mock
async def test_empty_final_continuation_clears_resume_link(monkeypatch) -> None:
    async def token(_scope: str) -> str:
        return "token"

    connector = _client(
        tenant_id="tenant",
        client_id="client",
        client_secret="secret",
    )
    connector.set_checkpoint(
        {
            "time": "2026-11-01T10:01:00Z",
            "id": "2",
            "sentinel_next_link": "https://management.azure.com/final-page",
        }
    )
    monkeypatch.setattr(connector, "_get_token", token)
    respx.get("https://management.azure.com/final-page").mock(return_value=httpx.Response(200, json={"value": []}))

    assert await connector.fetch_alerts() == []
    assert connector.get_checkpoint() == {
        "time": "2026-11-01T10:01:00Z",
        "id": "2",
    }


@pytest.mark.asyncio
@respx.mock
async def test_rejects_next_link_outside_arm_before_forwarding_token(monkeypatch) -> None:
    async def token(_scope: str) -> str:
        return "sensitive-token"

    connector = _client(
        tenant_id="tenant",
        client_id="client",
        client_secret="secret",
    )
    monkeypatch.setattr(connector, "_get_token", token)
    respx.get(url__regex=r".*/providers/Microsoft\.SecurityInsights/incidents\?.*").mock(
        return_value=httpx.Response(
            200,
            json={"value": [], "nextLink": "https://attacker.example/steal"},
        )
    )
    attacker = respx.get("https://attacker.example/steal").mock(return_value=httpx.Response(200, json={"value": []}))

    with pytest.raises(ValueError, match="management.azure.com"):
        await connector.fetch_alerts()

    assert not attacker.called
