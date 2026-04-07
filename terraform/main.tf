# Terraform configuration for Azure resources
terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }
}


provider "azurerm" {
    features {}
    skip_provider_registration = true

}

# Data source for existing resource group - name provided in requirements
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Variables for reusability and configurable values
variable "location" {
  description = "Azure region for resources - assumed value if not provided"
  type        = string
  default     = "East US"
}

variable "environment" {
  description = "Environment tag - assumed value"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag - assumed value"
  type        = string
  default     = "infrastructure-team"
}

variable "storage_account_name" {
  description = "Storage account name - must be globally unique, assumed value"
  type        = string
  default     = "iaacpocblobstorage"
}

variable "key_vault_name" {
  description = "Key Vault name - must be globally unique, assumed value"
  type        = string
  default     = "iaacpoc-keyvault"
}

variable "servicebus_namespace_name" {
  description = "Service Bus namespace name - assumed value"
  type        = string
  default     = "iaacpoc-servicebus"
}

# Storage Account for Blob Storage
resource "azurerm_storage_account" "blob_storage" {
  name                     = var.storage_account_name
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = var.location # Assumed location if not provided
  account_tier             = "Standard"    # As per requirements
  account_replication_type = "LRS"         # As per requirements

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Key Vault
resource "azurerm_key_vault" "kv" {
  name                       = var.key_vault_name
  location                   = var.location # Assumed location if not provided
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard" # Assumed SKU if not provided
  soft_delete_retention_days = 7          # Assumed value if not provided

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Data source to get current client config for tenant_id
data "azurerm_client_config" "current" {}

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb" {
  name                = var.servicebus_namespace_name
  location            = var.location # Assumed location if not provided
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Assumed SKU if not provided

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Note: Function App is not created as per instruction #6 - only Blob Storage, Cosmos DB, Key Vault, and Service Bus should be created
# The diagram shows Function App but it is ignored as per requirements
