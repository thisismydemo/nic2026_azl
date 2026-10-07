# Stage S7 Management (design §3, §10.2 S7; management-plane MP-01..MP-04): the private-only jump server.
# Design §10.3 lists no confirmed AVM Terraform module for the jump server, so this is azurerm (NIC) + azapi (VM, extensions).
# azapi is used for the VM on purpose: its `sensitive_body` is WRITE-ONLY, so the local-admin password supplied in memory
# by Invoke-LzAzureLocalDeploy.ps1 (ephemeral var.jump_admin_password) never lands in plan or state - the azurerm VM
# resource has no write-only password argument in the pinned provider line.

resource "azurerm_network_interface" "jump" {
  count = local.s7 ? 1 : 0

  name                           = var.names.nic_jump
  location                       = var.location
  resource_group_name            = var.names.rg_mgmt
  accelerated_networking_enabled = true
  tags                           = local.tags

  ip_configuration {
    name                          = "ipconfig01"
    subnet_id                     = local.subnet_id.jump
    private_ip_address_allocation = var.jump_private_ip == "" ? "Dynamic" : "Static"
    private_ip_address            = var.jump_private_ip == "" ? null : var.jump_private_ip
    # no public IP: private-only by design (MP-04)
  }
  depends_on = [azurerm_resource_group.this, module.vnet]
}

resource "azapi_resource" "jump_vm" {
  count = local.s7 ? 1 : 0

  type      = "Microsoft.Compute/virtualMachines@2024-07-01"
  name      = var.names.vm_jump
  location  = var.location
  parent_id = local.rg_id.rg_mgmt
  tags      = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    properties = {
      hardwareProfile = { vmSize = var.jump_vm_size }
      osProfile = {
        computerName = var.names.vm_jump_computer_name
        # adminUsername / adminPassword: ephemeral inputs, merged in through sensitive_body (write-only) below
        windowsConfiguration = {
          provisionVMAgent       = true
          enableAutomaticUpdates = true
          patchSettings = {
            patchMode         = "AutomaticByPlatform"
            assessmentMode    = "AutomaticByPlatform"
            enableHotpatching = true
          }
        }
      }
      storageProfile = {
        imageReference = {
          publisher = "MicrosoftWindowsServer"
          offer     = "WindowsServer"
          sku       = "2025-datacenter-azure-edition"
          version   = "latest"
        }
        osDisk = {
          name         = var.names.osdisk_jump
          createOption = "FromImage"
          deleteOption = "Delete"
          caching      = "ReadWrite"
          diskSizeGB   = 128
          managedDisk  = { storageAccountType = "Premium_LRS" }
        }
        dataDisks = [{
          name         = var.names.datadisk_jump
          lun          = 0
          createOption = "Empty"
          deleteOption = "Delete"
          caching      = "None"
          diskSizeGB   = var.jump_data_disk_gb
          managedDisk  = { storageAccountType = "Premium_LRS" }
        }]
      }
      networkProfile = {
        networkInterfaces = [{ id = azurerm_network_interface.jump[0].id, properties = { deleteOption = "Delete", primary = true } }]
      }
      securityProfile = {
        securityType     = "TrustedLaunch"
        uefiSettings     = { secureBootEnabled = true, vTpmEnabled = true }
        encryptionAtHost = var.jump_encryption_at_host
      }
      diagnosticsProfile = { bootDiagnostics = { enabled = true } }
    }
  }

  # Write-only: merged into the request body, never stored in state or shown in plan.
  sensitive_body = {
    properties = {
      osProfile = {
        adminUsername = var.jump_admin_username
        adminPassword = var.jump_admin_password
      }
    }
  }

  ignore_missing_property = true
  response_export_values  = ["identity.principalId"]
}

# Entra login (MP-03) and Azure Monitor Agent; DCR association is Day-2 Ready.
resource "azurerm_virtual_machine_extension" "aad_login" {
  count = local.s7 ? 1 : 0

  name                       = "AADLoginForWindows"
  virtual_machine_id         = azapi_resource.jump_vm[0].id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADLoginForWindows"
  type_handler_version       = "2.0"
  auto_upgrade_minor_version = true
  tags                       = local.tags
}

resource "azurerm_virtual_machine_extension" "ama" {
  count = local.s7 ? 1 : 0

  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azapi_resource.jump_vm[0].id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
  tags                       = local.tags
  depends_on                 = [azurerm_virtual_machine_extension.aad_login]
}
