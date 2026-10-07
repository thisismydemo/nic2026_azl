#Requires -Version 7.0
<#
.SYNOPSIS
    The Day-2 readiness gate of outline §3.7 (and the red baseline of §2.6) as ONE run: cluster health plus every
    Day-2 control, red/green table, exit code.
.DESCRIPTION
    Two inputs:
      1. Control state - the output of Get-Day2ControlState.ps1 (owned by the cluster-configure solutions). Accepted as
         objects (-ControlState), a JSON file (-ControlStatePath) or by running the script (-ControlStateScript; the
         default searches automation/azure-local/cluster-configure/**/Get-Day2ControlState.ps1). Expected row shape:
         { Control = '<key>'; Status = 'Present'|'Missing'|'Partial'|'Unknown'; Detail = '<names/counts>' }.
         The expected control keys and their outline section live in day2-controls.yml next to this script.
      2. Cluster health - Get-DemoClusterHealth over remoting (or -Health): nodes Up, pool and volumes Healthy, no
         fault, no job, intents Success, RDMA enabled on the storage adapters, witness Online.
    Every missing control or unhealthy item is RED. Exit code 1 when anything is RED; -PassThru returns the rows.
.PARAMETER ControlState
    Control rows (see above).
.PARAMETER ControlStatePath
    JSON file with the control rows.
.PARAMETER ControlStateScript
    Path of Get-Day2ControlState.ps1 to run (read-only).
.PARAMETER RegistryPath
    day2-controls.yml (default: next to this script).
.PARAMETER ComputerName
    Remoting target (default: cluster FQDN).
.PARAMETER Health
    Pre-collected cluster health snapshot.
.PARAMETER SkipCluster
    Evaluate controls only.
.PARAMETER PassThru
    Return the check rows instead of exiting.
.EXAMPLE
    ./Test-Day2Readiness.ps1                     # red in §2.6, green in §3.7
    ./Test-Day2Readiness.ps1 -ControlStatePath .\state.json -SkipCluster -PassThru
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [Parameter()]
    [object[]] $ControlState,

    [Parameter()]
    [string] $ControlStatePath,

    [Parameter()]
    [string] $ControlStateScript,

    [Parameter()]
    [string] $RegistryPath,

    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [object] $Health,

    [switch] $SkipCluster,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }
if (-not (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { Import-Module powershell-yaml -ErrorAction Stop }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
if (-not $ComputerName) { $ComputerName = (Get-DemoAzlNameSet -Config $config).RemotingTarget }
if (-not $RegistryPath) { $RegistryPath = Join-Path $PSScriptRoot '..' 'day2-controls.yml' }
$registry = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $RegistryPath -Raw) -Ordered

$checks = [System.Collections.Generic.List[pscustomobject]]::new()

# --- controls -------------------------------------------------------------------------------------------------------
$rows = @()
if ($ControlState) { $rows = @($ControlState) }
elseif ($ControlStatePath) { $rows = @(Get-Content -LiteralPath $ControlStatePath -Raw | ConvertFrom-Json) }
else {
    if (-not $ControlStateScript) {
        $searchRoot = Join-Path $PSScriptRoot '..' '..' '..' 'azure-local' 'cluster-configure'
        if (Test-Path -LiteralPath $searchRoot) {
            $found = @(Get-ChildItem -Path $searchRoot -Recurse -Filter 'Get-Day2ControlState.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($found.Count -gt 0) { $ControlStateScript = $found[0].FullName }
        }
    }
    if ($ControlStateScript -and (Test-Path -LiteralPath $ControlStateScript)) {
        $rows = @(& $ControlStateScript)
    }
    else {
        $checks.Add((New-DemoCheck -Section 'controls' -Name 'Get-Day2ControlState.ps1 available' -Passed $false -Detail 'cluster-configure solution not present; pass -ControlState/-ControlStatePath'))
    }
}
$byKey = @{}
foreach ($r in $rows) {
    $key = [string](Get-DemoConfigValue -Config $r -Key 'Control')
    if ($key) { $byKey[$key.ToLowerInvariant()] = $r }
}
foreach ($control in $registry.controls) {
    $key = [string]$control.key
    $section = '{0} {1}' -f $control.outline, $control.area
    $row = $byKey[$key.ToLowerInvariant()]
    if ($null -eq $row) {
        $checks.Add((New-DemoCheck -Section $section -Name $control.name -Passed $false -Detail 'no state reported'))
        continue
    }
    $status = [string](Get-DemoConfigValue -Config $row -Key 'Status')
    $detail = [string](Get-DemoConfigValue -Config $row -Key 'Detail')
    $present = $status -in @('Present', 'Applied', 'InPlace', 'Compliant', 'True', 'Healthy', 'Completed')
    $checks.Add((New-DemoCheck -Section $section -Name $control.name -Passed $present -Detail ("{0}{1}" -f $status, $(if ($detail) { ": $detail" } else { '' }))))
}
foreach ($extra in $byKey.Keys | Where-Object { $_ -notin @($registry.controls | ForEach-Object { ([string]$_.key).ToLowerInvariant() }) }) {
    $r = $byKey[$extra]
    $status = [string](Get-DemoConfigValue -Config $r -Key 'Status')
    $checks.Add((New-DemoCheck -Section 'controls (unregistered)' -Name $extra -Passed ($status -in @('Present', 'Applied', 'InPlace', 'Compliant', 'True', 'Healthy', 'Completed')) -Detail $status))
}

# --- cluster health -------------------------------------------------------------------------------------------------
if (-not $SkipCluster) {
    if ($null -eq $Health) { $Health = Get-DemoClusterHealth -ComputerName $ComputerName }
    $nodes = @($Health.Nodes)
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'All nodes Up' -Passed (@($nodes | Where-Object { $_.State -ne 'Up' }).Count -eq 0 -and $nodes.Count -ge 2) -Detail ((@($nodes | ForEach-Object { "$($_.Name)=$($_.State)" })) -join ', ')))
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'Storage pool Healthy' -Passed ($null -ne $Health.Pool -and $Health.Pool.HealthStatus -eq 'Healthy') -Detail $(if ($Health.Pool) { "$($Health.Pool.HealthStatus)/$($Health.Pool.OperationalStatus)" } else { 'no pool' })))
    $vd = @($Health.VirtualDisks)
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'All volumes Healthy' -Passed ($vd.Count -gt 0 -and @($vd | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -eq 0) -Detail "$($vd.Count) volume(s)"))
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'No health faults' -Passed (@($Health.Faults | Where-Object { $_.Severity -in @('Major', 'Critical', 'Fatal') }).Count -eq 0) -Detail "$(@($Health.Faults).Count) fault record(s)"))
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'No storage job running' -Passed (@($Health.StorageJobs).Count -eq 0) -Detail "$(@($Health.StorageJobs).Count) job(s)"))
    $intents = @($Health.Intents)
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'Network ATC intents Success' -Passed ($intents.Count -gt 0 -and @($intents | Where-Object { $_.ConfigurationStatus -ne 'Success' }).Count -eq 0) -Detail "$($intents.Count) intent/host rows"))
    $rdma = @($Health.RdmaAdapters)
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'RDMA enabled on storage adapters' -Passed ($rdma.Count -ge 2) -Detail "$($rdma.Count) RDMA-enabled adapter(s) on the queried host"))
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'Cloud witness Online' -Passed ($null -ne $Health.Quorum -and $Health.Quorum.WitnessState -eq 'Online') -Detail $(if ($Health.Quorum) { $Health.Quorum.WitnessState } else { 'unknown' })))
    $locks = @(Get-DemoFaultLock -Scope 'azure-local')
    $checks.Add((New-DemoCheck -Section 'cluster' -Name 'No demo fault active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ') })))
}

$all = $checks.ToArray()
Write-DemoCheckTable -Check $all -Title 'Day-2 readiness gate (outline 3.7)'
$code = Get-DemoCheckExitCode -Check $all
if ($PassThru) { return $all }
exit $code
