###############################################################################
# Terraform: dedicated user-assigned managed identity for the AiSOC actions
# Container App, with Sentinel Responder at RG scope.
#
# Pair with 03-container_apps_identity.tf (which handles the connectors app's
# reader identity). Writeback runs on the actions app, which is a separate
# Container App with a separate identity so a leaked connectors token cannot
# close incidents and a leaked actions token cannot read them.
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
}

###############################################################################
# Sentinel Responder at the Sentinel RG scope.
#
# Scope mirrors the connectors reader: Sentinel's own RG, which can live in
# a different subscription from the AiSOC deployment. Responder includes
# everything Reader does, so the actions app can also fetch an incident for
# its "read before PATCH" step — PATCH replaces ``properties`` wholesale.
###############################################################################

resource "azurerm_role_assignment" "actions_sentinel_responder" {
  provider             = azurerm.sentinel_subscription
  scope                = data.azurerm_resource_group.sentinel.id
  role_definition_name = "Microsoft Sentinel Responder"
  principal_id         = azurerm_user_assigned_identity.actions.principal_id

  depends_on = [azurerm_user_assigned_identity.actions]
}

###############################################################################
# Actions Container App.
#
# No AZURE_CLIENT_ID / AZURE_TENANT_ID exported here. The actions service
# constructs ``SentinelClient`` per request from the saved connector row's
# parameters, and the row carries ``sentinel_managed_identity_client_id``
# directly. That means one actions app can serve several tenants each with
# its own identity should that ever be useful, instead of baking a single
# identity into the process environment.
###############################################################################

resource "azurerm_container_app" "actions" {
  name                         = "${var.name_prefix}-actions"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.actions.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.actions.id
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
}

###############################################################################
# Outputs.
###############################################################################

output "actions_identity_client_id" {
  value       = azurerm_user_assigned_identity.actions.client_id
  description = "Paste this into the response-action's writeback credentials as 'sentinel_managed_identity_client_id'."
}

output "actions_identity_principal_id" {
  value       = azurerm_user_assigned_identity.actions.principal_id
  description = "Only used for debugging role assignments ('az role assignment list --assignee ...')."
  sensitive   = false
}
