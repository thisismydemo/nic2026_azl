#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only Lifecycle Manager view for outline §4.1: update environment, available/installed solution updates and
    the run history (the live half; the update run itself is the recorded time-lapse).
.DESCRIPTION
    Get-SolutionUpdateEnvironment / Get-SolutionUpdate / Get-SolutionUpdateRun over PowerShell remoting, printed
    through the screen-hygiene filter. -RunReadinessCheck additionally runs Test-EnvironmentReadiness on the cluster
    (read-only validators, several minutes) and prints the per-validator result. Nothing is installed.
.PARAMETER ComputerName
    Remoting target (default: cluster FQDN).
.PARAMETER RunReadinessCheck
    Run Test-EnvironmentReadiness (takes minutes; rehearse before deciding to do it live).
.PARAMETER PassThru
    Return the state object.
.EXAMPLE
    ./Invoke-LcmReadiness.ps1
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $ComputerName,

    [switch] $RunReadinessCheck,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
if (-not $ComputerName) { $ComputerName = (Get-DemoAzlNameSet -Config $config).RemotingTarget }

$state = Get-DemoUpdateState -ComputerName $ComputerName
Write-DemoScreen -InputObject '== Lifecycle Manager: update environment ==' -Raw
Write-DemoScreen -InputObject ('current version {0}; state {1}; health {2}; last checked {3}' -f $state.CurrentVersion, $state.State, $state.HealthState, $state.LastChecked)
Write-DemoScreen -InputObject '-- Solution updates (available / installed) --' -Raw
$state.Updates | Format-Table -Property Version, DisplayName, State, HealthState, InstalledDate -AutoSize | Out-String | Write-DemoScreen
Write-DemoScreen -InputObject '-- Update run history --' -Raw
$state.Runs | Sort-Object -Property TimeStarted -Descending | Format-Table -Property State, TimeStarted, LastUpdatedTime, Duration -AutoSize | Out-String | Write-DemoScreen

$readiness = $null
if ($RunReadinessCheck) {
    Write-DemoScreen -InputObject 'Running Test-EnvironmentReadiness (read-only validators; this takes a few minutes)...' -Raw
    $readiness = @(Invoke-DemoRemote -ComputerName $ComputerName -ScriptBlock {
            Test-EnvironmentReadiness -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Title = $_.Title; Status = [string]$_.Status; Severity = [string]$_.Severity; TargetResourceName = $_.TargetResourceName }
            }
        })
    $readiness | Format-Table -Property Status, Severity, Title, TargetResourceName -AutoSize -Wrap | Out-String -Width 200 | Write-DemoScreen
    $failed = @($readiness | Where-Object { $_.Status -notin @('SUCCESS', 'Success', 'Succeeded') -and $_.Severity -in @('CRITICAL', 'Critical') })
    Write-DemoScreen -InputObject ('readiness: {0} validator(s), {1} critical failure(s)' -f $readiness.Count, $failed.Count) -Raw
}
if ($PassThru) { return [pscustomobject]@{ Update = $state; Readiness = $readiness } }
