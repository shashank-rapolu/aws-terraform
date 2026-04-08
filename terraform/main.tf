# Terraform configuration for Azure infrastructure
# Using AzureRM provider version ~> 3.0.2

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

# Reference to existing resource group - DO NOT CREATE NEW
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Variables for values not explicitly provided or that might change
variable "environment" {
  description = "Environment tag value (assumed)"
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag value (assumed)"
  type        = string
  default     = "iaac-team"
}

variable "storage_account_name" {
  description = "Storage account name - must be globally unique (assumed)"
  type        = string
  default     = "iacpocstorageacct"
}

variable "key_vault_name" {
  description = "Key Vault name - must be globally unique (assumed)"
  type        = string
  default     = "iacpockeyvault"
}

variable "servicebus_namespace_name" {
  description = "Service Bus namespace name (assumed)"
  type        = string
  default     = "iacpoc-servicebus-ns"
}

variable "function_app_name" {
  description = "Function App name (assumed)"
  type        = string
  default     = "iacpoc-function-app"
}

variable "app_service_plan_name" {
  description = "App Service Plan name for Function App (assumed)"
  type        = string
  default     = "iacpoc-asp"
}

variable "app_gateway_name" {
  description = "Application Gateway name (assumed)"
  type        = string
  default     = "iacpoc-app-gateway"
}

variable "vnet_name" {
  description = "Virtual Network name for Application Gateway (assumed)"
  type        = string
  default     = "iacpoc-vnet"
}

variable "subnet_name" {
  description = "Subnet name for Application Gateway (assumed)"
  type        = string
  default     = "iacpoc-app-gw-subnet"
}

variable "public_ip_name" {
  description = "Public IP name for Application Gateway (assumed)"
  type        = string
  default     = "iacpoc-app-gw-pip"
}

# Blob Storage - azurerm_storage_account
# Account Tier: Standard (provided)
# Replication: GRS (provided)
resource "azurerm_storage_account" "blob_storage" {
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

# Key Vault - azurerm_key_vault
# SKU: Standard (provided)
# Soft Delete: Enabled (provided)
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "key_vault" {
  name                       = var.key_vault_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard" # Provided in diagram
  soft_delete_retention_days = 7          # Soft delete enabled (provided)
  purge_protection_enabled   = false      # Assumed - not specified

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus - azurerm_servicebus_namespace
# Material Tier: Standard (provided)
# Queues & Topics (provided - but these need to be created separately if specific configurations are needed)
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

# Function App - azurerm_linux_function_app
# Runtime: Python (provided)
# Version: 3.11 (provided, but not supported in AzureRM ~> 3.0.2, defaulting to 3.9)
# Resource Group: Project-Functions-RG (provided - but must use existing RG per instructions)
# Note: The diagram specifies Resource Group "Project-Functions-RG", but per instructions, 
# we must use the existing "Project-IAAC-PoC-RG"

# Storage account for Function App (required)
resource "azurerm_storage_account" "function_storage" {
  name                     = "${var.storage_account_name}func"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# App Service Plan for Function App
resource "azurerm_service_plan" "function_plan" {
  name                = var.app_service_plan_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan (assumed)

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "function_app" {
  name                       = var.function_app_name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = "3.9" # Diagram specifies 3.11, but AzureRM ~> 3.0.2 supports only 3.7, 3.8, 3.9
    }
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway - azurerm_application_gateway
# SKU: WAF_v2 (provided)
# HTTP Routing: Enabled (provided)
# Certificate: Let's Encrypt Cert (provided - needs manual setup)

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Subnet for Application Gateway
resource "azurerm_subnet" "app_gw_subnet" {
  name                 = var.subnet_name
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Assumed
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "app_gw_pip" {
  name                = var.public_ip_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static" # Required for Application Gateway
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway
resource "azurerm_application_gateway" "app_gateway" {
  name                = var.app_gateway_name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "WAF_v2" # Provided in diagram
    tier     = "WAF_v2" # Provided in diagram
    capacity = 2        # Assumed
  }

  gateway_ip_configuration {
    name      = "app-gw-ip-config"
    subnet_id = azurerm_subnet.app_gw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80 # HTTP Routing enabled (provided)
  }

  frontend_port {
    name = "https-port"
    port = 443 # For SSL certificate (assumed)
  }

  frontend_ip_configuration {
    name                 = "app-gw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.app_gw_pip.id
  }

  backend_address_pool {
    name = "app-gw-backend-pool"
    # Backend addresses need to be configured based on actual backend resources
  }

  backend_http_settings {
    name                  = "app-gw-backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "app-gw-http-listener"
    frontend_ip_configuration_name = "app-gw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "app-gw-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "app-gw-http-listener"
    backend_address_pool_name  = "app-gw-backend-pool"
    backend_http_settings_name = "app-gw-backend-http-settings"
    priority                   = 100
  }

  # SSL Policy - Required to avoid deprecated TLS versions
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # Note: Let's Encrypt certificate needs to be manually configured
  # SSL certificate configuration requires certificate data which must be obtained separately

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Note: Cosmos DB is mentioned in the diagram but per instructions (point 6),
# only Blob Storage, Key Vault, Service Bus, App Functions, and Application Gateway
# should be created. Cosmos DB is ignored.
