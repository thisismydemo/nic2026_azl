#Requires -Version 7.0
<#
.SYNOPSIS
    Attaches (or detaches) one DDA GPU to the Azure Local VMs listed in gpu.vms, with az stack-hci-vm (this build: Azure
    PowerShell is out of scope for Azure Local VMs; CLI stack-hci-vm >= 1.15.1).
.DESCRIPTION
    Learn "Manage GPUs via Discrete Device Assignment":
      https://learn.microsoft.com/azure/azure-local/manage/gpu-manage-via-device
    Idempotent: a VM whose hardwareProfile.virtualMachineGPUs already holds a GpuDDA entry is left alone (Attach), a VM
    without one is left alone (Detach). The VM is stopped before the change and started again after it (a DDA device
    can be added only to a stopped VM; Learn: the portal also shuts the VM down, attaches, restarts).
    The GPU hosts must be prepared first (Initialize-GpuHost.ps1). A DDA VM cannot live-migrate: gpu-design.md section 6.
    Default is a plan; -Execute changes the VM.
.PARAMETER VmName
    Limit to these Azure Local VM names (default: every gpu.vms entry).
.PARAMETER Action
    Attach (default) | Detach | Check.
.EXAMPLE
    .\Set-VmGpuAssignment.ps1 -Action Check
    .\Set-VmGpuAssignment.ps1 -VmName vm-iic-nic26-avd-azl-03 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$VmName,
    [ValidateSet('Attach', 'Detach', 'Check')][string]$Action = 'Attach',
    [switch]$Execute,
    [string]$EnvironmentPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$cfgArgs = @{ Scope = 'azure-local' }
if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$cfg = (Get-NIC26Config @cfgArgs).values
$rg = $cfg.vm_management.resource_group
$sub = $cfg.subscription_id
$vms = @($cfg.gpu.vms | Where-Object { -not $VmName -or $VmName -contains $_.name })
if ($vms.Count -eq 0) { throw 'No matching gpu.vms entry.' }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = & az @Arguments --subscription $sub --only-show-errors -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' '): $(($out | Out-String).Trim())" }
    if ($out) { return ($out | Out-String | ConvertFrom-Json) }
}

function Get-VmGpuState([string]$Name) {
    $vm = Invoke-Az -Arguments @('stack-hci-vm', 'show', '-g', $rg, '--name', $Name)
    $gpus = @()
    $hp = $vm.properties.hardwareProfile
    if ($hp.PSObject.Properties.Name -contains 'virtualMachineGPUs' -and $hp.virtualMachineGPUs) { $gpus = @($hp.virtualMachineGPUs) }
    [pscustomobject]@{
        Vm = $Name; ProvisioningState = $vm.properties.provisioningState; Power = $vm.properties.status.powerState
        Gpus = (@($gpus | ForEach-Object { "$($_.assignmentType):$($_.gpuName)" }) -join ', ')
        HasDda = @($gpus | Where-Object assignmentType -eq 'GpuDDA').Count -gt 0
    }
}

$plan = foreach ($v in $vms) {
    $s = Get-VmGpuState -Name $v.name
    $todo = switch ($Action) { 'Attach' { -not $s.HasDda } 'Detach' { $s.HasDda } default { $false } }
    $s | Add-Member -NotePropertyName Action -NotePropertyValue $(if ($todo) { $Action.ToLower() } else { 'none' }) -PassThru
}
$plan | Format-Table -AutoSize | Out-String -Width 200 | Write-Information -InformationAction Continue
if ($Action -eq 'Check') { return $plan }
$pending = @($plan | Where-Object Action -ne 'none')
if ($pending.Count -eq 0) { Write-Information 'Nothing to change.' -InformationAction Continue; return $plan }
if (-not $Execute) { Write-Warning "Plan only: $($pending.Count) VM(s) to $($Action.ToLower()). Re-run with -Execute."; return $plan }

foreach ($p in $pending) {
    if (-not $PSCmdlet.ShouldProcess($p.Vm, "$Action DDA GPU (stop, change, start)")) { continue }
    $wasRunning = $p.Power -match 'Running'
    if ($wasRunning) { $null = Invoke-Az -Arguments @('stack-hci-vm', 'stop', '-g', $rg, '--name', $p.Vm) }
    if ($Action -eq 'Attach') {
        $null = Invoke-Az -Arguments @('stack-hci-vm', 'gpu', 'attach', '-g', $rg, '--vm-name', $p.Vm, '--gpu-dda-count', '1', '--yes')
    }
    else {
        $null = Invoke-Az -Arguments @('stack-hci-vm', 'gpu', 'detach', '-g', $rg, '--vm-name', $p.Vm, '--yes')
    }
    $null = Invoke-Az -Arguments @('stack-hci-vm', 'start', '-g', $rg, '--name', $p.Vm)
}

# read back
foreach ($v in $vms) { Get-VmGpuState -Name $v.name }
