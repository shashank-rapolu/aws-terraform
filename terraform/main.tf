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

# Reference existing resource group - DO NOT CREATE
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Current Azure client configuration for Key Vault access policy
data "azurerm_client_config" "current" {}

# Random suffix for unique naming
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Variables for configurable values
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
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2)"
  type        = string
  default     = "3.9" # Assumed value
}

# Storage Account for Function Apps
resource "azurerm_storage_account" "function_storage" {
  name                     = "funcstorage${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Storage Account for Document Storage (Blob Storage)
resource "azurerm_storage_account" "document_storage" {
  name                     = "docstorage${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Storage Private Endpoint - Assumed for "Azure Storage Private Endpoint /28" in diagram
# Note: Private Endpoint creation requires a VNet and Subnet which are not shown in the diagram
# This is a placeholder comment - requires manual VNet/Subnet configuration

# Key Vault with unique name to avoid soft-delete conflicts
resource "azurerm_key_vault" "kv" {
  name                        = "kv-${random_string.suffix.result}"
  location                    = data.azurerm_resource_group.rg.location
  resource_group_name         = data.azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  purge_protection_enabled    = false
  soft_delete_retention_days  = 7

  # Network ACLs to allow access and avoid firewall errors
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Key Vault Access Policy for current deployment principal
resource "azurerm_key_vault_access_policy" "deployer_policy" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge"
  ]
}

# NOTE: Do NOT create Key Vault secrets in Terraform due to firewall propagation delays.
# After deployment, manually create secrets via Azure Portal or CLI:
# - "OpenAI Prereq Subnet" secrets (as shown in diagram)
# - Any other required secrets for your application

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-namespace-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Queue - "Incoming PNG Endpoint Subnet /28"
resource "azurerm_servicebus_queue" "incoming_queue" {
  name         = "incoming-png-endpoint"
  namespace_id = azurerm_servicebus_namespace.sb.id
}

# Service Bus Queue - "Outgoing VNETINT Subnet /28"
resource "azurerm_servicebus_queue" "outgoing_queue" {
  name         = "outgoing-vnetint"
  namespace_id = azurerm_servicebus_namespace.sb.id
}

# App Service Plan for Function Apps
resource "azurerm_service_plan" "asp" {
  name                = "asp-functions-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "B1" # Assumed value - Basic tier

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Function App - App Services
resource "azurerm_linux_function_app" "func_app" {
  name                       = "func-app-${random_string.suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.asp.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_python_version
    }
  }

  # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  # Azure automatically configures these based on application_stack and storage_account settings
  app_settings = {
    # Add custom app settings here if needed
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Log Analytics Workspace for Application Insights
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

# Application Insights
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

# Azure AI Search (formerly Cognitive Search)
resource "azurerm_search_service" "search" {
  name                = "search-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "standard" # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Document Intelligence (Form Recognizer)
resource "azurerm_cognitive_account" "doc_intelligence" {
  name                = "docintel-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer"
  sku_name            = "S0"
  custom_subdomain_name = "docintel-${random_string.suffix.result}" # Required for token-based auth

  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure OpenAI Cognitive Service

# Application Gateway
# Note: SSL certificates and private endpoint subnets require manual configuration or separate VNet resources
# Using HTTP (port 80) for listener and backend since SSL certificates cannot be auto-provisioned

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# NOTE: Application Gateway requires a VNet and Subnet which are not defined in the diagram
# The following is a placeholder - you must create or reference an existing VNet/Subnet

# Placeholder VNet for Application Gateway (assumed)
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Subnet for Application Gateway
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Assumed value
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "Standard_v2" # Assumed value
    tier     = "Standard_v2"
    capacity = 2 # Assumed value
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
    # Backend targets should be manually configured or added via variables
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
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

  # SSL Policy to avoid deprecated TLS versions
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # NOTE: SSL certificates must be configured manually or via separate automation
  # Add ssl_certificate block and update listeners/settings for HTTPS if needed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Note: Managed Identities shown in the diagram should be created and assigned manually or via separate automation
# - "Managed Identity for OpenAI"
# - "Managed Identity for Azure AI Search"
# - "Managed Identity for Storage"
# These can be created using azurerm_user_assigned_identity and assigned to respective resources
