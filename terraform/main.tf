# Terraform configuration for Azure Linux Function App with Python runtime

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

# Variable for Azure region location
variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "eastus" # Assumed: Not specified in diagram
}

# Variable for App Service Plan SKU
variable "service_plan_sku" {
  description = "SKU for the App Service Plan"
  type        = string
  default     = "Y1" # Assumed: Consumption plan for serverless
}

# Variable for Python version
variable "python_version" {
  description = "Python runtime version"
  type        = string
  default     = "3.11" # Assumed: Latest stable version
}

# Resource Group as specified in the diagram
resource "azurerm_resource_group" "main" {
  name     = "Project-IAAC-PoC-RG" # Provided in diagram
  location = var.location
}

# Storage Account (required for Azure Function App)
resource "azurerm_storage_account" "main" {
  name                     = "projectiaacpocsa" # Assumed: Must be globally unique, lowercase, no hyphens
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# App Service Plan for Linux Function App
resource "azurerm_service_plan" "main" {
  name                = "project-iaac-poc-asp"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.service_plan_sku
}

# Linux Function App with Python runtime as specified in the diagram
resource "azurerm_linux_function_app" "main" {
  name                       = "project-iaac-poc-func" # Assumed: Must be globally unique
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  service_plan_id            = azurerm_service_plan.main.id
  storage_account_name       = azurerm_storage_account.main.name
  storage_account_access_key = azurerm_storage_account.main.primary_access_key
  functions_extension_version = "~4"

  site_config {
    application_stack {
      python_version = var.python_version # Runtime: Python as specified in diagram
    }
  }
}
