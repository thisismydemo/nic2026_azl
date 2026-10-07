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
                [pscustomobject]@{ OSDiskName = 'example-os-disk'; OS = 'Windows' }
            }
            $global:BackupAsrEnabled = $false
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem {
                if ($FriendlyName -eq 'protected-vm') { [pscustomobject]@{ FriendlyName = $FriendlyName; SelectedTfoAzureNetworkId = 'another-network' } }
                elseif ($global:BackupAsrEnabled) { [pscustomobject]@{ FriendlyName = $FriendlyName; SelectedTfoAzureNetworkId = $null } }
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
                $HyperVToAzure -and $Name -eq 'example-vm' -and $OSDiskName -eq 'example-os-disk' -and $UseManagedDisk -eq 'true'
            }
            # the new VM and the already-replicating VM (reconciled: its test network differs) both get the test network
            Should -Invoke Set-AzRecoveryServicesAsrReplicationProtectedItem -Times 2 -Exactly -ParameterFilter {
                $TestNetworkId -eq '/subscriptions/example/virtualNetworks/example-test'
            }
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
            Mock Get-AzRecoveryServicesAsrReplicationProtectedItem { [pscustomobject]@{ FriendlyName = 'example-vm' } }
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

    Context 'Azure VM backup' {
        BeforeEach {
            Mock Set-AzContext {}
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
                [pscustomobject]@{ ReplicationHealth = $global:BackupAsrReplicationHealth; ProtectionState = 'Protected' }
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
