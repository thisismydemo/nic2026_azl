#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Az stubs are mocked; no Azure operations.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub parameters define the command surface consumed by Pester mocks and call assertions.')]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:Checker = Join-Path $PSScriptRoot '../scripts/Test-LandingZone.ps1'
    function Get-AzContext { }
    function Set-AzContext { [CmdletBinding()] param($SubscriptionId, $Tenant) }
    function Get-AzVM { [CmdletBinding()] param($Name, $ResourceGroupName, $DefaultProfile) }
    function Get-AzNetworkInterface { [CmdletBinding()] param($Name, $ResourceGroupName, $DefaultProfile) }
    function Get-AzEffectiveRouteTable { [CmdletBinding()] param($NetworkInterfaceName, $ResourceGroupName, $DefaultProfile) }
}

Describe 'Relocated jump effective routes' {
    BeforeEach {
        $script:Workload = [guid]::Empty.ToString()
        $script:External = [guid]::NewGuid().ToString()
        $script:VmId = "/subscriptions/$script:External/resourceGroups/rg-management/providers/Microsoft.Compute/virtualMachines/jump-relocated"
        $script:SubnetId = "/subscriptions/$script:External/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/management/subnets/operators"
        $script:Config = @{ subscription_id = $script:Workload; names = @{ nic_jump = 'old-nic'; rg_mgmt = 'old-rg' }; onprem_prefixes = @('192.0.2.0/24') }
        Mock Get-AzContext { [pscustomobject]@{ Subscription = @{ Id = [guid]::Empty.ToString() }; Tenant = @{ Id = [guid]::Empty.ToString() } } }
        Mock Set-AzContext { [pscustomobject]@{ Subscription = @{ Id = $SubscriptionId }; Tenant = @{ Id = [guid]::Empty.ToString() } } }
        Mock Get-AzVM {
            $sub = $DefaultProfile.Subscription.Id
            [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/virtualMachines/$Name"; NetworkProfile = @{ NetworkInterfaces = @(@{ Id = "/subscriptions/$sub/resourceGroups/rg-nic/providers/Microsoft.Network/networkInterfaces/relocated-nic"; Primary = $true }) } }
        }
        Mock Get-AzNetworkInterface {
            $sub = $DefaultProfile.Subscription.Id
            [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/networkInterfaces/$Name"; VirtualMachine = @{ Id = "/subscriptions/$sub/resourceGroups/rg-management/providers/Microsoft.Compute/virtualMachines/jump-relocated" }; IpConfigurations = @(@{ Primary = $true; Subnet = @{ Id = "/subscriptions/$sub/resourceGroups/rg-network/providers/Microsoft.Network/virtualNetworks/management/subnets/operators" } }) }
        }
        Mock Get-AzEffectiveRouteTable { [pscustomobject]@{ AddressPrefix = @('192.0.2.0/24'); NextHopType = 'VirtualNetworkGateway'; State = 'Active' } }
    }
    It 'reads discovered NIC and routes in the explicit external context and restores workload scope' {
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId $script:VmId -JumpSubnetResourceId $script:SubnetId -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Pass
        Should -Invoke Get-AzNetworkInterface -Times 1 -Exactly -ParameterFilter { $Name -eq 'relocated-nic' -and $ResourceGroupName -eq 'rg-nic' -and $DefaultProfile.Subscription.Id -eq $script:External }
        Should -Invoke Get-AzEffectiveRouteTable -Times 1 -Exactly -ParameterFilter { $NetworkInterfaceName -eq 'relocated-nic' -and $DefaultProfile.Subscription.Id -eq $script:External }
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:Workload }
    }
    It 'fails a denied explicit VM lookup without reading the old NIC or routes' {
        Mock Get-AzVM { throw 'AuthorizationFailed' }
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId $script:VmId -JumpSubnetResourceId $script:SubnetId -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Fail
        Should -Invoke Get-AzNetworkInterface -Times 0 -Exactly
        Should -Invoke Get-AzEffectiveRouteTable -Times 0 -Exactly
        Should -Invoke Set-AzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:Workload }
    }
    It 'rejects a wrong subnet before observing routes' {
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId $script:VmId -JumpSubnetResourceId ($script:SubnetId + '-wrong') -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Fail
        Should -Invoke Get-AzEffectiveRouteTable -Times 0 -Exactly
    }
    It 'does not accept an inactive gateway route' {
        Mock Get-AzEffectiveRouteTable { [pscustomobject]@{ AddressPrefix = @('192.0.2.0/24'); NextHopType = 'VirtualNetworkGateway'; State = 'Invalid' } }
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId $script:VmId -JumpSubnetResourceId $script:SubnetId -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Fail
    }
    It 'rejects a malformed target without external lookups' {
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId '/invalid/vm' -JumpSubnetResourceId $script:SubnetId -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Fail
        Should -Invoke Get-AzVM -Times 0 -Exactly
    }
    It 'does not pass when the expected on-prem route list is empty' {
        $script:Config.onprem_prefixes = @()
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -JumpVmResourceId $script:VmId -JumpSubnetResourceId $script:SubnetId -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Fail
        Should -Invoke Get-AzEffectiveRouteTable -Times 0 -Exactly
    }
    It 'uses canonical external inputs without ad-hoc command overrides' {
        $script:Config.external_jump_vm_id = $script:VmId
        $script:Config.external_jump_subnet_id = $script:SubnetId
        $rows = @(& $script:Checker -Config $script:Config -Checks effective-routes -InformationAction SilentlyContinue)
        $rows[0].Status | Should -Be Pass
        Should -Invoke Get-AzNetworkInterface -Times 1 -Exactly -ParameterFilter { $Name -eq 'relocated-nic' -and $DefaultProfile.Subscription.Id -eq $script:External }
    }
}
