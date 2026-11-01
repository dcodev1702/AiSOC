###############################################################################
# Terraform: dedicated user-assigned managed identity for the AiSOC connectors
# Container App, with Sentinel Reader at RG scope.
#
# This file is a prototype addition to AiSOC's Azure skeleton
# (infra/terraform/azure/). It intentionally defines a NEW connectors app
# rather than editing the api/web/ingest set, because the upstream Terraform
# does not yet include connectors, fusion, agents, actions, or threatintel.
#
# Pair with 03b_container_apps_identity_actions.tf for the writeback identity
# on the actions Container App when you're ready to grant Responder.
#
# Prerequisite: the matching Sentinel workspace lives in <sentinel_rg_name>.
###############################################################################

variable "sentinel_subscription_id" {
  type        = string
  description = "Subscription that owns the Sentinel workspace."
}

variable "sentinel_rg_name" {
  type        = string
  description = "Resource group that owns the Sentinel workspace. Role is granted at this scope — not at the subscription — so the connectors app can only read inside this RG."
}

###############################################################################
# User-assigned identity for the connectors app.
###############################################################################

resource "azurerm_user_assigned_identity" "connectors" {
  name                = "${var.name_prefix}-connectors"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
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
  provider             = azurerm.sentinel_subscription
  scope                = data.azurerm_resource_group.sentinel.id
  role_definition_name = "Microsoft Sentinel Reader"
  principal_id         = azurerm_user_assigned_identity.connectors.principal_id

  # The identity's principal ID is created a few seconds before Entra sees it
  # consistently; without a dependency the first apply after a cold start
  # fails with "principal not found" and succeeds on the next apply.
  depends_on = [azurerm_user_assigned_identity.connectors]
}

###############################################################################
# Connectors Container App.
#
# Minimal shape; mirror from container_apps.tf for the fuller env block (DB,
# Redis, Kafka). The identity-relevant pieces are:
#   - identity.type = "UserAssigned"
#   - identity.identity_ids holds the connectors identity resource ID
#   - env vars make it visible to the Python layer (not strictly required —
#     azure-identity reads IDENTITY_ENDPOINT itself — but useful for logs)
###############################################################################

resource "azurerm_container_app" "connectors" {
  name                         = "${var.name_prefix}-connectors"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.connectors.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.connectors.id
  }

  template {
    # One replica is a correctness constraint until the connector scheduler
    # has leader election. Two replicas each poll every connector; dedupe is
    # best-effort downstream.
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "connectors"
      image  = var.connectors_image
      cpu    = 0.5
      memory = "1Gi"

      # No AZURE_CLIENT_ID / AZURE_TENANT_ID exported here. The patched
      # connector reads ``managed_identity_client_id`` from the saved
      # connector row (per Sentinel instance), not from process env, so one
      # app can serve several tenants each with their own identity should
      # that ever be useful. For now the identity ID is also exported for
      # logging convenience.
      env {
        name  = "AISOC_CONNECTORS_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.connectors.client_id
      }
      env {
        name  = "AISOC_SCHEDULER_LEADER_ELECTION"
        value = "true"
      }
    }
  }
}

###############################################################################
# Outputs — the connectors identity's clientId is what the console form needs.
###############################################################################

output "connectors_identity_client_id" {
  value       = azurerm_user_assigned_identity.connectors.client_id
  description = "Paste this into the Sentinel connector's 'Managed Identity Client ID' field in the AiSOC console."
}

output "connectors_identity_principal_id" {
  value       = azurerm_user_assigned_identity.connectors.principal_id
  description = "Only used for debugging role assignments ('az role assignment list --assignee ...')."
  sensitive   = false
}
