# cluster-configure/platform — Terraform track (parity with bicep/main.bicep). Backend only via -backend-config (contract §3).
terraform {
  required_version = ">= 1.11.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.81.0, < 5.0.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.12"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
}
