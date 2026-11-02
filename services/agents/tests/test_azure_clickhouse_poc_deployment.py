"""Azure ClickHouse PoC deployment and five-year lifecycle contract."""

from __future__ import annotations

import pathlib

REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
AZURE_DIR = REPO_ROOT / "infra" / "terraform" / "azure"


def _read(relative: str) -> str:
    path = AZURE_DIR / relative
    assert path.is_file(), f"missing deployment artifact: {path.relative_to(REPO_ROOT)}"
    return path.read_text(encoding="utf-8")


def test_clickhouse_uses_a_small_interruptible_standard_ssd_vm() -> None:
    source = _read("clickhouse.tf")
    variables = _read("variables.tf")

    assert 'resource "azurerm_linux_virtual_machine" "clickhouse"' in source
    assert 'priority        = "Spot"' in source
    assert 'eviction_policy = "Deallocate"' in source
    assert "max_bid_price   = -1" in source
    assert "size                = var.clickhouse_vm_size" in source
    assert 'variable "clickhouse_vm_size"' in variables
    assert 'default     = "Standard_E2as_v5"' in variables
    assert source.count('"StandardSSD_LRS"') >= 2
    assert "PremiumSSD" not in source


def test_clickhouse_can_use_a_capacity_available_peered_region() -> None:
    source = _read("clickhouse.tf")
    variables = _read("variables.tf")

    assert 'variable "clickhouse_location"' in variables
    assert 'resource "azurerm_virtual_network" "clickhouse"' in source
    assert 'resource "azurerm_virtual_network_peering" "workload_to_clickhouse"' in source
    assert 'resource "azurerm_virtual_network_peering" "clickhouse_to_workload"' in source
    assert "location            = var.clickhouse_location" in source


def test_lake_storage_is_adls_gen2_lrs_with_the_requested_lifecycle() -> None:
    source = _read("clickhouse.tf")

    assert 'resource "azurerm_storage_account" "lake"' in source
    assert 'account_replication_type = "LRS"' in source
    assert "is_hns_enabled           = true" in source
    assert "tier_to_cool_after_days_since_modification_greater_than    = 0" in source
    assert "tier_to_cold_after_days_since_modification_greater_than    = 90" in source
    assert "tier_to_archive_after_days_since_modification_greater_than = 365" in source
    assert "delete_after_days_since_modification_greater_than          = 1460" in source
    assert "ZRS" not in source


def test_azure_runtime_writes_and_queries_the_clickhouse_lake() -> None:
    api = _read("container_apps.tf")
    services = _read("ai_services.tf")

    for name in (
        "CLICKHOUSE_HOST",
        "CLICKHOUSE_PORT",
        "CLICKHOUSE_DATABASE",
        "CLICKHOUSE_USER",
        "CLICKHOUSE_PASSWORD",
    ):
        assert name in api
        assert name in services
    assert 'name  = "AISOC_LAKE_WRITER_ENABLED"' in services
    assert 'value = "true"' in services


def test_raw_event_default_is_one_year_but_clickhouse_ceiling_stays_bounded() -> None:
    retention = (REPO_ROOT / "services" / "api" / "app" / "services" / "retention.py").read_text(encoding="utf-8")
    model = (REPO_ROOT / "services" / "api" / "app" / "models" / "data_lifecycle.py").read_text(encoding="utf-8")

    assert '"raw_events": 365' in retention
    assert "MAX_LAKE_DAYS = 400" in retention
    assert "raw_events_days: Mapped[int] = mapped_column(Integer, default=365)" in model


def test_agents_service_token_is_accepted_by_the_api() -> None:
    api = _read("container_apps.tf")

    assert 'name        = "AISOC_AGENTS_SERVICE_TOKEN"' in api
    assert 'secret_name = "service-token"' in api


def test_archive_and_backup_are_scheduled_managed_identity_jobs() -> None:
    source = _read("lake_operations.tf")

    assert 'resource "azurerm_container_app_job" "lake_archive"' in source
    assert 'resource "azurerm_container_app_job" "clickhouse_backup"' in source
    assert "app.workers.lake_archive" in source
    assert "app.workers.lake_backup" in source
    assert "azurerm_user_assigned_identity.pipeline.id" in source
    assert 'name  = "AZURE_STORAGE_ACCOUNT_URL"' in source


def test_ueba_hunts_and_graph_are_live_workloads_not_flags_only() -> None:
    hubs = _read("event_hubs.tf")
    services = _read("ai_services.tf")
    apps = _read("container_apps.tf")
    vm_bootstrap = _read("templates/clickhouse-cloud-init.yaml.tftpl")

    assert '"ueba.anomalies"' in hubs
    assert "aisoc-ueba-consumer" in hubs
    assert 'resource "azurerm_container_app" "ueba"' in services
    assert 'value = "true"' in services
    assert 'name  = "AISOC_UEBA_FUSION_ENABLED"' in services
    assert 'name  = "HUNT_SCHEDULER_ENABLED"' in apps
    assert 'name  = "AISOC_GRAPH_ENABLED"' in apps
    assert 'name  = "AISOC_NEO4J_URI"' in apps
    assert "aisoc-neo4j" in vm_bootstrap
    assert "NEO4J_AUTH" in vm_bootstrap


def test_operational_controls_are_codified() -> None:
    versions = _read("versions.tf")
    monitoring = _read("monitoring.tf")
    main = _read("main.tf")

    assert 'backend "azurerm"' in versions
    assert "use_azuread_auth" in versions
    assert 'resource "azurerm_monitor_action_group" "operations"' in monitoring
    assert 'resource "azurerm_monitor_metric_alert" "eventhub_server_errors"' in monitoring
    assert 'resource "azurerm_monitor_metric_alert" "clickhouse_vm_availability"' in monitoring
    assert 'resource "azurerm_private_endpoint" "key_vault"' in main


def test_ingest_readiness_is_checked_once_per_minute() -> None:
    apps = _read("container_apps.tf")

    assert 'name  = "AISOC_INGEST_HEALTH_URL"' in apps
    assert 'value = "60"' in apps
    assert 'path                    = "/livez"' in apps
    assert 'path                    = "/readyz"' in apps
    assert apps.count("interval_seconds        = 60") >= 2
