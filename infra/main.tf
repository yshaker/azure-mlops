###############################################################################
# Churn ML platform — core resources
#
#   Storage (data lake) ─┐
#   Key Vault ───────────┤
#   App Insights ────────┼──> Azure ML workspace ──> compute cluster
#   Container Registry ──┘         │
#                                  └──> managed online endpoint (created by
#                                       the MLOps pipeline, not Terraform)
#   APIM (system-assigned MI) ──> endpoint, using Entra ID tokens, no keys
###############################################################################

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  location = data.azurerm_resource_group.rg.location
  name     = "${var.prefix}-${random_string.suffix.result}"
  tags = {
    workload    = "churn-prediction"
    environment = "dev"
    managed_by  = "terraform"
  }
}

# --- Observability -----------------------------------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${local.name}"
  resource_group_name = var.resource_group_name
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_application_insights" "appi" {
  name                = "appi-${local.name}"
  resource_group_name = var.resource_group_name
  location            = local.location
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = local.tags
}

# --- Secrets (only where unavoidable) ----------------------------------------
resource "azurerm_key_vault" "kv" {
  name                          = "kv-${local.name}"
  resource_group_name           = var.resource_group_name
  location                      = local.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true # RBAC, not legacy access policies
  purge_protection_enabled      = false # true in production
  soft_delete_retention_days    = 7
  public_network_access_enabled = var.public_network_access
  tags                          = local.tags
}

# --- Data lake (ADLS Gen2) ---------------------------------------------------
resource "azurerm_storage_account" "lake" {
  name                            = "st${var.prefix}${random_string.suffix.result}"
  resource_group_name             = var.resource_group_name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  is_hns_enabled                  = true # hierarchical namespace = Data Lake Gen2
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = var.public_network_access
  # Shared keys left ON so the AML default datastores work out of the box.
  # Hardening (README step 11): switch datastores to identity-based access,
  # then set shared_access_key_enabled = false.
  tags = local.tags
}

# --- Container registry (holds inference/training images) --------------------
resource "azurerm_container_registry" "acr" {
  name                          = "acr${var.prefix}${random_string.suffix.result}"
  resource_group_name           = var.resource_group_name
  location                      = local.location
  sku                           = "Standard" # Premium needed for private endpoints
  admin_enabled                 = false      # no admin user/password — RBAC only
  public_network_access_enabled = true
  tags                          = local.tags
}

# --- Azure Machine Learning workspace ----------------------------------------
resource "azurerm_machine_learning_workspace" "mlw" {
  name                          = "mlw-${local.name}"
  resource_group_name           = var.resource_group_name
  location                      = local.location
  application_insights_id       = azurerm_application_insights.appi.id
  key_vault_id                  = azurerm_key_vault.kv.id
  storage_account_id            = azurerm_storage_account.lake.id
  container_registry_id         = azurerm_container_registry.acr.id
  public_network_access_enabled = var.public_network_access

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# --- Compute cluster with its own user-assigned managed identity -------------
resource "azurerm_user_assigned_identity" "compute" {
  name                = "id-${local.name}-compute"
  resource_group_name = var.resource_group_name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_machine_learning_compute_cluster" "cpu" {
  name                          = "cpu-cluster"
  location                      = local.location
  machine_learning_workspace_id = azurerm_machine_learning_workspace.mlw.id
  vm_size                       = var.compute_vm_size
  vm_priority                   = "LowPriority" # cheap for training; Dedicated for SLAs

  scale_settings {
    min_node_count                       = 0 # scales to zero = no idle cost
    max_node_count                       = var.compute_max_nodes
    scale_down_nodes_after_idle_duration = "PT15M"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.compute.id]
  }

  tags = local.tags
}

# --- API Management (controlled entry point) ---------------------------------
resource "azurerm_api_management" "apim" {
  name                = "apim-${local.name}"
  resource_group_name = var.resource_group_name
  location            = local.location
  publisher_name      = "Churn ML Team"
  publisher_email     = var.apim_publisher_email
  sku_name            = var.apim_sku

  identity {
    type = "SystemAssigned" # used to get Entra ID tokens for the ML endpoint
  }

  tags = local.tags
}
