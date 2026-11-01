"""
Microsoft Sentinel connector — patched to support Azure user-assigned managed
identity in addition to the existing client-credentials (app registration +
secret) auth mode.

What changed from upstream (services/connectors/app/connectors/microsoft_sentinel.py):

1. **Auth is pluggable per connector instance.** A new ``auth_mode`` field
   selects between ``client_secret`` (upstream default, unchanged on the
   wire) and ``managed_identity`` (new).

2. **Managed-identity path uses azure-identity.** When ``auth_mode`` is
   ``managed_identity`` the connector resolves tokens from the Container App's
   IMDS endpoint via ``azure.identity.aio.ManagedIdentityCredential``. The
   user-assigned identity is named explicitly by its ``client_id`` because
   Microsoft Learn's Container Apps managed-identity doc says a request that
   omits the ID silently falls through to a system-assigned identity, which
   may or may not exist.

3. **Token audience is now per-API.** Upstream reused one management-scoped
   token for both ``fetch_alerts`` (which hits ARM) and ``query`` (which
   hits Log Analytics). Log Analytics rejects a management token with
   ``InvalidAuthenticationTokenAudience``. We request two tokens:

   - ``https://management.azure.com/.default`` for ARM / Security Insights.
   - ``https://api.loganalytics.io/.default`` for Log Analytics queries.

4. **Access tokens cache with expiry.** Upstream cached a bearer string with
   no expiry check; a long-lived connector would eventually fail with 401
   until the ``if resp.status_code == 401`` fallback refreshed it. We cache
   ``AccessToken`` and refresh ~60s before ``expires_on``.

5. **Workspace ID is now a schema field.** Log Analytics queries address a
   workspace by its GUID ID, not by its Azure resource name. Upstream
   substituted the workspace *name* into the Log Analytics URL, which only
   works when name == ID by accident. New optional ``workspace_id`` field
   drives ``/v1/workspaces/{id}/query``; when absent the connector falls
   back to the old (broken) behaviour so an upgrade cannot regress a
   deployment that was somehow relying on it, but prints a loud warning.

6. **Pagination over ``nextLink``.** Upstream capped incident reads at the
   first 100 results of each poll. We follow ``nextLink`` with a per-poll
   budget so a busy workspace cannot silently drop incidents.

Backwards compatibility: a connector row saved under upstream (no
``auth_mode``, with a non-empty ``client_secret``) continues to work
unchanged. The console form's "Client Secret" field becomes optional.

File intended location:
  services/connectors/app/connectors/microsoft_sentinel.py
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta, timezone
from typing import Any, Literal

import httpx
import structlog

from app.connectors.base import BaseConnector, Capability, ConnectorSchema, Field
from app.federated.query import UnifiedQuery
from app.federated.translators import to_kql

# azure-identity is an optional runtime dep. We import it lazily so a
# deployment that never configures a managed-identity connector still boots
# without the package installed.
try:  # pragma: no cover - exercised in managed-identity CI only
    from azure.core.credentials_async import AsyncTokenCredential
    from azure.identity.aio import ManagedIdentityCredential
    _AZURE_IDENTITY_AVAILABLE = True
except ImportError:  # pragma: no cover
    AsyncTokenCredential = Any  # type: ignore[assignment,misc]
    ManagedIdentityCredential = None  # type: ignore[assignment,misc]
    _AZURE_IDENTITY_AVAILABLE = False

logger = structlog.get_logger()

# Upstream endpoints — unchanged.
_TOKEN_URL = "https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
_SENTINEL_API = (
    "https://management.azure.com"
    "/subscriptions/{sub_id}"
    "/resourceGroups/{rg}"
    "/providers/Microsoft.OperationalInsights/workspaces/{workspace}"
    "/providers/Microsoft.SecurityInsights/incidents"
)
_LOGS_API = "https://api.loganalytics.io/v1/workspaces/{workspace_id}/query"

# Per-API audience scopes. Upstream used a single management-scoped token for
# both; Log Analytics rejects it with InvalidAuthenticationTokenAudience.
_SCOPE_ARM = "https://management.azure.com/.default"
_SCOPE_LOGS = "https://api.loganalytics.io/.default"

# Refresh managed-identity tokens this many seconds before expiry so an
# in-flight request never races the clock.
_TOKEN_REFRESH_SKEW_S = 60

# Hard page cap for incident reads. The ARM API's own default ``$top`` is 50;
# we read ``_PAGE_SIZE`` per page and follow ``nextLink`` until exhausted or
# ``_POLL_BUDGET`` incidents reached — whichever comes first. Keeping a budget
# bounded is deliberate: a connector that reads everything on the first poll
# after a long outage can starve every other connector in the scheduler.
_PAGE_SIZE = 100
_POLL_BUDGET = 1000

AuthMode = Literal["client_secret", "managed_identity"]


class _CachedToken:
    """Access token + expiry, with a skew-aware ``is_expired``.

    ``azure-identity``'s ``AccessToken`` is a NamedTuple with
    ``token: str`` and ``expires_on: int`` (unix seconds). We only need the
    bare minimum, so this duplicates the shape without pulling in the type.
    """

    __slots__ = ("token", "expires_on")

    def __init__(self, token: str, expires_on: int) -> None:
        self.token = token
        self.expires_on = expires_on

    def is_expired(self) -> bool:
        now = int(datetime.now(UTC).timestamp())
        return now >= (self.expires_on - _TOKEN_REFRESH_SKEW_S)


class MicrosoftSentinelConnector(BaseConnector):
    """Microsoft Sentinel incidents + Log Analytics KQL federated search.

    Two auth modes:

    * ``client_secret`` (default, unchanged from upstream): Entra app
      registration with a client secret. All six legacy fields are required.

    * ``managed_identity``: for AiSOC services running on Azure compute (Container
      Apps, AKS workload-identity, VMs). The connector reads tokens from the
      platform's IMDS endpoint using the user-assigned identity named by
      ``managed_identity_client_id``. ``client_secret`` is ignored; ``client_id``
      is ignored. The tenant comes from the identity itself, so ``tenant_id``
      becomes optional too (kept in the schema for symmetry).
    """

    connector_id = "microsoft_sentinel"
    connector_name = "Microsoft Sentinel"
    connector_category = "siem"
    supports_federated_search = True

    @classmethod
    def schema(cls) -> ConnectorSchema:
        return ConnectorSchema(
            connector_id=cls.connector_id,
            connector_name=cls.connector_name,
            category=cls.connector_category,
            description=(
                "Microsoft Sentinel incidents via the Azure Security Insights "
                "REST API. Supports Entra app registration or Azure managed "
                "identity (when AiSOC runs on Azure compute)."
            ),
            docs_url="/docs/connectors/microsoft-sentinel",
            fields=[
                # New: auth mode selector. Default preserves upstream behaviour.
                Field(
                    "auth_mode",
                    "enum",
                    "Authentication mode",
                    required=False,
                    default="client_secret",
                    help_text=(
                        "Use 'client_secret' with an Entra app registration, "
                        "or 'managed_identity' when running on Azure Container "
                        "Apps / AKS with a user-assigned managed identity."
                    ),
                    # Enum members surface as a dropdown in the console form.
                    # If the Field dataclass in this repo doesn't support
                    # ``options`` yet, add it there; the UI uses an enum select
                    # already for the connector-type picker on the same page.
                    options=["client_secret", "managed_identity"],
                ),
                # Legacy fields — required only in client_secret mode. The
                # console form validates conditionally; the Python side
                # enforces presence in __init__ below.
                Field("tenant_id", "string", "Tenant ID", required=False),
                Field("client_id", "string", "Client ID", required=False),
                Field("client_secret", "secret", "Client Secret", required=False),
                # New: identity client ID when auth_mode == managed_identity.
                Field(
                    "managed_identity_client_id",
                    "string",
                    "Managed Identity Client ID",
                    required=False,
                    help_text=(
                        "The clientId of the user-assigned managed identity "
                        "attached to this container app. Not the principalId, "
                        "and not the identity's resource ID."
                    ),
                ),
                Field("subscription_id", "string", "Subscription ID"),
                Field("resource_group", "string", "Resource Group"),
                Field("workspace", "string", "Workspace Name"),
                # New: Log Analytics workspace ID (GUID) used only by federated
                # KQL search. Optional for incident pull; required if you want
                # /federated-search to work against Sentinel.
                Field(
                    "workspace_id",
                    "string",
                    "Log Analytics Workspace ID (GUID)",
                    required=False,
                    help_text=(
                        "Portal: Log Analytics workspace → Overview → "
                        "'Workspace ID'. Needed for KQL federated search; "
                        "unused for incident pull."
                    ),
                ),
            ],
        )

    @classmethod
    def capabilities(cls) -> tuple[Capability, ...]:
        return (Capability.PULL_ALERTS, Capability.QUERY_LOGS)

    def __init__(
        self,
        subscription_id: str,
        resource_group: str,
        workspace: str,
        *,
        auth_mode: AuthMode = "client_secret",
        tenant_id: str | None = None,
        client_id: str | None = None,
        client_secret: str | None = None,
        managed_identity_client_id: str | None = None,
        workspace_id: str | None = None,
    ) -> None:
        self._subscription_id = subscription_id
        self._resource_group = resource_group
        self._workspace = workspace
        self._workspace_id = workspace_id
        self._auth_mode: AuthMode = auth_mode

        # Validate the auth-mode-specific inputs up front so a misconfigured
        # connector fails at save time rather than at first poll. The console
        # already renders the connector-row banner on a ValueError raised in
        # __init__.
        if auth_mode == "client_secret":
            missing = [
                name
                for name, value in (
                    ("tenant_id", tenant_id),
                    ("client_id", client_id),
                    ("client_secret", client_secret),
                )
                if not value
            ]
            if missing:
                raise ValueError(
                    "microsoft_sentinel: auth_mode=client_secret requires "
                    f"{', '.join(missing)}"
                )
        elif auth_mode == "managed_identity":
            if not _AZURE_IDENTITY_AVAILABLE:
                raise ValueError(
                    "microsoft_sentinel: auth_mode=managed_identity requires "
                    "the azure-identity package. Add 'azure-identity' to "
                    "services/connectors/pyproject.toml."
                )
            if not managed_identity_client_id:
                raise ValueError(
                    "microsoft_sentinel: auth_mode=managed_identity requires "
                    "managed_identity_client_id (the user-assigned identity's "
                    "clientId, not its principalId)."
                )
        else:
            raise ValueError(
                f"microsoft_sentinel: unknown auth_mode={auth_mode!r}; "
                "expected 'client_secret' or 'managed_identity'"
            )

        self._tenant_id = tenant_id
        self._client_id = client_id
        self._client_secret = client_secret
        self._mi_client_id = managed_identity_client_id

        # Per-scope token caches.
        self._tokens: dict[str, _CachedToken] = {}

        # Lazy-constructed ManagedIdentityCredential; shared across both scope
        # requests so the SDK's internal connection pool is reused.
        self._mi_credential: ManagedIdentityCredential | None = None

    # ------------------------------------------------------------------
    # Token acquisition
    # ------------------------------------------------------------------

    async def _get_token(self, scope: str) -> str:
        """Return a valid bearer for ``scope``, refreshing if needed."""
        cached = self._tokens.get(scope)
        if cached is not None and not cached.is_expired():
            return cached.token

        if self._auth_mode == "client_secret":
            token = await self._fetch_token_client_secret(scope)
        else:
            token = await self._fetch_token_managed_identity(scope)

        self._tokens[scope] = token
        return token.token

    async def _fetch_token_client_secret(self, scope: str) -> _CachedToken:
        """Entra OAuth2 client-credentials flow. Unchanged logic from upstream.

        Upstream only ever requested the ARM scope; we now request whichever
        scope the caller named so KQL federated search gets a Log Analytics
        token.
        """
        assert self._tenant_id and self._client_id and self._client_secret
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(
                _TOKEN_URL.format(tenant_id=self._tenant_id),
                data={
                    "client_id": self._client_id,
                    "client_secret": self._client_secret,
                    "scope": scope,
                    "grant_type": "client_credentials",
                },
            )
            resp.raise_for_status()
            payload = resp.json()
        # Entra tokens from client-credentials carry ``expires_in`` seconds,
        # not ``expires_on``. Convert so the cache treats both auth modes the
        # same.
        expires_on = int(datetime.now(UTC).timestamp()) + int(payload["expires_in"])
        return _CachedToken(token=payload["access_token"], expires_on=expires_on)

    async def _fetch_token_managed_identity(self, scope: str) -> _CachedToken:
        """IMDS flow via ``azure-identity``. Lazy-opens the credential."""
        assert ManagedIdentityCredential is not None  # import guard
        if self._mi_credential is None:
            # Named by client_id because Microsoft Learn's Container Apps doc
            # says omitting an identifier falls back to a system-assigned
            # identity, which this connector never wants.
            self._mi_credential = ManagedIdentityCredential(
                client_id=self._mi_client_id
            )
        # ``get_token`` returns an ``AccessToken`` with ``expires_on`` as a
        # unix timestamp. The SDK handles IMDS retries and the per-platform
        # endpoint difference (Container Apps vs VM IMDS) for us.
        access = await self._mi_credential.get_token(scope)
        return _CachedToken(token=access.token, expires_on=access.expires_on)

    async def close(self) -> None:
        """Release the managed-identity credential, if any.

        The connector scheduler calls this on shutdown and on config reload
        (``services/connectors/app/scheduler.py`` tears a job down before
        rebuilding it when a row changes).
        """
        if self._mi_credential is not None:
            await self._mi_credential.close()
            self._mi_credential = None

    # ------------------------------------------------------------------
    # Public connector surface
    # ------------------------------------------------------------------

    async def test_connection(self) -> dict[str, Any]:
        """Prove the credential can both auth and read an incident page.

        Upstream's test only exchanged the token, which left two common
        misconfigurations undetected: a correct secret with the wrong role,
        and a managed identity attached but not role-assigned at the
        workspace scope. The ``$top=1`` call fails on either and returns the
        vendor's own error string.
        """
        try:
            token = await self._get_token(_SCOPE_ARM)
            api_url = _SENTINEL_API.format(
                sub_id=self._subscription_id,
                rg=self._resource_group,
                workspace=self._workspace,
            )
            async with httpx.AsyncClient(timeout=15.0) as client:
                resp = await client.get(
                    api_url,
                    headers={"Authorization": f"Bearer {token}"},
                    params={"api-version": "2022-12-01-preview", "$top": 1},
                )
                resp.raise_for_status()
            return {
                "success": True,
                "connector": self.connector_id,
                "workspace": self._workspace,
                "auth_mode": self._auth_mode,
            }
        except httpx.HTTPStatusError as exc:  # pragma: no cover - integration
            return {
                "success": False,
                "connector": self.connector_id,
                "auth_mode": self._auth_mode,
                "status_code": exc.response.status_code,
                "error": exc.response.text,
            }
        except Exception as exc:  # pragma: no cover - integration
            return {
                "success": False,
                "connector": self.connector_id,
                "auth_mode": self._auth_mode,
                "error": str(exc),
            }

    async def fetch_alerts(self, since_seconds: int = 300) -> list[dict[str, Any]]:
        """Pull incidents modified in the last ``since_seconds``.

        Follows ``nextLink`` up to ``_POLL_BUDGET`` incidents. Deliberately
        does not retry on 5xx — the scheduler records a failed poll and
        re-tries on the next tick, which is the right loop for a transient.
        """
        token = await self._get_token(_SCOPE_ARM)
        since = (
            datetime.now(UTC) - timedelta(seconds=since_seconds)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        api_url = _SENTINEL_API.format(
            sub_id=self._subscription_id,
            rg=self._resource_group,
            workspace=self._workspace,
        )
        params = {
            "api-version": "2022-12-01-preview",
            "$filter": f"properties/lastModifiedTimeUtc ge {since}",
            "$top": _PAGE_SIZE,
        }

        incidents: list[dict[str, Any]] = []
        next_url: str | None = api_url
        next_params: dict[str, Any] | None = params

        async with httpx.AsyncClient(timeout=30.0) as client:
            while next_url and len(incidents) < _POLL_BUDGET:
                headers = {"Authorization": f"Bearer {token}"}
                resp = await client.get(next_url, headers=headers, params=next_params)
                if resp.status_code == 401:
                    # Token invalidated mid-poll (rotation on the Entra side,
                    # or expiry we missed). Drop the cache entry and retry
                    # exactly once.
                    self._tokens.pop(_SCOPE_ARM, None)
                    token = await self._get_token(_SCOPE_ARM)
                    headers = {"Authorization": f"Bearer {token}"}
                    resp = await client.get(next_url, headers=headers, params=next_params)
                resp.raise_for_status()
                page = resp.json()
                incidents.extend(page.get("value", []))
                # ``nextLink``, when present, already carries the paging
                # cursor as a complete URL. Drop ``params`` on the next hop
                # so we don't double-encode ``$skiptoken``.
                next_url = page.get("nextLink")
                next_params = None

        if len(incidents) >= _POLL_BUDGET:
            logger.warning(
                "sentinel.fetch_alerts.budget_hit",
                budget=_POLL_BUDGET,
                workspace=self._workspace,
            )

        return [self.normalize(i) for i in incidents]

    async def query(self, unified: UnifiedQuery) -> list[dict[str, Any]]:
        """KQL federated search via Log Analytics.

        Addresses two upstream bugs:

        * Wrong audience. Upstream used the management token; Log Analytics
          rejects it. We request ``api.loganalytics.io/.default`` here.
        * Wrong workspace identifier. Upstream substituted the workspace
          *name* into the URL path; the API wants the workspace GUID.

        If ``workspace_id`` isn't set the method falls back to the upstream
        (broken) behaviour and logs a warning — safer than silently
        succeeding on an un-upgraded connector row.
        """
        workspace_id = self._workspace_id or self._workspace
        if not self._workspace_id:
            logger.warning(
                "sentinel.query.missing_workspace_id",
                workspace=self._workspace,
                hint="Set workspace_id (the Log Analytics GUID) in the connector row.",
            )

        token = await self._get_token(_SCOPE_LOGS)
        kql = to_kql(unified, table="CommonSecurityLog")

        async with httpx.AsyncClient(timeout=60.0) as client:
            url = _LOGS_API.format(workspace_id=workspace_id)
            resp = await client.post(
                url,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                json={"query": kql},
            )
            resp.raise_for_status()
            data = resp.json()

        tables = data.get("tables") or []
        if not tables:
            return []
        primary = tables[0]
        columns = [c.get("name") for c in primary.get("columns", [])]
        rows = primary.get("rows", [])
        return [dict(zip(columns, row, strict=False)) for row in rows]

    # ------------------------------------------------------------------
    # Normalization — unchanged from upstream.
    # ------------------------------------------------------------------

    def normalize(self, raw: dict[str, Any]) -> dict[str, Any]:
        props = raw.get("properties", {})
        severity_map = {
            "Informational": "info",
            "Low": "low",
            "Medium": "medium",
            "High": "high",
        }
        return {
            "source": self.connector_id,
            "external_id": raw.get("name", ""),
            "title": props.get("title", "Sentinel Incident"),
            "description": props.get("description", ""),
            "severity": severity_map.get(props.get("severity", "Medium"), "medium"),
            "status": props.get("status"),
            "hostname": _entity(raw, "Host", "hostName"),
            "username": _entity(raw, "Account", "accountName"),
            "tactics": props.get("additionalData", {}).get("tactics", []),
            "alert_count": props.get("additionalData", {}).get("alertsCount", 0),
            "raw_event": props,
            "created_at": props.get("createdTimeUtc"),
        }


def _entity(raw: dict[str, Any], kind: str, field: str) -> Any:
    """First entity of one kind, or None. Unchanged from upstream."""
    for entity in raw.get("entities") or []:
        if not isinstance(entity, dict) or entity.get("kind") != kind:
            continue
        props = entity.get("properties") or {}
        value = props.get(field) or props.get("friendlyName")
        if value:
            return value
    return None
