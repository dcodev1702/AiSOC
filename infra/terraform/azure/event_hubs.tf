/**
 * AiSOC's internal event spine. Sentinel remains the system of record: the
 * connectors service polls incidents in place and posts normalized records to
 * ingest. No Log Analytics diagnostic export is required for this path.
 */

locals {
  eventhub_topics = toset([
    "aisoc.raw_events",
    "aisoc.alerts.raw",
    "aisoc.alerts.fused",
    "aisoc.alerts.fused.dlq",
    "aisoc.vulnerability_matches",
    "security.graph_updates",
  ])
  eventhub_consumer_groups = {
    "aisoc.raw_events/aisoc-fusion-consumer"      = ["aisoc.raw_events", "aisoc-fusion-consumer"]
    "aisoc.alerts.raw/aisoc-fusion-consumer"      = ["aisoc.alerts.raw", "aisoc-fusion-consumer"]
    "aisoc.alerts.fused/aisoc-agents-triage"      = ["aisoc.alerts.fused", "aisoc-agents-triage"]
    "aisoc.alerts.fused/aisoc-realtime-ws"        = ["aisoc.alerts.fused", "aisoc-realtime-ws"]
    "security.graph_updates/aisoc-realtime-graph" = ["security.graph_updates", "aisoc-realtime-graph"]
  }
}

resource "azurerm_eventhub_namespace" "main" {
  name                          = "${var.name_prefix}-events-${random_string.acr_suffix.result}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = local.workload_location
  sku                           = "Standard"
  capacity                      = 1
  minimum_tls_version           = "1.2"
  local_authentication_enabled  = false
  public_network_access_enabled = false
  tags                          = var.tags
}

resource "azurerm_eventhub" "topic" {
  for_each = local.eventhub_topics

  name              = each.value
  namespace_id      = azurerm_eventhub_namespace.main.id
  partition_count   = 2
  message_retention = 1
}

resource "azurerm_eventhub_consumer_group" "app" {
  for_each = local.eventhub_consumer_groups

  name                = each.value[1]
  namespace_name      = azurerm_eventhub_namespace.main.name
  eventhub_name       = azurerm_eventhub.topic[each.value[0]].name
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone" "eventhubs" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "eventhubs" {
  name                  = "${var.name_prefix}-eventhubs-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.eventhubs.name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "eventhubs" {
  name                = "${var.name_prefix}-eventhubs-pe"
  location            = local.workload_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.privatelink.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-eventhubs-psc"
    private_connection_resource_id = azurerm_eventhub_namespace.main.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "eventhubs"
    private_dns_zone_ids = [azurerm_private_dns_zone.eventhubs.id]
  }
}

resource "azurerm_role_assignment" "eventhubs_sender" {
  scope                            = azurerm_eventhub_namespace.main.id
  role_definition_name             = "Azure Event Hubs Data Sender"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "eventhubs_receiver" {
  scope                            = azurerm_eventhub_namespace.main.id
  role_definition_name             = "Azure Event Hubs Data Receiver"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}
