<#
.SYNOPSIS
    Creates the nic26-clus01 logical networks and NSGs with the documented Azure CLI (az stack-hci-vm), in Microsoft's
    order, from environment/azure-local/environment.yml (sdn, logical_networks, network_security_groups).
.DESCRIPTION
    Order (Learn: Create logical networks; Create network security groups - prerequisite: a static logical network):
      1. every logical network that does not exist (or is Failed) - static, VLAN, pool, gateway, DNS, switch;
      2. every NSG and its rules;
      3. each NSG attached to its logical network (lnet update --network-security-group only; DNS is never re-sent,
         known issue on this release).
    Idempotent: existing Succeeded resources are left as they are. -WhatIf lists the actions only. Azure PowerShell is
    out of scope for VM management on this release, so this uses az stack-hci-vm (extension 1.15.1 or later).
    Prerequisites on a Local Identity cluster: the management network is Private on every node (the platform rule
    "VMO public server 50052" covers Domain and Private only), SDN enabled by Arc.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Environment folder for Get-NIC26Config (default: <repo>\environment\azure-local). Subscription, resource group,
    # custom location and region come from it (subscription_id, vm_management, location) - no environment value here (G5).
    [string]$EnvironmentPath,
    [string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$azExe = (Get-Command az.cmd -CommandType Application | Select-Object -First 1).Source
Import-Module (Join-Path $PSScriptRoot '..\..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$envy = (Get-NIC26Config @cfgArgs).values
$SubscriptionId = $envy.subscription_id; $ResourceGroupName = $envy.vm_management.resource_group
$CustomLocationName = $envy.vm_management.custom_location; $Location = $envy.location
$cl = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ExtendedLocation/customLocations/$CustomLocationName"
# StrictMode-safe lookup of an optional key on a config object (dictionary or PSCustomObject)
function Get-Opt($Object, [string]$Key) {
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Key] }
    if ($Object.PSObject.Properties[$Key]) { return $Object.$Key }
    return $null
}
$switch = [string]$envy.sdn.vm_switch_name
$tags = @((Get-NIC26NamingContext -Config $envy).TagPairs) + @('workload=azure-local')
function L([string]$m) { $line = "$(Get-Date -Format HH:mm:ss) $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }
function Invoke-AzCli([string[]]$a) {
    $out = & $azExe @a --subscription $SubscriptionId --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ($out -replace '\s+', ' ').Trim() }
    return $out
}
function State([string]$type, [string]$name) {
    $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/$type/$name"
    $s = & $azExe resource show --ids $id --query properties.provisioningState -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) { return '' } ; return [string]$s
}

# 1. Logical networks
foreach ($l in $envy.logical_networks) {
    $s = State 'logicalNetworks' $l.name
    if ($s -eq 'Succeeded') { L "lnet $($l.name): exists (Succeeded)"; continue }
    if ($s -eq 'Failed' -and $PSCmdlet.ShouldProcess($l.name, 'Delete failed logical network')) { L "lnet $($l.name): Failed - deleting first"; $null = Invoke-AzCli @('stack-hci-vm', 'network', 'lnet', 'delete', '-g', $ResourceGroupName, '--name', $l.name, '--yes') }
    if ($PSCmdlet.ShouldProcess($l.name, "Create logical network VLAN $($l.vlan_id)")) {
        $a = @('stack-hci-vm', 'network', 'lnet', 'create', '-g', $ResourceGroupName, '--custom-location', $cl, '--location', $Location, '--name', $l.name,
            '--vm-switch-name', "`"$switch`"", '--ip-allocation-method', 'Static', '--address-prefixes', $l.subnet, '--gateway', $l.gateway,
            '--dns-servers') + @($l.dns_servers) + @('--vlan', [string]$l.vlan_id, '--ip-pool-start', $l.ip_pool.start, '--ip-pool-end', $l.ip_pool.end,
            '--tags') + $tags + @("vlan=$($l.vlan_id)", "purpose=$(Get-Opt $l purpose)")
        $null = Invoke-AzCli $a; L "lnet $($l.name): created ($(State 'logicalNetworks' $l.name))"
    }
}

# 2. NSGs and rules
foreach ($n in $envy.network_security_groups) {
    if ((State 'networkSecurityGroups' $n.name) -ne 'Succeeded' -and $PSCmdlet.ShouldProcess($n.name, 'Create NSG')) {
        $null = Invoke-AzCli (@('stack-hci-vm', 'network', 'nsg', 'create', '-g', $ResourceGroupName, '--custom-location', $cl, '--location', $Location, '--name', $n.name, '--tags') + $tags)
        L "nsg $($n.name): created"
    }
    else { L "nsg $($n.name): exists" }
    foreach ($r in $n.rules) {
        $rid = "networkSecurityGroups/$($n.name)/securityRules"
        if ((State $rid $r.name) -eq 'Succeeded') { L "  rule $($r.name): exists"; continue }
        if (-not $PSCmdlet.ShouldProcess("$($n.name)/$($r.name)", 'Create rule')) { continue }
        $a = @('stack-hci-vm', 'network', 'nsg', 'rule', 'create', '-g', $ResourceGroupName, '--custom-location', $cl, '--location', $Location,
            '--nsg-name', $n.name, '--name', $r.name, '--priority', [string]$r.priority, '--direction', $r.direction, '--access', $r.access,
            '--protocol', $r.protocol, '--source-port-ranges', '*', '--source-address-prefixes') + @($r.source) + @('--destination-address-prefixes') + @($r.destination) +
        @('--destination-port-ranges') + @($r.ports)
        $desc = Get-Opt $r description; if ($desc) { $a += @('--description', [string]$desc) }
        $null = Invoke-AzCli $a; L "  rule $($r.name): created"
    }
}

# 3. Attach each NSG to its logical network (NSG only; DNS is never re-sent)
foreach ($l in $envy.logical_networks) {
    if (-not (Get-Opt $l nsg)) { continue }
    $cur = & $azExe stack-hci-vm network lnet show -g $ResourceGroupName --name $l.name --subscription $SubscriptionId --query 'properties.subnets[0].properties.networkSecurityGroup.id' -o tsv --only-show-errors 2>$null
    if ($cur -and ($cur -split '/')[-1] -eq $l.nsg) { L "lnet $($l.name): NSG $($l.nsg) already attached"; continue }
    if ($PSCmdlet.ShouldProcess($l.name, "Attach NSG $($l.nsg)")) {
        $null = Invoke-AzCli @('stack-hci-vm', 'network', 'lnet', 'update', '-g', $ResourceGroupName, '--name', $l.name, '--network-security-group', $l.nsg)
        L "lnet $($l.name): NSG $($l.nsg) attached"
    }
}
L 'done'
