#Requires -Version 7.0
# Pester 5 — pins the corrected NSG rules (verification log R-19) in BOTH IaC tracks so they cannot drift apart again:
#   - every subnet NSG that ends in an explicit deny-all outbound lets Windows reach Azure KMS (TCP 1688), otherwise activation fails;
#   - the jump NSG has no deny for the ASR test network (the jump server must reach test-failover VMs; isolation is on the asr-test NSG).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    $script:bicep = Get-Content (Join-Path $root 'bicep\modules\network.bicep') -Raw
    $script:tf = Get-Content (Join-Path $root 'terraform\s2-network.tf') -Raw
}

Describe 'Azure Local landing-zone NSG rules (Bicep and Terraform stay in step)' {
    It 'allows Azure KMS activation outbound on the jump, management, ASR and ASR-test NSGs in both tracks' {
        ([regex]::Matches($script:bicep, "AllowAzureKmsActivationOutbound'.*\['1688'\].*\['Internet'\]")).Count | Should -Be 4
        ([regex]::Matches($script:tf, '"AllowAzureKmsActivationOutbound".*\["1688"\].*\["Internet"\]')).Count | Should -Be 4
    }
    It 'has no jump-NSG deny for the ASR test network in either track' {
        $script:bicep | Should -Not -Match 'DenyAsrTestOutbound'
        $script:tf | Should -Not -Match 'DenyAsrTestOutbound'
    }
    It 'keeps the ASR test NSG isolated: inbound from the jump subnet only, outbound deny to on-prem and the VNet' {
        $script:bicep | Should -Match "AllowJumpInbound'.*subnet_jump_prefix.*subnet_asr_test_prefix"
        $script:bicep | Should -Match "DenyOnPremOutbound'"
        $script:bicep | Should -Match "DenyVnetOutbound'"
        $script:tf | Should -Match '"AllowJumpInbound"'
        $script:tf | Should -Match '"DenyOnPremOutbound"'
        $script:tf | Should -Match '"DenyVnetOutbound"'
    }
    It 'uses the same outbound priorities for the jump NSG in both tracks' {
        foreach ($pair in @(@('AllowVnetOutbound', 100), @('AllowOnPremOutbound', 110), @('AllowInternetHttpsOutbound', 120), @('AllowAzureKmsActivationOutbound', 130))) {
            $script:bicep | Should -Match "rule\('$($pair[0])', $($pair[1]), 'Outbound'"
            $script:tf | Should -Match "\[`"$($pair[0])`", $($pair[1]), `"Outbound`""
        }
    }
}
