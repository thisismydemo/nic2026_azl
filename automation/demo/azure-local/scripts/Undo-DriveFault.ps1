#Requires -Version 7.0
<#
.SYNOPSIS
    Reverses Invoke-DriveFault: re-enables (or un-retires) the drive, waits for the repair to finish, clears the fault lock.
.DESCRIPTION
    Reads the Drive fault lock (or -NodeName/-DiskSerialNumber/-Method when the lock is gone), prints the plan,
    and with -Execute runs Enable-PnpDevice or Set-PhysicalDisk -Usage AutoSelect on the node, then waits until no
    storage job is running and every volume is Healthy (-ResyncTimeoutMinutes). Idempotent: when the drive is already
    healthy and no lock exists the script reports "nothing to undo".
.PARAMETER NodeName
    Node (default: from the fault lock).
.PARAMETER DiskSerialNumber
    Drive serial (default: from the fault lock).
.PARAMETER Method
    PnpDisable | Retire (default: from the fault lock).
.PARAMETER ComputerName
    Remoting target for the health snapshot.
.PARAMETER ResyncTimeoutMinutes
    How long to wait for the repair (default 30).
.PARAMETER Execute
    Perform the undo.
.PARAMETER PassThru
    Return the result object.
.EXAMPLE
    ./Undo-DriveFault.ps1 -NodeName <node name> -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [Parameter()]
    [string] $NodeName,

    [Parameter()]
    [string] $DiskSerialNumber,

    [Parameter()]
    [ValidateSet('', 'PnpDisable', 'Retire')]
    [string] $Method = '',

    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [ValidateRange(1, 600)]
    [int] $ResyncTimeoutMinutes = 30,

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

$lock = @(Get-DemoFaultLock -Scope 'azure-local' | Where-Object { $_.Fault -eq 'Drive' }) | Select-Object -First 1
if ($lock) {
    if (-not $NodeName) { $NodeName = $lock.Target }
    if (-not $DiskSerialNumber) { $DiskSerialNumber = [string]$lock.Detail.SerialNumber }
    if (-not $Method) { $Method = [string]$lock.Detail.Method }
}
if (-not $NodeName -or -not $DiskSerialNumber) {
    Write-DemoScreen -InputObject 'Nothing to undo: no Drive fault lock and no -NodeName/-DiskSerialNumber given.' -Raw
    if ($PassThru) { return [pscustomobject]@{ Undone = $false; Reason = 'no lock' } }
    return
}
if (-not $Method) { $Method = 'PnpDisable' }
$pnpInstanceId = if ($lock -and $lock.Detail.PSObject.Properties['PnpInstanceId']) { [string]$lock.Detail.PnpInstanceId } else { '' }

$planLines = @(
    "undo    : drive fault on $NodeName (serial $DiskSerialNumber, method $Method)",
    $(if ($Method -eq 'Retire') { 'action  : Set-PhysicalDisk -Usage AutoSelect, then wait for the rebalance' } else { 'action  : Enable-PnpDevice, then wait for the repair jobs' }),
    "wait    : up to $ResyncTimeoutMinutes min for StorageJobs to finish and every volume to be Healthy",
    'then    : clear the Drive fault lock'
)
if (-not $Execute) {
    Write-DemoPlan -Lines $planLines -ScriptName 'Undo-DriveFault.ps1'
    if ($PassThru) { return [pscustomobject]@{ Undone = $false; Reason = 'whatif'; Node = $NodeName; SerialNumber = $DiskSerialNumber } }
    return
}

if ($PSCmdlet.ShouldProcess("$NodeName / $DiskSerialNumber", 'restore drive')) {
    $null = Invoke-DemoRemote -ComputerName $NodeName -ArgumentList @($DiskSerialNumber, $Method, $pnpInstanceId) -ScriptBlock {
        param($Serial, $How, $InstanceId)
        if ($How -eq 'Retire') {
            $pd = Get-PhysicalDisk -SerialNumber $Serial -ErrorAction Stop
            if ($pd.Usage -ne 'Auto-Select') { Set-PhysicalDisk -InputObject $pd -Usage AutoSelect -ErrorAction Stop }
            Get-StoragePool -IsPrimordial $false | Optimize-StoragePool -ErrorAction SilentlyContinue
            return
        }
        if (-not $InstanceId) {
            $pnp = @(Get-PnpDevice -Class DiskDrive -ErrorAction Stop | Where-Object { $_.InstanceId -like "*$Serial*" -and $_.Status -ne 'OK' })
            if ($pnp.Count -eq 1) { $InstanceId = $pnp[0].InstanceId }
        }
        if ($InstanceId) {
            $dev = Get-PnpDevice -InstanceId $InstanceId -ErrorAction Stop
            if ($dev.Status -ne 'OK') { Enable-PnpDevice -InstanceId $InstanceId -Confirm:$false -ErrorAction Stop }
        }
        Get-VirtualDisk | Where-Object { $_.HealthStatus -ne 'Healthy' } | Repair-VirtualDisk -AsJob -ErrorAction SilentlyContinue | Out-Null
    }
    Write-DemoScreen -InputObject ('Drive restored on {0}; waiting for the repair to complete (up to {1} min)...' -f $NodeName, $ResyncTimeoutMinutes)
    $healthy = Wait-DemoCondition -TimeoutMinutes $ResyncTimeoutMinutes -IntervalSeconds 30 -Activity 'storage repair' -Condition {
        $h = Get-DemoClusterHealth -ComputerName $ComputerName
        (@($h.StorageJobs).Count -eq 0) -and (@($h.VirtualDisks | Where-Object { $_.HealthStatus -ne 'Healthy' }).Count -eq 0) -and ($h.Pool.HealthStatus -eq 'Healthy')
    }
    $after = Get-DemoClusterHealth -ComputerName $ComputerName
    Write-DemoScreen -InputObject ('Pool: {0}/{1}; jobs running: {2}' -f $after.Pool.HealthStatus, $after.Pool.OperationalStatus, @($after.StorageJobs).Count)
    $after.VirtualDisks | Format-Table -Property FriendlyName, HealthStatus, OperationalStatus -AutoSize | Out-String | Write-DemoScreen
    if ($healthy) {
        Remove-DemoFaultLock -Fault Drive
        Write-DemoScreen -InputObject 'Drive fault undone; fault lock cleared.' -Raw
    }
    else {
        Write-Warning 'Storage is not fully healthy yet; the fault lock stays until a re-run of Undo-DriveFault.ps1 -Execute confirms it.'
    }
    if ($PassThru) { return [pscustomobject]@{ Undone = $healthy; Node = $NodeName; SerialNumber = $DiskSerialNumber; Method = $Method } }
}
