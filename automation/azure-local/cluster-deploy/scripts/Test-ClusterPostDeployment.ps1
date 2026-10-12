#Requires -Version 7.0
<#
.SYNOPSIS
    READ-ONLY post-deployment validation of the Azure Local instance (outline §2.6 "the green board"): nodes Up,
    cloud witness, S2D health, Network ATC intents Success, Arc Resource Bridge Running, custom location, Arc extensions,
    Local Identity facts (WORKGROUP, ADAware = 2), deployment secrets backed up to the cluster vault (names only).
.DESCRIPTION
    Azure-side checks use Az.* read cmdlets and GET calls. Node-side checks run through Invoke-Command (WinRM from the
    jump server over the management VLAN) with the local administrator credential resolved IN MEMORY from the ops vault
    (identity.local_admin_*_secret references); pass -SkipNodeChecks to run only the Azure side. Emits {check, result,
    evidence} objects and optionally a JSON file; changes nothing.
.PARAMETER InputFile
    terraform.generated.tfvars.json (or the example file for a dry run).
.PARAMETER OutputJson
    Optional path for the JSON result (Test-Day2Readiness-compatible shape: check, result, evidence, checkedAt).
.PARAMETER SkipNodeChecks
    Do not open WinRM sessions to the nodes.
.EXAMPLE
    .\Test-ClusterPostDeployment.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -OutputJson .\post-deployment.json
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$OutputJson,
    [switch]$SkipNodeChecks
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')

[void](Import-ClusterDeployAutomationModule)
$inputs = Get-ClusterDeployInputs -InputFile $InputFile
Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
$sub = [string]$inputs.subscription_id
$rg = [string]$inputs.names.rg_azl
$clusterName = [string]$inputs.cluster_name
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-PostCheck {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Test, [switch]$Skip, [string]$SkipReason)
    if ($Skip) { $results.Add((ConvertTo-ClusterDeployResult -Check $Name -Result 'skip' -Evidence $SkipReason)); return }
    try { $evidence = & $Test; $results.Add((ConvertTo-ClusterDeployResult -Check $Name -Result 'pass' -Evidence "$evidence")) }
    catch { $results.Add((ConvertTo-ClusterDeployResult -Check $Name -Result 'fail' -Evidence $_.Exception.Message)) }
}
function Assert-Post { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Get-AzlResource {
    param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-AzRestMethod -Path $Path -Method GET
    if ($r.StatusCode -ge 400) { throw "GET $Path -> HTTP $($r.StatusCode)" }
    return ($r.Content | ConvertFrom-Json -Depth 50)
}

# --- Azure side ---------------------------------------------------------------------------------------------------
Invoke-PostCheck -Name 'cluster resource provisioned and connected' -Test {
    $c = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI/clusters/${clusterName}?api-version=2025-09-15-preview"
    Assert-Post ($c.properties.provisioningState -eq 'Succeeded') "provisioningState=$($c.properties.provisioningState)"
    Assert-Post ($c.properties.status -in 'ConnectedRecently', 'Connected') "status=$($c.properties.status)"
    # The cluster version is reported under properties.reportedProperties (T-5.3.13); properties.clusterVersion is absent.
    $version = if ($c.properties.PSObject.Properties.Name -contains 'reportedProperties' -and $c.properties.reportedProperties.PSObject.Properties.Name -contains 'clusterVersion') { $c.properties.reportedProperties.clusterVersion } else { 'not reported' }
    Assert-Post ($version -ne 'not reported') 'reportedProperties.clusterVersion not reported'
    "status=$($c.properties.status); version=$version"
}
Invoke-PostCheck -Name 'deployment settings: Deploy pass Success' -Test {
    $s = Get-ClusterDeploymentSettingsState -SubscriptionId $sub -ResourceGroupName $rg -ClusterName $clusterName
    Assert-Post $s.Exists 'deploymentSettings/default not found'
    Assert-Post ($s.DeploymentStatus -eq 'Success') "deploymentStatus=$($s.DeploymentStatus) validation=$($s.ValidationStatus)"
    "validation=$($s.ValidationStatus); deployment=$($s.DeploymentStatus); steps=$($s.Steps.Count)"
}
Invoke-PostCheck -Name 'Local Identity: identityProvider = LocalIdentity in deployment settings' -Test {
    $d = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI/clusters/$clusterName/deploymentSettings/default?api-version=2025-09-15-preview"
    $ip = $d.properties.deploymentConfiguration.scaleUnits[0].deploymentData.identityProvider
    Assert-Post ($ip -eq 'LocalIdentity') "identityProvider=$ip"; "identityProvider=$ip"
}
Invoke-PostCheck -Name 'Arc machines connected (all configured nodes)' -Test {
    $bad = @()
    foreach ($n in $inputs.nodes) {
        $m = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$(Get-ClusterDeployArcMachineName -Node $n -Inputs $inputs)?api-version=2024-07-10"
        if ($m.properties.status -ne 'Connected') { $bad += "$($n.name)=$($m.properties.status)" }
    }
    Assert-Post ($bad.Count -eq 0) ($bad -join ', '); "$($inputs.nodes.Count) node(s) Connected"
}
Invoke-PostCheck -Name 'Arc extensions on every node (incl. AzureEdgeAKVBackupForWindows)' -Test {
    $required = 'AzureEdgeAKVBackupForWindows', 'AzureEdgeLifecycleManager', 'AzureEdgeDeviceManagement', 'AzureEdgeTelemetryAndDiagnostics'
    $problems = @()
    foreach ($n in $inputs.nodes) {
        $ext = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$(Get-ClusterDeployArcMachineName -Node $n -Inputs $inputs)/extensions?api-version=2024-07-10"
        $names = @($ext.value | ForEach-Object { $_.name })
        foreach ($req in $required) { if ($names -notcontains $req) { $problems += "$($n.name) missing $req" } }
        $failed = @($ext.value | Where-Object { $_.properties.provisioningState -ne 'Succeeded' } | ForEach-Object { "$($n.name)/$($_.name)=$($_.properties.provisioningState)" })
        $problems += $failed
    }
    Assert-Post ($problems.Count -eq 0) ($problems -join '; '); "required extensions present and Succeeded on $($inputs.nodes.Count) node(s)"
}
Invoke-PostCheck -Name 'custom location present' -Test {
    $cl = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ExtendedLocation/customLocations/$($inputs.names.cl_azl)?api-version=2021-08-15"
    Assert-Post ($cl.properties.provisioningState -eq 'Succeeded') "provisioningState=$($cl.properties.provisioningState)"; "$($cl.name): $($cl.properties.provisioningState)"
}
Invoke-PostCheck -Name 'Arc Resource Bridge appliance Running' -Test {
    $list = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ResourceConnector/appliances?api-version=2022-10-27"
    $arb = @($list.value)
    Assert-Post ($arb.Count -ge 1) 'no Microsoft.ResourceConnector/appliances in the cluster resource group'
    $running = @($arb | Where-Object { $_.properties.status -eq 'Running' })
    Assert-Post ($running.Count -ge 1) ("status: " + (($arb | ForEach-Object { "$($_.name)=$($_.properties.status)" }) -join ', '))
    ($running | ForEach-Object { "$($_.name)=Running" }) -join ', '
}
Invoke-PostCheck -Name 'cloud witness storage account present (GPv2, Standard_LRS)' -Test {
    $sa = Get-AzStorageAccount -ResourceGroupName $rg -Name $inputs.witness.storage_account_name
    Assert-Post ($sa.Kind -eq 'StorageV2' -and $sa.Sku.Name -eq 'Standard_LRS') "kind=$($sa.Kind) sku=$($sa.Sku.Name)"; "$($sa.StorageAccountName): $($sa.Kind)/$($sa.Sku.Name)"
}
Invoke-PostCheck -Name 'cluster vault: deployment secrets and backed-up secrets present (names only)' -Test {
    $all = @(Get-AzKeyVaultSecret -VaultName $inputs.kv_azl_name | Select-Object -ExpandProperty Name)
    $eceNames = Get-ClusterDeploySecretName -Inputs $inputs
    $ece = @($eceNames.LocalAdmin, $eceNames.WitnessKey) | Where-Object { $all -contains $_ }
    $backup = @($all | Where-Object { $_ -notin $eceNames.LocalAdmin, $eceNames.WitnessKey })
    Assert-Post ($ece.Count -eq 2) "ECE secrets present: $($ece -join ',')"
    Assert-Post ($backup.Count -ge 1) 'no backed-up secrets (BitLocker / RecoveryAdmin) found yet - the Key Vault backup extension writes them after deployment'
    "ece=$($ece.Count); backed-up secret names=$($backup.Count)"
}
Invoke-PostCheck -Name 'cluster vault: node identities hold Secrets Officer + Certificates Officer (vault scope only)' -Test {
    $kv = Get-AzKeyVault -VaultName $inputs.kv_azl_name
    $ra = @(Get-AzRoleAssignment -Scope $kv.ResourceId | Where-Object { $_.Scope -eq $kv.ResourceId })
    $missing = @()
    foreach ($n in $inputs.nodes) {
        $m = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$(Get-ClusterDeployArcMachineName -Node $n -Inputs $inputs)?api-version=2024-07-10"
        foreach ($role in 'Key Vault Secrets Officer', 'Key Vault Certificates Officer') {
            if (-not ($ra | Where-Object { $_.ObjectId -eq $m.identity.principalId -and $_.RoleDefinitionName -eq $role })) { $missing += "$($n.name):$role" }
        }
    }
    Assert-Post ($missing.Count -eq 0) ($missing -join ', '); 'both roles present for every node identity'
}

# --- Node side (WinRM) ----------------------------------------------------------------------------------------------
$session = $null
if (-not $SkipNodeChecks) {
    try {
        if (-not $IsWindows) { throw 'node checks need the Windows jump server (credential handling, WinRM)' }
        $user = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_username_secret -AsPlainText
        $pass = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_password_secret
        $cred = [pscredential]::new($user, $pass)
        $seed = [string]$inputs.nodes[0].management_ip
        $session = New-PSSession -ComputerName $seed -Credential $cred -Authentication Negotiate -ErrorAction Stop
        Remove-Variable -Name user, pass, cred -ErrorAction SilentlyContinue
    }
    catch {
        $results.Add((ConvertTo-ClusterDeployResult -Check 'node session' -Result 'skip' -Evidence "no WinRM session: $($_.Exception.Message)"))
        $session = $null
    }
}
$nodeSkip = ($SkipNodeChecks -or -not $session)
$nodeSkipReason = if ($SkipNodeChecks) { '-SkipNodeChecks' } else { 'no node session' }

Invoke-PostCheck -Name 'nodes Up (Get-ClusterNode)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    # State is converted to its name ON THE NODE: over remoting the ClusterNodeState enum arrives as its number (Up = 0).
    $n = Invoke-Command -Session $session -ScriptBlock { Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = $_.State.ToString() } } }
    $down = @($n | Where-Object { $_.State -ne 'Up' }); Assert-Post ($down.Count -eq 0) (($down | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ','); ($n | ForEach-Object { "$($_.Name)=Up" }) -join ','
}
Invoke-PostCheck -Name 'cloud witness online (Get-ClusterQuorum)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    # ClusterResourceState is converted on the node as well (Online = 2 over remoting).
    $q = Invoke-Command -Session $session -ScriptBlock { $w = (Get-ClusterQuorum).QuorumResource; [pscustomobject]@{ Name = $w.Name; State = $w.State.ToString(); Type = $w.ResourceType.Name } }
    Assert-Post ($q.Type -eq 'Cloud Witness' -and $q.State -eq 'Online') "witness=$($q.Type) state=$($q.State)"; "$($q.Name): $($q.State)"
}
Invoke-PostCheck -Name 'storage healthy (pool, virtual disks, storage faults)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    # The clustered subsystem also turns Warning for non-storage faults such as Microsoft.Health.FaultType.Cluster.UpdateAvailable
    # (a solution update is offered; updates stay manual). Judge storage on the pool, the virtual disks and the storage faults only.
    $s = Invoke-Command -Session $session -ScriptBlock {
        $faults = @(Get-HealthFault -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.FaultType })
        [pscustomobject]@{
            Pool   = @(Get-StoragePool -IsPrimordial $false | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" })
            Disks  = @(Get-VirtualDisk | Where-Object { [string]$_.HealthStatus -ne 'Healthy' } | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)" })
            Faults = $faults
        }
    }
    $other = @($s.Faults | Where-Object { $_ -ne 'Microsoft.Health.FaultType.Cluster.UpdateAvailable' })
    $badPool = @($s.Pool | Where-Object { $_ -notlike '*=Healthy' })
    Assert-Post ($badPool.Count -eq 0 -and $s.Disks.Count -eq 0 -and $other.Count -eq 0) "pool=$($s.Pool -join ',') unhealthyDisks=$($s.Disks -join ',') faults=$($other -join ',')"
    "pool=$($s.Pool -join ','); unhealthy virtual disks=0; storage faults=0; other faults=$(@($s.Faults).Count - $other.Count) (UpdateAvailable)"
}
Invoke-PostCheck -Name 'Network ATC intents Success (Get-NetIntentStatus)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $i = Invoke-Command -Session $session -ScriptBlock { Get-NetIntentStatus | Select-Object IntentName, Host, ConfigurationStatus, ProvisioningStatus }
    $bad = @($i | Where-Object { $_.ConfigurationStatus -ne 'Success' -or $_.ProvisioningStatus -ne 'Completed' })
    Assert-Post ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.IntentName)@$($_.Host)=$($_.ConfigurationStatus)/$($_.ProvisioningStatus)" }) -join ','); "$(@($i).Count) intent/host rows Success"
}
Invoke-PostCheck -Name 'RDMA on storage adapters only; jumbo 9014 on storage' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $storageAdapters = @(($inputs.intents | Where-Object { $_.traffic_types -contains 'Storage' }).adapters)
    $allAdapters = @($inputs.intents | ForEach-Object { $_.adapters })
    $r = Invoke-Command -Session $session -ArgumentList (, $allAdapters) -ScriptBlock {
        param($aa)
        $rdma = Get-NetAdapterRdma | Where-Object Enabled | Select-Object -ExpandProperty Name
        $jumbo = Get-NetAdapterAdvancedProperty -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue | Where-Object { $aa -contains $_.Name } | Select-Object Name, RegistryValue
        [pscustomobject]@{ Rdma = @($rdma); Jumbo = @($jumbo) }
    }
    $unexpected = @($r.Rdma | Where-Object { $storageAdapters -notcontains $_ -and $_ -notlike 'vSMB*' -and $_ -notlike 'vEthernet*' })
    Assert-Post ($unexpected.Count -eq 0) "RDMA enabled outside storage: $($unexpected -join ',')"
    $missing = @($storageAdapters | Where-Object { $r.Rdma -notcontains $_ })
    Assert-Post ($missing.Count -eq 0) "RDMA not enabled on storage adapter(s): $($missing -join ',')"
    # Jumbo per intent: the intent's override (default 1514) on every adapter of that intent (GPT review, 10 Oct).
    $wrong = foreach ($i in $inputs.intents) {
        $want = if ($i.overrides -and $i.overrides.jumbo_packet) { [string]$i.overrides.jumbo_packet } else { '1514' }
        foreach ($a in $i.adapters) { $have = [string](@($r.Jumbo | Where-Object Name -eq $a | Select-Object -ExpandProperty RegistryValue) -join ''); if ($have -ne $want) { "$a=$have (want $want)" } }
    }
    Assert-Post (@($wrong).Count -eq 0) "jumbo mismatch: $(@($wrong) -join ',')"
    "rdma=$($r.Rdma -join ','); jumbo=$(($r.Jumbo | ForEach-Object { "$($_.Name)=$($_.RegistryValue -join '')" }) -join ',')"
}
Invoke-PostCheck -Name 'Local Identity: node in WORKGROUP and ADAware = 2' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $li = Invoke-Command -Session $session -ScriptBlock { [pscustomobject]@{ Domain = (Get-CimInstance Win32_ComputerSystem).Domain; ADAware = (Get-ClusterResource 'Cluster Name' | Get-ClusterParameter ADAware).Value } }
    Assert-Post ($li.Domain -eq 'WORKGROUP' -and [int]$li.ADAware -eq 2) "domain=$($li.Domain) ADAware=$($li.ADAware)"; "WORKGROUP; ADAware=2 (Local Identity)"
}
Invoke-PostCheck -Name 'live migration bound to storage networks (R-03 verification)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $lm = Invoke-Command -Session $session -ScriptBlock { [pscustomobject]@{ Max = (Get-VMHost).MaximumVirtualMachineMigrations; Nets = @(Get-VMMigrationNetwork | Select-Object -ExpandProperty Subnet) } }
    # Every migration subnet must be a storage subnet (keeps live migration off the 1 Gb management path, design §6.3).
    $storageSubnets = @('storage_a', 'storage_b' | ForEach-Object { $inputs.vlans.$_.subnet } | Where-Object { $_ })
    $offStorage = @($lm.Nets | Where-Object { $storageSubnets -notcontains $_ })
    Assert-Post ($lm.Nets.Count -gt 0 -and $offStorage.Count -eq 0) "migration subnets not limited to storage ($($storageSubnets -join ',')): $($lm.Nets -join ',')"
    "MaximumVirtualMachineMigrations=$($lm.Max); migration subnets=$($lm.Nets -join ',')"
}
if ($session) { Remove-PSSession -Session $session }

$summary = [pscustomobject]@{ pass = @($results | Where-Object { $_.result -eq 'pass' }).Count; fail = @($results | Where-Object { $_.result -eq 'fail' }).Count; skip = @($results | Where-Object { $_.result -eq 'skip' }).Count }
$results | Format-Table check, result, evidence -AutoSize -Wrap | Out-String -Width 200 | Write-Information -InformationAction Continue
Write-ClusterDeployLog -Message "post-deployment: pass=$($summary.pass) fail=$($summary.fail) skip=$($summary.skip)"
if ($OutputJson) { [pscustomobject]@{ solution = 'cluster-deploy'; cluster = $clusterName; summary = $summary; checks = $results } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding utf8NoBOM }
return $results
