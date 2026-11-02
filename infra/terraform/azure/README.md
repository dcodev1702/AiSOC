# AiSOC on Azure — Terraform deployment

A serverless-first deployment of the AiSOC stack on Microsoft Azure, mirroring
the [GCP skeleton](../gcp/README.md):

- **Azure Container Apps** for the API, web console, ingest gateway,
  connectors scheduler, governed actions, fusion, UEBA, agents, realtime, and
  scheduled evidence-lifecycle jobs
- **Azure Event Hubs Standard** as the private Kafka-compatible application
  event spine, authenticated only with a user-assigned managed identity
- **Azure Database for PostgreSQL Flexible Server 16** for the application
  database (VNet-integrated private access, no public endpoint)
- **Azure Managed Redis** for queues, rate limits, and websocket fan-out
  (private endpoint, TLS-only)
- **Azure Key Vault** for application secrets, service-to-service tokens, and
  service-specific TLS database URLs
- **Azure Container Registry** as the registry CI pushes to
- **ClickHouse and Neo4j** on one isolated Spot VM with Standard SSD for the
  low-volume PoC's hot event search and entity relationship graph
- **ADLS Gen2 Standard LRS** with private endpoints for Parquet evidence and
  checksum/restore-verified ClickHouse backups
- **Microsoft Foundry** with private networking, local authentication disabled,
  and an internal OpenAI-compatible gateway that obtains model tokens with the
  pipeline managed identity
- **Four user-assigned managed identities** aligned to trust boundaries: a
  shared API/web runtime, an ingest/fusion/agents/realtime/model-gateway
  pipeline identity, a read-only Sentinel connector, and a Sentinel writeback
  identity — no Event Hubs connection strings, registry passwords, provider
  API keys, or application client secrets

Sentinel remains the system of record. The connector polls the existing
Sentinel incident API and sends those normalized records through ingest. Event
Hubs carries AiSOC's internal events from ingest to fusion, agents, and
realtime; Log Analytics tables do **not** need diagnostic export to Event Hubs.

## Layout

```
infra/terraform/azure/
├── README.md                ← you are here
├── versions.tf              ← terraform + provider pinning, provider features
├── variables.tf             ← input variables (defaults targeting startup credit)
├── main.tf                  ← resource group, VNet + subnets, existing LAW,
│                              Container Apps environment, ACR
├── database.tf              ← Postgres Flexible Server + DB + private DNS
├── redis.tf                 ← Azure Managed Redis + private endpoint
├── secrets.tf               ← Key Vault + generated/optional secret values
├── iam.tf                   ← shared runtime identity + role assignments
├── container_apps.tf        ← api / web / ingest Container Apps
├── event_hubs.tf            ← Standard Kafka endpoint, topics, private link
├── ai_services.tf           ← fusion / UEBA / agents / realtime Container Apps
├── ai_models.tf             ← private Foundry account, project, deployments,
│                              private endpoint/DNS, inference RBAC
├── ai_gateway.tf            ← internal model gateway using pipeline UAMI
├── clickhouse.tf            ← Spot VM, ClickHouse, Neo4j, ADLS Gen2, lifecycle
├── lake_operations.tf       ← scheduled Parquet archive + backup/restore jobs
├── monitoring.tf            ← Event Hubs and Spot VM operational alerts
├── connectors_identity.tf   ← connectors app + Sentinel Reader identity
├── actions_identity.tf      ← actions app + Sentinel Responder identity
├── ARCHITECTURE.md          ← deployed data flow, trust boundaries, storage
├── outputs.tf               ← URLs, connection targets, identity + vault IDs
└── terraform.tfvars.example ← copy → terraform.tfvars and override
```

Files are split by concern, not by module, to keep the skeleton legible. Lift
into modules when you start running multiple environments off the same code.

## Prerequisites

1. **An Azure subscription** with credits or billing attached.
2. **`az` authenticated** (`az login`) as a principal that can create resource
   groups, Container Apps, Postgres, Key Vault, and **role assignments**.
   Granting role assignments needs `Owner` or `User Access Administrator` on
   the subscription (the apply wires AcrPull + Key Vault Secrets User itself).
3. **Terraform 1.5+** and the `azurerm` 4.70 provider (the lockfile pins the
   exact versions on first `init`).
4. **Required Azure resource providers already registered.** The providers set
   `resource_provider_registrations = "none"` so a read-only `terraform plan`
   cannot change subscription-wide provider state. Register the services before
   the first apply:
   ```bash
   for namespace in \
     Microsoft.App Microsoft.Authorization Microsoft.Cache \
     Microsoft.CognitiveServices Microsoft.Compute Microsoft.ContainerRegistry \
     Microsoft.DBforPostgreSQL Microsoft.EventHub Microsoft.Insights \
     Microsoft.KeyVault Microsoft.ManagedIdentity Microsoft.Network \
     Microsoft.OperationalInsights Microsoft.SecurityInsights Microsoft.Storage; do
     az provider register --namespace "$namespace" --wait
   done
   ```
5. **The configured remote-state storage account.** This environment uses the
   Azure Storage backend declared in `versions.tf` and Entra authentication.
6. **An existing Log Analytics workspace with Microsoft Sentinel enabled** in
   the same Entra tenant. Set `sentinel_rg_name` and
   `sentinel_workspace_name`; set
   `sentinel_subscription_id` only when it differs from the deployment
   subscription.

## Quick start

```bash
cd infra/terraform/azure
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars            # set the Sentinel resource group + workspace

az login
az account set --subscription <subscription-id>

terraform init
terraform plan -out tfplan          # review the proposed plan
terraform apply tfplan
```

A full apply can take 20–45 minutes — most of that is PostgreSQL and Azure
Managed Redis provisioning. After apply, the
`api_url`, `web_url`, and `ingest_url` outputs are publicly reachable
immediately. Connectors, actions, fusion, agents, and realtime use internal
ingress and are reached through the API/web gateways.

## Sentinel, Log Analytics, and Event Hubs

The default hybrid path deliberately exports zero Log Analytics tables:

```text
Sentinel incident API -> connectors -> ingest -> Event Hubs -> fusion -> agents/realtime
```

`SecurityIncident`, `SecurityAlert`, and `AlertEvidence` remain queryable in
`drydock-law` for investigation. Add a Log Analytics data-export rule only if
you later need raw, near-real-time table streaming that the incident poll does
not provide. In that optional mode, forward only the tables required by the
specific use case; do not duplicate the entire workspace by default.

The connector records the last source event it successfully submitted as
`connectors.last_event_at`, while `events_ingested` is a cumulative accepted
counter. Direct ingest and Event Hubs replay have no connector row, so the
Operations Funnel uses the ingest service's `/readyz` result, cached for 60
seconds, as the primary status signal. That endpoint actively verifies the
managed-identity Kafka connection to Event Hubs. Recent persisted flow and
connector freshness remain fallbacks for deployments that do not configure the
active probe. Stale connectors still remain visible in the backlog and
connector-health views.

Event Hubs is the private application transport, not the analytical archive.
The deployed test stack persists application state in PostgreSQL, raw event
projections in ClickHouse, entity relationships in Neo4j, and lifecycle copies
in ADLS Gen2. Every hub uses the Standard tier maximum of seven days,
configurable from one through seven with `eventhub_message_retention_days`.
Extending the transport window does not change throughput or consumer
behavior, but retained volume beyond the tier's included allowance can add
storage charges.

## ClickHouse, Neo4j, and five-year evidence lifecycle

The PoC deliberately uses one small, evictable compute node rather than a
premium managed cluster:

- a `Standard_E2as_v5` Spot VM in an isolated, peered VNet;
- Standard SSD LRS for both the OS and the 512 GiB data disk;
- ClickHouse for 365-day hot search (with a 400-day TTL safety ceiling);
- Neo4j Community for entity and relationship pivots; and
- ADLS Gen2 Standard LRS with hierarchical namespace, private endpoints,
  public access disabled, and shared-key access disabled.

The daily archive job exports age-qualified ClickHouse rows as Parquet. ADLS
keeps the export cool/cold for its first year, archives it for the next three,
and deletes it after four years in ADLS. Combined with the first year in
ClickHouse, this is the requested five-year lifecycle. The weekly backup job
uploads a snapshot, downloads it again, verifies its SHA-256 digest, restores
it into a temporary ClickHouse table, and compares row counts.

This is a cost-oriented PoC floor, not a high-availability architecture. A Spot
eviction can interrupt search until the VM returns or a restore is performed;
ADLS and the verified backup job are the recovery boundary.

## AI model plane

The API and agents call an internal model gateway. The gateway is assigned the
pipeline user-managed identity and receives `Cognitive Services User` on the
private Foundry account. Foundry local authentication and public network access
are disabled, so upstream inference uses Entra tokens rather than provider API
keys.

`gpt-5-6-terra` is deployed and is the active fast and deep model in this test
subscription. `claude-sonnet-5-5` is fully codified but disabled by default.
Both Azure-hosted and publisher-hosted deployment attempts returned
`MarketplaceSubscriptionCannotBeCompleted`, which is a subscription-level
Marketplace allowlist condition. After Microsoft enables the offer, set the
accurate attestation variables and `enable_claude_sonnet = true`; the deep
aliases then switch to Claude without changing callers.

The Key Vault-backed `LITELLM_MASTER_KEY` authenticates internal clients to the
gateway. It is not a model-provider credential. The gateway itself obtains its
Foundry access token through managed identity.

## UEBA, continuous hunts, and response policy

Sentinel Entity Analytics is enabled for Azure Active Directory, native
Anomalies is enabled, and UEBA is active for sign-in, audit, managed identity,
device logon, SecurityEvent, and AzureActivity sources. AiSOC's UEBA service
also consumes `aisoc.raw_events` from its dedicated Event Hubs consumer group
using the pipeline identity.

The agents service vendors and schedules 68 hunt definitions for the PoC
tenant and reads the ClickHouse event lake on each cycle. The actions service
runs with `AISOC_MATURITY_TIER=L1`: policy evaluation is enabled, but
destructive or high-impact response remains human-approval gated.

## State backend

This environment uses the Entra-authenticated Azure Storage backend declared
in `versions.tf`. Run `terraform init -reconfigure` after changing backend
coordinates. Do not commit a local state file or pass storage account keys; the
backend and the deployed data plane both use Azure identity.

## Container images

The defaults point at the public GHCR demo images
(`ghcr.io/beenuar/aisoc-*:latest`) so the skeleton runs with
zero CI work. For a real deployment, push your own images to the ACR this stack
provisions:

```bash
ACR=$(terraform output -raw container_registry_login_server)
az acr login --name "${ACR%%.*}"

docker build -t $ACR/api:$(git rev-parse --short HEAD)    services/api
docker push     $ACR/api:$(git rev-parse --short HEAD)
# repeat for web, ingest, connectors, actions, fusion, agents, realtime,
# and the model gateway

terraform apply \
  -var "api_image=$ACR/api:<sha>" \
  -var "web_image=$ACR/web:<sha>" \
  -var "ingest_image=$ACR/ingest:<sha>" \
  -var "connectors_image=$ACR/connectors:<sha>" \
  -var "actions_image=$ACR/actions:<sha>"
```

The four managed identities already hold `AcrPull`, so no registry admin user
or password is needed. Four identities is the lean trust-boundary result, not
one identity per service: runtime covers API/web; pipeline covers the five
event and model workloads; connectors remains read-only in Sentinel; actions
keeps Sentinel writeback separate. The pipeline identity alone has Event Hubs
Data Sender/Receiver and Foundry inference. The connector Reader and action
Responder identities remain separate because their Sentinel permissions are
materially different.

## Connecting to Postgres from your laptop

The Flexible Server has no public endpoint — it's only resolvable inside the
VNet via the `privatelink.postgres.database.azure.com` zone. Reach it through a
jump host in the VNet or a point-to-site VPN. The runtime login is `aisoc_app`;
its password lives in Key Vault:

```bash
VAULT=$(terraform output -raw key_vault_name)
az keyvault secret show --vault-name "$VAULT" --name postgres-password \
  --query value -o tsv
```

The migration owner is deliberately separate from the runtime login. The API
reads `database-migration-url` only during fail-fast startup migrations, then
serves requests with the lower-privilege `database-url`. Connectors and actions
use `database-asyncpg-url`, which avoids a libpq-only query parameter rejected
by their direct asyncpg callers. Ingest uses `database-pgx-url`, which retains
`sslmode=require` without SQLAlchemy's driver marker and enables fail-closed
tenant validation. PostgreSQL enforces encrypted transport for all paths, and
Terraform allow-lists the `uuid-ossp` and `pgcrypto`
extensions required by the schema.

## Costs

Defaults favor a small deployment, but Azure Managed Redis, always-on pipeline
replicas, retained Event Hubs data, the Standard SSD, and ADLS capacity still
incur cost. The ClickHouse/Neo4j host is Spot and can be evicted. Check the
Azure calculator for the selected region and current pricing. For a
cost-sensitive sandbox, set
`postgres_sku = "B_Standard_B1ms"`, `managed_redis_sku = "Balanced_B0"`, and
`managed_redis_high_availability_enabled = false` in `terraform.tfvars`.

## Limitations

Known gaps:

- **External attribution and bulk IOC enrichment endpoints are not configured.**
  Native Sentinel UEBA/anomalies and the AiSOC UEBA consumer are active, but
  optional third-party enrichment calls fail open and log the missing service.
- **Managed Redis is TLS-only.** The API uses a Key Vault-backed `rediss://`
  URL and the other workloads use the database-reported encrypted port
  (currently `10000`).
- **The graph and lake are single-node PoC services.** ClickHouse and Neo4j
  share one Spot VM and one Standard SSD. Backups are restore-verified in ADLS,
  but search and graph queries are unavailable during eviction or restoration.
- **Claude Sonnet 5.5 is awaiting subscription allowlisting.** The deployment,
  routing, attestation inputs, and managed-identity path are present, but the
  test subscription cannot create the Marketplace deployment until Microsoft
  enables the offer. GPT-5.6-Terra remains the deep-model fallback meanwhile.
- **No Azure Front Door / WAF.** Container Apps ingress gives every service a
  managed `*.azurecontainerapps.io` certificate, fine for the skeleton. Put
  Azure Front Door + WAF in front of the API for a custom domain and edge
  filtering.
- **No customer-managed keys.** Key Vault is the secret store; CMEK on
  Postgres / Managed Redis / ACR is a small addition deferred to keep the trust
  boundary tight.
- **Key Vault public access stays on** to keep first-run secret population
  simple (it mirrors GCP Secret Manager's API-plane reachability). Lock it down
  with a private endpoint + `network_acls` for a hardened install.
- **Demo image source.** `ghcr.io/beenuar/aisoc-*` is the zero-config default;
  don't ship that to production. See *Container images* above.

## Tear-down

```bash
terraform destroy
```

Key Vault is created with soft-delete on but **purge-on-destroy enabled**
(`versions.tf`), so a destroy fully removes it — back up any secrets you want
to keep first. The Postgres server and Managed Redis instance are deleted with the rest of
the stack.
