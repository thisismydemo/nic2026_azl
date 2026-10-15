#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
param()
# Pester 5 — cluster-configure/backup-asr gates via the shared kit, plus solution-specific behaviour.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-backup-asr' `
    -RequiredInputs 'asr_policy', 'backup_policy' `
    -EntryScripts 'Invoke-BackupAsrConfigure.ps1'

Describe 'backup-asr specifics' {
    BeforeAll {
        $script:root = Split-Path $PSScriptRoot -Parent
        $script:scripts = Join-Path $script:root 'scripts'
        $script:subscription = '00000000-0000-0000-0000-000000000000'
        $script:asrParameters = @{
            SubscriptionId          = $script:subscription
            VaultResourceGroup      = 'example-bcdr'
            VaultName               = 'example-vault'
            HyperVSiteName          = 'example-site'
            PolicyName              = 'example-asr-policy'
            VmName                  = @('example-vm', 'protected-vm')
            RecoveryResourceGroupId = '/subscriptions/example/resourceGroups/example-dr'
            RecoveryNetworkId       = '/subscriptions/example/virtualNetworks/example-recovery'
            RecoverySubnetName      = 'example-recovery-subnet'
            TestNetworkId           = '/subscriptions/example/virtualNetworks/example-test'
        }
        $script:failoverParameters = @{
            SubscriptionId     = $script:subscription
            VaultResourceGroup = 'example-bcdr'
            VaultName          = 'example-vault'
            HyperVSiteName     = 'example-site'
            VmName             = 'example-vm'
            TestNetworkId      = '/subscriptions/example/virtualNetworks/example-test'
        }
        $script:backupParameters = @{
            SubscriptionId     = $script:subscription
            VaultResourceGroup = 'example-bcdr'
            VaultName          = 'example-vault'
            PolicyName         = 'example-backup-policy'
            VmResourceGroup    = 'example-vm-rg'
            VmName             = @('example-vm', 'protected-vm')
        }
        $script:readinessParameters = @{
            SubscriptionId     = $script:subscription
            VaultResourceGroup = 'example-bcdr'
            VaultName          = 'example-vault'
            AsrPolicyName      = 'example-asr-policy'
            BackupPolicyName   = 'example-backup-policy'
            HyperVSiteName     = 'example-site'
            VmName             = @('example-vm')
            AzureVmName        = 'example-jump'
        }
        $global:BackupAsrJobState = 'Succeeded'
        $global:BackupAsrJobErrors = @()
        $global:BackupAsrReplicationHealth = 'Normal'
        $global:BackupAsrRecoveryPoints = @([pscustomobject]@{ RecoveryPointId = 'example-point' })
    }

    AfterAll {
        Remove-Variable BackupAsrEnabled, BackupAsrJobState, BackupAsrJobErrors, BackupAsrReplicationHealth, BackupAsrRecoveryPoints -Scope Global -ErrorAction SilentlyContinue
    }

    It 'declares an existing vault and only the two Bicep policy resources' {
        $source = Get-Content (Join-Path $script:root 'bicep/main.bicep') -Raw
        $source | Should -Match 'vaults/replicationPolicies@'
        $source | Should -Match 'vaults/backupPolicies@'
        $source | Should -Match "vaults@\d{4}-\d{2}-\d{2}' existing"
        $source | Should -Not -Match "vaults@\d{4}-\d{2}-\d{2}'\s*="
    }

    It 'uses Terraform policy resources and only a data source for the vault' {
        $source = Get-Content (Join-Path $script:root 'terraform/main.tf') -Raw
        $source | Should -Match 'resource "azapi_resource" "asr_policy"'
        $source | Should -Match 'resource "azurerm_backup_policy_vm"'
        $source | Should -Match 'data "azurerm_recovery_services_vault"'
        $source | Should -Not -Match 'resource "azurerm_recovery_services_vault"'
    }

    It 'does not script a live failover or name a backup-server product' {
        foreach ($file in @(Get-ChildItem $script:scripts -Filter '*.ps1')) {
            $source = Get-Content $file.FullName -Raw
            $source | Should -Not -Match 'Start-AzRecoveryServicesAsrPlannedFailoverJob|UnplannedFailover'
            $source | Should -Not -Match 'MABS|Backup Server'
        }
        $readme = Get-Content (Join-Path $script:root 'README.md') -Raw
        $readme | Should -Not -Match 'MABS|Backup Server'
    }

    Context 'replication enablement' {
        BeforeEach {
            Mock Set-AzContext {}
            Mock Get-AzRecoveryServicesVault { [pscustomobject]@{ ID = 'example-vault-id' } }
            Mock Set-AzRecoveryServicesAsrVaultContext {}
            Mock Get-AzRecoveryServicesAsrFabric { [pscustomobject]@{ Name = 'example-site' } }
            Mock Get-AzRecoveryServicesAsrProtectionContainer { [pscustomobject]@{ Name = 'example-container' } }
            Mock Get-AzRecoveryServicesAsrProtectionContainerMapping { [pscustomobject]@{ PolicyFriendlyName = 'example-asr-policy' } }
            Mock Get-AzRecoveryServicesAsrProtectableItem {
                # Azure Local names the Hyper-V VM '<resource name>-<guid>'
                [pscustomobject]@{ FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000'; OSDiskName = 'example-os-disk'; OS = 'Windows'; Disks = @() }
                [pscustomobject]@{ FriendlyName = 'protected-vm'; OSDiskName = 'example-os-disk'; OS = 'Windows'; Disks = @() }
            }
            $global:BackupAsrEnabled = $false
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem {
                [pscustomobject]@{ Name = 'protected-vm'; FriendlyName = 'protected-vm'; SelectedTfoAzureNetworkId = 'another-network' }
                if ($global:BackupAsrEnabled) { [pscustomobject]@{ Name = 'example-vm'; FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000'; SelectedTfoAzureNetworkId = $null } }
            }
            Mock New-AzRecoveryServicesAsrReplicationProtectedItem { $global:BackupAsrEnabled = $true } -RemoveParameterType 'ProtectableItem', 'ProtectionContainerMapping'
            Mock Set-AzRecoveryServicesAsrReplicationProtectedItem {} -RemoveParameterType 'InputObject'
        }

        It 'does not enable replication without Execute' {
            & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @script:asrParameters | Out-Null
            Should -Invoke New-AzRecoveryServicesAsrReplicationProtectedItem -Times 0 -Exactly
        }

        It 'uses HyperVToAzure for each unprotected VM and skips a protected VM' {
            & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @script:asrParameters -Execute | Out-Null
            Should -Invoke New-AzRecoveryServicesAsrReplicationProtectedItem -Times 1 -Exactly -ParameterFilter {
                $HyperVToAzure -and $Name -eq 'example-vm' -and $RecoveryVmName -eq 'example-vm' -and $OSDiskName -eq 'example-os-disk' -and $UseManagedDisk -eq 'true'
            }
            # the new VM and the already-replicating VM (reconciled: its test network differs) both get the test network
            Should -Invoke Set-AzRecoveryServicesAsrReplicationProtectedItem -Times 2 -Exactly -ParameterFilter {
                $TestNetworkId -eq '/subscriptions/example/virtualNetworks/example-test'
            }
        }

        It 'passes the cache account, size and tags, and sets the isolated test subnet on the primary NIC' {
            $global:BackupAsrEnabled = $false
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem {
                if ($global:BackupAsrEnabled) {
                    [pscustomobject]@{ Name = 'example-vm'; FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000'; SelectedTfoAzureNetworkId = $null; NicDetailsList = @([pscustomobject]@{ NicId = 'example-nic' }) }
                }
            }
            $parameters = $script:asrParameters.Clone()
            $parameters.VmName = @('example-vm')
            & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @parameters -TestSubnetName 'example-test-subnet' `
                -LogStorageAccountId '/subscriptions/example/storageAccounts/examplecache' -Size 'Standard_D2s_v5' -Tag @{ project = 'example' } -Execute | Out-Null
            Should -Invoke New-AzRecoveryServicesAsrReplicationProtectedItem -Times 1 -Exactly -ParameterFilter {
                $LogStorageAccountId -eq '/subscriptions/example/storageAccounts/examplecache' -and $RecoveryAzureStorageAccountId -eq $LogStorageAccountId -and $Size -eq 'Standard_D2s_v5' -and $RecoveryVmTag.project -eq 'example' -and $DiskTag.project -eq 'example'
            }
            Should -Invoke Set-AzRecoveryServicesAsrReplicationProtectedItem -Times 1 -Exactly -ParameterFilter {
                $UpdateNic -eq 'example-nic' -and $TestNicSubnetName -eq 'example-test-subnet' -and $RecoveryNicSubnetName -eq 'example-recovery-subnet'
            }
        }

        It 'takes the OS from -OS and the single OS disk when the item reports neither' {
            Mock Get-AzRecoveryServicesAsrProtectableItem {
                [pscustomobject]@{ FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000'; OSDiskName = ''; OS = ''; Disks = @([pscustomobject]@{ Name = 'example-vm-OSDisk' }) }
            }
            $parameters = $script:asrParameters.Clone()
            $parameters.VmName = @('example-vm')
            { & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @parameters -Execute } | Should -Throw '*-OS*'
            & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @parameters -OS Windows -Execute | Out-Null
            Should -Invoke New-AzRecoveryServicesAsrReplicationProtectedItem -Times 1 -Exactly -ParameterFilter { $OS -eq 'Windows' -and $OSDiskName -eq 'example-vm-OSDisk' }
        }

        It 'throws when the requested policy has no container mapping' {
            Mock Get-AzRecoveryServicesAsrProtectionContainerMapping { [pscustomobject]@{ PolicyFriendlyName = 'another-policy' } }
            { & (Join-Path $script:scripts 'Enable-AsrReplication.ps1') @script:asrParameters -Execute } | Should -Throw '*mapping*'
            Should -Invoke New-AzRecoveryServicesAsrReplicationProtectedItem -Times 0 -Exactly
        }
    }

    Context 'test failover' {
        BeforeEach {
            $global:BackupAsrJobState = 'Succeeded'
            $global:BackupAsrJobErrors = @()
            Mock Set-AzContext {}
            Mock Get-AzRecoveryServicesVault { [pscustomobject]@{ ID = 'example-vault-id' } }
            Mock Set-AzRecoveryServicesAsrVaultContext {}
            Mock Get-AzRecoveryServicesAsrFabric { [pscustomobject]@{ Name = 'example-site' } }
            Mock Get-AzRecoveryServicesAsrProtectionContainer { [pscustomobject]@{ Name = 'example-container' } }
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem { [pscustomobject]@{ Name = 'example-vm'; FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000' } }
            Mock Start-AzRecoveryServicesAsrTestFailoverJob { [pscustomobject]@{ Name = 'example-job' } }
            Mock Start-AzRecoveryServicesAsrTestFailoverCleanupJob { [pscustomobject]@{ Name = 'example-cleanup-job' } }
            Mock Get-AzRecoveryServicesAsrJob { [pscustomobject]@{ State = $global:BackupAsrJobState; Errors = $global:BackupAsrJobErrors } }
        }

        It 'starts nothing without Execute' {
            & (Join-Path $script:scripts 'Invoke-AsrTestFailover.ps1') @script:failoverParameters | Out-Null
            Should -Invoke Start-AzRecoveryServicesAsrTestFailoverJob -Times 0 -Exactly
            Should -Invoke Start-AzRecoveryServicesAsrTestFailoverCleanupJob -Times 0 -Exactly
        }

        It 'starts on the test network and waits for Succeeded' {
            & (Join-Path $script:scripts 'Invoke-AsrTestFailover.ps1') @script:failoverParameters -Execute | Out-Null
            Should -Invoke Start-AzRecoveryServicesAsrTestFailoverJob -Times 1 -Exactly -ParameterFilter {
                $Direction -eq 'PrimaryToRecovery' -and $AzureVMNetworkId -eq '/subscriptions/example/virtualNetworks/example-test'
            }
            Should -Invoke Get-AzRecoveryServicesAsrJob -Times 1 -Exactly
        }

        It 'reports only the job error summary on failure' {
            $global:BackupAsrJobState = 'Failed'
            $global:BackupAsrJobErrors = @([pscustomobject]@{ ErrorMessage = 'Example job error'; InternalDetail = 'Private internal detail' })
            $caught = $null
            try { & (Join-Path $script:scripts 'Invoke-AsrTestFailover.ps1') @script:failoverParameters -Execute } catch { $caught = $_.ToString() }
            $caught | Should -Match 'Example job error'
            $caught | Should -Not -Match 'Private internal detail'
        }

        It 'runs the test-failover cleanup job' {
            & (Join-Path $script:scripts 'Invoke-AsrTestFailover.ps1') @script:failoverParameters -Action Cleanup -Execute | Out-Null
            Should -Invoke Start-AzRecoveryServicesAsrTestFailoverCleanupJob -Times 1 -Exactly
        }

        It 'requires the test network for Start' {
            $parameters = $script:failoverParameters.Clone()
            $parameters.Remove('TestNetworkId')
            { & (Join-Path $script:scripts 'Invoke-AsrTestFailover.ps1') @parameters -Execute } | Should -Throw '*TestNetworkId*'
        }
    }

    Context 'scripted Prepare infrastructure' {
        It 'reads lab values from the environment only and installs the documented extension' {
            $source = Get-Content (Join-Path $script:scripts 'Install-AsrInfrastructure.ps1') -Raw
            $source | Should -Match "publisher = 'Microsoft.SiteRecovery.Dra'; type = 'Windows'"
            $source | Should -Match 'arcSettings/default/extensions'
            $source | Should -Match 'instanceType = ''HyperVSite'''
            $source | Should -Not -Match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            $source | Should -Not -Match 'Restart-Computer|Restart-Service|shutdown'
        }

        It 'changes nothing without Execute' {
            $envFile = Join-Path $TestDrive 'environment.yml'
            $sharedFile = Join-Path $TestDrive 'shared.yml'
            @"
subscription_id: 00000000-0000-0000-0000-000000000000
cluster_name: example-cluster
vm_management: { resource_group: example-rg }
nodes:
  - { name: example-node-01, management_ip: 192.0.2.11 }
asr:
  vault_resource_group: example-bcdr
  vault_name: example-vault
  hyperv_site_name: example-site
  replication_policy_name: example-policy
  cache_storage_account: examplecache
  recovery_resource_group: example-dr
  network_resource_group: example-net
  vnet_name: example-vnet
  recovery_subnet_name: example-recovery
  test_subnet_name: example-test
  protected_vms: [ { name: example-vm, target_vm_size: Standard_D2s_v5 } ]
"@ | Set-Content $envFile
            "tenant_id: 00000000-0000-0000-0000-000000000000`nlocation: example" | Set-Content $sharedFile
            Mock Set-AzContext {}
            Mock Get-AzRoleAssignment {}
            Mock New-AzRoleAssignment {}
            Mock Invoke-AzRestMethod {
                if ($Method -ne 'GET') { throw 'no write expected' }
                if ($Path -match 'clusters/example-cluster\?') { return [pscustomobject]@{ StatusCode = 200; Content = '{"identity":{"principalId":"example-principal"}}' } }
                if ($Path -match 'vaults/example-vault\?') { return [pscustomobject]@{ StatusCode = 200; Content = '{"identity":{"principalId":"example-vault-principal"}}' } }
                if ($Path -match 'machines/') { return [pscustomobject]@{ StatusCode = 200; Content = '{"identity":{"principalId":"example-principal"}}' } }
                if ($Path -match '(replicationFabrics|extendedInformation|extensions)/') { return [pscustomobject]@{ StatusCode = 404; Content = '' } }
                [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            }
            $out = & (Join-Path $script:scripts 'Install-AsrInfrastructure.ps1') -EnvironmentFile $envFile -SharedEnvironmentFile $sharedFile
            ($out -join "`n") | Should -Match 'PLAN install cluster extension'
            Should -Invoke Invoke-AzRestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
            Should -Invoke New-AzRoleAssignment -Times 0 -Exactly
        }
    }

    Context 'Azure VM backup' {
        BeforeEach {
            Mock Set-AzContext {}
            Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'other-subscription' }; Tenant = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }   # the CI runner has no Azure login
            Mock Get-AzRecoveryServicesVault { [pscustomobject]@{ ID = 'example-vault-id' } }
            Mock Get-AzRecoveryServicesBackupProtectionPolicy { [pscustomobject]@{ Name = 'example-backup-policy' } }
            Mock Get-AzRecoveryServicesBackupItem {
                if ($FriendlyName -eq 'protected-vm') { [pscustomobject]@{ Name = 'protected-vm' } }
                elseif ($FriendlyName -eq 'moved-vm' -and -not $Policy) { [pscustomobject]@{ Name = 'moved-vm' } }
            } -RemoveParameterType 'Policy'
            Mock Enable-AzRecoveryServicesBackupProtection {} -RemoveParameterType 'Policy', 'Item'
        }

        It 'makes no change without Execute' {
            & (Join-Path $script:scripts 'Enable-AzureVmBackup.ps1') @script:backupParameters | Out-Null
            Should -Invoke Enable-AzRecoveryServicesBackupProtection -Times 0 -Exactly
        }

        It 'skips a VM already on the policy and one on another policy unless -ReassignPolicy is given' {
            $parameters = $script:backupParameters.Clone()
            $parameters.VmName = @('protected-vm', 'moved-vm')
            & (Join-Path $script:scripts 'Enable-AzureVmBackup.ps1') @parameters -Execute | Out-Null
            Should -Invoke Enable-AzRecoveryServicesBackupProtection -Times 0 -Exactly
            & (Join-Path $script:scripts 'Enable-AzureVmBackup.ps1') @parameters -ReassignPolicy -Execute | Out-Null
            Should -Invoke Enable-AzRecoveryServicesBackupProtection -Times 1 -Exactly -ParameterFilter { $VaultId -eq 'example-vault-id' }
        }

        It 'enables an unprotected VM and skips a protected VM' {
            & (Join-Path $script:scripts 'Enable-AzureVmBackup.ps1') @script:backupParameters -Execute | Out-Null
            Should -Invoke Enable-AzRecoveryServicesBackupProtection -Times 1 -Exactly -ParameterFilter { $Name -eq 'example-vm' }
        }
    }

    Context 'readiness checks' {
        BeforeEach {
            $global:BackupAsrReplicationHealth = 'Normal'
            $global:BackupAsrRecoveryPoints = @([pscustomobject]@{ RecoveryPointId = 'example-point' })
            Mock Set-AzContext {}
            Mock Get-AzRecoveryServicesVault {
                [pscustomobject]@{ ID = 'example-vault-id'; Properties = [pscustomobject]@{ ProvisioningState = 'Succeeded' } }
            }
            Mock Set-AzRecoveryServicesAsrVaultContext {}
            Mock Get-AzRecoveryServicesAsrPolicy { [pscustomobject]@{ Name = 'example-asr-policy' } }
            Mock Get-AzRecoveryServicesBackupProtectionPolicy { [pscustomobject]@{ Name = 'example-backup-policy' } }
            Mock Get-AzRecoveryServicesAsrFabric { [pscustomobject]@{ Name = 'example-site' } }
            Mock Get-AzRecoveryServicesAsrProtectionContainer { [pscustomobject]@{ Name = 'example-container' } }
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem {
                [pscustomobject]@{ Name = 'example-vm'; FriendlyName = 'example-vm-00000000-0000-0000-0000-000000000000'; ReplicationHealth = $global:BackupAsrReplicationHealth; ProtectionState = 'Protected' }
            }
            Mock Get-AzRecoveryServicesBackupItem { [pscustomobject]@{ Name = 'example-jump' } }
            Mock Get-AzRecoveryServicesBackupRecoveryPoint { $global:BackupAsrRecoveryPoints } -RemoveParameterType 'Item'
        }

        It 'returns one row per check with PassThru' {
            $rows = @(& (Join-Path $script:scripts 'Test-BackupAsrReadiness.ps1') @script:readinessParameters -PassThru)
            $rows.Count | Should -Be 6
            @($rows | Where-Object { -not $_.Passed }).Count | Should -Be 0
            $rows[0].PSObject.Properties.Name | Should -Contain 'Detail'
        }

        It 'throws on a failed check unless PassThru is used' {
            $global:BackupAsrReplicationHealth = 'Critical'
            { & (Join-Path $script:scripts 'Test-BackupAsrReadiness.ps1') @script:readinessParameters } | Should -Throw '*Replication*'
            $rows = @(& (Join-Path $script:scripts 'Test-BackupAsrReadiness.ps1') @script:readinessParameters -PassThru)
            @($rows | Where-Object { -not $_.Passed }).Count | Should -Be 1
        }
    }
}
