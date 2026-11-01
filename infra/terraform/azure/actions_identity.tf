###############################################################################
# Terraform: dedicated user-assigned managed identity for the AiSOC actions
# Container App, with Sentinel Responder at RG scope.
#
# Writeback runs on a separate Container App and identity so a compromised
# connectors token cannot close incidents. The actions identity can read and
# manage incidents, but only within the configured Sentinel resource group.
#
# Prerequisite: the matching Sentinel workspace lives in <sentinel_rg_name>
# in <sentinel_subscription_id>; the provider alias is already declared.
###############################################################################

###############################################################################
# User-assigned identity for the actions app.
###############################################################################

resource "azurerm_user_assigned_identity" "actions" {
  name                = "${var.name_prefix}-actions"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  tags                = var.tags
}

###############################################################################
# Sentinel Responder at the Sentinel RG scope.
#
# Scope mirrors the connectors reader: Sentinel's own RG, which can live in
# a different subscription from the AiSOC deployment. Responder includes
# everything Reader does, so the actions app can also fetch an incident for
# its "read before PATCH" step — the connector identity cannot write, while
# this action identity can read and manage incidents.
###############################################################################

resource "azurerm_role_assignment" "actions_sentinel_responder" {
  provider                         = azurerm.sentinel_subscription
  scope                            = data.azurerm_resource_group.sentinel.id
  role_definition_name             = "Microsoft Sentinel Responder"
  principal_id                     = azurerm_user_assigned_identity.actions.principal_id
  skip_service_principal_aad_check = true
}

###############################################################################
# Actions Container App.
#
# The identity client ID is deployment-controlled so action parameters cannot
# select a different identity attached to the app.
###############################################################################

resource "azurerm_container_app" "actions" {
  name                         = "${var.name_prefix}-actions"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.actions.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.actions.id
  }

  secret {
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.actions.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "credential-key"
    identity            = azurerm_user_assigned_identity.actions.id
    key_vault_secret_id = azurerm_key_vault_secret.credential_key.versionless_id
  }
  secret {
    name                = "secret-key"
    identity            = azurerm_user_assigned_identity.actions.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_key.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.actions.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8085
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 3

    container {
      name   = "actions"
      image  = var.actions_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AISOC_ACTIONS_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.actions.client_id
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
        name  = "PORT"
        value = "8085"
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
      env {
        name        = "AISOC_ACTIONS_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "AISOC_API_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      # The approval path depends on these being set — leaving the chatops
      # approver map unset refuses every Slack / Teams / email approval
      # with a 403, which is the right default when nothing has been
      # configured yet. See apps/docs/docs/operations/action-approvals.md.
      env {
        name  = "AISOC_ACTIONS_REQUIRE_APPROVER"
        value = "true"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.actions_sentinel_responder,
    azurerm_postgresql_flexible_server_database.aisoc,
  ]
}

###############################################################################
# Outputs.
###############################################################################

output "actions_identity_client_id" {
  value       = azurerm_user_assigned_identity.actions.client_id
  description = "Deployment-pinned client ID used by the actions service."
}

output "actions_identity_principal_id" {
  value       = azurerm_user_assigned_identity.actions.principal_id
  description = "Only used for debugging role assignments ('az role assignment list --assignee ...')."
  sensitive   = false
}
