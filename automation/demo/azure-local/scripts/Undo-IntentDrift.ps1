#Requires -Version 7.0
<#
.SYNOPSIS
    Reverses Invoke-IntentDrift: restores the adapter property (or confirms Network ATC already remediated) and clears the lock.
.DESCRIPTION
    Reads the IntentDrift fault lock (adapter, keyword, original value) or takes -NodeName/-AdapterName/-OriginalValue,
    prints the plan, and with -Execute sets the property back when it still differs, then prints Get-NetIntentStatus
    and clears the lock. Idempotent.
.PARAMETER NodeName
    Node (default: from the lock).
.PARAMETER AdapterName
    Adapter (default: from the lock).
.PARAMETER OriginalValue
    Value to restore (default: from the lock; 1514 when unknown).
.PARAMETER ComputerName
    Remoting target for cluster-wide status.
.PARAMETER Execute
    Perform the undo.
.PARAMETER PassThru
    Return the result object.
.EXAMPLE
    ./Undo-IntentDrift.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $NodeName,

    [Parameter()]
    [string] $AdapterName,

    [Parameter()]
    [string] $OriginalValue,

    [Parameter()]
    [string] $ComputerName,

    [switch] $Execute,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$config = Get-DemoConfig -Scope 'azure-local'
Initialize-DemoScreenHygiene -Config $config
if (-not $ComputerName) { $ComputerName = (Get-DemoAzlNameSet -Config $config).RemotingTarget }

$lock = @(Get-DemoFaultLock -Scope 'azure-local' | Where-Object { $_.Fault -eq 'IntentDrift' }) | Select-Object -First 1
if ($lock) {
    if (-not $NodeName) { $NodeName = $lock.Target }
    if (-not $AdapterName) { $AdapterName = [string]$lock.Detail.Adapter }
    if (-not $OriginalValue) { $OriginalValue = [string]$lock.Detail.OriginalValue }
}
if (-not $NodeName -or -not $AdapterName) {
    Write-DemoScreen -InputObject 'Nothing to undo: no IntentDrift fault lock and no -NodeName/-AdapterName given.' -Raw
    if ($PassThru) { return [pscustomobject]@{ Undone = $false; Reason = 'no lock' } }
    return
}
if (-not $OriginalValue) { $OriginalValue = '1514' }

$planLines = @(
    "undo    : intent drift on $NodeName / $AdapterName",
    "action  : Set-NetAdapterAdvancedProperty *JumboPacket -> $OriginalValue (skipped if ATC already remediated)",
    'then    : print Get-NetIntentStatus and clear the IntentDrift fault lock'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Undo-IntentDrift.ps1'
    if ($PassThru) { return [pscustomobject]@{ Undone = $false; Reason = 'whatif'; Node = $NodeName; Adapter = $AdapterName } }
    return
}

if ($PSCmdlet.ShouldProcess("$NodeName / $AdapterName", "JumboPacket -> $OriginalValue")) {
    $outcome = Invoke-DemoRemote -ComputerName $NodeName -ArgumentList @($AdapterName, $OriginalValue) -ScriptBlock {
        param($Adapter, $Value)
        $prop = Get-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -ErrorAction Stop
        if ([string]$prop.RegistryValue -eq [string]$Value) { return 'already-remediated' }
        Set-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -RegistryValue ([string]$Value) -NoRestart -ErrorAction Stop
        return 'restored'
    }
    Write-DemoScreen -InputObject $(if ($outcome -eq 'already-remediated') { 'Network ATC had already remediated the drift; nothing to restore.' } else { "Adapter property restored to $OriginalValue." }) -Raw
    Write-DemoScreen -InputObject '== Get-NetIntentStatus ==' -Raw
    Get-DemoIntentStatus -ComputerName $ComputerName | Format-Table -Property IntentName, Host, ConfigurationStatus, ProvisioningStatus, LastUpdated -AutoSize | Out-String | Write-DemoScreen
    Remove-DemoFaultLock -Fault IntentDrift
    Write-DemoScreen -InputObject 'Intent drift undone; fault lock cleared.' -Raw
    if ($PassThru) { return [pscustomobject]@{ Undone = $true; Outcome = $outcome; Node = $NodeName; Adapter = $AdapterName } }
}
