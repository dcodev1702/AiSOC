"""Microsoft Sentinel incident polling and Log Analytics search."""

from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from typing import Any, Literal
from urllib.parse import urlsplit

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
    from azure.identity.aio import ManagedIdentityCredential, WorkloadIdentityCredential

    _AZURE_IDENTITY_AVAILABLE = True
except ImportError:  # pragma: no cover
    AsyncTokenCredential = Any  # type: ignore[assignment,misc]
    ManagedIdentityCredential = None  # type: ignore[assignment,misc]
    WorkloadIdentityCredential = None  # type: ignore[assignment,misc]
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
_WORKSPACE_API = (
    "https://management.azure.com/subscriptions/{sub_id}/resourceGroups/{rg}/providers/Microsoft.OperationalInsights/workspaces/{workspace}"
)
_LOGS_API = "https://api.loganalytics.azure.com/v1/workspaces/{workspace_id}/query"
_SENTINEL_API_VERSION = "2025-09-01"
_WORKSPACE_API_VERSION = "2025-02-01"

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


def _validated_arm_next_link(value: Any) -> str | None:
    """Return an ARM continuation URL without risking bearer-token disclosure."""
    if value in (None, ""):
        return None
    if not isinstance(value, str):
        raise ValueError("Sentinel nextLink must be a string")
    parsed = urlsplit(value)
    if parsed.scheme != "https" or parsed.netloc != "management.azure.com":
        raise ValueError("Sentinel nextLink must use https://management.azure.com")
    return value


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

    * ``client_secret`` (default): Entra app registration with a client
      secret. Tenant ID, client ID, and client secret are required.

    * ``managed_identity``: for AiSOC services running on Azure compute
      (Container Apps, AKS workload identity, VMs). The deployment pins the
      user-assigned identity; a connector row cannot select another one.
    """

    connector_id = "microsoft_sentinel"
    connector_name = "Microsoft Sentinel"
    connector_category = "siem"
    supports_federated_search = True
    checkpoint_time_field = ("lastModifiedTimeUtc",)
    checkpoint_id_field = ("name",)

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
                # Default preserves client-secret behaviour for existing rows.
                Field(
                    "auth_mode",
                    "select",
                    "Authentication mode",
                    required=False,
                    default="client_secret",
                    help_text=(
                        "Use 'client_secret' with an Entra app registration, "
                        "or 'managed_identity' when running on Azure Container "
                        "Apps / AKS with a user-assigned managed identity."
                    ),
                    options=[
                        {"value": "client_secret", "label": "Client secret"},
                        {"value": "managed_identity", "label": "Managed identity"},
                    ],
                ),
                # These fields are required whenever they are visible. The
                # managed-identity selection hides and omits them entirely.
                Field(
                    "tenant_id",
                    "string",
                    "Tenant ID",
                    visible_when={"auth_mode": "client_secret"},
                ),
                Field(
                    "client_id",
                    "string",
                    "Client ID",
                    visible_when={"auth_mode": "client_secret"},
                ),
                Field(
                    "client_secret",
                    "secret",
                    "Client Secret",
                    visible_when={"auth_mode": "client_secret"},
                ),
                Field("subscription_id", "string", "Subscription ID"),
                Field("resource_group", "string", "Resource Group"),
                Field("workspace", "string", "Workspace Name"),
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

        # Validate mode-specific inputs at construction as a second boundary
        # behind the schema-driven console validation.
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
                raise ValueError(f"microsoft_sentinel: auth_mode=client_secret requires {', '.join(missing)}")
        elif auth_mode == "managed_identity":
            if not _AZURE_IDENTITY_AVAILABLE:
                raise ValueError(
                    "microsoft_sentinel: auth_mode=managed_identity requires "
                    "the azure-identity package. Add 'azure-identity' to "
                    "services/connectors/pyproject.toml."
                )
            deployment_client_id = os.getenv("AISOC_CONNECTORS_IDENTITY_CLIENT_ID")
            workload_client_id = os.getenv("AZURE_CLIENT_ID") if os.getenv("AZURE_FEDERATED_TOKEN_FILE") else None
            pinned_client_id = deployment_client_id or workload_client_id
            if pinned_client_id and managed_identity_client_id and managed_identity_client_id != pinned_client_id:
                raise ValueError("microsoft_sentinel: configured managed identity does not match the identity assigned to this deployment")
            managed_identity_client_id = pinned_client_id or managed_identity_client_id
            if not managed_identity_client_id:
                raise ValueError("microsoft_sentinel: managed identity client ID is not configured by the deployment")
        else:
            raise ValueError(f"microsoft_sentinel: unknown auth_mode={auth_mode!r}; expected 'client_secret' or 'managed_identity'")

        self._tenant_id = tenant_id
        self._client_id = client_id
        self._client_secret = client_secret
        self._mi_client_id = managed_identity_client_id

        # Per-scope token caches.
        self._tokens: dict[str, _CachedToken] = {}

        # Lazy-constructed ManagedIdentityCredential; shared across both scope
        # requests so the SDK's internal connection pool is reused.
        self._mi_credential: AsyncTokenCredential | None = None
        self._resume_next_link: str | None = None

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
        """Acquire a token from Container Apps or an AKS workload identity."""
        if self._mi_credential is None:
            token_file = os.getenv("AZURE_FEDERATED_TOKEN_FILE")
            if token_file:
                assert WorkloadIdentityCredential is not None
                tenant_id = os.getenv("AZURE_TENANT_ID")
                if not tenant_id:
                    raise ValueError("microsoft_sentinel: AZURE_TENANT_ID is required for AKS workload identity")
                self._mi_credential = WorkloadIdentityCredential(
                    tenant_id=tenant_id,
                    client_id=self._mi_client_id,
                    token_file_path=token_file,
                )
            else:
                assert ManagedIdentityCredential is not None
                self._mi_credential = ManagedIdentityCredential(client_id=self._mi_client_id)
        # ``get_token`` returns an ``AccessToken`` with ``expires_on`` as a
        # unix timestamp. The SDK handles IMDS retries and the per-platform
        # endpoint difference (Container Apps vs VM IMDS) for us.
        access = await self._mi_credential.get_token(scope)
        return _CachedToken(token=access.token, expires_on=access.expires_on)

    async def close(self) -> None:
        """Release the managed-identity credential, if any.

        The connector scheduler invokes this after every poll; stateless API
        routes also call it at the end of each request.
        """
        if self._mi_credential is not None:
            await self._mi_credential.close()
            self._mi_credential = None

    def set_checkpoint(self, checkpoint: dict[str, Any] | None) -> None:
        super().set_checkpoint(checkpoint)
        self._resume_next_link = None
        if isinstance(checkpoint, dict):
            next_link = checkpoint.get("sentinel_next_link")
            self._resume_next_link = _validated_arm_next_link(next_link)

    def _row_time(self, row: dict[str, Any]) -> str:
        return str((row.get("properties") or {}).get("lastModifiedTimeUtc") or "")

    def _row_id(self, row: dict[str, Any]) -> str:
        return str(row.get("name") or "")

    async def _resolve_workspace_id(self) -> str:
        if self._workspace_id:
            return self._workspace_id
        token = await self._get_token(_SCOPE_ARM)
        url = _WORKSPACE_API.format(
            sub_id=self._subscription_id,
            rg=self._resource_group,
            workspace=self._workspace,
        )
        async with httpx.AsyncClient(timeout=15.0) as client:
            response = await client.get(
                url,
                headers={"Authorization": f"Bearer {token}"},
                params={"api-version": _WORKSPACE_API_VERSION},
            )
            response.raise_for_status()
            workspace_id = str((response.json().get("properties") or {}).get("customerId") or "")
        if not workspace_id:
            raise ValueError("Sentinel workspace response did not include properties.customerId")
        self._workspace_id = workspace_id
        return workspace_id

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
            workspace_id = await self._resolve_workspace_id()
            async with httpx.AsyncClient(timeout=15.0) as client:
                resp = await client.get(
                    api_url,
                    headers={"Authorization": f"Bearer {token}"},
                    params={"api-version": _SENTINEL_API_VERSION, "$top": 1},
                )
                resp.raise_for_status()
                logs_token = await self._get_token(_SCOPE_LOGS)
                logs_response = await client.post(
                    _LOGS_API.format(workspace_id=workspace_id),
                    headers={"Authorization": f"Bearer {logs_token}"},
                    json={"query": "print Result=1"},
                )
                logs_response.raise_for_status()
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
        since = (datetime.now(UTC) - timedelta(seconds=since_seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
        api_url = _SENTINEL_API.format(
            sub_id=self._subscription_id,
            rg=self._resource_group,
            workspace=self._workspace,
        )
        params = {
            "api-version": _SENTINEL_API_VERSION,
            "$filter": f"properties/lastModifiedTimeUtc ge {since}",
            "$orderby": "properties/lastModifiedTimeUtc asc",
            "$top": _PAGE_SIZE,
        }

        incidents: list[dict[str, Any]] = []
        was_resuming = self._resume_next_link is not None
        next_url: str | None = self._resume_next_link or api_url
        next_params: dict[str, Any] | None = None if self._resume_next_link else params

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
                next_url = _validated_arm_next_link(page.get("nextLink"))
                next_params = None

        fresh = self.apply_checkpoint(incidents)
        if next_url:
            checkpoint = dict(self._next_checkpoint or self._incoming_checkpoint or {})
            checkpoint["sentinel_next_link"] = next_url
            self._next_checkpoint = checkpoint
            logger.warning(
                "sentinel.fetch_alerts.budget_hit",
                budget=_POLL_BUDGET,
                workspace=self._workspace,
            )
        elif was_resuming and self._next_checkpoint is None and self._incoming_checkpoint:
            # An empty (or duplicate-only) final continuation page still
            # needs to clear the stored nextLink. Re-stage the existing
            # watermark so the scheduler persists the checkpoint without
            # that exhausted cursor instead of replaying the same page on
            # every poll forever.
            self._next_checkpoint = dict(self._incoming_checkpoint)

        return [self.normalize(i) for i in fresh]

    async def query(self, unified: UnifiedQuery) -> list[dict[str, Any]]:
        """KQL federated search via Log Analytics.

        Addresses two upstream bugs:

        * Wrong audience. Upstream used the management token; Log Analytics
          rejects it. We request ``api.loganalytics.io/.default`` here.
        * Wrong workspace identifier. Upstream substituted the workspace
          *name* into the URL path; the API wants the workspace GUID.

        When ``workspace_id`` is not supplied, the connector resolves the
        workspace's customer ID through Azure Resource Manager first.
        """
        workspace_id = await self._resolve_workspace_id()

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
        # ``lastModifiedTimeUtc`` is the Sentinel collection cursor and is
        # therefore the best freshness watermark for an incident update.
        # Keep ``created_at`` as the original incident occurrence time for
        # OCSF/event-time consumers.
        timestamp = props.get("lastModifiedTimeUtc") or props.get("createdTimeUtc")
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
            "timestamp": timestamp,
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
