#Requires -Version 7.0
<#
.SYNOPSIS
    Execute actual teardown protection guards with synthetic ARM responses.
.NOTES
    Author: Kristopher Turner
    Version: 1.0.0
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Synthetic fixture state is shared with Pester mock callbacks and removed in AfterAll.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Local cmdlet stubs throw instead of changing resources; production guards are exercised with mocks.')]
param()
BeforeAll {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $script:source = Join-Path $PSScriptRoot '../scripts/New-LzTeardownPlan.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Teardown source does not parse.' }
    foreach ($name in 'Get-LzArmCollection', 'Assert-LzVaultUnprotected', 'Assert-LzClusterAbsent', 'Test-LzArmResourcePresent') {
        $definition = $ast.Find({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    function Invoke-AzRestMethod { [CmdletBinding()] param($Method, $Path) throw 'Unmocked ARM call.' }
    function Get-AzResource { [CmdletBinding()] param($ResourceGroupName, $ResourceType) throw 'Unmocked resource call.' }
    function Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }
    function Set-AzContext { [CmdletBinding(SupportsShouldProcess)] param($SubscriptionId) throw 'Unmocked context switch.' }
    function Get-AzResourceGroup { [CmdletBinding()] param($Name) $null }
    function Remove-AzResourceGroup { [CmdletBinding()] param($Name, [switch]$Force) throw 'Unmocked removal.' }
    $script:vault = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.RecoveryServices/vaults/vault-example'
    $script:collection = "$script:vault/backupProtectedItems?api-version=2025-08-01"
    $script:next = "https://management.azure.com$script:collection&page=2"
    $script:config = Get-Content (Join-Path $PSScriptRoot '../terraform/terraform.example.tfvars.json') -Raw | ConvertFrom-Json
    $global:NIC26TeardownFixture = @{}
    $global:NIC26TeardownFixture.managementId = "/subscriptions/$($script:config.subscription_id)/resourceGroups/$($script:config.names.rg_mgmt)"
    $global:NIC26TeardownFixture.clusterId = "/subscriptions/$($script:config.subscription_id)/resourceGroups/$($script:config.names.rg_azl)"
}

Describe 'Actual teardown protection guards' {
    BeforeEach {
        Mock Invoke-AzRestMethod {
            if ($Path -match '/(backupProtectedItems|replicationProtectedItems)\?') {
                [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
            }
            elseif ($Path -match '/resourceGroups/[^/]+\?' -and ($Path -split '\?')[0] -ne $global:NIC26TeardownFixture.clusterId) {
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound"}}' }
            }
            else {
                [pscustomobject]@{ StatusCode = 200; Content = (@{ id = ($Path -split '\?')[0] } | ConvertTo-Json) }
            }
        }
    }
    It 'accepts only complete empty backup and ASR inventories' {
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Not -Throw
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -like '*/backupProtectedItems?*' }
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $Path -like '*/replicationProtectedItems?*' }
    }
    It 'blocks Azure Files backup records' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"properties":{"workloadType":"AzureFileShare"}}]}' } }
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Throw '*backup item*'
    }
    It 'blocks ASR-only protection' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"replicated-vm"}]}' } } -ParameterFilter { $Path -like '*/replicationProtectedItems?*' }
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Throw '*replication item*'
    }
    It 'blocks an item found on a later page' {
        Mock Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(); nextLink = $script:next } | ConvertTo-Json) }
        } -ParameterFilter { $Path -notlike '*page=2' }
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"later-item"}]}' } } -ParameterFilter { $Path -like '*page=2' }
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Throw '*backup item*'
    }
    It 'blocks a failed later page' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(); nextLink = $script:next } | ConvertTo-Json) } } -ParameterFilter { $Path -notlike '*page=2' }
        Mock Invoke-AzRestMethod { throw 'page denied' } -ParameterFilter { $Path -like '*page=2' }
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Throw '*page denied*'
    }
    It 'rejects malformed or unsuccessful responses' -TestCases @(
        @{ Code = 403; Json = '{"error":{}}' },
        @{ Code = 200; Json = '{}' },
        @{ Code = 200; Json = '{"value":null}' },
        @{ Code = 200; Json = '{"value":[null]}' }
    ) {
        param($Code, $Json)
        $script:response = [pscustomobject]@{ StatusCode = $Code; Content = $Json }
        Mock Invoke-AzRestMethod { $script:response }
        { Assert-LzVaultUnprotected -VaultId $script:vault } | Should -Throw
    }
    It 'rejects an untrusted host or a different vault collection' -TestCases @(
        @{ Escape = 'https://example.com/page' },
        @{ Escape = 'https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/other-collection' }
    ) {
        param($Escape)
        $script:escape = $Escape
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(); nextLink = $script:escape } | ConvertTo-Json) } }
        { Get-LzArmCollection -CollectionPath $script:collection } | Should -Throw '*authorized ARM collection*'
        Should -Invoke Invoke-AzRestMethod -Times 1 -Exactly
    }
    It 'rejects pagination cycles' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(); nextLink = "https://management.azure.com$script:collection" } | ConvertTo-Json) } }
        { Get-LzArmCollection -CollectionPath $script:collection } | Should -Throw '*pagination cycle*'
    }
    It 'checks the Azure Local cluster type and blocks read failure' {
        Mock Get-AzResource { throw 'cluster read denied' }
        { Assert-LzClusterAbsent -ResourceGroupName 'rg-example' } | Should -Throw '*cluster read denied*'
        Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter { $ResourceType -eq 'Microsoft.AzureStackHCI/clusters' }
    }
    It 'blocks a present cluster' {
        Mock Get-AzResource { [pscustomobject]@{ Name = 'example-cluster' } }
        { Assert-LzClusterAbsent -ResourceGroupName 'rg-example' } | Should -Throw '*cluster still exists*'
    }
    It 'accepts an empty successful cluster query' {
        Mock Get-AzResource { @() }
        { Assert-LzClusterAbsent -ResourceGroupName 'rg-example' } | Should -Not -Throw
    }
    It 'accepts explicit resource absence only with a matching not-found code' -TestCases @(
        @{ Code = 'ResourceNotFound' }, @{ Code = 'ResourceGroupNotFound' }
    ) {
        param($Code)
        $script:code = $Code
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = (@{ error = @{ code = $script:code } } | ConvertTo-Json) } }
        Test-LzArmResourcePresent -ResourceId $script:vault -ApiVersion '2025-02-01' | Should -BeFalse
    }
    It 'does not equate authorization or arbitrary not-found responses with absence' -TestCases @(
        @{ Status = 403; Code = 'AuthorizationFailed' }, @{ Status = 404; Code = 'UnsupportedApi' }
    ) {
        param($Status, $Code)
        $script:status = $Status
        $script:code = $Code
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = $script:status; Content = (@{ error = @{ code = $script:code } } | ConvertTo-Json) } }
        { Test-LzArmResourcePresent -ResourceId $script:vault -ApiVersion '2025-02-01' } | Should -Throw '*absence not proven*'
    }
    It 'requires a successful presence response to identify the expected resource' {
        Test-LzArmResourcePresent -ResourceId $script:vault -ApiVersion '2025-02-01' | Should -BeTrue
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"id":"/different"}' } }
        { Test-LzArmResourcePresent -ResourceId $script:vault -ApiVersion '2025-02-01' } | Should -Throw '*expected resource*'
    }
    It 'does not delete the vault resource group after an S6 inventory failure' {
        Mock Invoke-AzRestMethod { throw 'inventory denied' } -ParameterFilter { $Path -like '*/providers/Microsoft.RecoveryServices/*' }
        Mock Remove-AzResourceGroup {}
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'failed-vault.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object { $_.Stage -eq 'S6' -and $_.Action -eq 'check' }).Status | Should -BeLike 'failed:*'
        Should -Invoke Remove-AzResourceGroup -Times 0 -Exactly
    }
    It 'does not delete witness storage after an S5 cluster read failure' {
        Mock Get-AzResource { throw 'cluster read denied' }
        Mock Remove-AzResourceGroup {}
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'failed-cluster.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object { $_.Stage -eq 'S5' -and $_.Action -eq 'check' }).Status | Should -BeLike 'failed:*'
        Should -Invoke Remove-AzResourceGroup -Times 0 -Exactly
    }
    It 'reports an already absent management group without deleting it' {
        Mock Remove-AzResourceGroup {}
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'absent.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -Be 'already absent'
        Should -Invoke Remove-AzResourceGroup -Times 0 -Exactly
    }
    It 'stops before deletion when the management group cannot be read' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } } -ParameterFilter { ($Path -split '\?')[0] -eq $global:NIC26TeardownFixture.managementId }
        Mock Remove-AzResourceGroup {}
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'read-denied.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -BeLike 'failed:*absence not proven*'
        Should -Invoke Remove-AzResourceGroup -Times 0 -Exactly
    }
    It 'claims deletion only after an exact post-removal not-found response' {
        $global:NIC26TeardownFixture.removed = $false
        Mock Invoke-AzRestMethod {
            if ($global:NIC26TeardownFixture.removed) { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"ResourceGroupNotFound"}}' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $global:NIC26TeardownFixture.managementId } | ConvertTo-Json) } }
        } -ParameterFilter { ($Path -split '\?')[0] -eq $global:NIC26TeardownFixture.managementId }
        Mock Remove-AzResourceGroup { $global:NIC26TeardownFixture.removed = $true }
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'removed.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -Be 'deleted'
        Should -Invoke Remove-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq (Split-Path $global:NIC26TeardownFixture.managementId -Leaf) -and $Force -and $ErrorAction -eq 'Stop' }
        Should -Invoke Invoke-AzRestMethod -Times 2 -Exactly -ParameterFilter { $Path -eq "$($global:NIC26TeardownFixture.managementId)?api-version=2021-04-01" }
    }
    It 'does not claim deletion when removal fails' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $global:NIC26TeardownFixture.managementId } | ConvertTo-Json) } } -ParameterFilter { ($Path -split '\?')[0] -eq $global:NIC26TeardownFixture.managementId }
        Mock Remove-AzResourceGroup { throw 'removal denied' }
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'remove-denied.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -BeLike 'failed:*removal denied*'
        Should -Invoke Remove-AzResourceGroup -Times 1 -Exactly
    }
    It 'does not claim deletion when the post-read is present or denied' -TestCases @(@{PostCode=200 }, @{PostCode=403 }) {
        param($PostCode)
        $global:NIC26TeardownFixture.postCode = $PostCode
        $global:NIC26TeardownFixture.removed = $false
        Mock Invoke-AzRestMethod {
            if ($global:NIC26TeardownFixture.removed -and $global:NIC26TeardownFixture.postCode -eq 403) { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
            else { [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $global:NIC26TeardownFixture.managementId } | ConvertTo-Json) } }
        } -ParameterFilter { ($Path -split '\?')[0] -eq $global:NIC26TeardownFixture.managementId }
        Mock Remove-AzResourceGroup { $global:NIC26TeardownFixture.removed = $true }
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'unverified.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -BeLike 'failed:*'
        Should -Invoke Remove-AzResourceGroup -Times 1 -Exactly
    }
    It 'does not delete in a mismatched active subscription' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = (@{ id = $global:NIC26TeardownFixture.managementId } | ConvertTo-Json) } } -ParameterFilter { ($Path -split '\?')[0] -eq $global:NIC26TeardownFixture.managementId }
        Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'different-subscription' } } }
        Mock Set-AzContext {}
        Mock Remove-AzResourceGroup {}
        $plan = & $script:source -Config $script:config -PlanPath (Join-Path $TestDrive 'wrong-context.json') -Execute -Confirm:$false -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        ($plan | Where-Object Stage -EQ 'S7').Status | Should -BeLike 'failed:*context does not match*'
        Should -Invoke Remove-AzResourceGroup -Times 0 -Exactly
    }
}

AfterAll { Remove-Variable -Name NIC26TeardownFixture -Scope Global -ErrorAction SilentlyContinue }
