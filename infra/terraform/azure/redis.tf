/**
 * AiSOC — Azure serverless skeleton
 *
 * Azure Managed Redis reached over a private endpoint. Public network access
 * is disabled; the Container Apps resolve the cache's private IP via the
 * privatelink.redis.azure.net DNS zone linked to the VNet.
 *
 * The primary access key is read back into Key Vault (secrets.tf) so the apps
 * inject it as REDIS_PASSWORD the same way every other secret flows.
 */

resource "azurerm_managed_redis" "main" {
  name                = "${var.name_prefix}-redis"
  resource_group_name = azurerm_resource_group.main.name
  location            = local.workload_location

  sku_name                  = var.managed_redis_sku
  high_availability_enabled = var.managed_redis_high_availability_enabled
  public_network_access     = "Disabled"

  default_database {
    access_keys_authentication_enabled = true
    client_protocol                    = "Encrypted"
    clustering_policy                  = "NoCluster"
  }

  tags = var.tags
}

# ─── Private endpoint + DNS ──────────────────────────────────────────────────

resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "${var.name_prefix}-redis-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.name_prefix}-redis-pe"
  resource_group_name = azurerm_resource_group.main.name
  location            = local.workload_location
  subnet_id           = azurerm_subnet.privatelink.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-redis-psc"
    private_connection_resource_id = azurerm_managed_redis.main.id
    subresource_names              = ["redisEnterprise"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}
