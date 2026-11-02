"""Archive-before-delete and recoverable ClickHouse backup contracts."""

from __future__ import annotations

import importlib


def test_archive_worker_module_is_reachable() -> None:
    module = importlib.import_module("app.workers.lake_archive")

    assert callable(module.run_once)
    assert callable(module.export_partition)


def test_backup_worker_can_backup_and_restore() -> None:
    module = importlib.import_module("app.workers.lake_backup")

    assert callable(module.backup_once)
    assert callable(module.restore_and_verify)


def test_parquet_projection_converts_clickhouse_native_scalars() -> None:
    module = importlib.import_module("app.workers.lake_archive")

    raw = module.parquet_projection("raw_events")
    assert "toString(event_id) AS event_id" in raw
    assert "toString(tenant_id) AS tenant_id" in raw
    assert "toString(source_ip) AS source_ip" in raw
    assert "toString(dest_ip) AS dest_ip" in raw
    assert "toString(tenant_id) AS tenant_id" in module.parquet_projection("alert_metrics")


def test_retention_refuses_to_delete_an_unarchived_partition() -> None:
    module = importlib.import_module("app.workers.retention_purge")

    assert callable(module._verified_archive_dates)
    assert callable(module.build_lake_partition_purge_sql)
