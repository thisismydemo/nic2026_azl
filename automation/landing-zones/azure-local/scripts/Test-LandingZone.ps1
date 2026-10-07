#Requires -Version 7.0
<#
.SYNOPSIS
    Stage S9: READ-ONLY validation of the Azure Local landing zone - design §11.1 as individual pass/fail checks.
.DESCRIPTION
    Every check is a function that returns Pass / Fail / Manual / Skipped with a detail string. Nothing is changed.
    Exit code = number of failed checks (0 = all pass). Includes the DNS resolution checks for the vault private
    endpoints (compares Resolve-DnsName with the private endpoint NIC addresses), the policy-impact pre-check list
    (review R-04), the P-13 peering checks (spoke<->identity, spoke<->management Connected), the DC DNS reachability
    check from the jump server, and the manual P2S DNS-profile note. The built-in role/policy GUID maps used by the
    Bicep gap-fill modules are verified against the tenant (checks role-map and policy-map).
.PARAMETER Config
    Canonical config object (Get-NIC26Config -Scope azure-local) incl. names and group_object_ids.
.PARAMETER Checks
    Optional subset of check names to run (default: all).
.PARAMETER OutputPath
    Optional JSON report path (names, states and details only).
.PARAMETER ExpectDnsPrivate
    When set, the vault DNS check expects the PRIVATE endpoint addresses (run on the jump server / P2S laptop / node after
    the DC forwarders exist). Without it the check only reports what resolves.
.EXAMPLE
    ./Test-LandingZone.ps1 -Config (Get-NIC26Config -Scope azure-local) -ExpectDnsPrivate
    ./Test-LandingZone.ps1 -Config $cfg -Checks providers,dns-vault
.NOTES
    Requires Az.Accounts, Az.Resources, Az.Network, Az.KeyVault, Az.OperationalInsights, Az.Security, Az.RecoveryServices (read roles suffice).
    Runs anywhere; the DNS checks are meaningful from the jump server, a P2S laptop and a node (design §11.1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [object] $Config,
    [string[]] $Checks,
    [string] $OutputPath,
    [switch] $ExpectDnsPrivate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sub = [string] $Config.subscription_id
$n = $Config.names
$subScope = "/subscriptions/$sub"
$script:Results = [System.Collections.Generic.List[object]]::new()

function Add-LzResult {
    param([string] $Name, [ValidateSet('Pass', 'Fail', 'Manual', 'Skipped')] [string] $Status, [string] $Detail = '')
    $script:Results.Add([pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail })
}
function Test-LzConfigKey {
    # Config is an OrderedDictionary from Get-NIC26Config or a PSCustomObject from JSON; support both.
    param([object] $Object, [string] $Key)
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    return $null -ne $Object.PSObject.Properties[$Key]
}
function Invoke-LzCheck {
    param([string] $Name, [scriptblock] $Body)
    if ($Checks -and $Name -notin $Checks) { return }
    try { & $Body } catch { Add-LzResult $Name 'Fail' "exception: $($_.Exception.Message)" }
}
function Get-LzPeeringState {
    param([string] $VnetId, [string] $PeeringName)
    $parts = $VnetId -split '/'
    $current = (Get-AzContext).Subscription.Id
    try {
        if ($parts[2] -ne $current) { $null = Set-AzContext -WhatIf:$false -SubscriptionId $parts[2] }
        $p = Get-AzVirtualNetworkPeering -ResourceGroupName $parts[4] -VirtualNetworkName $parts[-1] -Name $PeeringName -ErrorAction SilentlyContinue
        return $p
    }
    finally { if ($parts[2] -ne $current) { $null = Set-AzContext -WhatIf:$false -SubscriptionId $current } }
}

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
if ($ctx.Subscription.Id -ne $sub) { $null = Set-AzContext -WhatIf:$false -SubscriptionId $sub }

# ------------------------------------------------------------------ placement / providers / policy pre-check
Invoke-LzCheck 'mg-parent' {
    $mg = [string] $Config.management_group_id
    if (-not $mg) { Add-LzResult 'mg-parent' 'Skipped' 'management_group_id not set'; return }
    $children = (Get-AzManagementGroup -GroupName $mg -Expand -ErrorAction Stop).Children | Where-Object { $_.Type -like '*subscriptions' -and $_.Name -eq $sub }
    Add-LzResult 'mg-parent' ($children ? 'Pass' : 'Fail') "subscription is $($children ? '' : 'NOT ')a direct child of $mg"
}
Invoke-LzCheck 'policy-precheck' {
    # Review R-04: list every assignment at or above the subscription; flag Deny/DINE effects that could block the build.
    $assignments = @(Get-AzPolicyAssignment -Scope $subScope -IncludeDescendent:$false -ErrorAction Stop)
    $suspicious = foreach ($a in $assignments) {
        $def = $a.Properties.PolicyDefinitionId
        $name = $a.Properties.DisplayName
        if ($name -match 'deny|not allowed|disable public|purge protection|shared key|private endpoint|peering|extension|allowed resource types|allowed locations' -and $a.Name -notlike "asg-*nic26*") { "$name [$def]" }
    }
    $detail = "$($assignments.Count) assignment(s) in scope; review list: " + (($suspicious | Select-Object -First 15) -join '; ')
    Add-LzResult 'policy-precheck' ($suspicious ? 'Manual' : 'Pass') $detail
}
Invoke-LzCheck 'providers' {
    $needed = 'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity', 'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.HybridContainerService', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault', 'Microsoft.DeviceOnboarding', 'Microsoft.Edge', 'Microsoft.ManagedIdentity', 'Microsoft.PolicyInsights', 'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.RecoveryServices', 'Microsoft.Network', 'Microsoft.Security', 'Microsoft.Maintenance', 'Microsoft.EdgeMarketplace'
    $missing = foreach ($p in $needed) { $s = (Get-AzResourceProvider -ProviderNamespace $p | Select-Object -First 1).RegistrationState; if ($s -ne 'Registered') { "$p=$s" } }
    Add-LzResult 'providers' ($missing ? 'Fail' : 'Pass') ($missing ? ($missing -join ', ') : 'all Registered')
}
Invoke-LzCheck 'feature-ztp' {
    $f = Get-AzProviderFeature -ProviderNamespace 'Microsoft.DeviceOnboarding' -FeatureName 'AzureLocalZTP' -ErrorAction SilentlyContinue
    Add-LzResult 'feature-ztp' (($f.RegistrationState -eq 'Registered') ? 'Pass' : 'Fail') "AzureLocalZTP=$($f.RegistrationState)"
}
Invoke-LzCheck 'role-map' {
    $bicep = Get-Content (Join-Path $PSScriptRoot '..\bicep\modules\built-in-roles.bicep') -Raw
    $pairs = [regex]::Matches($bicep, "(?m)^\s*(\w+): '([0-9a-f-]{36})'")
    $bad = foreach ($m in $pairs) { $d = Get-AzRoleDefinition -Id $m.Groups[2].Value -ErrorAction SilentlyContinue; if (-not $d) { $m.Groups[1].Value } }
    Add-LzResult 'role-map' ($bad ? 'Fail' : 'Pass') ($bad ? "unknown role IDs: $($bad -join ', ')" : "$($pairs.Count) built-in role IDs resolve")
}
Invoke-LzCheck 'policy-map' {
    $bicep = Get-Content (Join-Path $PSScriptRoot '..\bicep\modules\policy-definitions.bicep') -Raw
    $pairs = [regex]::Matches($bicep, "(?m)^\s*(\w+): '([0-9a-f-]{36})'")
    $bad = foreach ($m in $pairs) { $d = Get-AzPolicyDefinition -Id "/providers/Microsoft.Authorization/policyDefinitions/$($m.Groups[2].Value)" -ErrorAction SilentlyContinue; if (-not $d) { $m.Groups[1].Value } }
    Add-LzResult 'policy-map' ($bad ? 'Fail' : 'Pass') ($bad ? "unknown policy IDs: $($bad -join ', ')" : "$($pairs.Count) built-in policy IDs resolve")
}

# ------------------------------------------------------------------ S1 governance
Invoke-LzCheck 'resource-groups' {
    $required = 'project', 'workload', 'environment', 'owner', 'managed-by', 'lifecycle', 'cost-center'
    $problems = foreach ($k in 'rg_azl', 'rg_net', 'rg_mon', 'rg_sec', 'rg_bcdr', 'rg_dr', 'rg_mgmt') {
        $rg = Get-AzResourceGroup -Name $n.$k -ErrorAction SilentlyContinue
        if (-not $rg) { "$($n.$k) missing"; continue }
        $missingTags = $required | Where-Object { -not $rg.Tags -or -not $rg.Tags.ContainsKey($_) }
        if ($missingTags) { "$($n.$k) lacks tags $($missingTags -join ',')" }
    }
    Add-LzResult 'resource-groups' ($problems ? 'Fail' : 'Pass') ($problems ? ($problems -join '; ') : 'seven groups with seven tags')
}
Invoke-LzCheck 'policy-guardrails' {
    $a = @(Get-AzPolicyAssignment -Scope $subScope -ErrorAction Stop | Where-Object { $_.Name -eq $n.asg_allowed_locations -or $_.Name -like "$($n.asg_inherit_tags)-*" -or $_.Name -like "$($n.asg_require_tags_rg)-*" -or $_.Name -eq $n.asg_activity_log })
    Add-LzResult 'policy-guardrails' (($a.Count -ge 16) ? 'Pass' : 'Fail') "$($a.Count) landing-zone assignments found (expected 1 + 7 + 7 + 1)"
}
Invoke-LzCheck 'budget' {
    $b = Get-AzConsumptionBudget -Name $n.budget_azl -ErrorAction SilentlyContinue
    $count = $b ? @($b.Notification.Keys).Count : 0
    Add-LzResult 'budget' (($count -eq 4) ? 'Pass' : 'Fail') "budget $($n.budget_azl): $count notification threshold(s)"
}
Invoke-LzCheck 'defender' {
    $cspm = Get-AzSecurityPricing -Name 'CloudPosture' -ErrorAction SilentlyContinue
    $vm = Get-AzSecurityPricing -Name 'VirtualMachines' -ErrorAction SilentlyContinue
    $plan = [string] $Config.defender_servers_plan
    $expectedTier = ($plan -eq 'off') ? 'Free' : 'Standard'
    $ok = $cspm -and $vm.PricingTier -eq $expectedTier -and ($plan -eq 'off' -or $vm.SubPlan -eq $plan)
    Add-LzResult 'defender' ($ok ? 'Pass' : 'Fail') "CloudPosture=$($cspm.PricingTier) VirtualMachines=$($vm.PricingTier)/$($vm.SubPlan) (expected $expectedTier/$plan)"
}

# ------------------------------------------------------------------ S2 network
Invoke-LzCheck 'vnet-subnets' {
    $vnet = Get-AzVirtualNetwork -Name $n.spoke_vnet -ResourceGroupName $n.rg_net -ErrorAction SilentlyContinue
    if (-not $vnet) { Add-LzResult 'vnet-subnets' 'Fail' 'spoke VNet missing'; return }
    $expected = @{ $n.snet_jump = $Config.subnet_jump_prefix; $n.snet_pe = $Config.subnet_pe_prefix; $n.snet_mgmt = $Config.subnet_mgmt_prefix; $n.snet_asr = $Config.subnet_asr_prefix; $n.snet_asr_test = $Config.subnet_asr_test_prefix }
    $problems = foreach ($name in $expected.Keys) {
        $s = $vnet.Subnets | Where-Object Name -EQ $name
        if (-not $s) { "$name missing"; continue }
        if ($s.AddressPrefix -notcontains $expected[$name]) { "$name prefix $($s.AddressPrefix) != $($expected[$name])" }
        if (-not $s.NetworkSecurityGroup) { "$name has no NSG" }
        if (-not $s.RouteTable) { "$name has no route table" }
    }
    $dnsOk = -not (Compare-Object @($vnet.DhcpOptions.DnsServers) @($Config.dns_servers))
    if (-not $dnsOk) { $problems += "custom DNS differs from dns_servers" }
    Add-LzResult 'vnet-subnets' ($problems ? 'Fail' : 'Pass') ($problems ? ($problems -join '; ') : "5 subnets, NSG + route table each, DNS = DCs")
}
Invoke-LzCheck 'route-table' {
    $rt = Get-AzRouteTable -Name $n.rt_azl -ResourceGroupName $n.rg_net -ErrorAction SilentlyContinue
    $ok = $rt -and -not $rt.DisableBgpRoutePropagation -and @($rt.Routes).Count -eq 0
    Add-LzResult 'route-table' ($ok ? 'Pass' : 'Fail') "propagation enabled=$(-not $rt.DisableBgpRoutePropagation) routes=$(@($rt.Routes).Count)"
}
Invoke-LzCheck 'peering-hub' {
    $local = Get-AzVirtualNetworkPeering -ResourceGroupName $n.rg_net -VirtualNetworkName $n.spoke_vnet -Name $n.peer_spoke_to_hub -ErrorAction SilentlyContinue
    $remote = Get-LzPeeringState -VnetId $Config.hub_vnet_id -PeeringName $n.peer_hub_to_spoke
    $ok = $local.PeeringState -eq 'Connected' -and $local.UseRemoteGateways -and $remote.PeeringState -eq 'Connected' -and $remote.AllowGatewayTransit
    Add-LzResult 'peering-hub' ($ok ? 'Pass' : 'Fail') "spoke=$($local.PeeringState)/useRemoteGateways=$($local.UseRemoteGateways) hub=$($remote.PeeringState)/allowGatewayTransit=$($remote.AllowGatewayTransit)"
}
foreach ($pair in @(
        @{ Name = 'peering-identity'; Flag = 'enable_identity_peering'; Local = 'peer_spoke_to_identity'; Remote = 'peer_identity_to_spoke'; VnetId = 'identity_spoke_vnet_id' }
        @{ Name = 'peering-mgmt'; Flag = 'enable_management_peering'; Local = 'peer_spoke_to_mgmt'; Remote = 'peer_mgmt_to_spoke'; VnetId = 'management_spoke_vnet_id' }
    )) {
    $p = $pair
    Invoke-LzCheck $p.Name {
        if (-not ((Test-LzConfigKey $Config $p.Flag) -and [bool]$Config.($p.Flag))) { Add-LzResult $p.Name 'Fail' "$($p.Flag) is false - P-13 requires this direct peering (owner approval pending?)"; return }
        $local = Get-AzVirtualNetworkPeering -ResourceGroupName $n.rg_net -VirtualNetworkName $n.spoke_vnet -Name $n.($p.Local) -ErrorAction SilentlyContinue
        $remote = Get-LzPeeringState -VnetId $Config.($p.VnetId) -PeeringName $n.($p.Remote)
        $ok = $local.PeeringState -eq 'Connected' -and $remote.PeeringState -eq 'Connected'
        Add-LzResult $p.Name ($ok ? 'Pass' : 'Fail') "spoke=$($local.PeeringState) remote=$($remote.PeeringState)"
    }
}
Invoke-LzCheck 'peering-avd' {
    if (-not $Config.avd_spoke_vnet_id) { Add-LzResult 'peering-avd' 'Skipped' 'avd_spoke_vnet_id not set yet'; return }
    $local = Get-AzVirtualNetworkPeering -ResourceGroupName $n.rg_net -VirtualNetworkName $n.spoke_vnet -Name $n.peer_spoke_to_avd -ErrorAction SilentlyContinue
    Add-LzResult 'peering-avd' (($local.PeeringState -eq 'Connected') ? 'Pass' : 'Fail') "spoke->avd=$($local.PeeringState)"
}
Invoke-LzCheck 'private-dns-zone' {
    if (-not [bool]$Config.enable_private_endpoints) { Add-LzResult 'private-dns-zone' 'Skipped' 'private endpoints are not used (D-029)'; return }
    if ($Config.privatelink_vaultcore_zone_id) { Add-LzResult 'private-dns-zone' 'Manual' 'shared zone reused; verify its links with the zone owner'; return }
    $zone = Get-AzPrivateDnsZone -ResourceGroupName $n.rg_net -Name $n.pdns_vaultcore -ErrorAction SilentlyContinue
    $links = $zone ? @(Get-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $n.rg_net -ZoneName $n.pdns_vaultcore) : @()
    $needed = @($n.link_azl, $n.link_identity) + ($Config.avd_spoke_vnet_id ? @($n.link_avd) : @())
    $missing = $needed | Where-Object { $_ -notin $links.Name }
    Add-LzResult 'private-dns-zone' (($zone -and -not $missing) ? 'Pass' : 'Fail') ($zone ? "links: $($links.Name -join ', ')$($missing ? "; missing $($missing -join ', ')" : '')" : 'own zone missing (P-11)')
}

# ------------------------------------------------------------------ DNS and reachability (design §11.1, A4)
Invoke-LzCheck 'dns-vault' {
    if (-not [bool]$Config.enable_private_endpoints) {
        $pub = foreach ($kv in @($n.kv_ops, $n.kv_azl)) { $a = @(Resolve-DnsName -Name "$kv.vault.azure.net" -Type A -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' }); if (-not $a) { "$kv.vault.azure.net unresolved" } }
        Add-LzResult 'dns-vault' ($pub ? 'Fail' : 'Pass') ($pub ? ($pub -join '; ') : 'vault names resolve (public endpoints, D-029)'); return
    }
    $problems = @(); $detail = @()
    foreach ($kv in @($n.kv_ops, $n.kv_azl)) {
        $fqdn = "$kv.vault.azure.net"
        $resolved = @(Resolve-DnsName -Name $fqdn -Type A -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress)
        $pepName = ($kv -eq $n.kv_ops) ? $n.pep_kv_ops : $n.pep_kv_azl
        $pep = Get-AzPrivateEndpoint -Name $pepName -ResourceGroupName $n.rg_sec -ErrorAction SilentlyContinue
        $peIps = @()
        if ($pep) { $nic = Get-AzNetworkInterface -ResourceId $pep.NetworkInterfaces[0].Id -ErrorAction SilentlyContinue; $peIps = @($nic.IpConfigurations.PrivateIpAddress) }
        $isPrivate = $resolved -and $peIps -and ($resolved | Where-Object { $_ -in $peIps })
        $detail += "$fqdn -> $($resolved -join ',') (PE: $($peIps -join ','))"
        if ($ExpectDnsPrivate -and -not $isPrivate) { $problems += $fqdn }
        if (-not $resolved) { $problems += "$fqdn unresolved" }
    }
    Add-LzResult 'dns-vault' ($problems ? 'Fail' : ($ExpectDnsPrivate ? 'Pass' : 'Manual')) ($detail -join ' | ')
}
Invoke-LzCheck 'dns-dc-reachable' {
    $bad = foreach ($dc in @($Config.dns_servers)) { $t = Test-NetConnection -ComputerName $dc -Port 53 -WarningAction SilentlyContinue -InformationLevel Quiet; if (-not $t) { $dc } }
    Add-LzResult 'dns-dc-reachable' ($bad ? 'Fail' : 'Pass') ($bad ? "DC DNS not reachable on TCP 53 from here: $($bad -join ', ') (P-13 identity peering?)" : "both domain controllers answer on TCP 53 from this host")
}
Invoke-LzCheck 'dns-forwarders' { if (-not [bool]$Config.enable_private_endpoints) { Add-LzResult 'dns-forwarders' 'Skipped' 'private endpoints are not used (D-029); the existing DNS needs no change'; return }; Add-LzResult 'dns-forwarders' 'Manual' 'Confirm on EVERY DC: conditional forwarder vault.azure.net (and vaultcore.azure.net) -> 168.63.129.16; Arc FQDNs still public (P-07, owner-approved change).' }
Invoke-LzCheck 'p2s-dns-profile' { Add-LzResult 'p2s-dns-profile' 'Manual' 'The hub pushes no DNS to P2S clients: the exported azurevpnconfig.xml must carry the DC DNS servers and be re-imported after every peering change (connectivity C-06).' }
Invoke-LzCheck 'effective-routes' {
    $nic = Get-AzNetworkInterface -Name $n.nic_jump -ResourceGroupName $n.rg_mgmt -ErrorAction SilentlyContinue
    if (-not $nic) { Add-LzResult 'effective-routes' 'Skipped' 'jump NIC not found (enable_jump_server?)'; return }
    $routes = @(Get-AzEffectiveRouteTable -NetworkInterfaceName $n.nic_jump -ResourceGroupName $n.rg_mgmt -ErrorAction SilentlyContinue)
    $onprem = @($Config.onprem_prefixes) | Where-Object { $p = $_; -not ($routes | Where-Object { $_.AddressPrefix -contains $p -and $_.NextHopType -eq 'VirtualNetworkGateway' }) }
    Add-LzResult 'effective-routes' ($onprem ? 'Fail' : 'Pass') ($onprem ? "missing gateway routes for $($onprem -join ', ')" : "on-prem prefixes via VirtualNetworkGateway ($($routes.Count) routes)")
}

# ------------------------------------------------------------------ S3 security
Invoke-LzCheck 'kv-config' {
    $problems = foreach ($spec in @(@{ Name = $n.kv_ops; Purge = $false; Phase = 'ops' }, @{ Name = $n.kv_azl; Purge = $true; Phase = 'azl' })) {
        $kv = Get-AzKeyVault -VaultName $spec.Name -ErrorAction SilentlyContinue
        if (-not $kv) { "$($spec.Name) missing"; continue }
        if (-not $kv.EnableRbacAuthorization) { "$($spec.Name) not RBAC-only" }
        if ($kv.SoftDeleteRetentionInDays -ne [int]$Config.kv_soft_delete_days) { "$($spec.Name) soft-delete $($kv.SoftDeleteRetentionInDays)d" }
        if ([bool]$kv.EnablePurgeProtection -ne $spec.Purge) { "$($spec.Name) purge protection $($kv.EnablePurgeProtection)" }
        if (@($kv.AccessPolicies).Count -gt 0) { "$($spec.Name) has access policies" }
        $expectedPna = if ([bool]$Config.enable_private_endpoints) { [string]$Config.kv_public_network_access.($spec.Phase) } else { 'Enabled' }
        if ($kv.PublicNetworkAccess -ne $expectedPna) { "$($spec.Name) publicNetworkAccess=$($kv.PublicNetworkAccess) (phase expects $expectedPna)" }
        if ([bool]$Config.enable_private_endpoints) {
            $pep = Get-AzPrivateEndpoint -Name (($spec.Phase -eq 'ops') ? $n.pep_kv_ops : $n.pep_kv_azl) -ResourceGroupName $n.rg_sec -ErrorAction SilentlyContinue
            if ($pep.PrivateLinkServiceConnections[0].PrivateLinkServiceConnectionState.Status -ne 'Approved') { "$($spec.Name) private endpoint not Approved" }
        }
    }
    Add-LzResult 'kv-config' ($problems ? 'Fail' : 'Pass') ($problems ? ($problems -join '; ') : 'both vaults: RBAC, soft delete, purge protection, public endpoint (D-029) or PE approved, phase flag')
}
Invoke-LzCheck 'kv-rbac' {
    $ops = (Get-AzKeyVault -VaultName $n.kv_ops -ErrorAction SilentlyContinue).ResourceId
    $azl = (Get-AzKeyVault -VaultName $n.kv_azl -ErrorAction SilentlyContinue).ResourceId
    if (-not $ops -or -not $azl) { Add-LzResult 'kv-rbac' 'Fail' 'vault(s) missing'; return }
    $problems = @()
    $opsRa = @(Get-AzRoleAssignment -Scope $ops); $azlRa = @(Get-AzRoleAssignment -Scope $azl)
    $g = $Config.group_object_ids
    if (-not ($opsRa | Where-Object { $_.ObjectId -eq $g.grp_lab_operators -and $_.RoleDefinitionName -eq 'Key Vault Secrets Officer' })) { $problems += 'lab-operators not Secrets Officer on ops' }
    if (-not ($azlRa | Where-Object { $_.ObjectId -eq $g.grp_lab_operators -and $_.RoleDefinitionName -eq 'Key Vault Secrets User' })) { $problems += 'lab-operators not Secrets User on azl' }
    $id = Get-AzUserAssignedIdentity -Name $n.id_deploy -ResourceGroupName $n.rg_sec -ErrorAction SilentlyContinue
    if (-not ($opsRa | Where-Object { $_.ObjectId -eq $id.PrincipalId -and $_.RoleDefinitionName -eq 'Key Vault Secrets User' })) { $problems += 'deploy identity not Secrets User on ops' }
    $admins = @($opsRa + $azlRa | Where-Object RoleDefinitionName -EQ 'Key Vault Administrator')
    if ($admins) { $problems += "Key Vault Administrator present ($($admins.Count))" }
    Add-LzResult 'kv-rbac' ($problems ? 'Fail' : 'Pass') ($problems ? ($problems -join '; ') : 'matches keyvault-and-secrets.md §4')
}
Invoke-LzCheck 'deploy-identity' {
    $id = Get-AzUserAssignedIdentity -Name $n.id_deploy -ResourceGroupName $n.rg_sec -ErrorAction SilentlyContinue
    if (-not $id) { Add-LzResult 'deploy-identity' 'Fail' 'identity missing'; return }
    $ra = @(Get-AzRoleAssignment -ObjectId $id.PrincipalId -Scope $subScope | Where-Object Scope -EQ $subScope)
    $contrib = $ra | Where-Object RoleDefinitionName -EQ 'Contributor'
    $rbac = $ra | Where-Object RoleDefinitionName -EQ 'Role Based Access Control Administrator'
    $ok = $contrib -and $rbac -and $rbac.Condition
    Add-LzResult 'deploy-identity' ($ok ? 'Pass' : 'Fail') "Contributor=$([bool]$contrib) RBACAdmin=$([bool]$rbac) condition=$([bool]($rbac.Condition))"
}
Invoke-LzCheck 'rp-app-role' {
    $ra = @(Get-AzRoleAssignment -ObjectId $Config.azl_rp_app_object_id -ResourceGroupName $n.rg_azl -ErrorAction SilentlyContinue | Where-Object RoleDefinitionName -EQ 'Azure Connected Machine Resource Manager')
    Add-LzResult 'rp-app-role' ($ra ? 'Pass' : 'Fail') 'Azure Local RP application: Azure Connected Machine Resource Manager on the cluster resource group'
}
Invoke-LzCheck 'pim' {
    $g = $Config.group_object_ids
    $missing = foreach ($pair in @(@{ G = 'grp_lab_operators'; R = 'Owner' }, @{ G = 'grp_azl_admins'; R = 'Azure Stack HCI Administrator' }, @{ G = 'grp_azl_operators'; R = 'Azure Stack HCI VM Contributor' })) {
        $e = Get-AzRoleEligibilitySchedule -Scope $subScope -Filter "principalId eq '$($g.($pair.G))'" -ErrorAction SilentlyContinue | Where-Object { $_.RoleDefinitionDisplayName -eq $pair.R }
        if (-not $e) { "$($pair.G):$($pair.R)" }
    }
    Add-LzResult 'pim' ($missing ? 'Fail' : 'Pass') ($missing ? "missing eligibilities: $($missing -join ', ')" : 'eligible assignments exist for the three groups (test activation is manual)')
}

# ------------------------------------------------------------------ S4 / S5 / S6
Invoke-LzCheck 'law' {
    $law = Get-AzOperationalInsightsWorkspace -Name $n.law -ResourceGroupName $n.rg_mon -ErrorAction SilentlyContinue
    $ok = $law -and $law.retentionInDays -eq [int]$Config.law_retention_days -and $law.WorkspaceCapping.DailyQuotaGb -eq [double]$Config.law_daily_cap_gb
    Add-LzResult 'law' ($ok ? 'Pass' : 'Fail') "retention=$($law.retentionInDays) dailyCap=$($law.WorkspaceCapping.DailyQuotaGb)"
}
Invoke-LzCheck 'activity-log' {
    $ds = @(Get-AzDiagnosticSetting -ResourceId $subScope -ErrorAction SilentlyContinue | Where-Object Name -EQ $n.asg_activity_log)
    Add-LzResult 'activity-log' ($ds ? 'Pass' : 'Fail') "subscription diagnostic setting $($n.asg_activity_log) $($ds ? 'present' : 'missing')"
}
Invoke-LzCheck 'witness' {
    $st = Get-AzStorageAccount -Name $n.st_witness -ResourceGroupName $n.rg_azl -ErrorAction SilentlyContinue
    $problems = @()
    if (-not $st) { $problems += 'missing' } else {
        if ($st.Kind -ne 'StorageV2') { $problems += "kind=$($st.Kind)" }
        if ($st.Sku.Name -ne 'Standard_LRS') { $problems += "sku=$($st.Sku.Name)" }
        if ($st.MinimumTlsVersion -ne 'TLS1_2') { $problems += "tls=$($st.MinimumTlsVersion)" }
        if ($st.AllowSharedKeyAccess -eq $false) { $problems += 'shared key disabled' }
        if ($st.PublicNetworkAccess -ne 'Enabled') { $problems += "publicNetworkAccess=$($st.PublicNetworkAccess)" }
        if ($st.AllowBlobPublicAccess) { $problems += 'blob public access enabled' }
    }
    Add-LzResult 'witness' ($problems ? 'Fail' : 'Pass') ($problems ? ($problems -join '; ') : 'GPv2, Standard_LRS, TLS1.2, shared key on, public on, blob public off (key in vault: deploy solution step)')
}
Invoke-LzCheck 'rsv' {
    $rsv = Get-AzRecoveryServicesVault -Name $n.rsv_azl -ResourceGroupName $n.rg_bcdr -ErrorAction SilentlyContinue
    if (-not $rsv) { Add-LzResult 'rsv' 'Fail' 'vault missing'; return }
    $props = Get-AzRecoveryServicesVaultProperty -VaultId $rsv.ID -ErrorAction SilentlyContinue
    $redundancy = (Get-AzRecoveryServicesBackupProperty -Vault $rsv -ErrorAction SilentlyContinue).BackupStorageRedundancy
    $drEmpty = @(Get-AzResource -ResourceGroupName $n.rg_dr -ErrorAction SilentlyContinue).Count -eq 0
    $ok = $rsv.Identity -and $props.SoftDeleteFeatureState -ne 'Disabled' -and $redundancy -eq $Config.rsv_storage_redundancy -and $drEmpty
    Add-LzResult 'rsv' ($ok ? 'Pass' : 'Fail') "identity=$([bool]$rsv.Identity) softDelete=$($props.SoftDeleteFeatureState) redundancy=$redundancy drRgEmpty=$drEmpty"
}
Invoke-LzCheck 'idempotency' { Add-LzResult 'idempotency' 'Manual' 'Run Invoke-LzAzureLocalDeploy.ps1 (WhatIf) for both tools right after deployment and confirm "no changes" (design §11.1).' }

# ------------------------------------------------------------------ report
$script:Results | Format-Table Check, Status, Detail -AutoSize -Wrap | Out-String | Write-Information -InformationAction Continue
if ($OutputPath) { $script:Results | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding utf8 }
$failed = @($script:Results | Where-Object Status -EQ 'Fail').Count
Write-Information ("{0} check(s): {1} pass, {2} fail, {3} manual, {4} skipped" -f $script:Results.Count, @($script:Results | Where-Object Status -EQ 'Pass').Count, $failed, @($script:Results | Where-Object Status -EQ 'Manual').Count, @($script:Results | Where-Object Status -EQ 'Skipped').Count) -InformationAction Continue
$script:Results
exit $failed
