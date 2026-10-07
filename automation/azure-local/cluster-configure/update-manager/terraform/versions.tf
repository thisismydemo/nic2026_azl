# cluster-configure/update-manager — Terraform track (parity with bicep/main.bicep). Backend only via -backend-config.
terraform {
  required_version = ">= 1.11.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.81.0, < 5.0.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {}
}
