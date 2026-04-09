# Terraform configuration for Azure infrastructure
# Based on the provided architecture diagram

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}


provider "azurerm" {
    features {}
    skip_provider_registration = true


# Reference existing resource group - DO NOT create new resource group
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Random suffix for unique naming (to avoid soft-delete conflicts)
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Variables for configuration
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev" # Assumed value
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "platform-team" # Assumed value
}

variable "function_app_python_version" {
  description = "Python version for Function App"
  type        = string
  default     = "3.9" # Must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2
}

# Storage Account for Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "funcstore${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Storage Account for general use (Azure Storage)
resource "azurerm_storage_account" "general_storage" {
  name                     = "storage${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Data Lake Storage Gen2
resource "azurerm_storage_account" "datalake" {
  name                     = "datalake${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # Enables Data Lake Gen2

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Data Lake Gen2 Filesystem
resource "azurerm_storage_data_lake_gen2_filesystem" "datalake_fs" {
  name               = "data"
  storage_account_id = azurerm_storage_account.datalake.id
}

# Key Vault with unique name to avoid soft-delete conflicts
resource "azurerm_key_vault" "keyvault" {
  name                        = "kv-${random_string.suffix.result}"
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = data.azurerm_resource_group.rg.location
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Current client configuration for Key Vault access policy
data "azurerm_client_config" "current" {}

# Key Vault Access Policy
resource "azurerm_key_vault_access_policy" "terraform_access" {
  key_vault_id = azurerm_key_vault.keyvault.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge",
    "Recover"
  ]

  key_permissions = [
    "Get",
    "List",
    "Create",
    "Delete",
    "Purge"
  ]

  certificate_permissions = [
    "Get",
    "List",
    "Create",
    "Delete",
    "Purge"
  ]
}

# NOTE: Do NOT create Key Vault secrets in Terraform due to firewall propagation delays.
# Create secrets manually via Azure Portal or CLI after deployment.

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "servicebus" {
  name                = "sb-namespace-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "Standard" # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Queue for Incoming FHIR Endpoint
resource "azurerm_servicebus_queue" "incoming_queue" {
  name         = "incoming-fhir-queue"
  namespace_id = azurerm_servicebus_namespace.servicebus.id
}

# Service Bus Queue for Outgoing FHIR Endpoint
resource "azurerm_servicebus_queue" "outgoing_queue" {
  name         = "outgoing-fhir-queue"
  namespace_id = azurerm_servicebus_namespace.servicebus.id
}

# App Service Plan for Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "asp-functions-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "function_app" {
  name                       = "func-app-${random_string.suffix.result}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = data.azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_python_version
    }
  }

  # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  # These are automatically set by Azure and cause 409 errors if manually configured
  app_settings = {
    "ServiceBusConnection" = azurerm_servicebus_namespace.servicebus.default_primary_connection_string
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Log Analytics Workspace for Application Insights
resource "azurerm_log_analytics_workspace" "workspace" {
  name                = "log-analytics-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Insights
resource "azurerm_application_insights" "appinsights" {
  name                = "appi-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.workspace.id
  retention_in_days   = 30

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Cognitive Services - Document Intelligence (Form Recognizer)
resource "azurerm_cognitive_account" "document_intelligence" {
  name                  = "doc-intel-${random_string.suffix.result}"
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = data.azurerm_resource_group.rg.location
  kind                  = "FormRecognizer"
  sku_name              = "S0"
  custom_subdomain_name = "docintel${random_string.suffix.result}" # Required for token-based auth

  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure AI Search (Cognitive Search)
resource "azurerm_search_service" "ai_search" {
  name                = "search-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "standard" # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-appgw-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Subnet for Application Gateway
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "snet-appgw"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-appgw-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "backend-pool"
    # Backend targets would be configured manually or via additional resources
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }

  # SSL policy to avoid deprecated TLS versions
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # NOTE: SSL certificates need to be configured manually if HTTPS is required
  # Use Azure Portal or CLI to upload certificates after deployment

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# NOTE: Managed Identities need to be created and assigned manually to resources
# Use Azure Portal or CLI to configure system-assigned or user-assigned managed identities
# for Function Apps, Storage Accounts, Key Vault, AI Search, OpenAI, and Document Intelligence
