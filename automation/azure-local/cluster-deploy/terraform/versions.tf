# NIC 2026 — Azure Local cluster deployment (cluster-deploy), Terraform track (parity with bicep/main.bicep; contract §6).
# Backend: ONLY via `terraform init -backend-config=<file from environment/>` (contract §3); nothing committed.
# Why azapi and not Azure/avm-res-azurestackhci-cluster (2.0.2): that module requires domain_fqdn / adou_path and a
# deployment user + service principal (Active Directory path), has no identity_provider / dns_zones input and no
# Validate|Deploy selector; it can also create its own Key Vault and witness account, which conflicts with the two-vault
# design (LZ-05). The same Microsoft.AzureStackHCI resource types as the Bicep track are therefore driven with azapi.
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
  tenant_id                       = var.tenant_id
  storage_use_azuread             = true
  resource_provider_registrations = "none" # registration is a landing-zone script (design §2.2)
  features {}
}

provider "azapi" {
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
