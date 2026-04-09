# Terraform configuration for Azure infrastructure
# Based on the provided diagram for Project-IAAC-PoC-RG

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
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

# Variables for configurable values
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "PoC" # From Tags section in diagram
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "IAAC-Team" # From Tags section in diagram
}

variable "cost_center" {
  description = "Cost Center tag"
  type        = string
  default     = "R&D" # From Tags section in diagram
}

variable "function_app_python_version" {
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2)"
  type        = string
  default     = "3.9" # Diagram shows 3.11 but not supported in this provider version
}

variable "function_app_timeout" {
  description = "Function app timeout in minutes"
  type        = number
  default     = 5 # From diagram
}

# Random suffix for unique Key Vault name
resource "random_string" "kv_suffix" {
  length  = 8
  special = false
  upper   = false
}

# 1. Blob Storage Account
resource "azurerm_storage_account" "blob_storage" {
  name                     = "projectiaacblobstorage" # Must be globally unique, lowercase, no hyphens
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # From diagram
  account_replication_type = "GRS"      # From diagram: RA-GRS (Geo-redundant)
  
  # Access: Private Endpoint (from diagram)
  # Note: Private endpoint configuration must be done manually or in separate config

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Storage containers for uploads and processed files
resource "azurerm_storage_container" "uploads" {
  name                  = "uploads" # From diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "processed" {
  name                  = "processed" # From diagram
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private"
}

# 2. Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = "kv-iaac-${random_string.kv_suffix.result}" # Unique name to avoid soft-delete conflicts
  location                    = data.azurerm_resource_group.rg.location
  resource_group_name         = data.azurerm_resource_group.rg.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard" # From diagram: SKU Standard
  soft_delete_retention_days  = 7          # Minimum retention for testing
  purge_protection_enabled    = false      # Allow Terraform to clean up

  # Network ACLs to avoid firewall issues
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

# Data source for current client configuration
data "azurerm_client_config" "current" {}

# Access policy for current user/service principal
resource "azurerm_key_vault_access_policy" "terraform_policy" {
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
}

# NOTE: Do NOT create Key Vault secrets in Terraform due to firewall propagation delays.
# After deployment, manually create the following secrets via Azure Portal or CLI:
# - conn-str (connection strings)
# - API keys
# Wait 5-10 minutes after Key Vault creation before adding secrets.

# 3. Service Bus Namespace
resource "azurerm_servicebus_namespace" "sb" {
  name                = "sb-iaac-poc-namespace"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard" # From diagram
  capacity            = 0          # Not applicable for Standard SKU

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Service Bus Queue: doc-ingest
resource "azurerm_servicebus_queue" "doc_ingest" {
  name         = "doc-ingest" # From diagram
  namespace_id = azurerm_servicebus_namespace.sb.id
  
  max_size_in_megabytes = 1024 # From diagram: MaxSize 1 GB

  enable_partitioning = false
}

# Service Bus Queue: processing
resource "azurerm_servicebus_queue" "processing" {
  name         = "processing" # From diagram
  namespace_id = azurerm_servicebus_namespace.sb.id
  
  max_size_in_megabytes = 1024 # From diagram: MaxSize 1 GB

  enable_partitioning = false
}

# Service Bus Topic: indexing-requests
resource "azurerm_servicebus_topic" "indexing_requests" {
  name         = "indexing-requests" # From diagram
  namespace_id = azurerm_servicebus_namespace.sb.id
  
  max_size_in_megabytes = 1024 # From diagram: MaxSize 1 GB

  enable_partitioning = false
}

# 9. Document Intelligence (Form Recognizer)
resource "random_string" "doc_intel_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_cognitive_account" "doc_intelligence" {
  name                = "doc-intel-${random_string.doc_intel_suffix.result}"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "FormRecognizer" # Document Intelligence service
  sku_name            = "S0"             # From diagram: SKU Standard (S0)
  
  custom_subdomain_name = "doc-intel-${random_string.doc_intel_suffix.result}" # Required for token auth

  # Network ACLs to avoid access issues
  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
    model_id    = "prebuilt-document" # From diagram
    api_version = "latest"            # From diagram
    plan        = "F0"                # From diagram: Free Tier
  }
}

# Storage account for Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "funciaacpocstorage" # Must be globally unique
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
  name                = "plan-iaac-func"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "Y1" # From diagram: Plan Y1 (Consumption)

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# 7. AI Search Service
resource "azurerm_search_service" "ai_search" {
  name                = "search-iaac-poc"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "standard" # From diagram: Service Tier Standard (S1)
  
  replica_count       = 1 # From diagram: Replicas 1
  partition_count     = 1 # From diagram: Partitions 1

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
    analyzer    = "en.microsoft" # From diagram
  }
}

# Monitor: Log Analytics Workspace
resource "azurerm_log_analytics_workspace" "log_analytics" {
  name                = "log-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "PerGB2018" # Standard pricing tier
  retention_in_days   = 30          # From diagram: Basic Logs Tier

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Monitor: Application Insights
resource "azurerm_application_insights" "app_insights" {
  name                = "appi-iaac-poc"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.log_analytics.id
  application_type    = "web" # Standard application type

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Function App (Linux)
resource "azurerm_linux_function_app" "function_app" {
  name                       = "func-iaac-poc-app"
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key
  
  site_config {
    application_stack {
      python_version = var.function_app_python_version # Diagram shows 3.11 but using 3.9 for compatibility
    }
    
    # From diagram: Timeout 5 min
    application_insights_connection_string = azurerm_application_insights.app_insights.connection_string
    application_insights_key               = azurerm_application_insights.app_insights.instrumentation_key
  }

  # App settings - DO NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  # Azure sets these automatically based on application_stack and storage account configuration
  app_settings = {
    # Key Vault reference for secrets (manual configuration needed)
    "KeyVaultUri" = azurerm_key_vault.kv.vault_uri
    
    # Storage account connection
    "BlobStorageConnection" = azurerm_storage_account.blob_storage.primary_connection_string
    
    # Service Bus connection
    "ServiceBusConnection" = azurerm_servicebus_namespace.sb.default_primary_connection_string
    
    # Document Intelligence endpoint and key
    "DocumentIntelligenceEndpoint" = azurerm_cognitive_account.doc_intelligence.endpoint
    "DocumentIntelligenceKey"      = azurerm_cognitive_account.doc_intelligence.primary_access_key
    
    # AI Search endpoint and key
    "SearchServiceEndpoint" = "https://${azurerm_search_service.ai_search.name}.search.windows.net"
    "SearchServiceKey"      = azurerm_search_service.ai_search.primary_key
    
    # Timeout configuration (from diagram: 5 minutes)
    "functionTimeout" = "00:0${var.function_app_timeout}:00"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# 4. Application Gateway
# Note: Using HTTP (port 80) since SSL certificates cannot be provisioned automatically

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-appgw-iaac"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Virtual Network for Application Gateway
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-iaac-poc"
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
  name                 = "snet-appgw"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-iaac-poc"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  sku {
    name     = "WAF_v2" # From diagram: SKU WAF_v2
    tier     = "WAF_v2"
    capacity = 2 # Minimum for WAF_v2
  }

  gateway_ip_configuration {
    name      = "appgw-ip-config"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_port {
    name = "http-port"
    port = 80 # Using HTTP since SSL certificate not available
  }

  frontend_ip_configuration {
    name                 = "appgw-frontend-ip"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  backend_address_pool {
    name = "func-backend-pool"
    # Function App backend - configure manually or use FQDN
    fqdns = ["${azurerm_linux_function_app.function_app.name}.azurewebsites.net"]
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80 # Using HTTP
    protocol              = "Http"
    request_timeout       = 60
    
    # Pick host name from backend address
    pick_host_name_from_backend_address = true
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http" # Using HTTP - for HTTPS, SSL certificate must be configured manually
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "func-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }

  # SSL Policy (required even for HTTP to avoid deprecated defaults)
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # WAF Configuration (from diagram: WAF Mode Prevention)
  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention" # From diagram
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  # Note: For HTTPS (TLS 1.2) listener as shown in diagram, SSL certificate must be added manually
  # Use Azure Portal or CLI to upload certificate and configure HTTPS listener

  tags = {
    environment = var.environment
    owner       = var.owner
    CostCenter  = var.cost_center
  }
}

# Note: Private endpoints for Storage and Cosmos DB must be configured manually
# Managed Identity assignments should be configured as needed for security
