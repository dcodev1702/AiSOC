/**
 * AiSOC — Azure serverless skeleton
 *
 * Provider pinning. AzureRM 4.70+ is required for Azure Managed Redis, which
 * supersedes the retired Azure Cache for Redis service for new deployments.
 */

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.70.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State backend left intentionally unconfigured. Pick one of:
  #
  #   backend "azurerm" {
  #     resource_group_name  = "aisoc-tfstate-rg"
  #     storage_account_name = "aisoctfstate<suffix>"
  #     container_name       = "tfstate"
  #     key                  = "azure.tfstate"
  #   }
  #   backend "local" {}
  #
  # …and bootstrap the storage account once per subscription before
  # `terraform init`. See the README for the bootstrap commands.
}

provider "azurerm" {
  subscription_id                 = var.subscription_id != "" ? var.subscription_id : null
  resource_provider_registrations = "none"

  features {
    key_vault {
      # Let `terraform destroy` purge soft-deleted vaults so a re-apply with
      # the same name_prefix doesn't collide with a tombstoned vault.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # Refuse to delete a resource group that still has resources Terraform
      # doesn't know about — protects against half-managed subscriptions.
      prevent_deletion_if_contains_resources = true
    }
  }
}

# Sentinel can live in a separate subscription, but it must be in the same
# Entra tenant as the deployment identity. A provider alias keeps the role
# assignments explicit while falling back to the current CLI subscription
# when no separate Sentinel subscription is supplied.
provider "azurerm" {
  alias                           = "sentinel_subscription"
  subscription_id                 = var.sentinel_subscription_id != "" ? var.sentinel_subscription_id : null
  resource_provider_registrations = "none"

  features {}
}
