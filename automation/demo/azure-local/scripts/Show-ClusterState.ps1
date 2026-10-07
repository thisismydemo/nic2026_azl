#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only on-stage dashboard: nodes, Storage Spaces Direct, Network ATC intents, Arc Resource Bridge and update
    state - every line through the screen-hygiene filter.
.DESCRIPTION
    One remoting snapshot (Get-DemoClusterHealth + Get-DemoUpdateState) and one Azure read (Get-DemoArbState).
    Changes nothing. -Count/-IntervalSeconds refresh the view during a fault beat.
.PARAMETER ComputerName
    Remoting target (default: cluster FQDN from the environment file).
.PARAMETER ResourceGroupName
    Cluster resource group for the ARB lookup (default: rg-<org>-<token>-azl-<region>-01).
.PARAMETER SkipAzure
    Skip the ARB lookup.
.PARAMETER SkipUpdate
    Skip the Lifecycle Manager state (saves ~10 s).
.PARAMETER Count
    How many refreshes (default 1).
.PARAMETER IntervalSeconds
    Seconds between refreshes (default 30).
.PARAMETER PassThru
    Return the snapshot object(s).
.EXAMPLE
    ./Show-ClusterState.ps1
    ./Show-ClusterState.ps1 -Count 10 -IntervalSeconds 20 -SkipUpdate
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [string] $ResourceGroupName,

    [switch] $SkipAzure,
    [switch] $SkipUpdate,

    [Parameter()]
    [ValidateRange(1, 1000)]
    [int] $Count = 1,

    [Parameter()]
    [ValidateRange(5, 3600)]
    [int] $IntervalSeconds = 30,

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
$names = Get-DemoAzlNameSet -Config $config
if (-not $ComputerName) { $ComputerName = $names.RemotingTarget }
if (-not $ResourceGroupName) { $ResourceGroupName = $names.ClusterResourceGroup }

$snapshots = for ($i = 1; $i -le $Count; $i++) {
    $health = Get-DemoClusterHealth -ComputerName $ComputerName
    $arb = if ($SkipAzure) { $null } else { Get-DemoArbState -ResourceGroupName $ResourceGroupName }
    $update = if ($SkipUpdate) { $null } else { Get-DemoUpdateState -ComputerName $ComputerName }
    $locks = @(Get-DemoFaultLock -Scope 'azure-local')

    Write-DemoScreen -InputObject ('== {0} - cluster state {1:HH:mm:ss} UTC ({2}/{3}) ==' -f $health.ClusterName, [DateTime]::UtcNow, $i, $Count)
    Write-DemoScreen -InputObject '-- Nodes --' -Raw
    $health.Nodes | Format-Table -Property Name, State -AutoSize | Out-String | Write-DemoScreen
    Write-DemoScreen -InputObject '-- Storage Spaces Direct --' -Raw
    if ($health.Pool) { Write-DemoScreen -InputObject ('pool {0}: {1}/{2}; witness {3}: {4}' -f $health.Pool.FriendlyName, $health.Pool.HealthStatus, $health.Pool.OperationalStatus, $health.Quorum.WitnessName, $health.Quorum.WitnessState) }
    $health.VirtualDisks | Format-Table -Property FriendlyName, HealthStatus, OperationalStatus, ResiliencySettingName -AutoSize | Out-String | Write-DemoScreen
    $diskSummary = $health.PhysicalDisks | Group-Object -Property Node | ForEach-Object {
        [pscustomobject]@{ Node = $_.Name; Drives = $_.Count; Healthy = @($_.Group | Where-Object { $_.HealthStatus -eq 'Healthy' }).Count; Unhealthy = @($_.Group | Where-Object { $_.HealthStatus -ne 'Healthy' } | ForEach-Object { "$($_.FriendlyName)=$($_.OperationalStatus)" }) -join ', ' }
    }
    $diskSummary | Format-Table -AutoSize | Out-String | Write-DemoScreen
    if (@($health.StorageJobs).Count -gt 0) { $health.StorageJobs | Format-Table -Property Name, JobState, PercentComplete -AutoSize | Out-String | Write-DemoScreen } else { Write-DemoScreen -InputObject 'storage jobs: none' -Raw }
    if (@($health.Faults).Count -gt 0) { $health.Faults | Format-Table -Property Severity, FaultType, FaultingObjectDescription -AutoSize -Wrap | Out-String | Write-DemoScreen }
    Write-DemoScreen -InputObject '-- Network ATC intents --' -Raw
    $health.Intents | Format-Table -Property IntentName, Host, ConfigurationStatus, ProvisioningStatus -AutoSize | Out-String | Write-DemoScreen
    if ($arb) {
        Write-DemoScreen -InputObject '-- Arc Resource Bridge --' -Raw
        Write-DemoScreen -InputObject ('appliance {0}: {1}; custom location {2}: {3}' -f $arb.ApplianceName, $arb.ApplianceStatus, $arb.CustomLocationName, $arb.CustomLocationState)
    }
    if ($update) {
        Write-DemoScreen -InputObject '-- Lifecycle Manager --' -Raw
        Write-DemoScreen -InputObject ('version {0}; state {1}; health {2}; last checked {3}' -f $update.CurrentVersion, $update.State, $update.HealthState, $update.LastChecked)
        $pending = @($update.Updates | Where-Object { $_.State -notin @('Installed', 'Installing') })
        if ($pending.Count -gt 0) { $pending | Format-Table -Property Version, DisplayName, State -AutoSize | Out-String | Write-DemoScreen } else { Write-DemoScreen -InputObject 'no pending solution update' -Raw }
    }
    if ($locks.Count -gt 0) { Write-DemoScreen -InputObject ('ACTIVE FAULT: ' + (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ')) }

    [pscustomobject]@{ Health = $health; Arb = $arb; Update = $update; FaultLocks = $locks }
    if ($i -lt $Count) { Start-DemoSleep -Seconds $IntervalSeconds }
}
if ($PassThru) { return $snapshots }
