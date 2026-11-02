"""Logical ClickHouse backup and isolated restore verification for the PoC."""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
from datetime import UTC, datetime

from app.db.clickhouse import execute_lake_query
from app.workers.lake_archive import _clickhouse_http, _storage_account_url, _upload, parquet_projection

TABLES = ("raw_events", "alert_metrics", "ioc_enrichments")


async def backup_once() -> dict[str, object]:
    """Write a full logical Parquet backup plus a checksum manifest to ADLS."""
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    manifest: dict[str, object] = {"created_at": datetime.now(UTC).isoformat(), "tables": {}}
    for table in TABLES:
        schema = await execute_lake_query(f"SHOW CREATE TABLE aisoc.{table}")
        count = await execute_lake_query(f"SELECT count() FROM aisoc.{table}")
        payload = await _clickhouse_http(f"SELECT {parquet_projection(table)} FROM aisoc.{table} FORMAT Parquet")
        payload_sha = hashlib.sha256(payload).hexdigest()
        blob_path = f"clickhouse/{stamp}/{table}-{payload_sha}.parquet"
        await _upload(
            blob_path,
            payload,
            content_type="application/vnd.apache.parquet",
            container="backups",
        )
        manifest["tables"][table] = {  # type: ignore[index]
            "create_sql": schema.rows[0][0],
            "row_count": int(count.rows[0][0]),
            "blob_path": blob_path,
            "sha256": payload_sha,
        }
    body = json.dumps(manifest, sort_keys=True, default=str).encode()
    digest = hashlib.sha256(body).hexdigest()
    manifest_path = f"clickhouse/{stamp}/manifest-{digest}.json"
    await _upload(manifest_path, body, content_type="application/json", container="backups")
    return {**manifest, "sha256": digest, "manifest_path": manifest_path}


async def _download(path: str) -> bytes:
    from azure.identity.aio import ManagedIdentityCredential
    from azure.storage.blob.aio import BlobServiceClient

    credential = ManagedIdentityCredential(client_id=os.environ.get("AZURE_CLIENT_ID") or None)
    client = BlobServiceClient(account_url=_storage_account_url(), credential=credential)
    try:
        stream = await client.get_blob_client(container="backups", blob=path).download_blob()
        return await stream.readall()
    finally:
        await client.close()
        await credential.close()


async def restore_and_verify() -> dict[str, object]:
    """Run a non-destructive recovery drill against the live source.

    Full event rehydration is intentionally a manual break-glass operation;
    this scheduled drill proves ClickHouse and all source schemas are readable
    and that a fresh backup manifest can be written to private ADLS.
    """
    backup = await backup_once()
    suffix = datetime.now(UTC).strftime("%Y%m%d%H%M%S")
    database = f"aisoc_restore_{suffix}"
    checked: dict[str, int] = {}
    await execute_lake_query(f"CREATE DATABASE {database}")
    try:
        tables = backup["tables"]
        assert isinstance(tables, dict)
        for table in TABLES:
            metadata = tables[table]
            assert isinstance(metadata, dict)
            payload = await _download(str(metadata["blob_path"]))
            if hashlib.sha256(payload).hexdigest() != metadata["sha256"]:
                raise RuntimeError(f"backup checksum mismatch for {table}")
            await execute_lake_query(f"CREATE TABLE {database}.{table} AS aisoc.{table}")
            await _clickhouse_http(f"INSERT INTO {database}.{table} FORMAT Parquet", payload)
            probe = await execute_lake_query(f"SELECT count() FROM {database}.{table}")
            restored = int(probe.rows[0][0])
            if restored != int(metadata["row_count"]):
                raise RuntimeError(f"restore row-count mismatch for {table}")
            checked[table] = restored
    finally:
        await execute_lake_query(f"DROP DATABASE IF EXISTS {database}")
    return {"status": "verified", "backup_sha256": backup["sha256"], "row_counts": checked}


if __name__ == "__main__":
    import sys

    operation = restore_and_verify if len(sys.argv) > 1 and sys.argv[1] == "restore-verify" else backup_once
    print(json.dumps(asyncio.run(operation()), default=str))
