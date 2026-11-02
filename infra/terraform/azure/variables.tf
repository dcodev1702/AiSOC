/**
 * AiSOC — Azure serverless skeleton
 *
 * Input variables. Defaults aim for "smallest viable AiSOC" so a `terraform
 * apply` against a fresh subscription produces a working stack inside an
 * Azure free-trial / startup-credit envelope, not a five-figure surprise.
 */

# ─── Subscription / location ─────────────────────────────────────────────────

variable "subscription_id" {
  description = "Azure subscription ID that will own every resource. Leave blank to use the ARM_SUBSCRIPTION_ID / az-cli default."
  type        = string
  default     = ""
}

variable "location" {
  description = "Azure region for the resource group and regional control-plane resources."
  type        = string
  default     = "eastus"
}

variable "workload_location" {
  description = "Optional region for the VNet, Container Apps, PostgreSQL, and Managed Redis. Empty uses location. Useful when a subscription has regional service restrictions."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix used for resource names (Container Apps, Postgres server, etc.). Must be lowercase; 3-12 chars keeps globally-unique names (ACR, Key Vault) under their length caps."
  type        = string
  default     = "aisoc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,11}$", var.name_prefix))
    error_message = "name_prefix must be 3-12 chars, lowercase letters/digits, starting with a letter (keeps ACR + Key Vault names valid)."
  }
}

variable "tags" {
  description = "Common tags applied to every resource."
  type        = map(string)
  default = {
    project    = "aisoc"
    managed_by = "terraform"
  }
}

# ─── Networking ──────────────────────────────────────────────────────────────

variable "vnet_cidr" {
  description = "CIDR for the VNet that hosts the Container Apps environment and the data-tier private endpoints."
  type        = string
  default     = "10.20.0.0/16"
}

variable "aca_subnet_cidr" {
  description = "Subnet for the Container Apps environment. Must be at least /23 for a Consumption-only environment."
  type        = string
  default     = "10.20.0.0/23"
}

variable "postgres_subnet_cidr" {
  description = "Delegated subnet for the Postgres Flexible Server VNet integration."
  type        = string
  default     = "10.20.2.0/27"
}

variable "privatelink_subnet_cidr" {
  description = "Subnet that holds the Redis (and any future) private endpoints."
  type        = string
  default     = "10.20.3.0/27"
}

# ─── PostgreSQL Flexible Server ──────────────────────────────────────────────

variable "postgres_sku" {
  description = "Flexible Server SKU. B_Standard_B1ms is the cheapest burstable dev tier; GP_Standard_D2s_v3 is the smallest sensible production tier."
  type        = string
  default     = "GP_Standard_D2s_v3"
}

variable "postgres_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "postgres_storage_mb" {
  description = "Initial storage in MB (must be a supported Flexible Server size, e.g. 32768, 65536)."
  type        = number
  default     = 32768
}

variable "postgres_db_name" {
  description = "Logical database name created inside the server."
  type        = string
  default     = "aisoc"
}

variable "postgres_user" {
  description = "Administrator login for the Flexible Server."
  type        = string
  default     = "aisoc"
}

variable "postgres_zone" {
  description = "Availability zone for the primary Flexible Server node."
  type        = string
  default     = "1"
}

# ─── Azure Managed Redis ─────────────────────────────────────────────────────

variable "managed_redis_sku" {
  description = "Azure Managed Redis SKU. Balanced_B0 is the smallest development tier."
  type        = string
  default     = "Balanced_B0"
}

variable "managed_redis_high_availability_enabled" {
  description = "Enable Azure Managed Redis high availability. Disable only for a cost-sensitive test deployment."
  type        = bool
  default     = true
}

# ─── Azure Event Hubs ────────────────────────────────────────────────────────

variable "eventhub_message_retention_days" {
  description = "Replay retention for every Event Hub in the Standard namespace. Azure Standard supports 1-7 days; retained volume beyond the included allowance can incur storage charges."
  type        = number
  default     = 7

  validation {
    condition     = var.eventhub_message_retention_days >= 1 && var.eventhub_message_retention_days <= 7
    error_message = "eventhub_message_retention_days must be between 1 and 7 for an Azure Event Hubs Standard namespace."
  }
}

# ─── Container Apps ──────────────────────────────────────────────────────────

variable "api_image" {
  description = "Container image for the API service (FastAPI). Defaults to the GHCR demo image."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-core-api:latest"
}

variable "web_image" {
  description = "Container image for the web service (Next.js)."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-web:latest"
}

variable "ingest_image" {
  description = "Container image for the ingest service (Go)."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-ingest:latest"
}

variable "connectors_image" {
  description = "Container image for the connectors scheduler and catalog service."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-connectors:latest"
}

variable "actions_image" {
  description = "Container image for the governed actions service."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-actions:latest"
}

variable "fusion_image" {
  description = "Container image for the always-on alert fusion service."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-fusion:latest"
}

variable "agents_image" {
  description = "Container image for the always-on AI agents service."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-agents:latest"
}

variable "realtime_image" {
  description = "Container image for the always-on realtime fan-out service."
  type        = string
  default     = "ghcr.io/beenuar/aisoc-realtime:latest"
}

variable "model_gateway_image" {
  description = "Container image for the internal LiteLLM model gateway. Pin a tested ACR digest for deployments."
  type        = string
  default     = "ghcr.io/berriai/litellm:v1.102.1"
}

variable "sentinel_subscription_id" {
  description = "Subscription containing the existing Sentinel workspace. Empty uses the authenticated Azure subscription."
  type        = string
  default     = ""
}

variable "sentinel_rg_name" {
  description = "Resource group containing the existing Log Analytics workspace with Microsoft Sentinel enabled."
  type        = string
}

variable "sentinel_workspace_name" {
  description = "Name of the existing Log Analytics workspace with Microsoft Sentinel enabled. It is reused for Container Apps diagnostics."
  type        = string
}

variable "api_min_replicas" {
  description = "Minimum Container App replicas for the API. Set >0 to avoid cold starts."
  type        = number
  default     = 0
}

variable "api_max_replicas" {
  description = "Maximum Container App replicas for the API."
  type        = number
  default     = 10
}

variable "web_max_replicas" {
  description = "Maximum Container App replicas for the web app."
  type        = number
  default     = 5
}

variable "ingest_max_replicas" {
  description = "Maximum Container App replicas for the ingest service."
  type        = number
  default     = 5
}

variable "cors_origins" {
  description = "Comma-separated CORS allow-list passed to the API service."
  type        = string
  default     = ""
}

# ─── OpenAI / agents ─────────────────────────────────────────────────────────

variable "openai_api_key" {
  description = "Optional OpenAI API key persisted to Key Vault. Leave blank to skip (air-gapped Ollama / LiteLLM config)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "ai_location" {
  description = "Azure region for Microsoft Foundry and model deployments. Sweden Central currently supports both requested models."
  type        = string
  default     = "swedencentral"
}

variable "gpt_terra_capacity" {
  description = "Global Standard capacity in thousands of tokens per minute for GPT-5.6-Terra."
  type        = number
  default     = 10

  validation {
    condition     = var.gpt_terra_capacity >= 1
    error_message = "gpt_terra_capacity must be at least 1."
  }
}

variable "enable_claude_sonnet" {
  description = "Deploy Claude Sonnet 5.5 after Microsoft has allowlisted the subscription for the Anthropic offer."
  type        = bool
  default     = false
}

variable "claude_sonnet_capacity" {
  description = "Global Standard capacity in thousands of tokens per minute for Claude Sonnet 5.5."
  type        = number
  default     = 10

  validation {
    condition     = var.claude_sonnet_capacity >= 1
    error_message = "claude_sonnet_capacity must be at least 1."
  }
}

variable "claude_organization_name" {
  description = "Legal entity name used for Anthropic Azure Marketplace attestation. Empty defers the Claude deployment."
  type        = string
  default     = ""
}

variable "claude_country_code" {
  description = "Two-letter ISO country code used for Anthropic Azure Marketplace attestation."
  type        = string
  default     = ""

  validation {
    condition     = var.claude_country_code == "" || can(regex("^[A-Z]{2}$", var.claude_country_code))
    error_message = "claude_country_code must be empty or a two-letter uppercase ISO country code."
  }
}

variable "claude_industry" {
  description = "Industry used for Anthropic Azure Marketplace attestation."
  type        = string
  default     = ""

  validation {
    condition = var.claude_industry == "" || contains([
      "technology", "finance", "healthcare", "education", "retail",
      "manufacturing", "government", "media", "other",
    ], var.claude_industry)
    error_message = "claude_industry must be empty or a supported lowercase Marketplace value."
  }
}
