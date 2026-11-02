###############################################################################
# Terraform: dedicated user-assigned managed identity for the AiSOC connectors
# Container App, with Sentinel Reader at RG scope.
#
# The polling identity is separate from the writeback identity so compromise
# of the connectors service cannot grant incident-management permissions.
#
# Prerequisite: the matching Sentinel workspace lives in <sentinel_rg_name>.
###############################################################################

###############################################################################
# User-assigned identity for the connectors app.
###############################################################################

resource "azurerm_user_assigned_identity" "connectors" {
  name                = "${var.name_prefix}-connectors"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

###############################################################################
# Sentinel Reader at the Sentinel RG scope.
#
# scope deliberately points at the Sentinel RG, which may live in a different
# subscription from the AiSOC deployment. The connectors app only ever reads
# incidents, so Reader is enough for the polling path; writeback (Responder)
# is a separate assignment on the actions app.
###############################################################################

data "azurerm_resource_group" "sentinel" {
  name     = var.sentinel_rg_name
  provider = azurerm.sentinel_subscription
}

resource "azurerm_role_assignment" "connectors_sentinel_reader" {
  provider                         = azurerm.sentinel_subscription
  scope                            = data.azurerm_resource_group.sentinel.id
  role_definition_name             = "Microsoft Sentinel Reader"
  principal_id                     = azurerm_user_assigned_identity.connectors.principal_id
  skip_service_principal_aad_check = true
}

###############################################################################
# Connectors Container App.
#
# This service is always on because it owns the polling scheduler. The
# deployment pins the identity client ID; a tenant-controlled connector row
# cannot select another identity attached to the app.
###############################################################################

resource "azurerm_container_app" "connectors" {
  name                         = "${var.name_prefix}-connectors"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.connectors.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.connectors.id
  }

  secret {
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.connectors.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "credential-key"
    identity            = azurerm_user_assigned_identity.connectors.id
    key_vault_secret_id = azurerm_key_vault_secret.credential_key.versionless_id
  }
  secret {
    name                = "secret-key"
    identity            = azurerm_user_assigned_identity.connectors.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_key.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.connectors.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8087
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Keep one steady-state replica for this test deployment. The database
    # lease still protects rolling revisions from polling the same source at
    # the same time.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "connectors"
      image  = var.connectors_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AISOC_CONNECTORS_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.connectors.client_id
      }
      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name = "AISOC_DATABASE_CONFIG_REVISION"
        value = nonsensitive(sha256(join(":", [
          azurerm_key_vault_secret.database_asyncpg_url.versionless_id,
          azurerm_key_vault_secret.database_asyncpg_url.value,
        ])))
      }
      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "PORT"
        value = "8087"
      }
      env {
        name  = "INGEST_SERVICE_URL"
        value = "https://${azurerm_container_app.ingest.ingress[0].fqdn}"
      }
      env {
        name  = "AISOC_SCHEDULER_LEADER_ELECTION"
        value = "true"
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "AISOC_CREDENTIAL_KEY"
        secret_name = "credential-key"
      }
      env {
        name        = "SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "AISOC_SERVICE_TOKEN"
        secret_name = "service-token"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.connectors_sentinel_reader,
    azurerm_postgresql_flexible_server_database.aisoc,
  ]
}

###############################################################################
# Outputs.
###############################################################################

output "connectors_identity_client_id" {
  value       = azurerm_user_assigned_identity.connectors.client_id
  description = "Deployment-pinned client ID used by the connectors service."
}

output "connectors_identity_principal_id" {
  value       = azurerm_user_assigned_identity.connectors.principal_id
  description = "Only used for debugging role assignments ('az role assignment list --assignee ...')."
  sensitive   = false
}
