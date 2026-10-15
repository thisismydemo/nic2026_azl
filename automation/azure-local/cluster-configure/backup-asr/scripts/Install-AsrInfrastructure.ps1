#Requires -Version 7.0
<#
.SYNOPSIS
    Scripted "Prepare infrastructure" for Azure Site Recovery on Azure Local (T-5.5.3): Hyper-V site in the vault, the
    cluster identity on the vault, the ASRExtension cluster extension on every node, and the replication policy mapped
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
         replicationFabrics) for the Azure Local cluster resource's system-assigned identity, scope = the vault only:
         the extension fetches the vault credentials with the cluster identity, not the node identities.
         The vault's own identity gets Contributor and Storage Blob Data Contributor on the cache storage account
         (replication to managed disks writes there as the vault).
      3. Cluster extension asr.extension_name (cluster-aware: Azure installs it on every node; the portal does the same).
         Healthy only when aggregateState is Succeeded; a failed node registration is repaired by deleting and
         installing the extension again (the documented route; forceUpdateTag is ignored by the API).
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
$site = Invoke-Arm GET $siteId $asrApi $null
if ($site) { L "site $($asr.hyperv_site_name): exists (SiteId $($site.properties.internalIdentifier))" }
elseif (-not $Execute) { L "PLAN create Hyper-V site $($asr.hyperv_site_name) in $($asr.vault_name)" }
else {
    $null = Invoke-Arm PUT $siteId $asrApi @{ properties = @{ customDetails = @{ instanceType = 'HyperVSite' } } }
    $site = Wait-Until { $s = Invoke-Arm GET $siteId $asrApi $null; if ($s -and $s.properties.internalIdentifier) { $s } } 'Hyper-V site' 10
    L "site $($asr.hyperv_site_name): created (SiteId $($site.properties.internalIdentifier))"
}

# 2. The cluster identity on the vault. The extension's RegisterAsr.ps1 takes a token for the Azure Local CLUSTER
#    resource's system-assigned identity (Arc IMDS on the node, "Get cluster msi token") and PUTs a vault credential
#    certificate (vaults/certificates/write), so the role belongs to the cluster identity, not the node identities
#    (13 Oct 2026: AuthorizationFailed for the cluster identity while only the nodes held the role).
$cluster = Invoke-Arm GET $clusterId $hciApi $null
if (-not $cluster -or -not $cluster.PSObject.Properties['identity'] -or -not $cluster.identity.principalId) { throw "Cluster $($envy.cluster_name) has no system-assigned identity." }
$clusterPrincipal = [string]$cluster.identity.principalId
$has = Get-AzRoleAssignment -ObjectId $clusterPrincipal -Scope $vaultId -RoleDefinitionName $role -ErrorAction SilentlyContinue | Where-Object Scope -eq $vaultId
if ($has) { L "cluster $($envy.cluster_name): '$role' on the vault exists" }
elseif (-not $Execute) { L "PLAN grant '$role' on $($asr.vault_name) to the cluster identity of $($envy.cluster_name)" }
else { $null = New-AzRoleAssignment -ObjectId $clusterPrincipal -Scope $vaultId -RoleDefinitionName $role -ObjectType ServicePrincipal; L "cluster $($envy.cluster_name): '$role' on the vault granted (allow a few minutes for propagation)"; Start-Sleep -Seconds 300 }

# 2b. The vault's managed identity on the cache storage account. With managed disks Site Recovery writes replication
#     data to the cache account as the vault identity: Contributor and Storage Blob Data Contributor on a Standard
#     account (Learn: Replicate machines with private endpoints, Grant required permissions to the vault; Site Recovery
#     FAQ). Without them enable replication fails with error 28143 (seen 13 Oct 2026).
$cacheId = "/subscriptions/$sub/resourceGroups/$($asr.vault_resource_group)/providers/Microsoft.Storage/storageAccounts/$($asr.cache_storage_account)"
$vault = Invoke-Arm GET $vaultId $asrApi $null
if (-not $vault.PSObject.Properties['identity'] -or -not $vault.identity.principalId) { throw "Vault $($asr.vault_name) has no system-assigned identity (lz-azure-local enables it)." }
foreach ($cacheRole in 'Contributor', 'Storage Blob Data Contributor') {
    $has = Get-AzRoleAssignment -ObjectId ([string]$vault.identity.principalId) -Scope $cacheId -RoleDefinitionName $cacheRole -ErrorAction SilentlyContinue | Where-Object Scope -eq $cacheId
    if ($has) { L "vault identity: '$cacheRole' on $($asr.cache_storage_account) exists" }
    elseif (-not $Execute) { L "PLAN grant '$cacheRole' on $($asr.cache_storage_account) to the vault identity" }
    else { $null = New-AzRoleAssignment -ObjectId ([string]$vault.identity.principalId) -Scope $cacheId -RoleDefinitionName $cacheRole -ObjectType ServicePrincipal; L "vault identity: '$cacheRole' on $($asr.cache_storage_account) granted" }
}

# 3. Cluster extension. Healthy only when every node reports Succeeded (aggregateState). A failed node registration is
#    repaired by the documented route (Learn: Azure Arc extension management on Azure Local, Uninstall an extension):
#    delete the extension, wait until it is gone, install it again. A forceUpdateTag is ignored by this API (PUT drops
#    it, PATCH rejects it; 13 Oct 2026). The handler manifest sets rebootAfterInstall false: no node restarts.
function Write-ExtState($e) {
    L "extension ${extName}: $($e.properties.provisioningState) / aggregate $($e.properties.aggregateState)"
    foreach ($pn in @($e.properties.perNodeExtensionDetails)) { L "  $($pn.name): $($pn.state)" }
}
$settings = [ordered]@{
    SubscriptionId                      = $sub
    Environment                         = 'AzureCloud'
    ResourceGroup                       = [string]$asr.vault_resource_group
    ResourceName                        = [string]$asr.vault_name
    Location                            = [string]$shared.location
    SiteId                              = if ($site) { [string]$site.properties.internalIdentifier } else { '' }
    SiteName                            = [string]$asr.hyperv_site_name
    PolicyId                            = $policyId
    PrivateEndpointStateForSiteRecovery = 'None'
}
$ext = Invoke-Arm GET $extId $hciApi $null
$healthy = $ext -and $ext.properties.provisioningState -eq 'Succeeded' -and $ext.properties.aggregateState -eq 'Succeeded'
if ($healthy) { Write-ExtState $ext }
elseif (-not $Execute) {
    if ($ext) { Write-ExtState $ext; L "PLAN delete $extName and install it again on every node (documented repair of a failed registration)" }
    else { L "PLAN install cluster extension $extName (Microsoft.SiteRecovery.Dra/Windows) on $($envy.cluster_name): every node" }
}
elseif ($ext -and $ext.properties.provisioningState -notin 'Succeeded', 'Failed') { Write-ExtState $ext; L 'extension busy - rerun later'; return }
else {
    $params = @{ publisher = 'Microsoft.SiteRecovery.Dra'; type = 'Windows'; enableAutomaticUpgrade = $true; settings = $settings }
    if ($ext) {
        L "extension ${extName}: aggregate $($ext.properties.aggregateState) - deleting it to install it again"
        $null = Invoke-AzRestMethod -Method DELETE -Path "$($extId)?api-version=$hciApi"
        $null = Wait-Until { if (-not (Invoke-Arm GET $extId $hciApi $null)) { $true } } "extension $extName deleted" 30
        L "extension ${extName}: deleted"
    }
    L "extension ${extName}: installing on every node"
    $null = Invoke-Arm PUT $extId $hciApi @{ properties = @{ extensionParameters = $params } }
    Start-Sleep -Seconds 60
    $ext = Wait-Until {
        $e = Invoke-Arm GET $extId $hciApi $null
        if ($e -and $e.properties.provisioningState -in 'Succeeded', 'Failed', 'Canceled' -and $e.properties.aggregateState -in 'Succeeded', 'Failed', 'PartiallySucceeded', 'Canceled') { $e }
    } "extension $extName" $WaitMinutes
    Write-ExtState $ext
    if ($ext.properties.aggregateState -ne 'Succeeded') { throw "Extension $extName did not succeed on every node; read RegisterLog_*.log under C:\ProgramData\GuestConfig\extension_logs\Microsoft.SiteRecovery.Dra.Windows on the node." }
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
