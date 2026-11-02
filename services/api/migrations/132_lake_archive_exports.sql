-- Evidence that an aged ClickHouse partition has been copied to ADLS Gen2.
-- The live retention worker refuses to remove a partition unless this ledger
-- contains a completed export whose row count and maximum ingest timestamp
-- still match ClickHouse.  Late-arriving events therefore invalidate an old
-- export instead of being silently lost.

CREATE TABLE IF NOT EXISTS lake_archive_exports (
    tenant_id          UUID NOT NULL,
    event_date         DATE NOT NULL,
    blob_path          TEXT NOT NULL,
    content_sha256     TEXT NOT NULL,
    row_count          BIGINT NOT NULL CHECK (row_count >= 0),
    max_ingest_time    TIMESTAMPTZ,
    legal_hold         BOOLEAN NOT NULL DEFAULT false,
    status             TEXT NOT NULL CHECK (status IN ('completed', 'failed')),
    exported_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    error              TEXT,
    PRIMARY KEY (tenant_id, event_date, legal_hold)
);

CREATE INDEX IF NOT EXISTS ix_lake_archive_exports_status
    ON lake_archive_exports (status, event_date);

ALTER TABLE lake_archive_exports ENABLE ROW LEVEL SECURITY;
ALTER TABLE lake_archive_exports FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lake_archive_exports_tenant ON lake_archive_exports;
CREATE POLICY lake_archive_exports_tenant ON lake_archive_exports
    USING (tenant_id = current_tenant_id() OR current_tenant_id() IS NULL)
    WITH CHECK (tenant_id = current_tenant_id() OR current_tenant_id() IS NULL);

GRANT SELECT, INSERT, UPDATE ON lake_archive_exports TO aisoc_app;

COMMENT ON TABLE lake_archive_exports IS
    'Archive-before-delete evidence. A completed, matching non-hold row is required before ClickHouse retention may purge a partition.';
