/**
 * AiSOC — Azure serverless skeleton
 *
 * Bootstraps shared resources required by every other file in this stack:
 *   - a resource group that owns everything
 *   - a VNet with three subnets (Container Apps, Postgres delegation,
 *     private endpoints)
 *   - an existing Sentinel Log Analytics workspace + Container Apps environment
 *   - a regional Azure Container Registry for AiSOC container images
 *
 * Service-specific resources live in:
 *   database.tf        — PostgreSQL Flexible Server
 *   redis.tf           — Azure Managed Redis
 *   secrets.tf         — Key Vault entries
 *   iam.tf             — user-assigned managed identities + role assignments
 *   container_apps.tf  — api / web / ingest container apps
 */

data "azurerm_client_config" "current" {}

locals {
  # When subscription_id is blank, azurerm falls back to ARM_SUBSCRIPTION_ID /
  # az-cli context; we only thread it into the provider via the root module if
  # the operator set it explicitly (kept out of the provider block to avoid a
  # required value during `validate`).
  subscription_id    = var.subscription_id != "" ? var.subscription_id : data.azurerm_client_config.current.subscription_id
  workload_location  = var.workload_location != "" ? var.workload_location : var.location
  workload_vnet_name = var.workload_location != "" && var.workload_location != var.location ? "${var.name_prefix}-${replace(var.workload_location, " ", "")}-vnet" : "${var.name_prefix}-vnet"
}

# ─── Resource group ──────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "${var.name_prefix}-rg"
  location = var.location
  tags     = var.tags
}

# ─── Network ─────────────────────────────────────────────────────────────────
#
# One VNet, three subnets:
#   - aca           : the Container Apps environment lives here (needs >= /23)
#   - postgres      : delegated to Microsoft.DBforPostgreSQL/flexibleServers
#                     for VNet-integrated private access (no public endpoint)
#   - privatelink   : holds private endpoints (Redis today, more later)

resource "azurerm_virtual_network" "main" {
  name                = local.workload_vnet_name
  location            = local.workload_location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aca" {
  name                 = "${var.name_prefix}-aca-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.aca_subnet_cidr]

  delegation {
    name = "container-apps"
    service_delegation {
      name = "Microsoft.App/environments"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "${var.name_prefix}-pg-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.postgres_subnet_cidr]
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

resource "azurerm_subnet" "privatelink" {
  name                 = "${var.name_prefix}-pl-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.privatelink_subnet_cidr]
}

# ─── Observability ───────────────────────────────────────────────────────────
#
# Reuse the existing Sentinel-backed Log Analytics workspace. This avoids a
# second telemetry island and keeps Container Apps diagnostics beside the
# security evidence the deployment is intended to exercise.

data "azurerm_log_analytics_workspace" "sentinel" {
  provider = azurerm.sentinel_subscription

  name                = var.sentinel_workspace_name
  resource_group_name = var.sentinel_rg_name
}

# ─── Container Apps environment ──────────────────────────────────────────────
#
# VNet-injected so the apps can reach Postgres (delegated subnet) and the Redis
# private endpoint over private IPs. internal_load_balancer_enabled = false
# keeps the ingress public (the api/web surfaces customers hit first).

resource "azurerm_container_app_environment" "main" {
  name                               = "${var.name_prefix}-aca-env"
  location                           = local.workload_location
  resource_group_name                = azurerm_resource_group.main.name
  log_analytics_workspace_id         = data.azurerm_log_analytics_workspace.sentinel.id
  infrastructure_resource_group_name = "ME_${var.name_prefix}-aca-env_${azurerm_resource_group.main.name}_${replace(local.workload_location, " ", "")}"

  infrastructure_subnet_id       = azurerm_subnet.aca.id
  internal_load_balancer_enabled = false

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
    minimum_count         = 0
    maximum_count         = 0
  }

  tags = var.tags
}

# ─── Azure Container Registry ────────────────────────────────────────────────
#
# Optional but recommended. CI can push images here instead of GHCR; the
# Container Apps pull them with the runtime identity's AcrPull role binding
# (set in iam.tf). Basic SKU is plenty for a single-region demo.

resource "azurerm_container_registry" "main" {
  name                = "${var.name_prefix}acr${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ACR names are globally unique and alphanumeric-only; a short random suffix
# avoids collisions across re-applies / forks without forcing the operator to
# pick a unique name_prefix.
resource "random_string" "acr_suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}
