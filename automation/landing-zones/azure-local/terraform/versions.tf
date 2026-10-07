# NIC 2026 — Azure Local landing zone, Terraform track (parity with bicep/main.bicep; contract §6).
# Backend: configured ONLY with `terraform init -backend-config=<file from environment/>` (contract §3); nothing committed.
# Terraform >= 1.11 is required for ephemeral variables and azapi `sensitive_body` (write-only jump-server password).
terraform {
  required_version = ">= 1.11.0"

  backend "azurerm" {}

  required_providers {
    # Pinned to the window the confirmed AVM modules accept (keyvault 0.11.0: >= 4.81 < 5.1; workspace 0.5.1: < 5.0).
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.81.0, < 5.0.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
