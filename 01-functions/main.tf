terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # Fully purge on destroy so re-deploys don't hit soft-delete conflicts.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "azuread" {}

resource "random_id" "suffix" {
  byte_length = 4
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "Central US"
}

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "serverless_mcp" {
  name     = "serverless-mcp-rg"
  location = var.location
}
