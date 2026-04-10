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

  }
}

# Reference existing resource group - DO NOT CREATE NEW
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Random suffix for unique naming (Key Vault, Storage, etc.)
resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
}

# Variables for configurable values
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "production" # Assumed value
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "admin" # Assumed value
}

variable "function_app_plan_sku" {
  description = "SKU for App Service Plan"
  type        = string
  default     = "Y1" # Assumed: Consumption plan for serverless
}

variable "ai_search_sku" {
  description = "SKU for AI Search service"
  type        = string
  default     = "standard" # Assumed value
}

variable "document_intelligence_sku" {
  description = "SKU for Document Intelligence"
  type        = string
  default     = "S0" # Assumed value
}

# =============================================================================
# APPLICATION GATEWAY
# =============================================================================

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "appgw_vnet" {
  name                = "appgw-vnet-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed address space

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Subnet for Application Gateway
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.appgw_vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Assumed subnet range
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static" # Required for Application Gateway v2
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "Standard_v2" # Assumed SKU
    tier     = "Standard_v2"
    capacity = 2 # Assumed capacity
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "backend-pool"
    # Backend addresses configured manually or via Function App integration
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
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

  tags = {
    environment = var.environment
    owner       = var.owner
  }

  # NOTE: SSL certificate configuration needs to be done manually if HTTPS is required
}

# =============================================================================
# APP SERVICE PLAN & FUNCTION APPS
# =============================================================================

# Storage Account for Function Apps
resource "azurerm_storage_account" "func_storage" {
  name                     = "funcstore${random_string.suffix.result}"
  location                 = data.azurerm_resource_group.rg.location
  resource_group_name      = data.azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# App Service Plan for Function Apps
resource "azurerm_service_plan" "func_plan" {
  name                = "func-plan-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = var.function_app_plan_sku

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Incoming PHQ Endpoint Subnet Function (depicted in diagram)
resource "azurerm_linux_function_app" "incoming_phq" {
  name                       = "incoming-phq-func-${random_string.suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  # NOTE: App Settings for external integrations need to be configured manually
  app_settings = {
    # Application-specific settings go here
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Outgoing MFEHIT Subnet Function (depicted in diagram)
resource "azurerm_linux_function_app" "outgoing_mfehit" {
  name                       = "outgoing-mfehit-func-${random_string.suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key

  site_config {
    application_stack {
      python_version = "3.9"
    }
  }

  app_settings = {
    # Application-specific settings go here
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# =============================================================================
# KEY VAULT
# =============================================================================

# Current client configuration for Key Vault access
data "azurerm_client_config" "current" {}

# Key Vault with unique name to avoid soft-delete conflicts
resource "azurerm_key_vault" "kv" {
  name                        = "kv-${random_string.suffix.result}"
  location                    = data.azurerm_resource_group.rg.location
  resource_group_name         = data.azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  # Network ACLs to allow access during deployment
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Access Policy for current client
resource "azurerm_key_vault_access_policy" "current_user" {
  key_vault_id = azurerm_key_vault.kv.id
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
    "Purge",
    "Recover"
  ]
}

# NOTE: Do NOT create azurerm_key_vault_secret resources in Terraform.
# Azure Key Vault firewall propagation delays cause persistent "ForbiddenByFirewall" errors.
# Create secrets manually via Azure Portal or CLI after deployment.

# =============================================================================
# STORAGE ACCOUNTS
# =============================================================================

# Azure Storage (Blob Storage) - depicted in diagram
resource "azurerm_storage_account" "blob_storage" {
  name                     = "blobstore${random_string.suffix.result}"
  location                 = data.azurerm_resource_group.rg.location
  resource_group_name      = data.azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Data Lake Storage Gen2 - depicted as "Azure Storage Private Endpoint /20"
resource "azurerm_storage_account" "datalake" {
  name                     = "datalake${random_string.suffix.result}"
  location                 = data.azurerm_resource_group.rg.location
  resource_group_name      = data.azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hfs_enabled           = true

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Data Lake Gen2 Filesystem
resource "azurerm_storage_data_lake_gen2_filesystem" "datalake_fs" {
  name               = "datalakefs"
  storage_account_id = azurerm_storage_account.datalake.id
}

# =============================================================================
# AZURE AI SEARCH
# =============================================================================

# Azure AI Search (depicted in diagram)
resource "azurerm_search_service" "search" {
  name                = "aisearch-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = var.ai_search_sku

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# =============================================================================
# DOCUMENT INTELLIGENCE (FORM RECOGNIZER)
# =============================================================================

# Document Intelligence (depicted in diagram)
resource "azurerm_cognitive_account" "document_intelligence" {
  name                = "docintel-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer"
  sku_name            = var.document_intelligence_sku
  custom_subdomain_name = "docintel-${random_string.suffix.result}" # Required for token-based auth

  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# =============================================================================
# AZURE MONITOR (APPLICATION INSIGHTS)
# =============================================================================

# Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Application Insights (depicted in diagram)
resource "azurerm_application_insights" "appinsights" {
  name                = "appinsights-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# =============================================================================
# SERVICE BUS
# =============================================================================

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb_namespace" {
  name                = "sb-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Assumed SKU

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Queue (App Services depicted in diagram)
resource "azurerm_servicebus_queue" "app_services_queue" {
  name         = "app-services-queue"
  namespace_id = azurerm_servicebus_namespace.sb_namespace.id
}

# NOTE: Azure OpenAI is not in the supported list — configure integration manually.
# NOTE: OpenAI Prompt Subnet and related OpenAI services are not provisioned by this Terraform configuration.
# NOTE: Managed Identity assignments and RBAC roles need to be configured manually based on access requirements.
