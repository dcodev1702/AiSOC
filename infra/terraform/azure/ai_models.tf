/**
 * Microsoft Foundry model plane.
 *
 * GPT-5.6-Terra is deployed immediately. Claude Sonnet 5.5 uses the
 * Azure-hosted catalog build and is conditional on legally accurate offer
 * attestation values. The deployment must never invent those values.
 */

locals {
  foundry_account_name  = "${var.name_prefix}-foundry-${random_string.foundry_suffix.result}"
  foundry_project_name  = "${var.name_prefix}-soc"
  claude_sonnet_enabled = var.enable_claude_sonnet && trimspace(var.claude_organization_name) != ""
  foundry_private_zones = toset([
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
  ])
}

resource "random_string" "foundry_suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azapi_resource" "foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-10-01-preview"
  name      = local.foundry_account_name
  parent_id = azurerm_resource_group.main.id
  location  = var.ai_location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "AIServices"
    sku = {
      name = "S0"
    }
    properties = {
      customSubDomainName    = local.foundry_account_name
      allowProjectManagement = true
      disableLocalAuth       = true
      publicNetworkAccess    = "Disabled"
    }
  }

  response_export_values = ["name", "identity.principalId"]
}

resource "azapi_resource" "foundry_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview"
  name      = local.foundry_project_name
  parent_id = azapi_resource.foundry.id
  location  = var.ai_location
  tags      = var.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {}
  }

  response_export_values = ["name", "identity.principalId"]
}

resource "azapi_resource" "gpt_terra" {
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name                      = "gpt-5-6-terra"
  parent_id                 = azapi_resource.foundry.id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.gpt_terra_capacity
    }
    properties = {
      model = {
        format  = "OpenAI"
        name    = "gpt-5.6-terra"
        version = "2026-07-09"
      }
      versionUpgradeOption = "NoAutoUpgrade"
      raiPolicyName        = "Microsoft.DefaultV2"
    }
  }

  response_export_values = ["name", "properties.provisioningState"]
  depends_on             = [azapi_resource.foundry_project]
}

resource "azapi_resource" "claude_sonnet" {
  count                     = local.claude_sonnet_enabled ? 1 : 0
  type                      = "Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview"
  name                      = "claude-sonnet-5-5"
  parent_id                 = azapi_resource.foundry.id
  schema_validation_enabled = false

  body = {
    sku = {
      name     = "GlobalStandard"
      capacity = var.claude_sonnet_capacity
    }
    properties = {
      model = {
        format  = "Anthropic"
        name    = "claude-sonnet-5-5"
        version = "2"
      }
      modelProviderData = {
        organizationName = var.claude_organization_name
        countryCode      = var.claude_country_code
        industry         = var.claude_industry
      }
      versionUpgradeOption = "NoAutoUpgrade"
      raiPolicyName        = "Microsoft.DefaultV2"
    }
  }

  lifecycle {
    precondition {
      condition     = var.claude_country_code != "" && var.claude_industry != ""
      error_message = "Claude deployment requires an accurate country code and industry with the legal organization name."
    }
  }

  response_export_values = ["name", "properties.provisioningState"]
  depends_on             = [azapi_resource.gpt_terra]
}

# The model gateway is the only workload that calls Foundry. It uses the
# existing pipeline UAMI and the least-privilege inference role.
resource "azurerm_role_assignment" "foundry_pipeline_user" {
  scope                            = azapi_resource.foundry.id
  role_definition_name             = "Cognitive Services User"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_private_dns_zone" "foundry" {
  for_each = local.foundry_private_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  for_each = local.foundry_private_zones

  name                  = "${var.name_prefix}-${replace(each.value, ".", "-")}-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.foundry[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "foundry" {
  name                = "${var.name_prefix}-foundry-pe"
  location            = local.workload_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.privatelink.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-foundry-psc"
    private_connection_resource_id = azapi_resource.foundry.id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "foundry"
    private_dns_zone_ids = [for zone in azurerm_private_dns_zone.foundry : zone.id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.foundry]
}
