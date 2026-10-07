#Requires -Version 7.0
# Pester 5 — cluster-configure/platform gates via the shared kit (manifest, converters, parity, hygiene, bicep/terraform, sweep).
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-platform' `
    -RequiredInputs 'logical_networks', 'storage', 'marketplace_images', 'vm_switch_name' `
    -EntryScripts 'Invoke-PlatformConfigure.ps1'

Describe 'platform specifics' {
    It 'pins the confirmed AVM modules' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $b | Should -Match 'br/public:avm/res/azure-stack-hci/logical-network:0\.3\.1'
        $b | Should -Match 'br/public:avm/res/azure-stack-hci/marketplace-gallery-image:0\.1\.0'
        (Get-Content (Join-Path $PSScriptRoot '..\terraform\main.tf') -Raw) | Should -Match 'avm-res-azurestackhci-logicalnetwork/azurerm"\s+version\s+=\s+"2\.0\.0"'
    }
    It 'defaults the marketplace catalogue to Win11 multi-session + M365 and Windows Server 2025' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\solution.yml') -Raw
        $t | Should -Match 'win11-25h2-avd-m365'
        $t | Should -Match '2025-datacenter-azure-edition'
    }
    It 'the volume script never deletes and refuses non-Windows hosts' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\scripts\New-ClusterWorkloadVolume.ps1') -Raw
        $t | Should -Not -Match 'Remove-Volume|Remove-VirtualDisk'
        $t | Should -Match 'if \(-not \$IsWindows\) \{ throw'
    }
}
