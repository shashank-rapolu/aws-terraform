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

# Reference the existing resource group
data "azurerm_resource_group" "rg" {
  name = "Project-IAAC-PoC-RG"
}

# Random suffix for Key Vault to avoid soft-delete conflicts
resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Random suffix for Document Intelligence subdomain
resource "random_string" "doc_intel_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Variables for configurable values
variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "PoC"
}

variable "owner" {
  description = "Owner tag"
  type        = string
  default     = "IAAC-Team"
}

variable "function_app_python_version" {
  description = "Python version for Function App (must be 3.7, 3.8, or 3.9 for AzureRM ~> 3.0.2)"
  type        = string
  default     = "3.9" # Version 3.11 from diagram is not supported in AzureRM ~> 3.0.2
}

# 1. Blob Storage Account
resource "azurerm_storage_account" "blob_storage" {
  name                     = "blobstorageiaacpoc" # Assumed name, must be globally unique
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard" # As specified in diagram
  account_replication_type = "GRS"      # As specified in diagram (GRS HA-GRS)
  account_kind             = "StorageV2"

  # Private endpoint access as specified in diagram
  # Note: public_network_access_enabled is not supported in AzureRM ~> 3.0.2

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_storage_container" "uploads" {
  name                  = "uploads" # Assumed name for document uploads
  storage_account_name  = azurerm_storage_account.blob_storage.name
  container_access_type = "private"
}

# 2. Data Lake Storage Gen2
resource "azurerm_storage_account" "data_lake" {
  name                     = "datalakeiaacpoc" # Assumed name, must be globally unique
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Premium" # As specified in diagram
  account_replication_type = "LRS"     # Assumed, Standard (S0) in diagram
  account_kind             = "BlockBlobStorage" # Premium tier requires BlockBlobStorage
  is_hns_enabled           = true      # Required for Data Lake Gen2

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_storage_data_lake_gen2_filesystem" "raw" {
  name               = "raw" # As specified in diagram
  storage_account_id = azurerm_storage_account.data_lake.id
}

resource "azurerm_storage_data_lake_gen2_filesystem" "refined" {
  name               = "refined" # As specified in diagram
  storage_account_id = azurerm_storage_account.data_lake.id
}

# 3. Document Intelligence (Form Recognizer)
resource "azurerm_cognitive_account" "document_intelligence" {
  name                = "azurerm-document-intelligence-${random_string.doc_intel_suffix.result}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  kind                = "FormRecognizer"
  sku_name            = "S0" # Standard (S0) as specified in diagram

  # Custom subdomain is required for token-based authentication
  custom_subdomain_name = "docintel-${random_string.doc_intel_suffix.result}"

  # Network access configuration
  network_acls {
    default_action = "Allow"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    model       = "prebuilt-document"
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# 3. Key Vault
resource "azurerm_key_vault" "main" {
  name                        = "kv-iaac-${random_string.kv_suffix.result}" # Unique name to avoid soft-delete conflicts
  resource_group_name         = data.azurerm_resource_group.rg.name
  location                    = data.azurerm_resource_group.rg.location
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard" # As specified in diagram
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false

  # Network ACLs to avoid firewall errors
  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

data "azurerm_client_config" "current" {}

# Access policy for current user/service principal
resource "azurerm_key_vault_access_policy" "terraform" {
  key_vault_id = azurerm_key_vault.main.id
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
# Create secrets manually via Azure Portal or CLI after deployment:
# - conn-str: Connection strings
# - api-keys: API keys as specified in diagram

# 4. Service Bus Namespace
resource "azurerm_servicebus_namespace" "main" {
  name                = "azurerm-servicebus-namespace" # Assumed name
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "Standard" # As specified in diagram

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# Service Bus Topic for doc-ingest/processing
resource "azurerm_servicebus_topic" "processing" {
  name         = "indexing-requests" # As specified in diagram
  namespace_id = azurerm_servicebus_namespace.main.id

  max_size_in_megabytes = 1024 # MaxSize: 1 GB as specified in diagram
}

resource "azurerm_servicebus_subscription" "processing_sub" {
  name               = "doc-processing-subscription" # Assumed name
  topic_id           = azurerm_servicebus_topic.processing.id
  max_delivery_count = 10
}

# 6. Application Gateway
resource "azurerm_public_ip" "appgw" {
  name                = "appgw-public-ip"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_virtual_network" "appgw_vnet" {
  name                = "appgw-vnet"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "appgw-subnet"
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.appgw_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_application_gateway" "main" {
  name                = "azurerm-application-gateway" # As specified in diagram
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location

  sku {
    name     = "WAF_v2" # SKU: WAF_v2 as specified in diagram
    tier     = "WAF_v2"
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
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  backend_address_pool {
    name = "function-app-backend-pool" # Assumed backend for Function App
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http" # Using HTTP since SSL certificates cannot be provisioned automatically
    request_timeout       = 60
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "appgw-frontend-ip"
    frontend_port_name             = "http-port"
    protocol                       = "Http" # Using HTTP listener (TLS 1.2 specified in diagram requires manual SSL certificate setup)
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "function-app-backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }

  # SSL Policy for secure communication (required to avoid deprecated TLS versions)
  ssl_policy {
    policy_type = "Predefined"
    policy_name = "AppGwSslPolicy20220101"
  }

  # WAF Configuration (WAF Mode: Prevention as specified in diagram)
  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention" # As specified in diagram
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  # NOTE: HTTPS listener with TLS 1.2 requires SSL certificate.
  # SSL certificates must be configured manually via Azure Portal or CLI.
  # Update the listener to use protocol = "Https" and add ssl_certificate block after manual setup.

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# 7. Function App (Linux Python)
# Storage account for Function App
resource "azurerm_storage_account" "function_storage" {
  name                     = "funcstorageiaacpoc" # Assumed name, must be globally unique
  resource_group_name      = data.azurerm_resource_group.rg.name
  location                 = data.azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# App Service Plan for Function App (Consumption Plan Y1)
resource "azurerm_service_plan" "function_plan" {
  name                = "function-app-plan"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "Y1" # Consumption plan as specified in diagram

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# Linux Function App
resource "azurerm_linux_function_app" "main" {
  name                       = "azurerm-linux-function-app" # As specified in diagram
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = data.azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.function_plan.id
  storage_account_name       = azurerm_storage_account.function_storage.name
  storage_account_access_key = azurerm_storage_account.function_storage.primary_access_key

  site_config {
    application_stack {
      python_version = var.function_app_python_version # Using 3.9 instead of 3.11 (not supported in AzureRM ~> 3.0.2)
    }
  }

  # App Settings for integrations
  # NOTE: Do NOT set FUNCTIONS_WORKER_RUNTIME, AzureWebJobsStorage, or FUNCTIONS_EXTENSION_VERSION
  # These are automatically set by Azure when application_stack and storage account are configured
  app_settings = {
    "KEY_VAULT_URL"              = azurerm_key_vault.main.vault_uri
    "DOCUMENT_INTELLIGENCE_ENDPOINT" = azurerm_cognitive_account.document_intelligence.endpoint
    "SERVICE_BUS_CONNECTION"     = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.main.vault_uri}secrets/conn-str/)" # Reference Key Vault secret (to be created manually)
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.main.instrumentation_key
  }

  tags = {
    environment      = var.environment
    owner            = var.owner
    plan             = "Basic Logs Tier"
    costcenter       = "R&D"
    resourcegroup    = "Project-Functions-RG" # As specified in diagram
    runtime          = "Python"
    runtime_version  = var.function_app_python_version
    timeout          = "5 min"
  }
}

# 10. Monitor (Log Analytics Workspace + Application Insights)
resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-analytics-iaac-poc"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30 # Assumed retention period

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

resource "azurerm_application_insights" "main" {
  name                = "azurerm-monitor" # As specified in diagram
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
  }
}

# 9. AI Search (Cognitive Search)
resource "azurerm_search_service" "main" {
  name                = "azurerm-search-service" # As specified in diagram
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "standard" # Standard (S1) as specified in diagram
  replica_count       = 1          # As specified in diagram
  partition_count     = 1          # As specified in diagram

  tags = {
    environment = var.environment
    owner       = var.owner
    plan        = "Basic Logs Tier"
    costcenter  = "R&D"
    tier        = "Standard (S1)"
    analyzer    = "en.microsoft"
  }
}

# NOTE: Cosmos DB is mentioned in the diagram but excluded per instructions (only specific resources to be created)
# NOTE: VNet Integration is mentioned but requires manual setup for Application Gateway WAF and private endpoints
# NOTE: Action Groups for alerts need to be configured manually via Azure Portal
