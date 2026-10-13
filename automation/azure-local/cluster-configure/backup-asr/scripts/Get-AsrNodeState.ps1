#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only node check around the Site Recovery agent install (T-5.5.3): last boot time, pending-reboot flags, the
    Hyper-V management service, the Site Recovery provider/agent services and free space on the system drive, per node.
.DESCRIPTION
    Run before Install-AsrNodeAgent.ps1 (no node may show a pending reboot: an installer could act on it) and after it
    (LastBootUpTime must be unchanged: the agent install must not have restarted a node; the Hyper-V management service
    start time shows whether it was restarted). Nothing is changed. Nodes are reached over WinRM with the cluster
    administrator pair from the ops Key Vault (environment identity.local_admin_*_secret); nothing secret is printed.
    Values come from environment/azure-local/environment.yml (nodes[].management_ip).
.EXAMPLE
    .\Get-AsrNodeState.ps1 | Format-Table
#>
[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\shared\environment.yml')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
Import-Module (Join-Path $PSScriptRoot '..\..\..\..\shared\powershell\NIC26.Automation\NIC26.Automation.psd1')

$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription ([string]$envy.subscription_id) -Scope Process -WhatIf:$false
$cred = [pscredential]::new([string](Resolve-NIC26KeyVaultRef -Ref $envy.identity.local_admin_username_secret -AsPlainText),
    (Resolve-NIC26KeyVaultRef -Ref $envy.identity.local_admin_password_secret))

foreach ($node in @($envy.nodes)) {
    $r = Invoke-Command -ComputerName ([string]$node.management_ip) -Credential $cred -ErrorAction Stop -ScriptBlock {
        $os = Get-CimInstance Win32_OperatingSystem
        $pendingFile = $null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wu = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        $vmms = Get-CimInstance Win32_Service -Filter "Name='vmms'"
        $vmmsProc = if ($vmms.ProcessId) { Get-Process -Id $vmms.ProcessId -ErrorAction SilentlyContinue } else { $null }
        $svc = @(Get-Service -Name dra, obengine -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ' '
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        [pscustomobject]@{
            LastBootUpTime   = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
            PendingFileRename = $pendingFile
            CbsRebootPending = $cbs
            WuRebootRequired = $wu
            VmmsState        = $vmms.State
            VmmsStartedUtc   = if ($vmmsProc) { $vmmsProc.StartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            AsrServices      = if ($svc) { $svc } else { 'not installed' }
            CFreeGB          = [math]::Round($c.FreeSpace / 1GB, 1)
            RunningVms       = @(Get-VM | Where-Object State -eq 'Running').Count
        }
    }
    [pscustomobject]@{
        Node              = [string]$node.name
        LastBootUpTimeUtc = $r.LastBootUpTime
        PendingReboot     = ($r.PendingFileRename -or $r.CbsRebootPending -or $r.WuRebootRequired)
        PendingDetail     = "file=$($r.PendingFileRename) cbs=$($r.CbsRebootPending) wu=$($r.WuRebootRequired)"
        VmmsState         = $r.VmmsState
        VmmsStartedUtc    = $r.VmmsStartedUtc
        AsrServices       = $r.AsrServices
        CFreeGB           = $r.CFreeGB
        RunningVms        = $r.RunningVms
    }
}
