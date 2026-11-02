/**
 * Cost-bounded ClickHouse event lake for the Azure proof of concept.
 *
 * This is deliberately not ClickHouse Cloud: a managed Basic service and a
 * customer-selected Spot VM are mutually exclusive deployment models.  The
 * PoC uses the requested Basic-sized self-hosted footprint instead:
 *
 *   - one interruptible D4as_v5-class VM
 *   - one 512 GiB Standard SSD LRS data disk
 *   - one ADLS Gen2 Standard LRS account for Parquet/archive objects
 *
 * Spot eviction deallocates the VM.  The managed data disk remains attached
 * and billable, so a restart recovers the lake, but queries and archival pause
 * while Azure has no Spot capacity.  That trade is appropriate only for this
 * low-traffic PoC; a production lake needs non-Spot replicas.
 */

locals {
  clickhouse_private_ip = azurerm_network_interface.clickhouse.private_ip_address
  lake_filesystems = {
    events  = "Normalized OCSF Parquet promoted from the searchable lake"
    backups = "ClickHouse backups and restore manifests"
  }
}

# ─── Private, cross-region Spot VM network ─────────────────────────────────

resource "azurerm_virtual_network" "clickhouse" {
  name                = "${var.name_prefix}-${var.clickhouse_location}-lake-vnet"
  location            = var.clickhouse_location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.clickhouse_vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "clickhouse" {
  name                 = "${var.name_prefix}-clickhouse-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.clickhouse.name
  address_prefixes     = [var.clickhouse_subnet_cidr]
}

resource "azurerm_virtual_network_peering" "workload_to_clickhouse" {
  name                      = "${var.name_prefix}-workload-to-lake"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.main.name
  remote_virtual_network_id = azurerm_virtual_network.clickhouse.id
}

resource "azurerm_virtual_network_peering" "clickhouse_to_workload" {
  name                      = "${var.name_prefix}-lake-to-workload"
  resource_group_name       = azurerm_resource_group.main.name
  virtual_network_name      = azurerm_virtual_network.clickhouse.name
  remote_virtual_network_id = azurerm_virtual_network.main.id
}

resource "azurerm_network_security_group" "clickhouse" {
  name                = "${var.name_prefix}-clickhouse-nsg"
  location            = var.clickhouse_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  security_rule {
    name                       = "clickhouse-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["8123", "9000", "7687"]
    source_address_prefix      = var.vnet_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "clickhouse" {
  subnet_id                 = azurerm_subnet.clickhouse.id
  network_security_group_id = azurerm_network_security_group.clickhouse.id
}

# The VM NIC is private-only. A subnet NAT Gateway retains outbound package and
# container-image access without assigning an Internet-routable address to the
# host. Administration remains on Azure Run Command or a future Bastion.
resource "azurerm_public_ip" "clickhouse_outbound" {
  name                = "${var.name_prefix}-clickhouse-outbound"
  location            = var.clickhouse_location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "clickhouse" {
  name                    = "${var.name_prefix}-clickhouse-nat"
  location                = var.clickhouse_location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "clickhouse" {
  nat_gateway_id       = azurerm_nat_gateway.clickhouse.id
  public_ip_address_id = azurerm_public_ip.clickhouse_outbound.id
}

resource "azurerm_subnet_nat_gateway_association" "clickhouse" {
  subnet_id      = azurerm_subnet.clickhouse.id
  nat_gateway_id = azurerm_nat_gateway.clickhouse.id
}

resource "azurerm_network_interface" "clickhouse" {
  name                = "${var.name_prefix}-clickhouse-nic"
  location            = var.clickhouse_location
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags

  ip_configuration {
    name                          = "private"
    subnet_id                     = azurerm_subnet.clickhouse.id
    private_ip_address_allocation = "Dynamic"
  }

  depends_on = [azurerm_subnet_nat_gateway_association.clickhouse]
}

# ─── Spot ClickHouse node ───────────────────────────────────────────────────

resource "tls_private_key" "clickhouse_admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "azurerm_linux_virtual_machine" "clickhouse" {
  name                = "${var.name_prefix}-clickhouse"
  computer_name       = "aisoc-clickhouse"
  location            = var.clickhouse_location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.clickhouse_vm_size
  admin_username      = var.clickhouse_admin_username

  priority        = "Spot"
  eviction_policy = "Deallocate"
  max_bid_price   = -1

  network_interface_ids = [azurerm_network_interface.clickhouse.id]

  disable_password_authentication = true
  secure_boot_enabled             = true
  vtpm_enabled                    = true
  admin_ssh_key {
    username   = var.clickhouse_admin_username
    public_key = tls_private_key.clickhouse_admin.public_key_openssh
  }

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${var.name_prefix}-clickhouse-os"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/templates/clickhouse-cloud-init.yaml.tftpl", {
    clickhouse_image    = var.clickhouse_image
    clickhouse_password = random_password.clickhouse.result
    neo4j_image         = var.neo4j_image
    neo4j_password      = random_password.neo4j.result
    init_sql_b64        = base64encode(file("${path.module}/../../../services/api/clickhouse/001_init.sql"))
  }))

  boot_diagnostics {}
  tags = merge(var.tags, {
    workload  = "clickhouse-lake"
    lifecycle = "poc-spot"
  })

  depends_on = [
    azurerm_subnet_network_security_group_association.clickhouse,
  ]
}

resource "azurerm_managed_disk" "clickhouse_data" {
  name                 = "${var.name_prefix}-clickhouse-data"
  location             = var.clickhouse_location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.clickhouse_data_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "clickhouse_data" {
  managed_disk_id    = azurerm_managed_disk.clickhouse_data.id
  virtual_machine_id = azurerm_linux_virtual_machine.clickhouse.id
  lun                = 0
  caching            = "ReadWrite"
}

# ─── ADLS Gen2 LRS archive ──────────────────────────────────────────────────

resource "random_string" "lake_suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "azurerm_storage_account" "lake" {
  name                = "${var.name_prefix}lake${random_string.lake_suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = local.workload_location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  access_tier              = "Hot"
  is_hns_enabled           = true

  min_tls_version                   = "TLS1_2"
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  public_network_access_enabled     = false
  cross_tenant_replication_enabled  = false
  allow_nested_items_to_be_public   = false
  infrastructure_encryption_enabled = true

  tags = merge(var.tags, {
    workload  = "clickhouse-lake-archive"
    retention = "five-years"
  })
}

# Containers are created through ARM rather than the Blob data plane.  This
# keeps first apply compatible with public access disabled and avoids a shared
# storage key merely to bootstrap the managed-identity-only account.
resource "azapi_resource" "lake_filesystem" {
  for_each = local.lake_filesystems

  type      = "Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01"
  name      = each.key
  parent_id = "${azurerm_storage_account.lake.id}/blobServices/default"
  body = {
    properties = {
      publicAccess = "None"
      metadata = {
        purpose = each.value
      }
    }
  }
}

# An event is exported from ClickHouse at the end of its searchable year.  Its
# Parquet object then spends 90 days in Cool, 275 days in Cold, and 1,095 days
# in Archive before deletion: one searchable year + one online Parquet year +
# three archive years = five years total.  Legal-hold objects use a separate
# prefix and are intentionally excluded from this rule.
resource "azurerm_storage_management_policy" "lake" {
  storage_account_id = azurerm_storage_account.lake.id

  rule {
    name    = "five-year-event-lifecycle"
    enabled = true

    filters {
      prefix_match = ["events/parquet/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 0
        tier_to_cold_after_days_since_modification_greater_than    = 90
        tier_to_archive_after_days_since_modification_greater_than = 365
        delete_after_days_since_modification_greater_than          = 1460
      }
    }
  }

  depends_on = [azapi_resource.lake_filesystem]
}

locals {
  lake_private_link_zones = {
    blob = "privatelink.blob.core.windows.net"
    dfs  = "privatelink.dfs.core.windows.net"
  }
}

resource "azurerm_private_dns_zone" "lake" {
  for_each = local.lake_private_link_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.main.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "lake" {
  for_each = local.lake_private_link_zones

  name                  = "${var.name_prefix}-${each.key}-dns-link"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.lake[each.key].name
  virtual_network_id    = azurerm_virtual_network.main.id
  registration_enabled  = false
  tags                  = var.tags
}

resource "azurerm_private_endpoint" "lake" {
  for_each = local.lake_private_link_zones

  name                = "${var.name_prefix}-lake-${each.key}-pe"
  location            = local.workload_location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.privatelink.id
  tags                = var.tags

  private_service_connection {
    name                           = "${var.name_prefix}-lake-${each.key}-connection"
    private_connection_resource_id = azurerm_storage_account.lake.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.lake[each.key].id]
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.lake]
}

# The existing pipeline UAMI exports Parquet.  API/web may inspect manifests
# but cannot alter evidence.  The VM identity can write backups without an
# account key or SAS token.
resource "azurerm_role_assignment" "lake_pipeline_contributor" {
  scope                            = azurerm_storage_account.lake.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.pipeline.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "lake_runtime_reader" {
  scope                            = azurerm_storage_account.lake.id
  role_definition_name             = "Storage Blob Data Reader"
  principal_id                     = azurerm_user_assigned_identity.runtime.principal_id
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "lake_clickhouse_contributor" {
  scope                            = azurerm_storage_account.lake.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_linux_virtual_machine.clickhouse.identity[0].principal_id
  skip_service_principal_aad_check = true
}
