terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Variable for the existing resource group name
variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
  default     = "Project-IAAC-PoC-RG" # Value from the diagram
}

# Variable for location - assumed as not specified in diagram
variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "East US"
}

# Variable for Service Plan SKU - assumed as not specified in diagram
variable "service_plan_sku" {
  description = "SKU for the App Service Plan"
  type        = string
  default     = "B1" # Basic tier assumed
}

# Variable for Python version - diagram shows Python runtime
variable "python_version" {
  description = "Python version for the function app"
  type        = string
  default     = "3.11"
}

# Data source to reference the existing resource group
data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

# Storage Account required for Azure Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "funcstorageiaacpoc" # Must be globally unique, adjust as needed
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# App Service Plan for Linux Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "func-plan-iaac-poc"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.service_plan_sku
}

# Linux Function App with Python runtime
resource "azurerm_linux_function_app" "main" {
  name                       = "func-app-iaac-poc" # Must be globally unique, adjust as needed
  resource_group_name        = data.azurerm_resource_group.main.name
  location                   = data.azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key
  functions_extension_version = "~4"

  site_config {
    application_stack {
      python_version = var.python_version # Python runtime as specified in diagram
    }
  }
}
