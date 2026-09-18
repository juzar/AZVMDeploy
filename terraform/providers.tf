terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-azvmdeploy"
    storage_account_name = "sttfstateazvmdeploy"
    container_name       = "tfstate"
    # key is provided via -backend-config at init time:
    #   terraform init -backend-config="key=azvmdeploy.${ENVIRONMENT}.tfstate"
    # This prevents all environments from writing to the same state file.
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.117"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
