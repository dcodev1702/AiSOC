"""Microsoft Sentinel REST client for incident lifecycle writeback.

Sentinel incidents live behind Azure Resource Manager, so every call needs the
full workspace path (subscription / resource group / workspace) plus an Entra
token scoped to ``https://management.azure.com/.default``. The identity (app
registration *or* managed identity) needs the *Microsoft Sentinel Responder*
role on the workspace; *Reader* is enough to fetch an incident and not enough
to update one, which surfaces as a 403 on the PATCH and nothing earlier.

Credentials expected in ``ActionRequest.parameters``:

Client-secret mode (upstream, unchanged):
    sentinel_tenant_id, sentinel_client_id, sentinel_client_secret
    sentinel_subscription_id, sentinel_resource_group, sentinel_workspace_name

Managed-identity mode:
    sentinel_auth_mode="managed_identity"
    sentinel_subscription_id, sentinel_resource_group, sentinel_workspace_name

The deployment pins the managed-identity client ID. A legacy parameter may be
accepted only when it matches that deployed identity.

"""

from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any, Literal
from urllib.parse import urlsplit

import httpx
import structlog

# azure-identity is an optional runtime dependency — a deployment that only
# ever uses client-secret auth should still boot without it installed. The
# dispatcher validates in ``from_params`` / the constructor that the package
# is present when a managed-identity row is used.
try:  # pragma: no cover - exercised in managed-identity CI only
    from azure.identity.aio import ManagedIdentityCredential, WorkloadIdentityCredential

    _AZURE_IDENTITY_AVAILABLE = True
except ImportError:  # pragma: no cover
    ManagedIdentityCredential = None  # type: ignore[assignment,misc]
    WorkloadIdentityCredential = None  # type: ignore[assignment,misc]
    _AZURE_IDENTITY_AVAILABLE = False

logger = structlog.get_logger()

#: Pinned: the incident ``properties`` contract differs between versions, and
#: a floating ``api-version`` would change what a PATCH means without a deploy.
API_VERSION = "2025-09-01"

ARM_BASE = "https://management.azure.com"
AUTHORITY = "https://login.microsoftonline.com"
SCOPE = "https://management.azure.com/.default"

#: Sentinel's closed-incident classifications. ``Undetermined`` is deliberately
#: absent from the writeback mapping: it is what a human picks when they gave
#: up, and it is not something the platform should claim on their behalf.
CLASSIFICATION_FALSE_POSITIVE = "FalsePositive"
CLASSIFICATION_BENIGN_POSITIVE = "BenignPositive"
CLASSIFICATION_TRUE_POSITIVE = "TruePositive"

#: Refresh managed-identity tokens this many seconds before expiry so a
#: long-running backfill (``list_closed_incidents`` over a wide window) never
#: races the clock mid-page.
_TOKEN_REFRESH_SKEW_S = 60

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


class SentinelClient:
    """Async client for Microsoft Sentinel incident updates.

    Two auth modes, picked at construction time:

    * ``client_secret`` (default): Entra app
      registration with a client secret, three fields required.
    * ``managed_identity``: Azure user-assigned managed identity pinned by
      the actions deployment. The tenant comes from the identity itself.
      This is usable only when the service runs on Azure compute with that
      identity attached.

    All upstream call sites that use keyword arguments keep working with
    no edits; the only new requirement is that the dispatcher forwards the
    additional ``sentinel_auth_mode`` and ``sentinel_managed_identity_client_id``
    fields when the saved connector row has them. ``from_params`` below
    does that translation in one place.
    """

    def __init__(
        self,
        tenant_id: str | None = None,
        client_id: str | None = None,
        client_secret: str | None = None,
        subscription_id: str | None = None,
        resource_group: str | None = None,
        workspace_name: str | None = None,
        *,
        auth_mode: AuthMode = "client_secret",
        managed_identity_client_id: str | None = None,
        timeout: float = 30.0,
    ) -> None:
        missing_coordinates = [
            name
            for name, value in (
                ("subscription_id", subscription_id),
                ("resource_group", resource_group),
                ("workspace_name", workspace_name),
            )
            if not value
        ]
        if missing_coordinates:
            raise ValueError(f"SentinelClient: workspace coordinates require {', '.join(missing_coordinates)}")
        assert subscription_id and resource_group and workspace_name
        self._subscription_id = subscription_id
        self._resource_group = resource_group
        self._workspace_name = workspace_name
        self._timeout = timeout

        self._auth_mode: AuthMode = auth_mode
        self._tenant_id = tenant_id
        self._client_id = client_id
        self._client_secret = client_secret

        # Validate the mode-specific inputs up front so a misconfigured
        # action row fails at dispatch rather than at first REST call. The
        # executor wraps construction and surfaces this as a dispatch
        # refusal, which the audit trail records with its reason.
        if auth_mode == "client_secret":
            missing = [
                n
                for n, v in (
                    ("tenant_id", tenant_id),
                    ("client_id", client_id),
                    ("client_secret", client_secret),
                )
                if not v
            ]
            if missing:
                raise ValueError(f"SentinelClient: client_secret mode requires {', '.join(missing)}")
        elif auth_mode == "managed_identity":
            if not _AZURE_IDENTITY_AVAILABLE:
                raise ValueError(
                    "SentinelClient: managed_identity mode requires the "
                    "azure-identity package. Add 'azure-identity' to "
                    "services/actions/pyproject.toml."
                )
            deployment_client_id = os.getenv("AISOC_ACTIONS_IDENTITY_CLIENT_ID")
            workload_client_id = os.getenv("AZURE_CLIENT_ID") if os.getenv("AZURE_FEDERATED_TOKEN_FILE") else None
            pinned_client_id = deployment_client_id or workload_client_id
            if pinned_client_id and managed_identity_client_id and managed_identity_client_id != pinned_client_id:
                raise ValueError("SentinelClient: configured managed identity does not match the identity assigned to this deployment")
            managed_identity_client_id = pinned_client_id or managed_identity_client_id
            if not managed_identity_client_id:
                raise ValueError("SentinelClient: managed identity client ID is not configured by the deployment")
        else:
            raise ValueError(f"SentinelClient: unknown auth_mode={auth_mode!r}")
        self._mi_client_id = managed_identity_client_id

        # Cache the bearer with its expiry so long history reads can refresh
        # before a paging or entity request races token rotation.
        self._token: str | None = None
        self._token_expires_on: int | None = None

        # Lazy-constructed credential; released by ``close()`` on executor
        # shutdown.
        self._mi_credential: Any | None = None

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------

    @classmethod
    def from_params(cls, params: dict[str, Any]) -> SentinelClient:
        """Build a client from the dict shape stored on ``ActionRequest.parameters``.

        Keeps the auth-mode dispatch in one place so the executor doesn't
        have to know which fields each mode needs. Field names match the
        upstream convention (``sentinel_*`` prefix) because the dispatcher
        already stores and forwards them that way; adding a prefix-free
        alias here would just invite drift.
        """
        auth_mode: AuthMode = params.get("sentinel_auth_mode", "client_secret")
        return cls(
            subscription_id=params["sentinel_subscription_id"],
            resource_group=params["sentinel_resource_group"],
            workspace_name=params["sentinel_workspace_name"],
            auth_mode=auth_mode,
            tenant_id=params.get("sentinel_tenant_id"),
            client_id=params.get("sentinel_client_id"),
            client_secret=params.get("sentinel_client_secret"),
            managed_identity_client_id=params.get("sentinel_managed_identity_client_id"),
        )

    # ------------------------------------------------------------------
    # URL builders — identical to upstream.
    # ------------------------------------------------------------------

    def _incident_url(self, incident_id: str) -> str:
        return (
            f"{ARM_BASE}/subscriptions/{self._subscription_id}"
            f"/resourceGroups/{self._resource_group}"
            f"/providers/Microsoft.OperationalInsights/workspaces/{self._workspace_name}"
            f"/providers/Microsoft.SecurityInsights/incidents/{incident_id}"
        )

    def _incidents_url(self) -> str:
        return (
            f"{ARM_BASE}/subscriptions/{self._subscription_id}"
            f"/resourceGroups/{self._resource_group}"
            f"/providers/Microsoft.OperationalInsights/workspaces/{self._workspace_name}"
            f"/providers/Microsoft.SecurityInsights/incidents"
        )

    # ------------------------------------------------------------------
    # Token acquisition
    # ------------------------------------------------------------------

    def _token_is_fresh(self) -> bool:
        """True iff the cached token exists and is not within the skew window.

        Both auth modes track expiry. The skew prevents a long paging loop
        from starting another request with a token about to expire.
        """
        if self._token is None:
            return False
        if self._token_expires_on is None:
            return True
        now = int(datetime.now(UTC).timestamp())
        return now < (self._token_expires_on - _TOKEN_REFRESH_SKEW_S)

    async def _access_token(self, client: httpx.AsyncClient) -> str:
        """Return a bearer, dispatching to whichever path ``auth_mode`` selected."""
        if self._token_is_fresh() and self._token is not None:
            return self._token

        if self._auth_mode == "client_secret":
            assert self._tenant_id and self._client_id and self._client_secret
            response = await client.post(
                f"{AUTHORITY}/{self._tenant_id}/oauth2/v2.0/token",
                data={
                    "grant_type": "client_credentials",
                    "client_id": self._client_id,
                    "client_secret": self._client_secret,
                    "scope": SCOPE,
                },
            )
            response.raise_for_status()
            payload = response.json()
            self._token = payload["access_token"]
            self._token_expires_on = int(datetime.now(UTC).timestamp()) + int(payload.get("expires_in", 3600))
            return self._token

        # managed_identity
        if self._mi_credential is None:
            token_file = os.getenv("AZURE_FEDERATED_TOKEN_FILE")
            if token_file:
                assert WorkloadIdentityCredential is not None
                tenant_id = os.getenv("AZURE_TENANT_ID")
                if not tenant_id:
                    raise ValueError("SentinelClient: AZURE_TENANT_ID is required for AKS workload identity")
                self._mi_credential = WorkloadIdentityCredential(
                    tenant_id=tenant_id,
                    client_id=self._mi_client_id,
                    token_file_path=token_file,
                )
            else:
                assert ManagedIdentityCredential is not None
                self._mi_credential = ManagedIdentityCredential(client_id=self._mi_client_id)
        access = await self._mi_credential.get_token(SCOPE)
        self._token = access.token
        self._token_expires_on = access.expires_on
        return self._token

    async def close(self) -> None:
        """Release the managed-identity credential, if any.

        Request-scoped callers invoke this in ``finally`` blocks so the Azure
        Identity transport is released deterministically.
        """
        if self._mi_credential is not None:
            await self._mi_credential.close()
            self._mi_credential = None

    # ------------------------------------------------------------------
    # Public API — unchanged from upstream.
    # ------------------------------------------------------------------

    async def list_closed_incidents(
        self,
        since: datetime,
        until: datetime,
        *,
        limit: int = 1000,
    ) -> list[dict[str, Any]]:
        """List incidents an analyst closed in the window, with their classification.

        Gap-closure Phase 1.1. ARM pages with ``nextLink``; the loop follows it
        rather than reading only the first page, because a first-page-only read
        would silently grade a customer on whichever incidents happened to sort
        first and report the sample size as if it were the whole window.

        The OData filter bounds the window server-side. ``Status eq 'Closed'``
        is the only status that carries a classification, so an open incident
        cannot enter the corpus.

        Each incident is then given its ``entities``. An incident's
        ``properties`` carry a title, a severity and a classification and
        **no account and no host** — those live behind the incident's own
        entities endpoint — so without this second call every replayed
        Sentinel incident reached triage describing nobody.
        """
        results: list[dict[str, Any]] = []
        url: str | None = self._incidents_url()
        params: dict[str, Any] | None = {
            "api-version": API_VERSION,
            "$filter": (
                f"properties/status eq 'Closed' and "
                f"properties/lastModifiedTimeUtc ge {since.isoformat()} and "
                f"properties/lastModifiedTimeUtc le {until.isoformat()}"
            ),
            "$orderby": "properties/lastModifiedTimeUtc asc",
            "$top": min(limit, 200),
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            token = await self._access_token(client)
            while url and len(results) < limit:
                # Refresh the bearer per page when the cache went stale
                # mid-sweep (only possible on the managed-identity path,
                # which tracks expiry). Upstream re-used the first token
                # for the whole backfill — fine inside an hour, but a
                # 24-hour window can straddle a rotation.
                if not self._token_is_fresh():
                    token = await self._access_token(client)
                response = await client.get(
                    url,
                    headers={"Authorization": f"Bearer {token}"},
                    params=params,
                )
                response.raise_for_status()
                body = response.json() if response.content else {}
                results.extend(body.get("value") or [])
                # nextLink carries its own query string; re-sending params
                # would duplicate $filter and ARM rejects the request.
                url = _validated_arm_next_link(body.get("nextLink"))
                params = None
            incidents = results[:limit]
            for incident in incidents:
                if not self._token_is_fresh():
                    token = await self._access_token(client)
                entities = await self._incident_entities(client, token, str(incident.get("name") or ""))
                if entities:
                    incident["entities"] = entities
            return incidents

    async def _incident_entities(
        self,
        client: httpx.AsyncClient,
        token: str,
        incident_id: str,
    ) -> list[dict[str, Any]]:
        """The accounts, hosts and addresses ARM associates with one incident.

        One request per incident, which is what the API offers: entities are a
        sub-resource and there is no expansion on the list call. A history read
        is a once-per-evaluation-window job rather than a hot path, so the cost
        is paid there instead of leaving the corpus without entities.

        Never raises. An incident whose entities cannot be read still carries
        its analyst's classification, which is the label the evaluation is
        graded against; dropping the whole window over a missing host would
        trade the measurement for one of its columns.
        """
        if not incident_id:
            return []
        try:
            response = await client.post(
                f"{self._incident_url(incident_id)}/entities",
                headers={"Authorization": f"Bearer {token}"},
                params={"api-version": API_VERSION},
            )
            response.raise_for_status()
            body = response.json() if response.content else {}
        except Exception as exc:  # noqa: BLE001, a missing entity list degrades to no host and no user
            logger.warning(
                "sentinel.incident_entities_unavailable",
                incident_id=incident_id,
                error=str(exc),
            )
            return []
        return [entity for entity in body.get("entities") or [] if isinstance(entity, dict)]

    async def get_incident(self, incident_id: str) -> dict[str, Any]:
        """Read one incident. Used as the writeback verification probe."""
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            token = await self._access_token(client)
            response = await client.get(
                self._incident_url(incident_id),
                headers={"Authorization": f"Bearer {token}"},
                params={"api-version": API_VERSION},
            )
            response.raise_for_status()
            return response.json() if response.content else {}

    async def update_incident(
        self,
        incident_id: str,
        *,
        status: str,
        classification: str | None = None,
        classification_comment: str | None = None,
        owner_upn: str | None = None,
    ) -> dict[str, Any]:
        """PATCH an incident's status and classification.

        Sentinel's incident PATCH replaces ``properties`` wholesale rather than
        merging, so ``title`` and ``severity`` must be echoed back or the call
        fails validation. That means a read is not an optimisation here — it is
        required for correctness, and it is why this method issues two
        requests.
        """
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            token = await self._access_token(client)
            headers = {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            }
            url = self._incident_url(incident_id)
            params = {"api-version": API_VERSION}

            current = await client.get(url, headers=headers, params=params)
            current.raise_for_status()
            existing = (current.json() or {}).get("properties", {}) if current.content else {}

            properties: dict[str, Any] = {
                "title": existing.get("title") or f"AiSOC incident {incident_id}",
                "severity": existing.get("severity") or "Medium",
                "status": status,
            }
            if classification:
                properties["classification"] = classification
            if classification_comment:
                properties["classificationComment"] = classification_comment[:2000]
            if owner_upn:
                properties["owner"] = {"userPrincipalName": owner_upn}

            response = await client.patch(url, headers=headers, params=params, json={"properties": properties})
            response.raise_for_status()
            logger.info(
                "sentinel.incident.updated",
                incident_id=incident_id,
                status=status,
                classification=classification,
                auth_mode=self._auth_mode,
            )
            return {
                "success": True,
                "action": "update_incident",
                "incident_id": incident_id,
                "status": status,
                "classification": classification,
                "response": response.json() if response.content else {},
            }

    async def close_incident(
        self,
        incident_id: str,
        *,
        classification: str,
        comment: str,
    ) -> dict[str, Any]:
        """Close an incident with a classification and AiSOC's reasoning."""
        return await self.update_incident(
            incident_id,
            status="Closed",
            classification=classification,
            classification_comment=comment,
        )

    async def escalate_incident(
        self,
        incident_id: str,
        *,
        comment: str,
        owner_upn: str | None = None,
    ) -> dict[str, Any]:
        """Move an incident to Active and record why, leaving it OPEN.

        No classification is set: Sentinel only accepts one on a closed
        incident, and an incident AiSOC confirmed is precisely the one that
        must not be closed.
        """
        return await self.update_incident(
            incident_id,
            status="Active",
            classification_comment=comment,
            owner_upn=owner_upn,
        )
