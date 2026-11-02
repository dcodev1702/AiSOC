-- The Azure proof of concept keeps one full year searchable in ClickHouse.
--
-- Existing explicit tenant choices are not rewritten: a stored 90-day policy
-- may be intentional.  This only changes the database default for new policy
-- rows, matching app.services.retention.DEFAULT_RETENTION and the ORM model.

ALTER TABLE retention_policies
    ALTER COLUMN raw_events_days SET DEFAULT 365;
