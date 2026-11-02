/**
 * AiSOC — Azure serverless skeleton
 *
 * Outputs scoped to what an operator needs right after `terraform apply`: the
 * public Container App URLs, the connection targets the API dials, and the IDs
 * the matching CI workflow needs to push container images. Mirrors the GCP
 * stack's outputs.tf.
 */

# ─── Container App URLs ──────────────────────────────────────────────────────

output "api_url" {
  description = "Public Container App URL for the AiSOC API."
  value       = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

output "web_url" {
  description = "Public Container App URL for the AiSOC web console."
  value       = "https://${azurerm_container_app.web.ingress[0].fqdn}"
}

output "ingest_url" {
  description = "Public Container App URL for the AiSOC ingest endpoint."
  value       = "https://${azurerm_container_app.ingest.ingress[0].fqdn}"
}

# ─── PostgreSQL Flexible Server ──────────────────────────────────────────────

output "postgres_fqdn" {
  description = "Private FQDN of the PostgreSQL Flexible Server (resolves inside the VNet)."
  value       = azurerm_postgresql_flexible_server.main.fqdn
}

output "postgres_database" {
  description = "Application database name inside the Flexible Server."
  value       = azurerm_postgresql_flexible_server_database.aisoc.name
}

output "postgres_admin_user" {
  description = "Administrator login for the Flexible Server."
  value       = var.postgres_user
}

# ─── Azure Managed Redis ─────────────────────────────────────────────────────

output "redis_hostname" {
  description = "Private hostname of the Azure Managed Redis instance."
  value       = azurerm_managed_redis.main.hostname
}

output "redis_ssl_port" {
  description = "TLS port of the Azure Managed Redis instance."
  value       = azurerm_managed_redis.main.default_database[0].port
}

# ─── Container Registry ──────────────────────────────────────────────────────

output "container_registry_login_server" {
  description = "ACR login server (push target for CI image builds)."
  value       = azurerm_container_registry.main.login_server
}

# ─── Managed identities ──────────────────────────────────────────────────────

output "identity_runtime_client_id" {
  description = "Client ID of the shared API and web runtime identity."
  value       = azurerm_user_assigned_identity.runtime.client_id
}

output "identity_pipeline_client_id" {
  description = "Client ID of the ingest, fusion, agents, and realtime pipeline identity."
  value       = azurerm_user_assigned_identity.pipeline.client_id
}

output "event_hubs_namespace" {
  description = "Standard Event Hubs namespace used through its Kafka-compatible endpoint."
  value       = azurerm_eventhub_namespace.main.name
}

output "fusion_url" {
  description = "Internal fusion service URL."
  value       = local.internal_fusion_url
}

output "agents_url" {
  description = "Internal agents service URL."
  value       = local.internal_agents_url
}

output "realtime_url" {
  description = "Internal realtime service URL."
  value       = local.internal_realtime_url
}

# ─── Key Vault ───────────────────────────────────────────────────────────────

output "key_vault_name" {
  description = "Name of the Key Vault holding the runtime secrets."
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Vault URI for ad-hoc `az keyvault secret show` after apply."
  value       = azurerm_key_vault.main.vault_uri
}

output "realtime_jwt_secret_name" {
  description = "Key Vault secret name for the shared realtime WS/SSE ticket secret (Issue #239). Wire this into the realtime workload (always-on Container App / AKS follow-up) as AISOC_REALTIME_JWT_SECRET so it verifies the same tickets the API mints."
  value       = azurerm_key_vault_secret.realtime_jwt_secret.name
}
