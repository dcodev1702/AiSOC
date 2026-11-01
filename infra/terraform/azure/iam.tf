/**
 * AiSOC — Azure serverless skeleton
 *
 * Three user-assigned managed identities split the deployment by trust
 * boundary rather than by process:
 *   - runtime: api, web, and ingest platform access
 *   - connectors: read-only Sentinel polling
 *   - actions: governed Sentinel writeback
 *
 * Bindings:
 * Every identity gets AcrPull. All three read runtime secrets from Key Vault;
 * the Sentinel permissions remain exclusive to connectors and actions.
 * Sharing runtime trades per-process isolation for a smaller, test-friendly
 * RBAC surface. Split it again for production if web compromise must not grant
 * access to API/ingest secrets.
 */

# ─── User-assigned managed identities ────────────────────────────────────────

resource "azurerm_user_assigned_identity" "runtime" {
  name                = "${var.name_prefix}-runtime"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

# ─── ACR pull ────────────────────────────────────────────────────────────────

locals {
  acr_pull_identities = {
    runtime    = azurerm_user_assigned_identity.runtime.principal_id
    connectors = azurerm_user_assigned_identity.connectors.principal_id
    actions    = azurerm_user_assigned_identity.actions.principal_id
  }
}

resource "azurerm_role_assignment" "acr_pull" {
  for_each = local.acr_pull_identities

  scope                            = azurerm_container_registry.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = each.value
  skip_service_principal_aad_check = true
}

# ─── Key Vault Secrets User ──────────────────────────────────────────────────

locals {
  kv_reader_identities = {
    runtime    = azurerm_user_assigned_identity.runtime.principal_id
    connectors = azurerm_user_assigned_identity.connectors.principal_id
    actions    = azurerm_user_assigned_identity.actions.principal_id
  }
}

resource "azurerm_role_assignment" "kv_secrets_user" {
  for_each = local.kv_reader_identities

  scope                            = azurerm_key_vault.main.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = each.value
  skip_service_principal_aad_check = true
}
