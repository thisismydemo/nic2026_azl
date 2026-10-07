#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-session smoke test for every live beat of the Azure Local session (outline §1-§5): reachability, DNS, cluster,
    Azure signals, ASR, Day-2 state script, recordings. Pass/fail list and exit code. Read-only.
.DESCRIPTION
    From the jump server: no transcript, Az context, no fault lock; vault names resolve to PRIVATE addresses (K-4
    DNS dependency); node WinRM 5985, cluster name resolves;
    optional P2S check (ICMP to the presenter laptop's VPN address, -P2SClientAddress); cluster health snapshot (nodes,
    pool, intents, witness); Arc Resource Bridge Running; Insights data flowing (Heartbeat from every node in the last
    15 minutes); ASR replication Normal; Get-Day2ControlState.ps1 present; fallback recordings folder present.
.PARAMETER P2SClientAddress
    The presenter laptop's P2S address to probe (skipped when empty).
.PARAMETER SkipCluster
    Skip remoting checks.
.PARAMETER SkipAzure
    Skip ARB, Insights and ASR checks.
.PARAMETER PassThru
    Return the check rows instead of exiting.
.EXAMPLE
    ./Test-DemoSmoke.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [Parameter()]
    [string] $P2SClientAddress = '',

    [switch] $SkipCluster,
    [switch] $SkipAzure,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAzlNameSet -Config $config
$checks = [System.Collections.Generic.List[pscustomobject]]::new()

# --- console / session ---
$checks.Add((New-DemoCheck -Section '0 console' -Name 'No transcript active' -Passed (-not (Test-DemoTranscriptActive))))
$checks.Add((New-DemoCheck -Section '0 console' -Name 'Az context' -Passed ($SkipAzure -or (Test-DemoAzContext)) -Skipped:$SkipAzure))
$locks = @(Get-DemoFaultLock -Scope 'azure-local')
$checks.Add((New-DemoCheck -Section '0 console' -Name 'No fault lock active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ') })))
if ($P2SClientAddress) {
    $checks.Add((New-DemoCheck -Section '0 console' -Name 'P2S presenter laptop reachable' -Passed (Test-DemoIcmp -ComputerName $P2SClientAddress) -Detail 'ICMP to the P2S client address'))
}
else {
    $checks.Add((New-DemoCheck -Section '0 console' -Name 'P2S presenter laptop reachable' -Skipped -Detail 'pass -P2SClientAddress'))
}

# --- vault DNS: public endpoints by default (D-029); private endpoints only when enable_private_endpoints is true (K-4) ---
$usePrivate = [bool](Get-DemoConfigValue -Config $config -Key 'enable_private_endpoints')
foreach ($kv in @($names.KvOps, $names.KvAzl)) {
    $addresses = @(Resolve-DemoDnsName -Name "$kv.vault.azure.net")
    $private = ($addresses.Count -gt 0 -and @($addresses | Where-Object { -not (Test-DemoPrivateAddress -Address $_) }).Count -eq 0)
    $resolvedOk = if ($usePrivate) { $private } else { $addresses.Count -gt 0 }
    $checkName = if ($usePrivate) { "$kv resolves to a private endpoint" } else { "$kv resolves (public endpoint, D-029)" }
    $checks.Add((New-DemoCheck -Section '2.1 vaults' -Name $checkName -Passed $resolvedOk -Detail $(if ($addresses.Count -eq 0) { 'does not resolve' } elseif ($private) { 'private address' } elseif ($usePrivate) { 'PUBLIC address - private DNS zone link missing' } else { 'public address' })))
}

# --- rack reachability ---
$clusterFqdn = $names.RemotingTarget
$checks.Add((New-DemoCheck -Section '2.6 cluster' -Name "cluster name resolves ($clusterFqdn)" -Passed (@(Resolve-DemoDnsName -Name $clusterFqdn).Count -gt 0)))
foreach ($node in $names.Nodes) {
    $checks.Add((New-DemoCheck -Section '2.6 cluster' -Name "$($node.Name) WinRM 5985" -Passed (Test-DemoTcpPort -ComputerName $node.ManagementIp -Port 5985) -Detail 'PowerShell remoting path (S2S -> management VLAN)'))
}

# --- cluster health ---
if (-not $SkipCluster) {
    try {
        $health = Get-DemoClusterHealth -ComputerName $clusterFqdn
        $checks.Add((New-DemoCheck -Section '2.6 cluster' -Name 'All nodes Up' -Passed (@($health.Nodes | Where-Object { $_.State -ne 'Up' }).Count -eq 0) -Detail ((@($health.Nodes | ForEach-Object { "$($_.Name)=$($_.State)" })) -join ', ')))
        $checks.Add((New-DemoCheck -Section '2.6 cluster' -Name 'Pool and volumes Healthy' -Passed ($health.Pool.HealthStatus -eq 'Healthy' -and @($health.VirtualDisks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -eq 0)))
        $checks.Add((New-DemoCheck -Section '2.5 intents' -Name 'Network ATC intents Success' -Passed (@($health.Intents | Where-Object { $_.ConfigurationStatus -ne 'Success' }).Count -eq 0 -and @($health.Intents).Count -gt 0)))
        $checks.Add((New-DemoCheck -Section '2.6 cluster' -Name 'Witness Online' -Passed ($health.Quorum.WitnessState -eq 'Online')))
        $checks.Add((New-DemoCheck -Section '4.2 faults' -Name 'No storage job running (fault demos need a quiet pool)' -Passed (@($health.StorageJobs).Count -eq 0)))
        $healthyData = @($health.PhysicalDisks | Where-Object { $_.HealthStatus -eq 'Healthy' }).Count
        $checks.Add((New-DemoCheck -Section '4.2 faults' -Name 'All drives Healthy' -Passed ($healthyData -eq @($health.PhysicalDisks).Count -and $healthyData -gt 0) -Detail "$healthyData/$(@($health.PhysicalDisks).Count)"))
    }
    catch {
        $checks.Add((New-DemoCheck -Section '2.6 cluster' -Name 'Cluster health snapshot' -Passed $false -Detail (($_.Exception.Message -split "`n")[0])))
    }
}

# --- Azure signals ---
if (-not $SkipAzure) {
    try {
        $arb = Get-DemoArbState -ResourceGroupName $names.ClusterResourceGroup
        $checks.Add((New-DemoCheck -Section '4.4 arc' -Name 'Arc Resource Bridge Running' -Passed ($arb.ApplianceStatus -eq 'Running') -Detail "$($arb.ApplianceName): $($arb.ApplianceStatus); custom location $($arb.CustomLocationState)"))
    }
    catch { $checks.Add((New-DemoCheck -Section '4.4 arc' -Name 'Arc Resource Bridge Running' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }

    if ($names.LogAnalyticsWorkspaceId) {
        try {
            $nodeNames = @($names.Nodes | ForEach-Object { $_.Name })
            $query = "Heartbeat | where TimeGenerated > ago(15m) | summarize LastBeat = max(TimeGenerated) by Computer"
            $rows = @(Invoke-DemoLogQuery -WorkspaceId $names.LogAnalyticsWorkspaceId -Query $query -TimespanHours 1)
            $seen = @($rows | ForEach-Object { ([string]$_.Computer -split '\.')[0] })
            $missing = @($nodeNames | Where-Object { $_ -notin $seen })
            $checks.Add((New-DemoCheck -Section '3.1 insights' -Name 'Insights data flowing (Heartbeat < 15 min from every node)' -Passed ($missing.Count -eq 0) -Detail $(if ($missing.Count -eq 0) { "$($seen.Count) computer(s) reporting" } else { "missing: $($missing -join ', ')" })))
        }
        catch { $checks.Add((New-DemoCheck -Section '3.1 insights' -Name 'Insights data flowing' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }
    }
    else {
        $checks.Add((New-DemoCheck -Section '3.1 insights' -Name 'Insights data flowing' -Passed $false -Detail 'log_analytics_workspace_id empty in the environment file'))
    }

    try {
        $asr = Get-DemoAsrState -ResourceGroupName $names.BcdrResourceGroup -VaultName $names.RecoveryVault
        $checks.Add((New-DemoCheck -Section '4.5 asr' -Name 'Replication health Normal for every item' -Passed (@($asr.ProtectedItems).Count -ge 1 -and @($asr.ProtectedItems | Where-Object { $_.ReplicationHealth -ne 'Normal' }).Count -eq 0) -Detail "$(@($asr.ProtectedItems).Count) item(s)"))
        $checks.Add((New-DemoCheck -Section '4.5 asr' -Name 'Recovery plan present' -Passed (@($asr.RecoveryPlans | Where-Object { $_.Name -eq $names.RecoveryPlan }).Count -eq 1) -Detail $names.RecoveryPlan))
    }
    catch { $checks.Add((New-DemoCheck -Section '4.5 asr' -Name 'Site Recovery state' -Passed $false -Detail (($_.Exception.Message -split "`n")[0]))) }
}

# --- scripts and media the beats depend on ---
$ccRoot = Join-Path $PSScriptRoot '..' '..' '..' 'azure-local' 'cluster-configure'
$stateScript = if (Test-Path -LiteralPath $ccRoot) { @(Get-ChildItem -Path $ccRoot -Recurse -Filter 'Get-Day2ControlState.ps1' -File -ErrorAction SilentlyContinue).Count } else { 0 }
$checks.Add((New-DemoCheck -Section '3.7 readiness' -Name 'Get-Day2ControlState.ps1 present (cluster-configure)' -Passed ($stateScript -gt 0) -Detail 'needed by Test-Day2Readiness.ps1'))
$fallback = Join-Path $PSScriptRoot '..' '..' '..' '..' 'presentation' 'azure-local' 'fallback'
$clips = if (Test-Path -LiteralPath $fallback) { @(Get-ChildItem -Path $fallback -File -ErrorAction SilentlyContinue).Count } else { -1 }
$checks.Add((New-DemoCheck -Section 'D-021 fallback' -Name 'Recorded backups folder' -Passed ($clips -gt 0) -Detail $(if ($clips -lt 0) { 'presentation/azure-local/fallback missing' } else { "$clips file(s)" })))

$all = $checks.ToArray()
Write-DemoCheckTable -Check $all -Title 'Azure Local session smoke test'
$code = Get-DemoCheckExitCode -Check $all
if ($PassThru) { return $all }
exit $code
