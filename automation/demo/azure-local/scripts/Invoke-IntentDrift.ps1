#Requires -Version 7.0
<#
.SYNOPSIS
    Benign, reversible Network ATC drift on ONE node (outline §4.2, second fault): changes one adapter property that
    ATC owns so the platform detects and remediates it. -WhatIf is the default.
.DESCRIPTION
    Prints the UNDO command first, runs Test-FaultPreflight, prints Get-NetIntentStatus BEFORE, then with -Execute
    sets the JumboPacket advanced property of one Compute-intent adapter on the node to -DriftValue (default 4088;
    the intent default is 1514). Nothing is removed from a switch, no VLAN changes, no storage adapter is touched.
    Prints Get-NetIntentStatus AFTER (ATC shows the host as drifted/retrying and remediates on its next pass;
    Set-NetIntentRetryState forces it). Records a fault lock; Undo-IntentDrift restores the original value or confirms
    that ATC already did.
.PARAMETER NodeName
    Node to drift.
.PARAMETER AdapterName
    Adapter (default: first adapter of the Compute intent in the environment file).
.PARAMETER DriftValue
    JumboPacket value to set (default 4088).
.PARAMETER ComputerName
    Remoting target for cluster-wide status (default: cluster FQDN).
.PARAMETER Execute
    Apply the drift.
.PARAMETER PassThru
    Return the plan/result object.
.EXAMPLE
    ./Invoke-IntentDrift.ps1 -NodeName <node name> -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string] $NodeName,

    [Parameter()]
    [string] $AdapterName,

    [Parameter()]
    [ValidateSet(1514, 4088, 9014)]
    [int] $DriftValue = 4088,

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
if (-not $AdapterName) {
    $compute = @(Get-DemoConfigValue -Config $config -Key 'intents' | Where-Object { (Get-DemoConfigValue -Config $_ -Key 'name') -eq 'Compute' }) | Select-Object -First 1
    if (-not $compute) { throw 'No Compute intent in the environment file; pass -AdapterName.' }
    $AdapterName = [string]@(Get-DemoConfigValue -Config $compute -Key 'adapters')[0]
}

Write-DemoUndo -Command ('{0} -NodeName {1} -Execute' -f (Join-Path $PSScriptRoot 'Undo-IntentDrift.ps1'), $NodeName)

$preflight = & (Join-Path $PSScriptRoot 'Test-FaultPreflight.ps1') -Fault IntentDrift -NodeName $NodeName -ComputerName $ComputerName
if (-not $preflight.Passed) { throw 'REFUSED: the cluster is not clean enough for an intent-drift demo (see the preflight table). Nothing was changed.' }

Write-DemoScreen -InputObject '== Get-NetIntentStatus BEFORE ==' -Raw
$preflight.Health.Intents | Format-Table -Property IntentName, Host, ConfigurationStatus, ProvisioningStatus -AutoSize | Out-String | Write-DemoScreen

$plan = [pscustomobject]@{ Fault = 'IntentDrift'; Node = $NodeName; Adapter = $AdapterName; Keyword = '*JumboPacket'; DriftValue = $DriftValue; OriginalValue = $null; Executed = $false }
$planLines = @(
    "fault   : Network ATC drift on $NodeName",
    "change  : Set-NetAdapterAdvancedProperty '$AdapterName' *JumboPacket -> $DriftValue (benign; compute adapter only)",
    'expect  : Get-NetIntentStatus shows the host drifted/retrying; ATC remediates on its next pass (or Set-NetIntentRetryState)'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Invoke-IntentDrift.ps1'
    if ($PassThru) { return $plan }
    return
}

if ($PSCmdlet.ShouldProcess("$NodeName / $AdapterName", "JumboPacket -> $DriftValue")) {
    # Read the original value first (read-only) so the lock can record it BEFORE anything changes: a change whose original value is lost cannot be undone.
    $original = Invoke-DemoRemote -ComputerName $NodeName -ArgumentList @(, $AdapterName) -ScriptBlock {
        param($Adapter)
        $prop = Get-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -ErrorAction Stop
        return [string]$prop.RegistryValue
    }
    $plan.OriginalValue = [string]$original
    $null = New-DemoFaultLock -Fault IntentDrift -Target $NodeName -Scope 'azure-local' -Detail @{ Adapter = $AdapterName; Keyword = '*JumboPacket'; OriginalValue = [string]$original; DriftValue = $DriftValue }
    try {
        $null = Invoke-DemoRemote -ComputerName $NodeName -ArgumentList @($AdapterName, $DriftValue) -ScriptBlock {
            param($Adapter, $Value)
            $prop = Get-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -ErrorAction Stop
            if ([string]$prop.RegistryValue -ne [string]$Value) {
                Set-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -RegistryValue ([string]$Value) -NoRestart -ErrorAction Stop
                $check = Get-NetAdapterAdvancedProperty -Name $Adapter -RegistryKeyword '*JumboPacket' -ErrorAction Stop
                if ([string]$check.RegistryValue -ne [string]$Value) { throw "The adapter reports JumboPacket '$($check.RegistryValue)' after the change, not '$Value'." }
            }
            return [string]$prop.RegistryValue
        }
    }
    catch {
        throw ("The drift change outcome is unknown ({0}). The fault lock is KEPT with the original value {1}. Run the Undo: {2} -NodeName {3} -Execute" -f (($_.Exception.Message -replace '\s+', ' ')), $original, (Join-Path $PSScriptRoot 'Undo-IntentDrift.ps1'), $NodeName)
    }
    $plan.Executed = $true
    Write-DemoScreen -InputObject ('Drift applied on {0}/{1}: JumboPacket {2} -> {3}. Waiting 60 s for ATC to notice...' -f $NodeName, $AdapterName, $original, $DriftValue)
    Start-DemoSleep -Seconds 60
    Write-DemoScreen -InputObject '== Get-NetIntentStatus AFTER ==' -Raw
    Get-DemoIntentStatus -ComputerName $ComputerName | Format-Table -Property IntentName, Host, ConfigurationStatus, ProvisioningStatus, LastUpdated -AutoSize | Out-String | Write-DemoScreen
    Write-DemoScreen -InputObject 'ATC remediation runs periodically; to force it on stage: Invoke-Command <node> { Set-NetIntentRetryState -Name Compute }' -Raw
    Write-DemoUndo -Command ('{0} -NodeName {1} -Execute' -f (Join-Path $PSScriptRoot 'Undo-IntentDrift.ps1'), $NodeName)
}
if ($PassThru) { return $plan }
