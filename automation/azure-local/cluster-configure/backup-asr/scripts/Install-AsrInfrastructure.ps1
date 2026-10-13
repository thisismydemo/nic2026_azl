#Requires -Version 7.0
<#
.SYNOPSIS
    Scripted "Prepare infrastructure" for Azure Site Recovery on Azure Local (T-5.5.3): Hyper-V site in the vault, the
    node identities on the vault, the ASRExtension cluster extension on every node, and the replication policy mapped
    to the site. Preview by default; -Execute changes Azure and installs the agent on the nodes.
.DESCRIPTION
    Microsoft documents two routes to the same result: the portal (Azure Local resource > Capabilities > Disaster recovery
    > Prepare infrastructure) and the cluster extension by CLI/PowerShell (Learn: "Azure Arc extension management on Azure
    Local", Install an extension, Azure Site Recovery: publisher Microsoft.SiteRecovery.Dra, type Windows, settings
    SubscriptionId, Environment, ResourceGroup, ResourceName, Location, SiteId, SiteName, PolicyId,
    PrivateEndpointStateForSiteRecovery). Learn "Protect VM workloads with Azure Site Recovery on Azure Local" step 1
    lists what the portal does: vault and policy (pre-created here by lz-azure-local and backup-asr Apply), an agent
    downloaded on each node, the node's managed identity fetching the vault registration key, the policy associated with
    the Hyper-V site and the hosts registered. This script does the same, in order, idempotently:
      0. Vault extended information (integrity key) when missing, as the portal creates it on first use.
      1. Hyper-V site (replicationFabrics, instanceType HyperVSite); its internalIdentifier is the extension's SiteId.
      2. Role asr.node_vault_role (default Site Recovery Contributor: vault certificates/write, extendedInformation,
         replicationFabrics) for each node's Arc system-assigned identity, scope = the vault only.
      3. Cluster extension asr.extension_name (cluster-aware: Azure installs it on every node; the portal does the same).
         Learn documents no node restart for this install; run Get-AsrNodeState.ps1 before (no pending reboot) and after
         (LastBootUpTime unchanged).
      4. Wait until every node is a Connected provider in the site, then map the replication policy to the site's
         protection container (target "Microsoft Azure") when no mapping uses it yet.
    Values: environment/azure-local/environment.yml (subscription_id, cluster_name, vm_management.resource_group, nodes,
    asr.*) and environment/shared/environment.yml (tenant_id, location). No secret is read or written.
.PARAMETER WaitMinutes
    How long to wait for the extension and the node registration.
.EXAMPLE
    .\Install-AsrInfrastructure.ps1             # plan only
    .\Install-AsrInfrastructure.ps1 -Execute    # prepare
#>
[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\shared\environment.yml'),
    [ValidateRange(5, 180)][int]$WaitMinutes = 60,
    [switch]$Execute,
    [string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml

$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$asr = $envy.asr
$sub = [string]$envy.subscription_id
$null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription $sub -Scope Process -WhatIf:$false

$asrApi = '2024-04-01'
$hciApi = '2024-04-01'
$vaultId = "/subscriptions/$sub/resourceGroups/$($asr.vault_resource_group)/providers/Microsoft.RecoveryServices/vaults/$($asr.vault_name)"
$siteId = "$vaultId/replicationFabrics/$($asr.hyperv_site_name)"
$policyId = "$vaultId/replicationPolicies/$($asr.replication_policy_name)"
$clusterId = "/subscriptions/$sub/resourceGroups/$($envy.vm_management.resource_group)/providers/Microsoft.AzureStackHCI/clusters/$($envy.cluster_name)"
$extName = if ($asr.ContainsKey('extension_name') -and $asr.extension_name) { [string]$asr.extension_name } else { 'ASRExtension' }
$extId = "$clusterId/arcSettings/default/extensions/$extName"
$role = if ($asr.ContainsKey('node_vault_role') -and $asr.node_vault_role) { [string]$asr.node_vault_role } else { 'Site Recovery Contributor' }

function L([string]$m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }
function Invoke-Arm([string]$Method, [string]$Path, [string]$Api, $Body) {
    $p = @{ Method = $Method; Path = "$Path$(if ($Path.Contains('?')) { '&' } else { '?' })api-version=$Api" }
    if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    $r = Invoke-AzRestMethod @p
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 300) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
    if ($r.Content) { return ($r.Content | ConvertFrom-Json -Depth 30) } else { return [pscustomobject]@{} }
}
function Wait-Until([scriptblock]$Test, [string]$What, [int]$Minutes) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while ($true) {
        $v = & $Test
        if ($v) { return $v }
        if ((Get-Date) -ge $deadline) { throw "Timed out after $Minutes min waiting for: $What" }
        Start-Sleep -Seconds 30
    }
}

if (-not (Invoke-Arm GET $vaultId $asrApi $null)) { throw "Vault $($asr.vault_name) not found (lz-azure-local creates it)." }
if (-not (Invoke-Arm GET $policyId $asrApi $null)) { throw "Replication policy $($asr.replication_policy_name) not found (Invoke-BackupAsrConfigure.ps1 -Action Apply creates it)." }

# 0. Vault extended information (channel integrity key). The portal creates it on the first Site Recovery visit; the
#    Az.RecoveryServices vault-context cmdlet fails with a null reference while it is missing (seen 13 Oct 2026). The
#    key is generated in memory and never printed.
$extInfoId = "$vaultId/extendedInformation/vaultExtendedInfo"
if (Invoke-Arm GET $extInfoId $asrApi $null) { L 'vault extended information: exists' }
elseif (-not $Execute) { L 'PLAN create the vault extended information (channel integrity key, as the portal does)' }
else {
    $bytes = [byte[]]::new(128); [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $null = Invoke-Arm PUT $extInfoId $asrApi @{ properties = @{ algorithm = 'None'; integrityKey = [Convert]::ToBase64String($bytes) } }
    $bytes = $null
    L 'vault extended information: created'
}

# 1. Hyper-V site
$site =Invoke-Arm GET $siteId $asrApi $null
if ($site) { L "site $($asr.hyperv_site_name): exists (SiteId $($site.properties.internalIdentifier))" }
elseif (-not $Execute) { L "PLAN create Hyper-V site $($asr.hyperv_site_name) in $($asr.vault_name)" }
else {
    $null = Invoke-Arm PUT $siteId $asrApi @{ properties = @{ customDetails = @{ instanceType = 'HyperVSite' } } }
    $site = Wait-Until { $s = Invoke-Arm GET $siteId $asrApi $null; if ($s -and $s.properties.internalIdentifier) { $s } } 'Hyper-V site' 10
    L "site $($asr.hyperv_site_name): created (SiteId $($site.properties.internalIdentifier))"
}

# 2. Node identities on the vault
foreach ($node in @($envy.nodes)) {
    $m = Invoke-Arm GET "/subscriptions/$sub/resourceGroups/$($envy.vm_management.resource_group)/providers/Microsoft.HybridCompute/machines/$($node.name)" '2024-07-10' $null
    if (-not $m -or -not $m.identity.principalId) { throw "Arc machine $($node.name) has no system-assigned identity." }
    $pid_ = [string]$m.identity.principalId
    $has = Get-AzRoleAssignment -ObjectId $pid_ -Scope $vaultId -RoleDefinitionName $role -ErrorAction SilentlyContinue | Where-Object Scope -eq $vaultId
    if ($has) { L "$($node.name): '$role' on the vault exists" }
    elseif (-not $Execute) { L "PLAN grant '$role' on $($asr.vault_name) to $($node.name) (Arc identity)" }
    else { $null = New-AzRoleAssignment -ObjectId $pid_ -Scope $vaultId -RoleDefinitionName $role -ObjectType ServicePrincipal; L "$($node.name): '$role' on the vault granted" }
}

# 3. Cluster extension
$ext = Invoke-Arm GET $extId $hciApi $null
if ($ext -and $ext.properties.provisioningState -eq 'Succeeded') { L "extension ${extName}: $($ext.properties.provisioningState) / $($ext.properties.aggregateState)" }
elseif (-not $Execute) { L "PLAN install cluster extension $extName (Microsoft.SiteRecovery.Dra/Windows) on $($envy.cluster_name): every node" }
elseif ($ext) { L "extension ${extName}: present in state '$($ext.properties.provisioningState)' - left for an operator decision"; return }
else {
    $settings = [ordered]@{
        SubscriptionId                      = $sub
        Environment                         = 'AzureCloud'
        ResourceGroup                       = [string]$asr.vault_resource_group
        ResourceName                        = [string]$asr.vault_name
        Location                            = [string]$shared.location
        SiteId                              = [string]$site.properties.internalIdentifier
        SiteName                            = [string]$asr.hyperv_site_name
        PolicyId                            = $policyId
        PrivateEndpointStateForSiteRecovery = 'None'
    }
    $body = @{ properties = @{ extensionParameters = @{ publisher = 'Microsoft.SiteRecovery.Dra'; type = 'Windows'; enableAutomaticUpgrade = $true; settings = $settings } } }
    L "extension ${extName}: installing on every node"
    $null = Invoke-Arm PUT $extId $hciApi $body
    $ext = Wait-Until {
        $e = Invoke-Arm GET $extId $hciApi $null
        if ($e -and $e.properties.provisioningState -in 'Succeeded', 'Failed', 'Canceled') { $e }
    } "extension $extName" $WaitMinutes
    L "extension ${extName}: $($ext.properties.provisioningState) / $($ext.properties.aggregateState)"
    foreach ($pn in @($ext.properties.perNodeExtensionDetails)) { L "  $($pn.name): $($pn.state) $($pn.instanceView.status.message)" }
    if ($ext.properties.provisioningState -ne 'Succeeded') { throw "Extension $extName did not succeed." }
}
if (-not $Execute) { return }

# 4. Node registration, then the policy mapped to the site's container
$nodeNames = @($envy.nodes | ForEach-Object { [string]$_.name })
$providers = Wait-Until {
    $p = Invoke-Arm GET "$siteId/replicationRecoveryServicesProviders" $asrApi $null
    $ok = @($p.value | Where-Object { $_.properties.connectionStatus -eq 'Connected' })
    if (@($nodeNames | Where-Object { $n = $_; -not ($ok | Where-Object { $_.properties.friendlyName -like "$n*" }) }).Count -eq 0) { $ok }
} 'every node Connected in the Hyper-V site' $WaitMinutes
foreach ($pv in $providers) { L "provider $($pv.properties.friendlyName): $($pv.properties.connectionStatus), version $($pv.properties.providerVersion)" }

$containers = Wait-Until { $c = Invoke-Arm GET "$siteId/replicationProtectionContainers" $asrApi $null; if (@($c.value).Count -gt 0) { @($c.value) } } 'protection container' 15
$container = $containers[0]
$maps = Invoke-Arm GET "$($container.id)/replicationProtectionContainerMappings" $asrApi $null
$map = @($maps.value | Where-Object { $_.properties.policyId -eq $policyId -or $_.properties.policyFriendlyName -eq $asr.replication_policy_name }) | Select-Object -First 1
if ($map) { L "mapping $($map.name): policy $($asr.replication_policy_name) -> $($map.properties.targetProtectionContainerId) ($($map.properties.state))" }
else {
    $mapName = "map-$($asr.replication_policy_name)"
    $null = Invoke-Arm PUT "$($container.id)/replicationProtectionContainerMappings/$mapName" $asrApi @{ properties = @{ policyId = $policyId; targetProtectionContainerId = 'Microsoft Azure'; providerSpecificInput = @{} } }
    $map = Wait-Until { $x = Invoke-Arm GET "$($container.id)/replicationProtectionContainerMappings/$mapName" $asrApi $null; if ($x -and $x.properties.state -eq 'Paired') { $x } } 'container mapping Paired' 15
    L "mapping ${mapName}: policy $($asr.replication_policy_name) -> Microsoft Azure ($($map.properties.state))"
}
