/** Always-on AI processing path: fusion -> agents -> realtime. */

locals {
  kafka_bootstrap_server     = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net:9093"
  kafka_oauth_resource       = "https://${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
  internal_api_url           = "https://${var.name_prefix}-api.internal.${azurerm_container_app_environment.main.default_domain}"
  internal_fusion_url        = "https://${var.name_prefix}-fusion.internal.${azurerm_container_app_environment.main.default_domain}"
  internal_agents_url        = "https://${var.name_prefix}-agents.internal.${azurerm_container_app_environment.main.default_domain}"
  internal_realtime_url      = "https://${var.name_prefix}-realtime.internal.${azurerm_container_app_environment.main.default_domain}"
  internal_ueba_url          = "https://${var.name_prefix}-ueba.internal.${azurerm_container_app_environment.main.default_domain}"
  internal_model_gateway_url = "https://${var.name_prefix}-model-gateway.internal.${azurerm_container_app_environment.main.default_domain}"
  web_origin                 = "https://${var.name_prefix}-web.${azurerm_container_app_environment.main.default_domain}"
}

resource "azurerm_container_app" "fusion" {
  name                         = "${var.name_prefix}-fusion"
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
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "redis-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_url.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }
  secret {
    name                = "clickhouse-password"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.clickhouse_password.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8003
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
      name   = "fusion"
      image  = var.fusion_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SECURITY_PROTOCOL"
        value = "SASL_SSL"
      }
      env {
        name  = "KAFKA_SASL_MECHANISM"
        value = "OAUTHBEARER"
      }
      env {
        name  = "KAFKA_OAUTH_RESOURCE"
        value = local.kafka_oauth_resource
      }
      env {
        name  = "KAFKA_MANAGED_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "AISOC_LAKE_WRITER_ENABLED"
        value = "true"
      }
      env {
        name  = "CLICKHOUSE_HOST"
        value = local.clickhouse_private_ip
      }
      env {
        name  = "CLICKHOUSE_PORT"
        value = "9000"
      }
      env {
        name  = "CLICKHOUSE_DATABASE"
        value = "aisoc"
      }
      env {
        name  = "CLICKHOUSE_USER"
        value = "aisoc"
      }
      env {
        name  = "AISOC_UEBA_FUSION_ENABLED"
        value = "true"
      }
      env {
        name  = "AISOC_FUSE_ENRICHMENT"
        value = "false"
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "REDIS_URL"
        secret_name = "redis-url"
      }
      env {
        name        = "AISOC_SERVICE_TOKEN"
        secret_name = "service-token"
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
    azurerm_role_assignment.eventhubs_sender,
    azurerm_role_assignment.eventhubs_receiver,
    azurerm_private_endpoint.eventhubs,
    azurerm_virtual_machine_data_disk_attachment.clickhouse_data,
  ]
}

resource "azurerm_container_app" "agents" {
  name                         = "${var.name_prefix}-agents"
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
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "redis-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_url.versionless_id
  }
  secret {
    name                = "credential-key"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.credential_key.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }
  secret {
    name                = "litellm-master-key"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.litellm_master_key.versionless_id
  }
  secret {
    name                = "clickhouse-password"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.clickhouse_password.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8084
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
      name   = "agents"
      image  = var.agents_image
      cpu    = 1.0
      memory = "2Gi"

      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name  = "PORT"
        value = "8084"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SECURITY_PROTOCOL"
        value = "SASL_SSL"
      }
      env {
        name  = "KAFKA_SASL_MECHANISM"
        value = "OAUTHBEARER"
      }
      env {
        name  = "KAFKA_OAUTH_RESOURCE"
        value = local.kafka_oauth_resource
      }
      env {
        name  = "KAFKA_MANAGED_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "AISOC_HUNT_SCHEDULER_DISABLE"
        value = "0"
      }
      env {
        name  = "AISOC_DEFAULT_TENANT_ID"
        value = var.poc_tenant_id
      }
      env {
        name  = "AISOC_HUNTS_DIR"
        value = "/app/app/hunt/corpus"
      }
      env {
        name  = "AISOC_GRAPH_ENABLED"
        value = "true"
      }
      env {
        name  = "AISOC_NEO4J_URI"
        value = "bolt://${local.clickhouse_private_ip}:7687"
      }
      env {
        name  = "OTEL_EXPORTER"
        value = "none"
      }
      env {
        name  = "CLICKHOUSE_HOST"
        value = local.clickhouse_private_ip
      }
      env {
        name  = "CLICKHOUSE_PORT"
        value = "9000"
      }
      env {
        name  = "CLICKHOUSE_DATABASE"
        value = "aisoc"
      }
      env {
        name  = "CLICKHOUSE_USER"
        value = "aisoc"
      }
      env {
        name  = "AISOC_API_URL"
        value = local.internal_api_url
      }
      env {
        name  = "API_SERVICE_URL"
        value = local.internal_api_url
      }
      env {
        name  = "API_URL"
        value = local.internal_api_url
      }
      env {
        name  = "FUSION_SERVICE_URL"
        value = local.internal_fusion_url
      }
      env {
        name  = "CONNECTORS_SERVICE_URL"
        value = "https://${var.name_prefix}-connectors.internal.${azurerm_container_app_environment.main.default_domain}"
      }
      env {
        name  = "REALTIME_URL"
        value = local.internal_realtime_url
      }
      env {
        name  = "AISOC_UEBA_URL"
        value = local.internal_ueba_url
      }
      env {
        name  = "LLM_GATEWAY_URL"
        value = "${local.internal_model_gateway_url}/v1"
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "REDIS_URL"
        secret_name = "redis-url"
      }
      env {
        name        = "AISOC_CREDENTIAL_KEY"
        secret_name = "credential-key"
      }
      env {
        name        = "AISOC_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "AISOC_AGENTS_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "AISOC_API_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "LITELLM_MASTER_KEY"
        secret_name = "litellm-master-key"
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
    azurerm_role_assignment.eventhubs_receiver,
    azurerm_private_endpoint.eventhubs,
    azurerm_container_app.model_gateway,
    azurerm_container_app.ueba,
    azurerm_virtual_machine_data_disk_attachment.clickhouse_data,
  ]
}

resource "azurerm_container_app" "realtime" {
  name                         = "${var.name_prefix}-realtime"
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
    name                = "redis-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_url.versionless_id
  }
  secret {
    name                = "realtime-jwt-secret"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.realtime_jwt_secret.versionless_id
  }
  secret {
    name                = "realtime-internal-token"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.realtime_internal_token.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8086
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
      name   = "realtime"
      image  = var.realtime_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name  = "PORT"
        value = "8086"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SECURITY_PROTOCOL"
        value = "SASL_SSL"
      }
      env {
        name  = "KAFKA_SASL_MECHANISM"
        value = "OAUTHBEARER"
      }
      env {
        name  = "KAFKA_OAUTH_RESOURCE"
        value = local.kafka_oauth_resource
      }
      env {
        name  = "KAFKA_MANAGED_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "AISOC_CORS_ORIGINS"
        value = local.web_origin
      }
      env {
        name        = "REDIS_URL"
        secret_name = "redis-url"
      }
      env {
        name        = "AISOC_REALTIME_JWT_SECRET"
        secret_name = "realtime-jwt-secret"
      }
      env {
        name        = "REALTIME_INTERNAL_TOKEN"
        secret_name = "realtime-internal-token"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.eventhubs_receiver,
    azurerm_private_endpoint.eventhubs,
  ]
}

# Behavioral analytics consumes the same normalized event stream as fusion
# and publishes scored anomalies back to a dedicated Event Hub. The existing
# pipeline UAMI owns both directions; no broker key or fifth identity exists.
resource "azurerm_container_app" "ueba" {
  name                         = "${var.name_prefix}-ueba"
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
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.database_asyncpg_url.versionless_id
  }
  secret {
    name                = "database-migration-url"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.database_migration_url.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }

  ingress {
    external_enabled = false
    target_port      = 8004
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
      name   = "ueba"
      image  = var.ueba_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = local.kafka_bootstrap_server
      }
      env {
        name  = "KAFKA_SECURITY_PROTOCOL"
        value = "SASL_SSL"
      }
      env {
        name  = "KAFKA_SASL_MECHANISM"
        value = "OAUTHBEARER"
      }
      env {
        name  = "KAFKA_OAUTH_RESOURCE"
        value = local.kafka_oauth_resource
      }
      env {
        name  = "KAFKA_MANAGED_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "KAFKA_INPUT_TOPIC"
        value = "aisoc.raw_events"
      }
      env {
        name  = "KAFKA_OUTPUT_TOPIC"
        value = "ueba.anomalies"
      }
      env {
        name  = "KAFKA_CONSUMER_GROUP"
        value = "aisoc-ueba-consumer"
      }
      env {
        name  = "OTEL_ENDPOINT"
        value = ""
      }
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "DATABASE_MIGRATION_URL"
        secret_name = "database-migration-url"
      }
      env {
        name        = "AISOC_SERVICE_TOKEN"
        secret_name = "service-token"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.eventhubs_sender,
    azurerm_role_assignment.eventhubs_receiver,
    azurerm_private_endpoint.eventhubs,
    azurerm_postgresql_flexible_server_database.aisoc,
  ]
}
