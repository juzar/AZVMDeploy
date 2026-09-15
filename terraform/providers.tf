terraform {
  required_version = ">= 1.5.0"

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-azvmdeploy"
    storage_account_name = "sttfstateazvmdeploy"
    container_name       = "tfstate"
    key                  = "azvmdeploy.dev.tfstate"
    # access_key provided via ARM_ACCESS_KEY env var in CI
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
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
