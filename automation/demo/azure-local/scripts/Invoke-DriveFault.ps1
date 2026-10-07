#Requires -Version 7.0
<#
.SYNOPSIS
    Software-induced drive fault on ONE node (outline §4.2, first fault: drive -> drift -> node). -WhatIf is the default.
.DESCRIPTION
    Prints the UNDO command first, runs Test-FaultPreflight (refuses if a repair is running, another fault is active,
    or any node/volume/intent is unhealthy), picks one healthy data drive on the node (or -DiskSerialNumber), then
    with -Execute:
      PnpDisable (default) - Disable-PnpDevice on the drive's device instance: the pool reports the drive as
                             Lost Communication, volumes go Degraded/Incomplete, Insights raises the storage alert.
      Retire               - Set-PhysicalDisk -Usage Retired: the pool evacuates the drive (softer, slower signal).
    Records a fault lock so Invoke-IntentDrift / Invoke-NodePowerOff refuse until Undo-DriveFault has run. Nothing is
    typed into a node console; everything runs over PowerShell remoting from the jump server.
.PARAMETER NodeName
    Node that owns the drive.
.PARAMETER DiskSerialNumber
    Specific drive (default: the first healthy data drive on the node by friendly name).
.PARAMETER Method
    PnpDisable | Retire
.PARAMETER ComputerName
    Remoting target for the health snapshot (default: cluster FQDN from the environment file).
.PARAMETER Execute
    Perform the fault. Without it the plan is printed.
.PARAMETER PassThru
    Return the plan/result object.
.EXAMPLE
    ./Invoke-DriveFault.ps1 -NodeName <node name>
    ./Invoke-DriveFault.ps1 -NodeName <node name> -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [string] $NodeName,

    [Parameter()]
    [string] $DiskSerialNumber,

    [Parameter()]
    [ValidateSet('PnpDisable', 'Retire')]
    [string] $Method = 'PnpDisable',

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
$names = Get-DemoAzlNameSet -Config $config
if (-not $ComputerName) { $ComputerName = $names.RemotingTarget }

Write-DemoUndo -Command ('{0} -NodeName {1} -Execute' -f (Join-Path $PSScriptRoot 'Undo-DriveFault.ps1'), $NodeName)

$preflight = & (Join-Path $PSScriptRoot 'Test-FaultPreflight.ps1') -Fault Drive -NodeName $NodeName -ComputerName $ComputerName
if (-not $preflight.Passed) {
    throw "REFUSED: the cluster cannot take a drive fault right now (see the preflight table). Nothing was changed."
}

$candidates = @($preflight.Health.PhysicalDisks | Where-Object { $_.Node -eq $NodeName -and $_.HealthStatus -eq 'Healthy' -and $_.Usage -in @('Auto-Select', 'AutoSelect', 'Data') } | Sort-Object -Property FriendlyName)
$disk = if ($DiskSerialNumber) { @($candidates | Where-Object { $_.SerialNumber -eq $DiskSerialNumber }) | Select-Object -First 1 } else { $candidates | Select-Object -First 1 }
if (-not $disk) { throw "No healthy data drive matched on $NodeName (serial filter: '$DiskSerialNumber')." }

$plan = [pscustomobject]@{
    Fault        = 'Drive'
    Node         = $NodeName
    Method       = $Method
    Disk         = $disk.FriendlyName
    SerialNumber = $disk.SerialNumber
    MediaType    = $disk.MediaType
    Action       = $(if ($Method -eq 'PnpDisable') { 'Disable-PnpDevice (drive appears lost)' } else { 'Set-PhysicalDisk -Usage Retired' })
    Executed     = $false
}
$planLines = @(
    "fault   : drive on $NodeName",
    "drive   : $($disk.FriendlyName) ($($disk.MediaType)) serial $($disk.SerialNumber)",
    "method  : $($plan.Action)",
    'expect  : pool/volume health degrades, Insights alert fires, no data loss (2-way mirror), repair after Undo'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Invoke-DriveFault.ps1'
    if ($PassThru) { return $plan }
    return
}

if ($PSCmdlet.ShouldProcess("$NodeName / $($disk.FriendlyName)", $plan.Action)) {
    # Lock first: a fault that nothing records would let a second fault start and leave the Undo with nothing to read.
    # The disk identity is already known; the PnP instance id is added once the fault is applied (the Undo re-derives it from the serial when absent).
    $lockDetail = @{ Method = $Method; SerialNumber = [string]$disk.SerialNumber; PnpInstanceId = ''; FriendlyName = [string]$disk.FriendlyName; Status = 'Pending' }
    $null = New-DemoFaultLock -Fault Drive -Target $NodeName -Scope 'azure-local' -Detail $lockDetail
    try {
        $detail = Invoke-DemoRemote -ComputerName $NodeName -ArgumentList @($disk.SerialNumber, $Method) -ScriptBlock {
            param($Serial, $How)
            $pd = Get-PhysicalDisk -SerialNumber $Serial -ErrorAction Stop
            if ($How -eq 'Retire') {
                Set-PhysicalDisk -InputObject $pd -Usage Retired -ErrorAction Stop
                return [pscustomobject]@{ Applied = $true; Reason = ''; PnpInstanceId = ''; Serial = $Serial; FriendlyName = $pd.FriendlyName }
            }
            $all = @(Get-PnpDevice -Class DiskDrive -PresentOnly -ErrorAction Stop)
            # Most specific match first: the serial in the instance id, then the adapter serial; the model name alone is the last resort. Never guess between several.
            $pnp = @($all | Where-Object { $_.InstanceId -like "*$Serial*" })
            if ($pnp.Count -eq 0 -and $pd.AdapterSerialNumber) { $pnp = @($all | Where-Object { $_.InstanceId -like "*$($pd.AdapterSerialNumber)*" }) }
            if ($pnp.Count -eq 0) { $pnp = @($all | Where-Object { $_.FriendlyName -eq $pd.FriendlyName }) }
            if ($pnp.Count -ne 1) {
                return [pscustomobject]@{ Applied = $false; Reason = "Could not map drive serial '$Serial' to exactly one PnP device ($($pnp.Count) matches). Re-run with -Method Retire."; PnpInstanceId = ''; Serial = $Serial; FriendlyName = $pd.FriendlyName }
            }
            Disable-PnpDevice -InstanceId $pnp[0].InstanceId -Confirm:$false -ErrorAction Stop
            return [pscustomobject]@{ Applied = $true; Reason = ''; PnpInstanceId = $pnp[0].InstanceId; Serial = $Serial; FriendlyName = $pd.FriendlyName }
        }
    }
    catch {
        throw ("The drive fault outcome is unknown ({0}). The fault lock is KEPT. Check the drive, then run the Undo: {1} -NodeName {2} -Execute" -f (($_.Exception.Message -replace '\s+', ' ')), (Join-Path $PSScriptRoot 'Undo-DriveFault.ps1'), $NodeName)
    }
    if (-not $detail.Applied) {
        # nothing was changed on the drive: release the lock
        Remove-DemoFaultLock -Fault Drive
        throw "REFUSED: $($detail.Reason) Nothing was changed."
    }
    $lockDetail.PnpInstanceId = [string]$detail.PnpInstanceId
    $lockDetail.Status = 'Applied'
    $null = New-DemoFaultLock -Fault Drive -Target $NodeName -Scope 'azure-local' -Detail $lockDetail
    $plan.Executed = $true
    Write-DemoScreen -InputObject ('Drive fault applied on {0}: {1}. Watching the pool...' -f $NodeName, $detail.FriendlyName)
    Start-DemoSleep -Seconds 20
    $after = Get-DemoClusterHealth -ComputerName $ComputerName
    Write-DemoScreen -InputObject ('Pool: {0}/{1}' -f $after.Pool.HealthStatus, $after.Pool.OperationalStatus)
    $after.VirtualDisks | Format-Table -Property FriendlyName, HealthStatus, OperationalStatus -AutoSize | Out-String | Write-DemoScreen
    $after.PhysicalDisks | Where-Object { $_.Node -eq $NodeName } | Format-Table -Property FriendlyName, HealthStatus, OperationalStatus, Usage -AutoSize | Out-String | Write-DemoScreen
    Write-DemoUndo -Command ('{0} -NodeName {1} -Execute' -f (Join-Path $PSScriptRoot 'Undo-DriveFault.ps1'), $NodeName)
}
if ($PassThru) { return $plan }
