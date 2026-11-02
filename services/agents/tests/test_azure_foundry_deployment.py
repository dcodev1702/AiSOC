"""Azure Foundry deployment contract for the two-model AiSOC runtime."""

from __future__ import annotations

import pathlib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
AZURE_DIR = REPO_ROOT / "infra" / "terraform" / "azure"
MODELS_TF = AZURE_DIR / "ai_models.tf"
GATEWAY_TF = AZURE_DIR / "ai_gateway.tf"
GATEWAY_DOCKERFILE = REPO_ROOT / "services" / "model-gateway" / "Dockerfile"


def _read(path: pathlib.Path) -> str:
    assert path.is_file(), f"missing deployment artifact: {path.relative_to(REPO_ROOT)}"
    return path.read_text(encoding="utf-8")


def test_foundry_deploys_exact_requested_models_without_local_auth():
    source = _read(MODELS_TF)
    variables = _read(AZURE_DIR / "variables.tf")

    assert 'name    = "gpt-5.6-terra"' in source
    assert 'version = "2026-07-09"' in source
    assert 'name    = "claude-sonnet-5-5"' in source
    assert 'format  = "Anthropic"' in source
    assert 'version = "2"' in source
    assert 'disableLocalAuth       = true' in source
    assert 'publicNetworkAccess    = "Disabled"' in source
    assert 'variable "enable_claude_sonnet"' in variables
    assert "var.enable_claude_sonnet" in source


def test_foundry_is_private_and_pipeline_identity_is_least_privilege():
    source = _read(MODELS_TF)

    assert 'role_definition_name             = "Cognitive Services User"' in source
    assert "azurerm_user_assigned_identity.pipeline.principal_id" in source
    assert 'subresource_names              = ["account"]' in source
    for zone in (
        "privatelink.cognitiveservices.azure.com",
        "privatelink.openai.azure.com",
        "privatelink.services.ai.azure.com",
    ):
        assert zone in source


def test_gateway_uses_managed_identity_upstream_and_no_provider_key():
    source = _read(GATEWAY_TF)

    assert 'value = "ManagedIdentityCredential"' in source
    assert 'value = "https://ai.azure.com/.default"' in source
    assert "azurerm_user_assigned_identity.pipeline.client_id" in source
    assert 'value = "azure/gpt-5-6-terra"' in source
    assert 'local.claude_sonnet_enabled ? "azure_ai/claude-sonnet-5-5" : "azure/gpt-5-6-terra"' in source
    assert "AZURE_AI_API_KEY" not in source
    assert "ANTHROPIC_API_KEY" not in source


def test_gateway_image_pins_the_measured_litellm_release_by_digest():
    source = _read(GATEWAY_DOCKERFILE)

    assert "ghcr.io/berriai/litellm@sha256:" in source
    assert ":latest" not in source
