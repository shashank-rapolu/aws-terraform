# Terraform configuration for Azure infrastructure
# Provider version: AzureRM ~> 3.0.2
# Terraform version: >= 1.5

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

# Reference existing resource group
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Current client configuration for Key Vault access policy
data "azurerm_client_config" "current" {}

# Random suffix for Key Vault to avoid soft-delete conflicts
resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Variables for configurable values
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "PoC" # Provided in Tags section
}

variable "owner" {
  description = "Owner of the resources"
  type        = string
  default     = "IAAC-Team" # Provided in Tags section
}

variable "cost_center" {
  description = "Cost center for the resources"
  type        = string
  default     = "R&D" # Provided in Tags section
}

variable "function_app_python_version" {
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2)"
  type        = string
  default     = "3.9" # Diagram specifies 3.11 but AzureRM ~> 3.0.2 does not support it, defaulting to 3.9
}

# 1. Blob Storage
resource "azurerm_storage_account" "blob_storage" {
  name                     = "iaacblobstorage${random_string.kv_suffix.result}" # Storage account names must be globally unique
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # Provided in diagram
  account_replication_type = "GRS"      # Provided in diagram as RA-GRS (Read-Access Geo-Redundant Storage)

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Blob containers for uploads and processed files
resource "azurerm_storage_container" "uploads" {
  name                  = "uploads" # Provided in diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private" # Provided in diagram: Access: Private Endpoint
}

resource "azurerm_storage_container" "processed" {
  name                  = "processed" # Provided in diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private"
}

# 2. Key Vault
resource "azurerm_key_vault" "key_vault" {
  name                       = "iaac-kv-${random_string.kv_suffix.result}" # Unique name to avoid soft-delete conflicts
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard" # Provided in diagram: SKU: Standard
  soft_delete_retention_days = 7          # Minimum retention for easy cleanup
  purge_protection_enabled   = false      # Disabled for Terraform cleanup capability

  # Network ACLs to allow access (required to avoid firewall errors)
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Access policy for Terraform client (current user/service principal)
resource "azurerm_key_vault_access_policy" "terraform_policy" {
  key_vault_id = azurerm_key_vault.key_vault.id
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

# NOTE: Do NOT create Key Vault secrets in Terraform due to firewall propagation delays causing 403 errors.
# After deployment, create secrets manually via Azure Portal or CLI:
# - conn-str (connection string)
# - API keys
# Diagram mentions: Secrets: conn-str, API keys

# 3. Service Bus Namespace
resource "azurerm_servicebus_namespace" "servicebus" {
  name                = "iaac-servicebus-${random_string.kv_suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Provided in diagram: SKU: Standard

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Service Bus Queues
resource "azurerm_servicebus_queue" "doc_ingest" {
  name         = "doc-ingest" # Provided in diagram: Queues: doc-ingest, processing
  namespace_id = azurerm_servicebus_namespace.servicebus.id

  max_size_in_megabytes = 1024 # Provided in diagram: MaxSize: 1 GB
}

resource "azurerm_servicebus_queue" "processing" {
  name         = "processing"
  namespace_id = azurerm_servicebus_namespace.servicebus.id

  max_size_in_megabytes = 1024
}

# Service Bus Topic
resource "azurerm_servicebus_topic" "indexing_requests" {
  name         = "indexing-requests" # Provided in diagram: Topics: indexing-requests
  namespace_id = azurerm_servicebus_namespace.servicebus.id

  max_size_in_megabytes = 1024
}

# 4. Application Gateway
# NOTE: SSL certificate configuration must be done manually. This setup uses HTTP only.

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "iaac-appgw-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard" # Required for Application Gateway v2 SKU

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Virtual Network for Application Gateway (required)
resource "azurerm_virtual_network" "appgw_vnet" {
  name                = "iaac-appgw-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Subnet for Application Gateway
resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.appgw_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "iaac-appgw"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "WAF_v2" # Provided in diagram: SKU: WAF_v2
    tier     = "WAF_v2"
    capacity = 2 # Assumed: minimum capacity for WAF_v2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80 # Using HTTP since SSL certificates cannot be provisioned automatically
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "appgw-backend-pool"
    # Backend targets would be configured separately (e.g., Function App, VMs)
  }

  backend_http_settings {
    name                  = "appgw-backend-http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http" # Using HTTP; upgrade to HTTPS requires SSL certificate configuration
    request_timeout       = 30
  }

  http_listener {
    name                           = "appgw-http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http" # Using HTTP; TLS 1.2 requires SSL certificate
  }

  request_routing_rule {
    name                       = "appgw-routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "appgw-http-listener"
    backend_address_pool_name  = "appgw-backend-pool"
    backend_http_settings_name = "appgw-backend-http-settings"
    priority                   = 100 # Required for Application Gateway v2
  }

  # SSL Policy (required to avoid deprecated TLS versions)
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101" # Non-deprecated policy
  }

  # WAF Configuration
  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention" # Provided in diagram: WAF Mode: Prevention
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# 6. Function App (Linux with Python runtime)
# Note: Cosmos DB is not in the allowed resource list, so it is not created.

# Storage account for Function App (required)
resource "azurerm_storage_account" "function_storage" {
  name                     = "iaacfuncstorage${random_string.kv_suffix.result}"
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# App Service Plan for Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "iaac-function-plan"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Provided in diagram: Plan: Y1 (Consumption)

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "function_app" {
  name                       = "iaac-function-app-${random_string.kv_suffix.result}"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_python_version # Diagram specifies 3.11 but using 3.9 for compatibility
    }
  }

  app_settings = {
    # Do NOT set FUNCTIONS_WORKER_RUNTIME or AzureWebJobsStorage manually - Azure sets these automatically
    FUNCTIONS_EXTENSION_VERSION = "~4" # Assumed: latest runtime version
    # Additional app settings can be added here (e.g., Key Vault references)
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# 7. AI Search (Azure Cognitive Search)
resource "azurerm_search_service" "ai_search" {
  name                = "iaac-search-${random_string.kv_suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "standard" # Provided in diagram: Service Tier: Standard (S1)

  replica_count   = 1 # Provided in diagram: Replicas: 1
  partition_count = 1 # Provided in diagram: Partitions: 1

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# 8. Monitor (Log Analytics Workspace + Application Insights)
resource "azurerm_log_analytics_workspace" "log_analytics" {
  name                = "iaac-log-analytics-${random_string.kv_suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018" # Standard pricing tier
  retention_in_days   = 30          # Assumed: 30 days retention (Basic Logs Tier mentioned in diagram)

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

resource "azurerm_application_insights" "app_insights" {
  name                = "iaac-app-insights"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.log_analytics.id
  application_type    = "web" # Assumed: web application type

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# NOTE: Private Endpoints for Storage and Cosmos DB need to be configured separately
# Managed Identity (System Assigned) should be enabled on Function App and Application Gateway via Azure Portal
# Alerts and Action Groups for monitoring need to be configured separately in Azure Monitor
