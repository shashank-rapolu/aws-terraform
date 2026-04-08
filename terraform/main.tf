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

# Reference existing resource group - DO NOT create a new one
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-RG"
}

# Variables for reusability
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "PoC" # Assumed from diagram tags
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "IAAC-Team" # Assumed from diagram tags
}

variable "function_app_python_version" {
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2)"
  type        = string
  default     = "3.9" # Version 3.11 specified in diagram is not supported in AzureRM ~> 3.0.2, using 3.9 instead
}

variable "function_app_timeout" {
  description = "Function App timeout in minutes"
  type        = number
  default     = 5 # Provided in diagram
}

# Blob Storage Account
resource "azurerm_storage_account" "blob_storage" {
  name                     = "iaacpocblobstorage" # Assumed unique name
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # Provided in diagram
  account_replication_type = "GRS"      # Provided in diagram (RA-GRS)

  # Note: public_network_access_enabled is not available in AzureRM ~> 3.0.2, omitted
  # Access: Private Endpoint as mentioned in diagram needs to be configured separately

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Blob Storage Containers
resource "azurerm_storage_container" "uploads" {
  name                  = "uploads" # Provided in diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private" # Assumed from diagram (Private Endpoint access)
}

resource "azurerm_storage_container" "processed" {
  name                  = "processed" # Provided in diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private"   # Assumed from diagram
}

# Key Vault
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = "iaacpockv${substr(md5(data.azurerm_resource_group.rg.id), 0, 6)}" # Unique name
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard" # Provided in diagram (SKU: Standard)
  soft_delete_retention_days = 90         # Assumed (Soft Delete: Enabled)
  purge_protection_enabled   = true       # Provided in diagram (Purge Protection: Enabled)

  tags = {
    Environment = var.environment
    Owner       = var.owner
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
    "Recover",
    "Backup",
    "Restore",
    "Purge"
  ]

  key_permissions = [
    "Get",
    "List",
    "Create",
    "Delete",
    "Recover",
    "Backup",
    "Restore",
    "Purge"
  ]
}

# Key Vault Secrets (conn-str, API keys as mentioned in diagram)
# Note: Actual secret values need to be provided manually or via variables
resource "azurerm_key_vault_secret" "connection_string" {
  name         = "conn-str" # Provided in diagram
  value        = "placeholder-connection-string" # Needs to be set manually
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_key_vault_access_policy.current]
}

resource "azurerm_key_vault_secret" "api_keys" {
  name         = "api-keys" # Provided in diagram
  value        = "placeholder-api-keys" # Needs to be set manually
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [azurerm_key_vault_access_policy.current]
}

# Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb" {
  name                = "iaacpocservicebus" # Assumed unique name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # Provided in diagram

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Service Bus Queues
resource "azurerm_servicebus_queue" "doc_ingest" {
  name         = "doc-ingest" # Provided in diagram
  namespace_id = azurerm_servicebus_namespace.sb.id

  max_size_in_megabytes = 1024 # Provided in diagram (MaxSize: 1 GB)
}

resource "azurerm_servicebus_queue" "processing" {
  name         = "processing" # Provided in diagram
  namespace_id = azurerm_servicebus_namespace.sb.id

  max_size_in_megabytes = 1024 # Assumed from diagram
}

# Service Bus Topics
resource "azurerm_servicebus_topic" "indexing_requests" {
  name         = "indexing-requests" # Provided in diagram
  namespace_id = azurerm_servicebus_namespace.sb.id

  max_size_in_megabytes = 1024 # Assumed
}

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "iaacpoc-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"] # Assumed address space

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # Assumed address prefix
}

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "iaacpoc-appgw-pip"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static" # Required for Application Gateway
  sku                 = "Standard"

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "iaacpoc-appgw"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name

  sku {
    name     = "WAF_v2" # Provided in diagram (SKU: WAF_v2)
    tier     = "WAF_v2"
    capacity = 2 # Assumed minimum capacity
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "https-port"
    port = 443 # Provided in diagram (HTTPS TLS 1.2)
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "function-app-backend"
    # Backend addresses need to be configured based on Function App
  }

  backend_http_settings {
    name                  = "https-backend-settings"
    cookie_based_affinity = "Disabled"
    port                  = 443
    protocol              = "Https"
    request_timeout       = 60
  }

  http_listener {
    name                           = "https-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "https-port"
    protocol                       = "Https"
    # SSL certificate needs to be configured manually and associated here
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "https-listener"
    backend_address_pool_name  = "function-app-backend"
    backend_http_settings_name = "https-backend-settings"
    priority                   = 100
  }

  waf_configuration {
    enabled          = true             # Provided in diagram (WAF Mode: Prevention)
    firewall_mode    = "Prevention"     # Provided in diagram
    rule_set_type    = "OWASP"
    rule_set_version = "3.1"            # Assumed recent version
  }

  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101" # Non-deprecated SSL policy
  }

  # Note: SSL certificate needs to be uploaded manually to Key Vault and referenced here
  # ssl_certificate block omitted - needs manual configuration

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Storage Account for Function App (required)
resource "azurerm_storage_account" "function_storage" {
  name                     = "iaacpocfuncstorage" # Assumed unique name
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# App Service Plan for Function App
resource "azurerm_service_plan" "function_plan" {
  name                = "iaacpoc-function-plan"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # Provided in diagram (Plan: Y1 Consumption)

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "function_app" {
  name                       = "iaacpoc-function-app"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_python_version # Using 3.9 instead of 3.11 (not supported in AzureRM ~> 3.0.2)
    }
  }

  app_settings = {
    "FUNCTIONS_WORKER_RUNTIME"       = "python" # Provided in diagram
    "AzureWebJobsStorage"            = azurerm_storage_account.function_storage.primary_connection_string
    "SERVICEBUS_CONNECTION_STRING"   = azurerm_servicebus_namespace.sb.default_primary_connection_string
    "KEY_VAULT_URI"                  = azurerm_key_vault.kv.vault_uri
    # Additional app settings as needed
  }

  identity {
    type = "SystemAssigned" # Provided in diagram (Managed Identity)
  }

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}

# Key Vault Access Policy for Function App
resource "azurerm_key_vault_access_policy" "function_app" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = azurerm_linux_function_app.function_app.identity[0].tenant_id
  object_id    = azurerm_linux_function_app.function_app.identity[0].principal_id

  secret_permissions = [
    "Get",
    "List"
  ]

  key_permissions = [
    "Get",
    "List"
  ]
}

# AI Search Service
resource "azurerm_search_service" "ai_search" {
  name                = "iaacpoc-aisearch"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "standard" # Provided in diagram (Service Tier: Standard S1)
  replica_count       = 1          # Provided in diagram (Replicas: 1)
  partition_count     = 1          # Provided in diagram (Partitions: 1)

  tags = {
    Environment = var.environment
    Owner       = var.owner
  }
}
