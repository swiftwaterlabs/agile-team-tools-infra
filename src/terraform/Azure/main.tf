terraform {
  required_version = ">=1.0"

  required_providers {
    azurerm = {
      version = "=2.91.0"
      source  = "hashicorp/azurerm"
    }
    azuread = {
      version = "=2.8.0"
      source  = "hashicorp/azuread"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  use_msi         = var.use_msi_to_authenticate
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
  environment     = var.azure_environment
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azuread_client_config" "current" {

}

locals {
  primary_region                = var.regions[0]
  api_base_url                  = "${var.service_name}-api-${var.environment}.${local.functions_baseurl}"
  executing_serviceprincipal_id = data.azuread_client_config.current.object_id
  resource_group_name           = coalesce(var.resource_group_name, "${var.service_name}-${var.environment}")
}

locals {
  function_os_type  = "linux"
  function_version  = "~4"
  function_runtime  = "dotnet"
  functions_baseurl = var.azure_environment == "usgovernment" ? "azurewebsites.us" : "azurewebsites.net"
}

# Foundation
resource "azurerm_resource_group" "service_resource_group" {
  name     = local.resource_group_name
  location = local.primary_region
}

# Identities
resource "azurerm_user_assigned_identity" "signalr_managed_identity" {
  name                = "${var.service_name}-signalr-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
}

# Storage
resource "azurerm_storage_account" "storage_account" {
  name                     = "${var.service_name}${var.environment}"
  resource_group_name      = azurerm_resource_group.service_resource_group.name
  location                 = azurerm_resource_group.service_resource_group.location
  account_tier             = "Standard"
  account_replication_type = "GRS"
}

# WebUI
resource "azurerm_storage_account" "static_site" {
  name                      = "${var.service_name}web${var.environment}"
  resource_group_name       = azurerm_resource_group.service_resource_group.name
  location                  = azurerm_resource_group.service_resource_group.location
  account_kind              = "StorageV2"
  account_tier              = "Standard"
  account_replication_type  = "RAGRS"
  enable_https_traffic_only = true
  min_tls_version           = "TLS1_2"
  static_website {
    index_document     = "index.html"
    error_404_document = "index.html"
  }
}

# SignalR
resource "azurerm_signalr_service" "signalr_service" {
  name                     = "${var.service_name}${var.environment}"
  resource_group_name      = azurerm_resource_group.service_resource_group.name
  location                 = azurerm_resource_group.service_resource_group.location

  sku {
    name     = "Free_F1"
    capacity = 1
  }

  cors {
    allowed_origins = [local.api_base_url]
  }

  service_mode              = "Serverless"
}


# Logging
resource "azurerm_log_analytics_workspace" "loganalytics" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  sku                 = "PerGB2018"
}

resource "azurerm_application_insights" "appinsights" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  workspace_id        = azurerm_log_analytics_workspace.loganalytics.id
  application_type    = "web"
}

# Azure Function
resource "azurerm_app_service_plan" "function_serviceplan" {
  name                = "${var.service_name}-${var.environment}"
  resource_group_name = azurerm_resource_group.service_resource_group.name
  location            = azurerm_resource_group.service_resource_group.location
  kind                = "FunctionApp"
  reserved            = local.function_os_type == "linux" ? true : false # Linux requires a reserved plan
  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

resource "azurerm_function_app" "function_api" {
  name                       = "${var.service_name}-api-${var.environment}"
  resource_group_name        = azurerm_resource_group.service_resource_group.name
  location                   = azurerm_resource_group.service_resource_group.location
  app_service_plan_id        = azurerm_app_service_plan.function_serviceplan.id
  storage_account_name       = azurerm_storage_account.storage_account.name
  storage_account_access_key = azurerm_storage_account.storage_account.primary_access_key
  version                    = local.function_version
  https_only                 = true
  os_type                    = local.function_os_type
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.signalr_api_managed_identity.id]
  }

 site_config {
    http2_enabled   = true
    ftps_state      = "FtpsOnly"
    min_tls_version = "1.2"

    cors {
      allowed_origins     = [azurerm_storage_account.static_site.primary_web_endpoint]
      support_credentials = true
    }
  }

  app_settings = {
    "APPINSIGHTS_INSTRUMENTATIONKEY"        = azurerm_application_insights.appinsights.instrumentation_key
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.appinsights.connection_string
    "WEBSITE_RUN_FROM_PACKAGE"              = "1"
    "ASPNETCORE_ENVIRONMENT"                = "Release"
    "FUNCTIONS_EXTENSION_VERSION"           = local.function_version
    "FUNCTIONS_WORKER_RUNTIME"              = local.function_runtime
    "AzureSignalRConnectionString"          = azurerm_signalr_service.signalr_service.primary_connection_string

  }
}