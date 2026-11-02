"""Managed Postgres DSNs must work in every UEBA database path."""

from app.core.database import normalize_asyncpg_url


def test_azure_sslmode_is_forwarded_as_asyncpg_ssl() -> None:
    url, connect_args = normalize_asyncpg_url("postgresql+asyncpg://user:secret@db.postgres.database.azure.com/aisoc?sslmode=require")

    assert url == "postgresql+asyncpg://user:secret@db.postgres.database.azure.com/aisoc"
    assert connect_args == {"ssl": "require"}


def test_libpq_scheme_and_only_unsupported_query_keys_are_normalized() -> None:
    url, connect_args = normalize_asyncpg_url(
        "postgresql://user:secret@db/aisoc?sslmode=disable&channel_binding=require&application_name=ueba"
    )

    assert url == "postgresql+asyncpg://user:secret@db/aisoc?application_name=ueba"
    assert connect_args == {"ssl": False}
