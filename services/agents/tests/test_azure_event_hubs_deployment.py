"""Azure Event Hubs retention contract for the AiSOC event spine."""

from __future__ import annotations

import pathlib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
AZURE_DIR = REPO_ROOT / "infra" / "terraform" / "azure"


def test_every_event_hub_uses_the_validated_seven_day_retention_default() -> None:
    event_hubs = (AZURE_DIR / "event_hubs.tf").read_text(encoding="utf-8")
    variables = (AZURE_DIR / "variables.tf").read_text(encoding="utf-8")

    assert 'variable "eventhub_message_retention_days"' in variables
    retention_block = variables.split('variable "eventhub_message_retention_days"', maxsplit=1)[1].split(
        "}\n", maxsplit=1
    )[0]
    assert "default     = 7" in retention_block
    assert "var.eventhub_message_retention_days >= 1" in retention_block
    assert "var.eventhub_message_retention_days <= 7" in retention_block

    assert 'resource "azurerm_eventhub" "topic"' in event_hubs
    assert "for_each = local.eventhub_topics" in event_hubs
    assert "message_retention = var.eventhub_message_retention_days" in event_hubs
    assert "message_retention = 1" not in event_hubs
