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

# Reference existing resource group (not creating a new one)
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Variables for customizable values
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev" # Assumed value
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "IAAC-Team" # Based on diagram tags
}

variable "function_app_runtime" {
  description = "Python runtime version for Function Apps"
  type        = string
  default     = "3.9" # Assumed - must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2
}

variable "service_bus_sku" {
  description = "Service Bus SKU"
  type        = string
  default     = "Standard" # Assumed - required for topics
}

variable "search_sku" {
  description = "AI Search service SKU"
  type        = string
  default     = "basic" # Assumed value
}

# Random suffix for globally unique names
resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}

# ===========================
# 1. Azure Monitor (Log Analytics Workspace + Application Insights)
# ===========================

resource "azurerm_log_analytics_workspace" "monitor" {
  name                = "law-iaac-poc-${random_string.unique.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"        # Assumed value
  retention_in_days   = 30                 # Default retention

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_application_insights" "monitor" {
  name                = "appi-iaac-poc-${random_string.unique.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.monitor.id
  application_type    = "web" # Assumed value

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# ===========================
# 5. Service Bus (Namespace, Queue, Topic)
# ===========================

resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-iaac-poc-${random_string.unique.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = var.service_bus_sku

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

resource "azurerm_servicebus_queue" "queue" {
  name         = "messages-queue" # Assumed name
  namespace_id = azurerm_servicebus_namespace.sb.id

  # Assumed settings for message relay
  max_delivery_count              = 10
  lock_duration                   = "PT1M"
  enable_partitioning             = false
}

resource "azurerm_servicebus_topic" "topic" {
  name         = "alerts-topic" # Assumed name for alerts routing
  namespace_id = azurerm_servicebus_namespace.sb.id

  enable_partitioning = false # Assumed value
}

resource "azurerm_servicebus_subscription" "subscription" {
  name               = "function-subscription" # Assumed name
  topic_id           = azurerm_servicebus_topic.topic.id
  max_delivery_count = 10
  lock_duration      = "PT1M"
}

# ===========================
# 8. AI Search (Cognitive Search)
# ===========================

resource "azurerm_search_service" "search" {
  name                = "search-iaac-poc-${random_string.unique.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = var.search_sku

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# ===========================
# Key Vault (for secrets management)
# ===========================

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                        = "kv-iaac-${random_string.unique.result}"
  location                    = data.azurerm_resource_group.rg.location
  resource_group_name         = data.azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  
  # Allow Terraform to destroy the vault
  purge_protection_enabled    = false
  soft_delete_retention_days  = 7

  # Open network access to avoid firewall issues
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Access policy for current user/service principal
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Recover",
    "Backup",
    "Restore",
    "Purge"
  ]
}

# NOTE: Do NOT create azurerm_key_vault_secret resources here.
# Azure Key Vault firewall propagation delays cause persistent "ForbiddenByFirewall" 403 errors.
# After deployment, create secrets manually via Azure Portal or CLI:
# - Service Bus connection strings
# - AI Search API keys
# - Function App secrets

# ===========================
# 7. Function App (azurerm_linux_function_app)
# ===========================

# Storage account for Function App
resource "azurerm_storage_account" "func_storage" {
  name                     = "stfunc${random_string.unique.result}"
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
resource "azurerm_service_plan" "func_plan" {
  name                = "asp-iaac-poc-${random_string.unique.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan - assumed

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App (Component 7)
resource "azurerm_linux_function_app" "func_relay" {
  name                       = "func-relay-${random_string.unique.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage.name
  storage_account_access_key = azurerm_storage_account.func_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_runtime
    }

    application_insights_connection_string = azurerm_application_insights.monitor.connection_string
    application_insights_key               = azurerm_application_insights.monitor.instrumentation_key
  }

  # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  # Azure automatically sets these when storage and application_stack are configured
  app_settings = {
    "ServiceBusConnectionString" = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/ServiceBusConnectionString/)" # Needs to be created manually
    "SearchServiceEndpoint"      = "https://${azurerm_search_service.search.name}.search.windows.net"
    # NOTE: SearchServiceApiKey should be stored in Key Vault and referenced here
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# ===========================
# 9. App Functions (Additional Function App)
# ===========================

# Storage account for second Function App
resource "azurerm_storage_account" "func_storage_2" {
  name                     = "stfunc2${random_string.unique.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# Linux Function App (Component 9 - Serverless Functions)
resource "azurerm_linux_function_app" "func_process" {
  name                       = "func-process-${random_string.unique.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.func_plan.id
  storage_account_name       = azurerm_storage_account.func_storage_2.name
  storage_account_access_key = azurerm_storage_account.func_storage_2.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_runtime
    }

    application_insights_connection_string = azurerm_application_insights.monitor.connection_string
    application_insights_key               = azurerm_application_insights.monitor.instrumentation_key
  }

  # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  app_settings = {
    "SearchServiceEndpoint"      = "https://${azurerm_search_service.search.name}.search.windows.net"
    # NOTE: SearchServiceApiKey should be stored in Key Vault and referenced here
  }

  tags = {
    environment = var.environment
    owner       = var.owner
  }
}

# ===========================
# NOTES:
# ===========================
# - Application Gateway with WAF mentioned in diagram but requires manual SSL certificate setup
# - Managed Identity setup needs to be configured manually for Function Apps to access Key Vault
# - Private Endpoints for Storage mentioned in diagram - configure manually if required
# - VNet Integration is optional per diagram - configure manually if needed
# - Action Groups for alerts need to be configured manually in Azure Monitor
# - Diagnostic Settings mentioned in diagram - configure manually via Azure Portal
