"""Export aged ClickHouse partitions to managed-identity protected ADLS.

Each export is Parquet plus a JSON manifest.  The Postgres ledger is written
only after both objects are durable.  Retention rechecks the source row count
and maximum ingest timestamp against that ledger immediately before deleting.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import uuid
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime

import httpx
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.clickhouse import execute_lake_query
from app.db.database import AsyncSessionLocal
from app.workers.retention_purge import _load_policies, _tenant_is_held


@dataclass(frozen=True)
class ArchiveExport:
    tenant_id: str
    event_date: str
    blob_path: str
    content_sha256: str
    row_count: int
    max_ingest_time: str | None
    legal_hold: bool


def _storage_account_url() -> str:
    url = (os.environ.get("AZURE_STORAGE_ACCOUNT_URL") or os.environ.get("AISOC_LAKE_STORAGE_URL", "")).rstrip("/")
    if not url:
        raise RuntimeError("AISOC_LAKE_STORAGE_URL is required")
    return url


async def _upload(path: str, payload: bytes, *, content_type: str, container: str = "events") -> None:
    from azure.identity.aio import ManagedIdentityCredential
    from azure.storage.blob import ContentSettings
    from azure.storage.blob.aio import BlobServiceClient

    credential = ManagedIdentityCredential(client_id=os.environ.get("AZURE_CLIENT_ID") or None)
    client = BlobServiceClient(account_url=_storage_account_url(), credential=credential)
    try:
        blob = client.get_blob_client(container=container, blob=path)
        await blob.upload_blob(
            payload,
            overwrite=True,
            content_settings=ContentSettings(content_type=content_type),
            metadata={"aisoc_evidence": "true"},
        )
    finally:
        await client.close()
        await credential.close()


async def _clickhouse_http(query: str, payload: bytes | None = None) -> bytes:
    host = os.environ.get("CLICKHOUSE_HOST", "").strip()
    if not host:
        raise RuntimeError("CLICKHOUSE_HOST is required")
    port = int(os.environ.get("CLICKHOUSE_HTTP_PORT", "8123"))
    database = os.environ.get("CLICKHOUSE_DATABASE", "aisoc")
    user = os.environ.get("CLICKHOUSE_USER", "aisoc")
    password = os.environ.get("CLICKHOUSE_PASSWORD", "")
    body = query.encode() if payload is None else payload
    params = {"database": database}
    if payload is not None:
        params["query"] = query
    async with httpx.AsyncClient(timeout=httpx.Timeout(300.0)) as client:
        response = await client.post(
            f"http://{host}:{port}/",
            params=params,
            content=body,
            auth=(user, password),
        )
        if response.is_error:
            detail = response.text.strip()[:1_000]
            raise RuntimeError(f"ClickHouse HTTP query failed ({response.status_code}): {detail}")
        return response.content


_PARQUET_PROJECTIONS = {
    "raw_events": (
        "* REPLACE (toString(event_id) AS event_id, toString(tenant_id) AS tenant_id, "
        "toString(source_ip) AS source_ip, toString(dest_ip) AS dest_ip)"
    ),
    "alert_metrics": "* REPLACE (toString(tenant_id) AS tenant_id)",
    "ioc_enrichments": "* REPLACE (toString(tenant_id) AS tenant_id)",
}


def parquet_projection(table: str) -> str:
    """Project ClickHouse-only scalar types into reversible Parquet strings."""
    try:
        return _PARQUET_PROJECTIONS[table]
    except KeyError as exc:
        raise ValueError(f"no Parquet projection declared for {table!r}") from exc


async def _parquet_bytes(tenant_id: uuid.UUID, event_date: date) -> bytes:
    query = (
        f"SELECT {parquet_projection('raw_events')} FROM aisoc.raw_events "
        f"WHERE tenant_id = '{tenant_id}' AND toDate(event_time) = toDate('{event_date.isoformat()}') "
        "ORDER BY event_time FORMAT Parquet"
    )
    return await _clickhouse_http(query)


async def export_partition(
    tenant_id: uuid.UUID,
    event_date: date,
    *,
    row_count: int,
    max_ingest_time: datetime | None,
    legal_hold: bool,
    db: AsyncSession,
) -> ArchiveExport:
    payload = await _parquet_bytes(tenant_id, event_date)
    digest = hashlib.sha256(payload).hexdigest()
    prefix = "legal-hold" if legal_hold else "parquet"
    blob_path = f"{prefix}/tenant_id={tenant_id}/event_date={event_date.isoformat()}/raw_events.parquet"
    manifest_path = blob_path.removesuffix(".parquet") + ".manifest.json"
    result = ArchiveExport(
        tenant_id=str(tenant_id),
        event_date=event_date.isoformat(),
        blob_path=blob_path,
        content_sha256=digest,
        row_count=row_count,
        max_ingest_time=max_ingest_time.astimezone(UTC).isoformat() if max_ingest_time else None,
        legal_hold=legal_hold,
    )
    await _upload(blob_path, payload, content_type="application/vnd.apache.parquet")
    await _upload(
        manifest_path,
        json.dumps({**asdict(result), "exported_at": datetime.now(UTC).isoformat()}, sort_keys=True).encode(),
        content_type="application/json",
    )
    await db.execute(
        text("""
            INSERT INTO lake_archive_exports
                (tenant_id, event_date, blob_path, content_sha256, row_count,
                 max_ingest_time, legal_hold, status, exported_at, error)
            VALUES
                (:tenant_id, :event_date, :blob_path, :sha, :row_count,
                 :max_ingest_time, :legal_hold, 'completed', now(), NULL)
            ON CONFLICT (tenant_id, event_date, legal_hold) DO UPDATE SET
                blob_path = EXCLUDED.blob_path,
                content_sha256 = EXCLUDED.content_sha256,
                row_count = EXCLUDED.row_count,
                max_ingest_time = EXCLUDED.max_ingest_time,
                status = 'completed', exported_at = now(), error = NULL
        """),
        {
            "tenant_id": str(tenant_id),
            "event_date": event_date,
            "blob_path": blob_path,
            "sha": digest,
            "row_count": row_count,
            "max_ingest_time": max_ingest_time,
            "legal_hold": legal_hold,
        },
    )
    return result


async def run_once(*, db: AsyncSession | None = None) -> list[ArchiveExport]:
    own_session = db is None
    if db is None:
        db = AsyncSessionLocal()
    exports: list[ArchiveExport] = []
    try:
        for tenant_id, config in await _load_policies(db):
            days = max(1, min(400, int(config["raw_events_days"])))
            result = await execute_lake_query(
                "SELECT toDate(event_time), count(), max(ingest_time) "
                "FROM aisoc.raw_events "
                f"WHERE tenant_id = '{tenant_id}' AND event_time < now() - INTERVAL {days} DAY "
                "GROUP BY toDate(event_time) ORDER BY toDate(event_time)"
            )
            held = bool(await _tenant_is_held(db, tenant_id))
            for event_date, row_count, max_ingest in result.rows:
                exports.append(
                    await export_partition(
                        tenant_id,
                        event_date,
                        row_count=int(row_count),
                        max_ingest_time=max_ingest,
                        legal_hold=held,
                        db=db,
                    )
                )
        await db.commit()
        return exports
    finally:
        if own_session:
            await db.close()


if __name__ == "__main__":
    completed = asyncio.run(run_once())
    print(json.dumps({"status": "ok", "exports": len(completed)}))
