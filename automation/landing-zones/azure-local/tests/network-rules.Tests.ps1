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
    It 'never blocks the jump server: AllowJumpServerInbound (101, all protocols and ports) on all five NSGs in both tracks (D-056)' {
        $script:bicep | Should -Match "name: 'AllowJumpServerInbound'"
        $script:bicep | Should -Match "priority: 101\s+direction: 'Inbound'\s+access: 'Allow'\s+protocol: '\*'\s+sourcePortRange: '\*'\s+destinationPortRange: '\*'\s+sourceAddressPrefix: jump_server_source_prefix\s+destinationAddressPrefix: '\*'"
        $script:bicep | Should -Match "description: 'Jump server is never blocked \(owner, 12 Oct 2026\)'"
        ([regex]::Matches($script:bicep, 'securityRules: concat\(jumpServerRules, \[')).Count | Should -Be 5
        $script:tf | Should -Match '\["AllowJumpServerInbound", 101, "Inbound", "Allow", "\*", \["\*"\], \[p\], \["\*"\], "Jump server is never blocked \(owner, 12 Oct 2026\)"\]'
        ([regex]::Matches($script:tf, 'nsg_[a-z_]+ = concat\(local\.jump_server_rules, \[')).Count | Should -Be 5
        $script:tf | Should -Match 'description\s+= try\(security_rule\.value\[8\], null\)'
    }
    It 'drops the jump-server rule when jump_server_source_prefix is empty (attendee default)' {
        $script:bicep | Should -Match "param jump_server_source_prefix string = ''"
        $script:bicep | Should -Match 'jumpServerRules = empty\(jump_server_source_prefix\) \? \[\] :'
        $script:tf | Should -Match 'for p in compact\(\[var\.jump_server_source_prefix\]\)'
    }
    It 'uses the same outbound priorities for the jump NSG in both tracks' {
        foreach ($pair in @(@('AllowVnetOutbound', 100), @('AllowOnPremOutbound', 110), @('AllowInternetHttpsOutbound', 120), @('AllowAzureKmsActivationOutbound', 130))) {
            $script:bicep | Should -Match "rule\('$($pair[0])', $($pair[1]), 'Outbound'"
            $script:tf | Should -Match "\[`"$($pair[0])`", $($pair[1]), `"Outbound`""
        }
    }
}

Describe 'jump_server_source_prefix input contract (D-056)' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $shared = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'shared'
        $script:Schema = Get-Content (Join-Path $shared 'schemas/azure-local.environment.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:Example = Get-Content (Join-Path $shared 'examples/environment.azure-local.example.yml') -Raw | ConvertFrom-Yaml
        # Validate the one property against its own schema node (the full example needs the shared scope merged in).
        $node = $script:Schema.properties.jump_server_source_prefix
        $script:PropSchema = @{ '$schema' = 'https://json-schema.org/draft/2020-12/schema'; '$defs' = $script:Schema['$defs']; type = 'object'; properties = @{ v = $node } } | ConvertTo-Json -Depth 20
        $script:TestValue = { param($v) (@{ v = $v } | ConvertTo-Json | Test-Json -Schema $script:PropSchema -ErrorAction SilentlyContinue) }
    }
    It 'the example carries a documentation /32' {
        $script:Example.jump_server_source_prefix | Should -Be '192.0.2.10/32'
        & $script:TestValue $script:Example.jump_server_source_prefix | Should -BeTrue
    }
    It 'accepts empty (no rule) and rejects a subnet or an invalid host' {
        & $script:TestValue '' | Should -BeTrue
        & $script:TestValue '192.0.2.0/24' | Should -BeFalse
        & $script:TestValue ((('999', '0', '2', '10') -join '.') + '/32') | Should -BeFalse
    }
}
