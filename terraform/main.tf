# Terraform configuration for Azure infrastructure
# Using AzureRM provider version 3.0.2

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

}

# Reference the existing resource group - DO NOT CREATE
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Variables for configurable values
variable "storage_account_name" {
  description = "Name of the storage account - must be unique"
  type        = string
  default     = "iaacstorageaccount" # Assumed - must be globally unique
}

variable "key_vault_name" {
  description = "Name of the Key Vault - must be unique"
  type        = string
  default     = "iaac-key-vault" # Assumed - must be globally unique
}

variable "servicebus_namespace_name" {
  description = "Name of the Service Bus namespace"
  type        = string
  default     = "iaac-servicebus-namespace" # Assumed - must be globally unique
}

variable "cosmosdb_account_name" {
  description = "Name of the Cosmos DB account"
  type        = string
  default     = "iaac-cosmosdb-account" # Assumed - must be globally unique
}

variable "function_app_name" {
  description = "Name of the Function App"
  type        = string
  default     = "iaac-function-app" # Assumed - must be globally unique
}

variable "app_service_plan_name" {
  description = "Name of the App Service Plan for Function App"
  type        = string
  default     = "iaac-app-service-plan" # Assumed
}

variable "app_gateway_name" {
  description = "Name of the Application Gateway"
  type        = string
  default     = "iaac-app-gateway" # Assumed
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev" # Assumed
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "iaac-team" # Assumed
}

# Storage Account for Blob Storage
# Account Tier: Standard (provided in diagram)
# Replication: GRS (provided in diagram)
resource "azurerm_storage_account" "storage" {
  name                     = var.storage_account_name
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # Provided in diagram
  account_replication_type = "GRS"      # Provided in diagram

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Key Vault
# SKU: Standard (provided in diagram)
# Soft Delete: Enabled (provided in diagram)
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "keyvault" {
  name                       = var.key_vault_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard" # Provided in diagram
  soft_delete_retention_days = 7          # Soft delete enabled (provided in diagram)
  purge_protection_enabled   = false      # Assumed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Namespace
# Material Tier: Standard (provided in diagram)
resource "azurerm_servicebus_namespace" "servicebus" {
  name                = var.servicebus_namespace_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Provided in diagram as Material Tier: Standard

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Queue (Assumed - diagram mentions "Queues & Topics")
resource "azurerm_servicebus_queue" "queue" {
  name         = "iaac-queue" # Assumed name
  namespace_id = azurerm_servicebus_namespace.servicebus.id
}

# Service Bus Topic (Assumed - diagram mentions "Queues & Topics")
resource "azurerm_servicebus_topic" "topic" {
  name         = "iaac-topic" # Assumed name
  namespace_id = azurerm_servicebus_namespace.servicebus.id
}

# Cosmos DB Account
# SQL Database: "iac-db" (provided in diagram)
# Material Tier: Standard (provided in diagram)
resource "azurerm_cosmosdb_account" "cosmosdb" {
  name                = var.cosmosdb_account_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  offer_type          = "Standard" # Provided in diagram as Material Tier: Standard
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session" # Assumed
  }

  geo_location {
    location          = data.azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Cosmos DB SQL Database
# Database name: "iac-db" (provided in diagram)
resource "azurerm_cosmosdb_sql_database" "sqldb" {
  name                = "iac-db" # Provided in diagram
  resource_group_name = data.azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmosdb.name
}

# Storage Account for Function App (required for Function App)
resource "azurerm_storage_account" "function_storage" {
  name                     = "${var.storage_account_name}func" # Assumed - must be unique
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # Assumed
  account_replication_type = "LRS"      # Assumed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# App Service Plan for Function App
# Note: Diagram indicates Resource Group: Project-Functions-RG, but we use the existing RG
resource "azurerm_service_plan" "function_plan" {
  name                = var.app_service_plan_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux" # Provided in diagram (azurerm_linux_function_app)
  sku_name            = "Y1"    # Assumed - Consumption plan for serverless

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App
# Runtime: Python (provided in diagram)
# Version: 3.11 (provided in diagram) - Note: AzureRM 3.0.2 only supports 3.7, 3.8, 3.9, defaulting to 3.9
resource "azurerm_linux_function_app" "function_app" {
  name                       = var.function_app_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = "3.9" # Diagram specifies 3.11, but AzureRM 3.0.2 only supports 3.7, 3.8, 3.9
    }
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway
# SKU: WAF_v2 (provided in diagram)
# HTTP Routing: Enabled (provided in diagram)
# Certificate: Let's Encrypt Cert (provided in diagram - needs manual setup)

# Virtual Network for Application Gateway (required)
resource "azurerm_virtual_network" "vnet" {
  name                = "iaac-vnet" # Assumed
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Subnet for Application Gateway (required)
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet" # Assumed
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Assumed
}

# Public IP for Application Gateway (required)
resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip" # Assumed
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static" # Required for WAF_v2
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway
# SKU: WAF_v2 (provided in diagram)
# Note: Let's Encrypt certificate needs to be set up manually or through separate process
resource "azurerm_application_gateway" "appgw" {
  name                = var.app_gateway_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "WAF_v2" # Provided in diagram
    tier     = "WAF_v2" # Provided in diagram
    capacity = 2        # Assumed
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "frontend-port-http"
    port = 80
  }

  frontend_port {
    name = "frontend-port-https"
    port = 443
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "appgw-backend-pool"
    # Backend addresses need to be configured based on actual function app or other backends
  }

  backend_http_settings {
    name                  = "appgw-backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "appgw-http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "frontend-port-http"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "appgw-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "appgw-http-listener"
    backend_address_pool_name  = "appgw-backend-pool"
    backend_http_settings_name = "appgw-backend-http-settings"
    priority                   = 100
  }

  # WAF configuration
  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention" # Assumed
    rule_set_type    = "OWASP"      # Assumed
    rule_set_version = "3.0"        # Assumed
  }

  # Note: Let's Encrypt certificate needs to be manually configured or added via ssl_certificate block
  # This requires the certificate to be uploaded or managed separately

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}
