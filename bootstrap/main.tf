###############################################################################
# BOOTSTRAP — run ONCE, locally, as a human with Owner on the subscription.
#
# Creates:
#   1. A storage account for Terraform remote state (Entra ID auth, no keys)
#   2. The workload resource group
#   3. A USER-ASSIGNED MANAGED IDENTITY that the CI/CD pipeline logs in as,
#      via a federated credential (OIDC) — no client secret exists anywhere.
#   4. Least-privilege role assignments for that identity
###############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true # data-plane calls use Entra ID, not storage keys
}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "eastus2"
}
variable "prefix" {
  type    = string
  default = "churn"
}
variable "github_repo" {
  type        = string
  description = "owner/repo, e.g. yahya/azure-mlops-churn"
}
variable "github_environment" {
  type    = string
  default = "dev"
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

# --- Terraform state ---------------------------------------------------------
resource "azurerm_resource_group" "tfstate" {
  name     = "rg-${var.prefix}-tfstate"
  location = var.location
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${var.prefix}tf${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = var.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false # keys disabled: Entra ID only
  allow_nested_items_to_be_public = false

  blob_properties {
    versioning_enabled = true # lets you recover a corrupted state file
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# --- Workload resource group -------------------------------------------------
resource "azurerm_resource_group" "workload" {
  name     = "rg-${var.prefix}-dev"
  location = var.location
}

# --- Pipeline identity (managed identity + OIDC federation) ------------------
resource "azurerm_user_assigned_identity" "pipeline" {
  name                = "id-${var.prefix}-github"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = var.location
}

# GitHub Actions jobs that target the "dev" environment can exchange their
# OIDC token for an Entra ID token for this identity. Nothing else can.
resource "azurerm_federated_identity_credential" "github_env" {
  name                = "github-${var.github_environment}"
  resource_group_name = azurerm_resource_group.tfstate.name
  parent_id           = azurerm_user_assigned_identity.pipeline.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repo}:environment:${var.github_environment}"
}

# Pull-request plans run without an environment, so they get their own subject.
resource "azurerm_federated_identity_credential" "github_pr" {
  name                = "github-pr"
  resource_group_name = azurerm_resource_group.tfstate.name
  parent_id           = azurerm_user_assigned_identity.pipeline.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = "https://token.actions.githubusercontent.com"
  subject             = "repo:${var.github_repo}:pull_request"
}

# --- Least-privilege RBAC for the pipeline -----------------------------------
# Scoped to the workload RG only, never the whole subscription.
resource "azurerm_role_assignment" "pipeline_contributor" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.pipeline.principal_id
}

# Needed because the infra code creates role assignments + one custom role.
# In production, prefer "Role Based Access Control Administrator" with an ABAC
# condition limiting which roles it may assign.
resource "azurerm_role_assignment" "pipeline_uaa" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "User Access Administrator"
  principal_id         = azurerm_user_assigned_identity.pipeline.principal_id
}

resource "azurerm_role_assignment" "pipeline_state" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.pipeline.principal_id
}

# --- Outputs: copy these into GitHub repo variables --------------------------
data "azurerm_client_config" "current" {}

output "AZURE_CLIENT_ID" { value = azurerm_user_assigned_identity.pipeline.client_id }
output "AZURE_TENANT_ID" { value = data.azurerm_client_config.current.tenant_id }
output "AZURE_SUBSCRIPTION_ID" { value = var.subscription_id }
output "TFSTATE_RESOURCE_GROUP" { value = azurerm_resource_group.tfstate.name }
output "TFSTATE_STORAGE_ACCOUNT" { value = azurerm_storage_account.tfstate.name }
output "WORKLOAD_RESOURCE_GROUP" { value = azurerm_resource_group.workload.name }
