"""Managed-identity OAuth for Kafka-compatible Azure Event Hubs."""

from __future__ import annotations

from dataclasses import dataclass

import pytest

from app.core.kafka_security import ManagedIdentityTokenProvider, resolve_transport


@dataclass
class _Token:
    token: str
    expires_on: int


class _Credential:
    def __init__(self) -> None:
        self.scopes: list[str] = []
        self.closed = False

    async def get_token(self, scope: str) -> _Token:
        self.scopes.append(scope)
        return _Token("managed-identity-token", 4_000)

    async def close(self) -> None:
        self.closed = True


@pytest.mark.asyncio
async def test_managed_identity_provider_uses_namespace_scope_and_caches_token() -> None:
    credential = _Credential()
    provider = ManagedIdentityTokenProvider(
        resource="https://aisoc.servicebus.windows.net",
        client_id="pipeline-client-id",
        credential_factory=lambda _client_id: credential,
        clock=lambda: 1_000,
    )

    first = await provider.token()
    second = await provider.token()

    assert first == "managed-identity-token"
    assert second == first
    assert credential.scopes == ["https://aisoc.servicebus.windows.net/.default"]
    assert credential.closed is True


def test_oauthbearer_transport_builds_aiokafka_token_provider(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("KAFKA_SASL_MECHANISM", "OAUTHBEARER")
    monkeypatch.setenv("KAFKA_OAUTH_RESOURCE", "https://aisoc.servicebus.windows.net")
    monkeypatch.setenv("KAFKA_MANAGED_IDENTITY_CLIENT_ID", "pipeline-client-id")

    transport = resolve_transport(environment="production", protocol="SASL_SSL")
    kwargs = transport.client_kwargs()

    assert kwargs["security_protocol"] == "SASL_SSL"
    assert kwargs["sasl_mechanism"] == "OAUTHBEARER"
    assert isinstance(kwargs["sasl_oauth_token_provider"], ManagedIdentityTokenProvider)
    assert "sasl_plain_username" not in kwargs
    assert "sasl_plain_password" not in kwargs
