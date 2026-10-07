#Requires -Version 7.0
<#
    Pester 5 - owner decision D-029 (no private endpoints) in lz-azure-local: the switch exists in both tracks, defaults to
    off, forces the vaults public and keeps the lock-down steps from running. Static checks; no Azure call.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester 5: BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    function Get-Text([string]$relative) { Get-Content -LiteralPath (Join-Path $script:root $relative) -Raw }
}

Describe 'enable_private_endpoints switch (D-029) in lz-azure-local' {
    It 'is declared in Bicep and Terraform with default false' {
        (Get-Text 'bicep\main.bicep') | Should -Match 'param enable_private_endpoints bool = false'
        (Get-Text 'terraform\variables.tf') | Should -Match 'variable "enable_private_endpoints"[\s\S]*?default\s*=\s*false'
    }
    It 'forces both vaults public and drops the private endpoints when off' {
        (Get-Text 'bicep\main.bicep') | Should -Match "kvPublicEffective = enable_private_endpoints \? kv_public_network_access : \{ ops: 'Enabled', azl: 'Enabled' \}"
        (Get-Text 'bicep\modules\security.bicep') | Should -Match 'privateEndpoints: enable_private_endpoints \?'
        $tf = Get-Text 'terraform\s3-security.tf'
        $tf | Should -Match 'private_endpoints = !var\.enable_private_endpoints \? \{\}'
        (Get-Text 'terraform\main.tf') | Should -Match 'kv_public\s*=\s*var\.enable_private_endpoints \?'
    }
    It 'skips the S8 lock-down and the DNS forwarder expectations when off' {
        (Get-Text 'scripts\Invoke-LzAzureLocalDeploy.ps1') | Should -Match 'S8 lock-down not applicable'
        $test = Get-Text 'scripts\Test-LandingZone.ps1'
        $test | Should -Match 'private endpoints are not used \(D-029\)'
    }
    It 'ships the examples with private endpoints off' {
        (Get-Text 'bicep\main.example.bicepparam') | Should -Match 'param enable_private_endpoints = false'
        (Get-Text 'terraform\terraform.example.tfvars.json') | Should -Match '"enable_private_endpoints":\s*false'
    }
}
