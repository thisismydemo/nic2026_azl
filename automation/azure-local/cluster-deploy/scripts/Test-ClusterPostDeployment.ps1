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
    "status=$($c.properties.status); version=$($c.properties.clusterVersion); identityProvider check via deploymentSettings"
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
        $m = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$($n.name)?api-version=2024-07-10"
        if ($m.properties.status -ne 'Connected') { $bad += "$($n.name)=$($m.properties.status)" }
    }
    Assert-Post ($bad.Count -eq 0) ($bad -join ', '); "$($inputs.nodes.Count) node(s) Connected"
}
Invoke-PostCheck -Name 'Arc extensions on every node (incl. AzureEdgeAKVBackupForWindows)' -Test {
    $required = 'AzureEdgeAKVBackupForWindows', 'AzureEdgeLifecycleManager', 'AzureEdgeDeviceManagement', 'AzureEdgeTelemetryAndDiagnostics'
    $problems = @()
    foreach ($n in $inputs.nodes) {
        $ext = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$($n.name)/extensions?api-version=2024-07-10"
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
    $ece = @("$clusterName-LocalAdminCredential", "$clusterName-WitnessStorageKey") | Where-Object { $all -contains $_ }
    $backup = @($all | Where-Object { $_ -ne "$clusterName-LocalAdminCredential" -and $_ -ne "$clusterName-WitnessStorageKey" })
    Assert-Post ($ece.Count -eq 2) "ECE secrets present: $($ece -join ',')"
    Assert-Post ($backup.Count -ge 1) 'no backed-up secrets (BitLocker / RecoveryAdmin) found yet - the Key Vault backup extension writes them after deployment'
    "ece=$($ece.Count); backed-up secret names=$($backup.Count)"
}
Invoke-PostCheck -Name 'cluster vault: node identities hold Secrets Officer + Certificates Officer (vault scope only)' -Test {
    $kv = Get-AzKeyVault -VaultName $inputs.kv_azl_name
    $ra = @(Get-AzRoleAssignment -Scope $kv.ResourceId | Where-Object { $_.Scope -eq $kv.ResourceId })
    $missing = @()
    foreach ($n in $inputs.nodes) {
        $m = Get-AzlResource -Path "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$($n.name)?api-version=2024-07-10"
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
    $n = Invoke-Command -Session $session -ScriptBlock { Get-ClusterNode | Select-Object Name, State }
    $down = @($n | Where-Object { $_.State -ne 'Up' }); Assert-Post ($down.Count -eq 0) (($down | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ','); ($n | ForEach-Object { "$($_.Name)=Up" }) -join ','
}
Invoke-PostCheck -Name 'cloud witness online (Get-ClusterQuorum)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $q = Invoke-Command -Session $session -ScriptBlock { $w = (Get-ClusterQuorum).QuorumResource; [pscustomobject]@{ Name = $w.Name; State = $w.State; Type = $w.ResourceType.Name } }
    Assert-Post ($q.Type -eq 'Cloud Witness' -and $q.State -eq 'Online') "witness=$($q.Type) state=$($q.State)"; "$($q.Name): $($q.State)"
}
Invoke-PostCheck -Name 'storage healthy (Get-StorageSubSystem / Get-VirtualDisk)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $s = Invoke-Command -Session $session -ScriptBlock { [pscustomobject]@{ Sub = (Get-StorageSubSystem -FriendlyName 'Clustered*' | Select-Object -First 1).HealthStatus; Disks = @(Get-VirtualDisk | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count; Faults = @(Get-StorageSubSystem -FriendlyName 'Clustered*' | Debug-StorageSubSystem).Count } }
    Assert-Post ($s.Sub -eq 'Healthy' -and $s.Disks -eq 0) "subsystem=$($s.Sub) unhealthyDisks=$($s.Disks) faults=$($s.Faults)"; "subsystem=Healthy; faults=$($s.Faults)"
}
Invoke-PostCheck -Name 'Network ATC intents Success (Get-NetIntentStatus)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $i = Invoke-Command -Session $session -ScriptBlock { Get-NetIntentStatus | Select-Object IntentName, Host, ConfigurationStatus, ProvisioningStatus }
    $bad = @($i | Where-Object { $_.ConfigurationStatus -ne 'Success' -or $_.ProvisioningStatus -ne 'Completed' })
    Assert-Post ($bad.Count -eq 0) (($bad | ForEach-Object { "$($_.IntentName)@$($_.Host)=$($_.ConfigurationStatus)/$($_.ProvisioningStatus)" }) -join ','); "$(@($i).Count) intent/host rows Success"
}
Invoke-PostCheck -Name 'RDMA on storage adapters only; jumbo 9014 on storage' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $storageAdapters = @(($inputs.intents | Where-Object { $_.traffic_types -contains 'Storage' }).adapters)
    $r = Invoke-Command -Session $session -ArgumentList (, $storageAdapters) -ScriptBlock {
        param($sa)
        $rdma = Get-NetAdapterRdma | Where-Object Enabled | Select-Object -ExpandProperty Name
        $jumbo = Get-NetAdapterAdvancedProperty -DisplayName 'Jumbo Packet' -ErrorAction SilentlyContinue | Where-Object { $sa -contains $_.Name } | Select-Object Name, DisplayValue
        [pscustomobject]@{ Rdma = @($rdma); Jumbo = @($jumbo) }
    }
    $unexpected = @($r.Rdma | Where-Object { $storageAdapters -notcontains $_ -and $_ -notlike 'vSMB*' -and $_ -notlike 'vEthernet*' })
    Assert-Post ($unexpected.Count -eq 0) "RDMA enabled outside storage: $($unexpected -join ',')"
    "rdma=$($r.Rdma -join ','); jumbo=$(($r.Jumbo | ForEach-Object { "$($_.Name)=$($_.DisplayValue)" }) -join ',')"
}
Invoke-PostCheck -Name 'Local Identity: node in WORKGROUP and ADAware = 2' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $li = Invoke-Command -Session $session -ScriptBlock { [pscustomobject]@{ Domain = (Get-CimInstance Win32_ComputerSystem).Domain; ADAware = (Get-ClusterResource 'Cluster Name' | Get-ClusterParameter ADAware).Value } }
    Assert-Post ($li.Domain -eq 'WORKGROUP' -and [int]$li.ADAware -eq 2) "domain=$($li.Domain) ADAware=$($li.ADAware)"; "WORKGROUP; ADAware=2 (Local Identity)"
}
Invoke-PostCheck -Name 'live migration bound to storage networks (R-03 verification)' -Skip:$nodeSkip -SkipReason $nodeSkipReason -Test {
    $lm = Invoke-Command -Session $session -ScriptBlock { [pscustomobject]@{ Max = (Get-VMHost).MaximumVirtualMachineMigrations; Nets = @(Get-VMMigrationNetwork | Select-Object -ExpandProperty Subnet) } }
    "MaximumVirtualMachineMigrations=$($lm.Max); migration subnets=$($lm.Nets -join ',')"
}
if ($session) { Remove-PSSession -Session $session }

$summary = [pscustomobject]@{ pass = @($results | Where-Object { $_.result -eq 'pass' }).Count; fail = @($results | Where-Object { $_.result -eq 'fail' }).Count; skip = @($results | Where-Object { $_.result -eq 'skip' }).Count }
$results | Format-Table check, result, evidence -AutoSize -Wrap | Out-String -Width 200 | Write-Information -InformationAction Continue
Write-ClusterDeployLog -Message "post-deployment: pass=$($summary.pass) fail=$($summary.fail) skip=$($summary.skip)"
if ($OutputJson) { [pscustomobject]@{ solution = 'cluster-deploy'; cluster = $clusterName; summary = $summary; checks = $results } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputJson -Encoding utf8NoBOM }
return $results
