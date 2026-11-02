"""Async Postgres URL normalization shared by UEBA HTTP, worker, and Alembic."""

from __future__ import annotations

from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

_SSLMODES = {"disable", "allow", "prefer", "require", "verify-ca", "verify-full"}


def normalize_asyncpg_url(url: str) -> tuple[str, dict[str, Any]]:
    """Return a SQLAlchemy asyncpg URL and asyncpg-compatible connect args.

    Azure PostgreSQL emits libpq URLs with ``sslmode=require``. SQLAlchemy
    forwards that query key to asyncpg, which rejects it; asyncpg expects the
    equivalent ``ssl`` connect argument instead.
    """

    if url.startswith("postgres://"):
        url = "postgresql+asyncpg://" + url[len("postgres://") :]
    elif url.startswith("postgresql://"):
        url = "postgresql+asyncpg://" + url[len("postgresql://") :]

    parts = urlsplit(url)
    remaining: list[tuple[str, str]] = []
    connect_args: dict[str, Any] = {}
    for key, value in parse_qsl(parts.query, keep_blank_values=True):
        if key == "sslmode":
            mode = value.strip().lower()
            if mode in _SSLMODES:
                connect_args["ssl"] = False if mode == "disable" else mode
            continue
        if key == "channel_binding":
            continue
        remaining.append((key, value))

    normalized = urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(remaining), parts.fragment))
    return normalized, connect_args
