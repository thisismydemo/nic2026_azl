#Requires -Version 7.0
<#
.SYNOPSIS
    Execute actual teardown protection guards with synthetic ARM responses.
.NOTES
    Author: Kristopher Turner
    Version: 1.0.0
#>
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
    function Get-AzResourceGroup { [CmdletBinding()] param($Name) $null }
    function Remove-AzResourceGroup { [CmdletBinding()] param($Name, [switch]$Force) throw 'Unmocked removal.' }
    $script:vault = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.RecoveryServices/vaults/vault-example'
    $script:collection = "$script:vault/backupProtectedItems?api-version=2025-08-01"
    $script:next = "https://management.azure.com$script:collection&page=2"
    $script:config = Get-Content (Join-Path $PSScriptRoot '../terraform/terraform.example.tfvars.json') -Raw | ConvertFrom-Json
}

Describe 'Actual teardown protection guards' {
    BeforeEach {
        Mock Invoke-AzRestMethod {
            if ($Path -match '/(backupProtectedItems|replicationProtectedItems)\?') {
                [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
            } else {
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
        Mock Invoke-AzRestMethod { throw 'inventory denied' }
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
}
