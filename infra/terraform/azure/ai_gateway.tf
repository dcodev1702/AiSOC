/** Internal OpenAI-compatible gateway for managed-identity Foundry access. */

resource "azurerm_container_app" "model_gateway" {
  name                         = "${var.name_prefix}-model-gateway"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.pipeline.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.pipeline.id
  }

  secret {
    name                = "litellm-master-key"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.litellm_master_key.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 4000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = 1

    container {
      name   = "model-gateway"
      image  = var.model_gateway_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "AISOC_LLM_MODEL_FAST"
        value = "azure/gpt-5-6-terra"
      }
      env {
        name  = "AISOC_LLM_MODEL_DEEP"
        value = local.claude_sonnet_enabled ? "azure_ai/claude-sonnet-5-5" : "azure/gpt-5-6-terra"
      }
      env {
        name  = "AISOC_LLM_BASE_MODEL_FAST"
        value = "azure/gpt-5.6-terra"
      }
      env {
        name  = "AISOC_LLM_BASE_MODEL_DEEP"
        value = local.claude_sonnet_enabled ? "azure_ai/claude-sonnet-5-5" : "azure/gpt-5.6-terra"
      }
      env {
        name  = "AISOC_LLM_API_BASE"
        value = "https://${local.foundry_account_name}.services.ai.azure.com"
      }
      env {
        name  = "AISOC_LITELLM_REQUEST_TIMEOUT"
        value = "120"
      }
      env {
        name  = "AZURE_CREDENTIAL"
        value = "ManagedIdentityCredential"
      }
      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "AZURE_SCOPE"
        value = "https://ai.azure.com/.default"
      }
      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
      }

      liveness_probe {
        transport = "HTTP"
        port      = 4000
        path      = "/health/liveliness"
      }

      readiness_probe {
        transport = "HTTP"
        port      = 4000
        path      = "/health/liveliness"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.foundry_pipeline_user,
    azurerm_private_endpoint.foundry,
    azapi_resource.gpt_terra,
    azapi_resource.claude_sonnet,
  ]
}
