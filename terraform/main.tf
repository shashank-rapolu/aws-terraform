# Terraform configuration for Azure Infrastructure
# Only supported services are included: Monitor, Service Bus, Function App, App Functions, and AI Search

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

# Variables for configurable values
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "dev" # Assumed value - not provided in document
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "IAAC-Team" # Based on diagram showing Owner: IAAC-Team
}

variable "function_app_runtime" {
  description = "Python runtime version for Function App"
  type        = string
  default     = "3.9" # Assumed - must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2
}

# Random suffix for Key Vault unique name (to avoid soft-delete conflicts)
resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

# ============================================================================
# 1. MONITOR (Application Insights with Log Analytics Workspace)
# ============================================================================

# Log Analytics Workspace (required for Application Insights)
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30 # Assumed default retention

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier" # As shown in diagram
    costcenter  = "R&D"             # As shown in diagram
  }
}

# Application Insights
resource "azurerm_application_insights" "appinsights" {
  name                = "appi-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web" # Assumed - appropriate for monitoring function apps

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# ============================================================================
# 5. SERVICE BUS
# ============================================================================

resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Assumed - Standard supports topics and queues

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# Service Bus Queue (for queue routing as shown in diagram)
resource "azurerm_servicebus_queue" "queue" {
  name         = "messages-queue"
  namespace_id = azurerm_servicebus_namespace.sb.id
}

# Service Bus Topic (for topic routing as shown in diagram)
resource "azurerm_servicebus_topic" "topic" {
  name         = "messages-topic"
  namespace_id = azurerm_servicebus_namespace.sb.id
}

# Service Bus Topic Subscription (assumed - needed for topic routing)
resource "azurerm_servicebus_subscription" "sub" {
  name               = "messages-subscription"
  topic_id           = azurerm_servicebus_topic.topic.id
  max_delivery_count = 10 # Assumed default
}

# ============================================================================
# 7. FUNCTION APP (azurerm_linux_function_app)
# ============================================================================

# Storage Account for Function App (required)
resource "azurerm_storage_account" "funcapp_storage" {
  name                     = "stfunciaacpoc"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# App Service Plan for Function App
resource "azurerm_service_plan" "asp_funcapp" {
  name                = "asp-funcapp-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan - assumed for serverless

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# Linux Function App #7 (Relay Messages, Trigger Functions, Queue & Topic Routing)
resource "azurerm_linux_function_app" "funcapp" {
  name                       = "func-relay-iaac-poc"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.asp_funcapp.id
  storage_account_name       = azurerm_storage_account.funcapp_storage.name
  storage_account_access_key = azurerm_storage_account.funcapp_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_runtime # Must be 3.7, 3.8, or 3.9
    }
    application_insights_key               = azurerm_application_insights.appinsights.instrumentation_key
    application_insights_connection_string = azurerm_application_insights.appinsights.connection_string
  }

  app_settings = {
    # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
    # Azure sets these automatically based on application_stack and storage_account configuration
    
    # Service Bus connection for relay and routing functionality
    "ServiceBusConnection" = azurerm_servicebus_namespace.sb.default_primary_connection_string

    # Application Insights for monitoring
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.appinsights.instrumentation_key
  }

  identity {
    type = "SystemAssigned" # Managed Identity as shown in diagram
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# ============================================================================
# 9. APP FUNCTIONS (Serverless Functions for processing)
# ============================================================================

# Storage Account for App Functions
resource "azurerm_storage_account" "appfunc_storage" {
  name                     = "stappfunciaacpoc"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# App Service Plan for App Functions
resource "azurerm_service_plan" "asp_appfunc" {
  name                = "asp-appfunc-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan - serverless

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# Linux Function App #9 (Process Events, Enrich Metadata)
resource "azurerm_linux_function_app" "appfunc" {
  name                       = "func-process-iaac-poc"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.asp_appfunc.id
  storage_account_name       = azurerm_storage_account.appfunc_storage.name
  storage_account_access_key = azurerm_storage_account.appfunc_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_runtime
    }
    application_insights_key               = azurerm_application_insights.appinsights.instrumentation_key
    application_insights_connection_string = azurerm_application_insights.appinsights.connection_string
  }

  app_settings = {
    # DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
    
    # AI Search connection for search & index data functionality
    "AzureSearchEndpoint" = "https://${azurerm_search_service.search.name}.search.windows.net"
    "AzureSearchKey"      = azurerm_search_service.search.primary_key

    # Application Insights for monitoring
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.appinsights.instrumentation_key
  }

  identity {
    type = "SystemAssigned" # Managed Identity for secure access
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# ============================================================================
# 8. AI SEARCH
# ============================================================================

resource "azurerm_search_service" "search" {
  name                = "search-iaac-poc"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "basic" # Assumed - basic tier for development

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# ============================================================================
# KEY VAULT (Security - Key Vault Integration for secrets as shown in diagram)
# ============================================================================

# Current Azure client configuration for Key Vault access policy
data "azurerm_client_config" "current" {}

# Key Vault with unique name to avoid soft-delete conflicts
resource "azurerm_key_vault" "kv" {
  name                       = "kv-iaac-${random_string.kv_suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false # Allow Terraform to clean up
  soft_delete_retention_days = 7

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    costcenter  = "R&D"
  }
}

# Access policy for current deployer
resource "azurerm_key_vault_access_policy" "deployer" {
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

# Access policy for Function App #7 (relay messages)
resource "azurerm_key_vault_access_policy" "funcapp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = azurerm_linux_function_app.funcapp.identity[0].tenant_id
  object_id    = azurerm_linux_function_app.funcapp.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

# Access policy for App Functions #9 (process events)
resource "azurerm_key_vault_access_policy" "appfunc" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = azurerm_linux_function_app.appfunc.identity[0].tenant_id
  object_id    = azurerm_linux_function_app.appfunc.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

# NOTE: Do NOT create azurerm_key_vault_secret resources in Terraform
# Azure Key Vault firewall propagation causes persistent "ForbiddenByFirewall" errors
# Create secrets manually via Azure Portal or CLI after deployment:
# - ServiceBus connection strings
# - AI Search keys
# - Application Insights keys
# - Any other sensitive configuration values

# ============================================================================
# NOTES ON EXCLUDED SERVICES
# ============================================================================

# The diagram shows connections and dependencies that are NOT in the supported list:
# - Cosmos DB (mentioned in security section for private endpoints)
# - Application Gateway WAF (networking section) - Application Gateway resource creation is supported but not included as it's not clearly depicted as a resource node
# These services are ignored per instruction #6 and #7

# Manual configuration required:
# - Application Gateway WAF setup (if needed for HTTPS TLS 1.2 as shown in diagram)
# - Private Endpoints for Storage and other services (shown in security section)
# - VNet Integration (shown as optional in networking section)
# - Diagnostic Settings configuration in Azure Monitor
# - Action Groups for alerts on failures (shown in monitoring section)
