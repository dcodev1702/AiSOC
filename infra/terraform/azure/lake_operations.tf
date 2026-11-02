/** Scheduled evidence lifecycle jobs, authenticated only with the pipeline UAMI. */

locals {
  lake_job_env = {
    AZURE_CLIENT_ID      = azurerm_user_assigned_identity.pipeline.client_id
    CLICKHOUSE_HOST      = local.clickhouse_private_ip
    CLICKHOUSE_HTTP_PORT = "8123"
    CLICKHOUSE_PORT      = "9000"
    CLICKHOUSE_DATABASE  = "aisoc"
    CLICKHOUSE_USER      = "aisoc"
  }
}

resource "azurerm_container_app_job" "lake_archive" {
  name                         = "${var.name_prefix}-lake-archive"
  location                     = local.workload_location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 2
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
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "clickhouse-password"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.clickhouse_password.versionless_id
  }
  schedule_trigger_config {
    cron_expression          = "15 2 * * *"
    parallelism              = 1
    replica_completion_count = 1
  }
  template {
    container {
      name    = "lake-archive"
      image   = var.api_image
      cpu     = 0.5
      memory  = "1Gi"
      command = ["python", "-m", "app.workers.lake_archive"]

      dynamic "env" {
        for_each = local.lake_job_env
        content {
          name  = env.key
          value = env.value
        }
      }
      env {
        name  = "AZURE_STORAGE_ACCOUNT_URL"
        value = azurerm_storage_account.lake.primary_blob_endpoint
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "CLICKHOUSE_PASSWORD"
        secret_name = "clickhouse-password"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.lake_pipeline_contributor,
    azurerm_private_endpoint.lake,
    azurerm_virtual_machine_data_disk_attachment.clickhouse_data,
  ]
}

resource "azurerm_container_app_job" "clickhouse_backup" {
  name                         = "${var.name_prefix}-clickhouse-backup"
  location                     = local.workload_location
  resource_group_name          = azurerm_resource_group.main.name
  container_app_environment_id = azurerm_container_app_environment.main.id
  workload_profile_name        = "Consumption"
  replica_timeout_in_seconds   = 1800
  replica_retry_limit          = 2
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
    name                = "clickhouse-password"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.clickhouse_password.versionless_id
  }
  schedule_trigger_config {
    cron_expression          = "15 3 * * 0"
    parallelism              = 1
    replica_completion_count = 1
  }
  template {
    container {
      name    = "clickhouse-backup"
      image   = var.api_image
      cpu     = 0.5
      memory  = "1Gi"
      command = ["python", "-m", "app.workers.lake_backup", "restore-verify"]

      dynamic "env" {
        for_each = local.lake_job_env
        content {
          name  = env.key
          value = env.value
        }
      }
      env {
        name  = "AZURE_STORAGE_ACCOUNT_URL"
        value = azurerm_storage_account.lake.primary_blob_endpoint
      }
      env {
        name        = "CLICKHOUSE_PASSWORD"
        secret_name = "clickhouse-password"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.lake_pipeline_contributor,
    azurerm_private_endpoint.lake,
    azurerm_virtual_machine_data_disk_attachment.clickhouse_data,
  ]
}
