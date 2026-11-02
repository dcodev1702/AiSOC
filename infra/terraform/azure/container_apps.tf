/**
 * AiSOC — Azure serverless skeleton
 *
 * Container Apps for the three customer-visible workloads:
 *
 *   - api    — FastAPI control plane (port 8000)
 *   - web    — Next.js console (port 3000)
 *   - ingest — Go fan-in service that accepts /v1/ingest/batch (port 8080)
 *
 * Long-running workloads (agents, alert-fusion, realtime, threatintel,
 * connectors, fusion, ocsf) intentionally aren't here — they belong on a
 * dedicated always-on Container App (min_replicas > 0) or AKS in a follow-up
 * plan because scale-to-zero doesn't fit websocket fan-out or scheduler loops.
 * This skeleton ships the surface customers see first, mirroring the GCP stack.
 *
 * Secrets flow: Key Vault entry -> `secret { key_vault_secret_id, identity }`
 * -> `env { secret_name }`. The managed identity reads Key Vault at revision
 * activation time, so the apps depend on the "Key Vault Secrets User" role
 * assignment (iam.tf) existing first.
 */

locals {
  # Azure Postgres Flexible Server is reached by FQDN over the private DNS zone;
  # unlike Cloud SQL there's no unix socket, so the app dials host:5432 w/ TLS.
  postgres_host = azurerm_postgresql_flexible_server.main.fqdn

  # Azure Managed Redis uses an encrypted endpoint (currently port 10000).
  redis_host = azurerm_managed_redis.main.hostname
  redis_port = azurerm_managed_redis.main.default_database[0].port
}

# ─── API ─────────────────────────────────────────────────────────────────────

resource "azurerm_container_app" "api" {
  name                         = "${var.name_prefix}-api"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.runtime.id
  }

  # ── Key Vault-backed secrets ───────────────────────────────────────────────
  secret {
    name                = "database-url"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.database_url.versionless_id
  }
  secret {
    name                = "database-migration-url"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.database_migration_url.versionless_id
  }
  secret {
    name                = "postgres-password"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.postgres_password.versionless_id
  }
  secret {
    name                = "secret-key"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_key.versionless_id
  }
  secret {
    name                = "credential-key"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.credential_key.versionless_id
  }
  # Shared HS256 secret the API uses to mint realtime WS/SSE tickets (Issue
  # #239). The Node realtime workload (an always-on Container App / AKS in the
  # follow-up plan) reads the same Key Vault entry to verify them.
  secret {
    name                = "realtime-jwt-secret"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.realtime_jwt_secret.versionless_id
  }
  secret {
    name                = "redis-auth"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_auth.versionless_id
  }
  secret {
    name                = "redis-url"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_url.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }
  secret {
    name                = "jwt-secret"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.jwt_secret.versionless_id
  }
  secret {
    name                = "metrics-token"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.metrics_token.versionless_id
  }
  secret {
    name                = "realtime-internal-token"
    identity            = azurerm_user_assigned_identity.runtime.id
    key_vault_secret_id = azurerm_key_vault_secret.realtime_internal_token.versionless_id
  }
  dynamic "secret" {
    for_each = toset(var.openai_api_key == "" ? [] : ["openai"])
    content {
      name                = "openai-api-key"
      identity            = azurerm_user_assigned_identity.runtime.id
      key_vault_secret_id = azurerm_key_vault_secret.openai_api_key[0].versionless_id
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto" # HTTP/1.1 + HTTP/2 + websockets (for realtime later)

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.api_min_replicas
    max_replicas = var.api_max_replicas

    container {
      name    = "api"
      image   = var.api_image
      cpu     = 1.0
      memory  = "2Gi"
      command = ["/bin/sh", "-c"]
      args    = ["python -m app.scripts.run_migrations && exec python -m app.scripts.serve"]

      # ── Static config ────────────────────────────────────────────────────────
      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name = "AISOC_DATABASE_CONFIG_REVISION"
        value = nonsensitive(sha256(join(":", [
          azurerm_key_vault_secret.database_url.value,
          azurerm_key_vault_secret.database_migration_url.value,
        ])))
      }
      env {
        name  = "AISOC_REDIS_CONFIG_REVISION"
        value = nonsensitive(sha256(azurerm_key_vault_secret.redis_url.value))
      }
      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "AISOC_MIGRATIONS_STRICT"
        value = "1"
      }
      env {
        name  = "POSTGRES_DB"
        value = var.postgres_db_name
      }
      env {
        name  = "POSTGRES_USER"
        value = "aisoc_app"
      }
      env {
        name  = "POSTGRES_HOST"
        value = local.postgres_host
      }
      env {
        name  = "POSTGRES_PORT"
        value = "5432"
      }
      env {
        name  = "POSTGRES_SSLMODE"
        value = "require"
      }
      env {
        name  = "REDIS_HOST"
        value = local.redis_host
      }
      env {
        name  = "REDIS_PORT"
        value = tostring(local.redis_port)
      }
      env {
        name  = "REDIS_SSL"
        value = "true"
      }
      env {
        name  = "CORS_ORIGINS"
        value = var.cors_origins
      }
      env {
        name  = "CONNECTORS_SERVICE_URL"
        value = "https://${azurerm_container_app.connectors.ingress[0].fqdn}"
      }
      env {
        name  = "AISOC_ACTIONS_BASE_URL"
        value = "https://${azurerm_container_app.actions.ingress[0].fqdn}"
      }
      env {
        name  = "AGENTS_SERVICE_URL"
        value = local.internal_agents_url
      }
      env {
        name  = "FUSION_SERVICE_URL"
        value = local.internal_fusion_url
      }
      env {
        name  = "REALTIME_BASE_URL"
        value = local.internal_realtime_url
      }
      env {
        name  = "AISOC_CONNECTORS_IDENTITY_NAME"
        value = azurerm_user_assigned_identity.connectors.name
      }
      env {
        name  = "AISOC_CONNECTORS_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.connectors.client_id
      }
      env {
        name  = "AISOC_CONNECTORS_IDENTITY_PRINCIPAL_ID"
        value = azurerm_user_assigned_identity.connectors.principal_id
      }
      env {
        name  = "AISOC_ACTIONS_IDENTITY_NAME"
        value = azurerm_user_assigned_identity.actions.name
      }
      env {
        name  = "AISOC_ACTIONS_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.actions.client_id
      }
      env {
        name  = "AISOC_ACTIONS_IDENTITY_PRINCIPAL_ID"
        value = azurerm_user_assigned_identity.actions.principal_id
      }
      env {
        name  = "AISOC_SENTINEL_SUBSCRIPTION_ID"
        value = var.sentinel_subscription_id != "" ? var.sentinel_subscription_id : data.azurerm_client_config.current.subscription_id
      }
      env {
        name  = "AISOC_SENTINEL_RESOURCE_GROUP"
        value = var.sentinel_rg_name
      }
      env {
        name  = "AISOC_SENTINEL_WORKSPACE_NAME"
        value = var.sentinel_workspace_name
      }

      # ── Secret-backed env ────────────────────────────────────────────────────
      env {
        name        = "DATABASE_URL"
        secret_name = "database-url"
      }
      env {
        name        = "DATABASE_MIGRATION_URL"
        secret_name = "database-migration-url"
      }
      env {
        name        = "AISOC_APP_DB_PASSWORD"
        secret_name = "postgres-password"
      }
      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "postgres-password"
      }
      env {
        name        = "SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "AISOC_CREDENTIAL_KEY"
        secret_name = "credential-key"
      }
      env {
        name        = "AISOC_REALTIME_JWT_SECRET"
        secret_name = "realtime-jwt-secret"
      }
      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-auth"
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
        name        = "AISOC_ACTIONS_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
      env {
        name        = "METRICS_TOKEN"
        secret_name = "metrics-token"
      }
      env {
        name        = "REALTIME_INTERNAL_TOKEN"
        secret_name = "realtime-internal-token"
      }
      dynamic "env" {
        for_each = toset(var.openai_api_key == "" ? [] : ["openai"])
        content {
          name        = "OPENAI_API_KEY"
          secret_name = "openai-api-key"
        }
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_postgresql_flexible_server_database.aisoc,
  ]
}

# ─── Web ─────────────────────────────────────────────────────────────────────

resource "azurerm_container_app" "web" {
  name                         = "${var.name_prefix}-web"
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runtime.id]
  }

  registry {
    server   = azurerm_container_registry.main.login_server
    identity = azurerm_user_assigned_identity.runtime.id
  }

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = var.web_max_replicas

    container {
      name   = "web"
      image  = var.web_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        # The self-host web bundle uses same-origin browser requests and its
        # startup script rewrites Next.js server routes from API_URL. A
        # NEXT_PUBLIC_* variable set only at runtime cannot change the bundle.
        name  = "API_URL"
        value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
      }
      env {
        name  = "AGENTS_URL"
        value = local.internal_agents_url
      }
      env {
        name  = "REALTIME_URL"
        value = local.internal_realtime_url
      }
      env {
        name  = "FUSION_URL"
        value = local.internal_fusion_url
      }
      env {
        name  = "NODE_ENV"
        value = "production"
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}

# ─── Ingest ──────────────────────────────────────────────────────────────────

resource "azurerm_container_app" "ingest" {
  name                         = "${var.name_prefix}-ingest"
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
    name                = "postgres-password"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.postgres_password.versionless_id
  }
  secret {
    name                = "secret-key"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.secret_key.versionless_id
  }
  secret {
    name                = "redis-auth"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.redis_auth.versionless_id
  }
  secret {
    name                = "service-token"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.service_token.versionless_id
  }
  secret {
    name                = "jwt-secret"
    identity            = azurerm_user_assigned_identity.pipeline.id
    key_vault_secret_id = azurerm_key_vault_secret.jwt_secret.versionless_id
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 1
    max_replicas = var.ingest_max_replicas

    container {
      name   = "ingest"
      image  = var.ingest_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "AISOC_DEPLOYMENT"
        value = "azure-containerapps"
      }
      env {
        name  = "ENVIRONMENT"
        value = "production"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = "${azurerm_eventhub_namespace.main.name}.servicebus.windows.net:9093"
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
        value = "https://${azurerm_eventhub_namespace.main.name}.servicebus.windows.net"
      }
      env {
        name  = "KAFKA_MANAGED_IDENTITY_CLIENT_ID"
        value = azurerm_user_assigned_identity.pipeline.client_id
      }
      env {
        name  = "KAFKA_TOPIC"
        value = "aisoc.raw_events"
      }
      env {
        name  = "POSTGRES_DB"
        value = var.postgres_db_name
      }
      env {
        name  = "POSTGRES_USER"
        value = "aisoc_app"
      }
      env {
        name  = "POSTGRES_HOST"
        value = local.postgres_host
      }
      env {
        name  = "POSTGRES_PORT"
        value = "5432"
      }
      env {
        name  = "POSTGRES_SSLMODE"
        value = "require"
      }
      env {
        name  = "REDIS_HOST"
        value = local.redis_host
      }
      env {
        name  = "REDIS_PORT"
        value = tostring(local.redis_port)
      }
      env {
        name  = "REDIS_SSL"
        value = "true"
      }

      env {
        name        = "POSTGRES_PASSWORD"
        secret_name = "postgres-password"
      }
      env {
        name        = "SECRET_KEY"
        secret_name = "secret-key"
      }
      env {
        name        = "REDIS_PASSWORD"
        secret_name = "redis-auth"
      }
      env {
        name        = "AISOC_SERVICE_TOKEN"
        secret_name = "service-token"
      }
      env {
        name        = "JWT_SECRET"
        secret_name = "jwt-secret"
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.acr_pull,
    azurerm_role_assignment.kv_secrets_user,
    azurerm_role_assignment.eventhubs_sender,
    azurerm_private_endpoint.eventhubs,
    azurerm_postgresql_flexible_server_database.aisoc,
  ]
}
