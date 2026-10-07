// Stage S7 Management (design §3, §10.2 S7): the private-only jump server vm-<org>-<token>-jump-<region>-01
// (computer name from the catalog, NetBIOS <= 15), Windows Server 2025 Datacenter: Azure Edition, Trusted launch,
// no public IP (reached through the existing Bastion or P2S), Entra login (AADLoginForWindows) and Azure Monitor Agent.
// The local administrator credential arrives as @secure() parameters supplied IN MEMORY by Invoke-LzAzureLocalDeploy.ps1,
// which generates the password and writes it to the ops vault; Bicep never generates, reads or outputs it.
// AVM: compute/virtual-machine 0.22.3.
targetScope = 'resourceGroup'

param names object
param location string
param tags object
param jump_subnet_id string
param jump_vm_size string
param jump_data_disk_gb int
param jump_private_ip string
param jump_encryption_at_host bool
@secure()
param jump_admin_username string
@secure()
param jump_admin_password string

module vm 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: 'vm-jump'
  params: {
    name: names.vm_jump
    computerName: names.vm_jump_computer_name
    location: location
    tags: tags
    osType: 'Windows'
    vmSize: jump_vm_size
    availabilityZone: -1
    adminUsername: jump_admin_username
    adminPassword: jump_admin_password
    imageReference: {
      publisher: 'MicrosoftWindowsServer'
      offer: 'WindowsServer'
      sku: '2025-datacenter-azure-edition'
      version: 'latest'
    }
    osDisk: {
      name: names.osdisk_jump
      createOption: 'FromImage'
      deleteOption: 'Delete'
      caching: 'ReadWrite'
      diskSizeGB: 128
      managedDisk: { storageAccountType: 'Premium_LRS' }
    }
    // MP-02: 256 GiB Premium SSD data disk (repos, ISOs, Packer output, WSL2 VHDX); host caching off.
    dataDisks: [
      {
        name: names.datadisk_jump
        lun: 0
        diskSizeGB: jump_data_disk_gb
        createOption: 'Empty'
        caching: 'None'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    ]
    nicConfigurations: [
      {
        name: names.nic_jump
        deleteOption: 'Delete'
        enableAcceleratedNetworking: true
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: jump_subnet_id
            privateIPAllocationMethod: empty(jump_private_ip) ? 'Dynamic' : 'Static'
            privateIPAddress: empty(jump_private_ip) ? null : jump_private_ip
            // no pipConfiguration: private-only by design
          }
        ]
      }
    ]
    managedIdentities: { systemAssigned: true }
    securityType: 'TrustedLaunch'
    secureBootEnabled: true
    vTpmEnabled: true
    encryptionAtHost: jump_encryption_at_host // MP-02 wants it on; needs Microsoft.Compute/EncryptionAtHost (Register-LzProviders.ps1)
    bootDiagnostics: true
    patchMode: 'AutomaticByPlatform'
    enableAutomaticUpdates: true
    enableHotpatching: true
    extensionAadJoinConfig: { enabled: true }
    extensionMonitoringAgentConfig: { enabled: true, dataCollectionRuleAssociations: [] }
  }
}

output vmId string = vm.outputs.resourceId
output vmPrincipalId string = vm.outputs.?systemAssignedMIPrincipalId ?? ''
