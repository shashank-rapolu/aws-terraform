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

# Reference existing resource group - DO NOT create a new one
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Current client configuration for Key Vault access policy
data "azurerm_client_config" "current" {}

# Random suffix for globally unique names
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Variables for configurable values
variable "environment" {
  description = "Environment tag value"
  type        = string
  default     = "dev" # Assumed value - update as needed
}

variable "owner" {
  description = "Owner tag value"
  type        = string
  default     = "infrastructure-team" # Assumed value - update as needed
}

variable "app_service_plan_sku" {
  description = "SKU for App Service Plan"
  type        = string
  default     = "P1v2" # Assumed value - update as needed
}

variable "function_python_version" {
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9)"
  type        = string
  default     = "3.9"
}

variable "application_gateway_sku" {
  description = "SKU configuration for Application Gateway"
  type = object({
    name     = string
    tier     = string
    capacity = number
  })
  default = {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }
}

# Log Analytics Workspace for Application Insights
resource "azurerm_log_analytics_workspace" "workspace" {
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

# Application Insights for monitoring
resource "azurerm_application_insights" "insights" {
  name                = "appi-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.workspace.id
  retention_in_days   = 30

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Storage Account for Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "stfunc${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Storage Account for general Azure Storage (Blob Storage)
resource "azurerm_storage_account" "storage" {
  name                     = "stgeneral${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Storage Private Endpoint Storage Account
resource "azurerm_storage_account" "private_endpoint_storage" {
  name                     = "stprivate${random_string.suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Key Vault with unique name to avoid soft-delete conflicts
resource "azurerm_key_vault" "kv" {
  name                        = "kv-${random_string.suffix.result}"
  location                    = data.azurerm_resource_group.rg.location
  resource_group_name         = data.azurerm_resource_group.rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  sku_name                    = "standard"

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Key Vault Access Policy for current user/service principal
resource "azurerm_key_vault_access_policy" "current" {
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

# NOTE: Do NOT create azurerm_key_vault_secret resources here due to firewall propagation delays.
# Create secrets manually via Azure Portal or CLI after deployment.

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Assumed value - update as needed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Service Bus Queue for incoming PHI endpoint
resource "azurerm_servicebus_queue" "incoming_phi" {
  name         = "incoming-phi-endpoint-queue"
  namespace_id = azurerm_servicebus_namespace.sb.id

  # Assumed configuration - update as needed
  enable_partitioning = false
}

# Service Bus Queue for outgoing FHIR
resource "azurerm_servicebus_queue" "outgoing_fhir" {
  name         = "outgoing-fhir-queue"
  namespace_id = azurerm_servicebus_namespace.sb.id

  # Assumed configuration - update as needed
  enable_partitioning = false
}

# App Service Plan for Function App
resource "azurerm_service_plan" "plan" {
  name                = "asp-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = var.app_service_plan_sku

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "function" {
  name                       = "func-${random_string.suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_python_version
    }

    application_insights_key               = azurerm_application_insights.insights.instrumentation_key
    application_insights_connection_string = azurerm_application_insights.insights.connection_string
  }

  app_settings = {
    # NOTE: Azure OpenAI is not in the supported list — configure integration manually.
    # Do NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION manually
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure AI Search (Cognitive Search)
resource "azurerm_search_service" "search" {
  name                = "search-${random_string.suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "standard" # Assumed value - update as needed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Azure Document Intelligence (Form Recognizer)
resource "azurerm_cognitive_account" "document_intelligence" {
  name                = "doc-intel-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer"
  sku_name            = "S0"

  # Required for token-based authentication
  custom_subdomain_name = "doc-intel-${random_string.suffix.result}"

  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed value - update as needed

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
  address_prefixes     = ["10.0.1.0/24"] # Assumed value - update as needed
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-appgw-${random_string.suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
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
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = var.application_gateway_sku.name
    tier     = var.application_gateway_sku.tier
    capacity = var.application_gateway_sku.capacity
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
    # Backend targets should be configured manually or via additional resources
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

  # SSL policy block to avoid deprecated TLS versions
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # NOTE: SSL certificates need to be configured manually - cannot be provisioned automatically

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# NOTE: Azure OpenAI and Cosmos DB are not in the supported list — configure manually if needed.
# NOTE: Managed Identity assignments should be configured manually based on access requirements.
