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

  # Values supplied at init time (see README step 3 / the infra workflow):
  #   terraform init -backend-config="resource_group_name=..." \
  #                  -backend-config="storage_account_name=..."
  backend "azurerm" {
    container_name   = "tfstate"
    key              = "churn-dev.tfstate"
    use_azuread_auth = true # state access via Entra ID / managed identity, no keys
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
  subscription_id = var.subscription_id
  # In CI these come from env vars: ARM_USE_OIDC=true, ARM_CLIENT_ID, ARM_TENANT_ID
}
