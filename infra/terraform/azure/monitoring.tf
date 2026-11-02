/** Minimum viable operational alerting for the PoC event spine and Spot lake. */

resource "azurerm_monitor_action_group" "operations" {
  name                = "${var.name_prefix}-operations"
  resource_group_name = azurerm_resource_group.main.name
  short_name          = "aisocops"
  tags                = var.tags

  dynamic "email_receiver" {
    for_each = var.operations_email == "" ? [] : [var.operations_email]
    content {
      name                    = "primary-operator"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_metric_alert" "eventhub_server_errors" {
  name                = "${var.name_prefix}-eventhub-server-errors"
  resource_group_name = azurerm_resource_group.main.name
  scopes              = [azurerm_eventhub_namespace.main.id]
  description         = "Event Hubs server errors can stop AiSOC ingestion, UEBA, fusion, and agents."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.EventHub/namespaces"
    metric_name      = "ServerErrors"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 0
  }
  action {
    action_group_id = azurerm_monitor_action_group.operations.id
  }
  tags = var.tags
}

resource "azurerm_monitor_metric_alert" "clickhouse_vm_availability" {
  name                     = "${var.name_prefix}-clickhouse-vm-unavailable"
  resource_group_name      = azurerm_resource_group.main.name
  scopes                   = [azurerm_linux_virtual_machine.clickhouse.id]
  target_resource_type     = "Microsoft.Compute/virtualMachines"
  target_resource_location = var.clickhouse_location
  description              = "The Spot VM hosting ClickHouse and Neo4j is unavailable or evicted."
  severity                 = 1
  frequency                = "PT5M"
  window_size              = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }
  action {
    action_group_id = azurerm_monitor_action_group.operations.id
  }
  tags = var.tags
}
