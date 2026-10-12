#Requires -Version 7.0
<#
.SYNOPSIS
    Prepares the GPUs of every Azure Local machine for Discrete Device Assignment (DDA): disable, dismount, install the
    NVIDIA mitigation INF - one node at a time, drained, with a storage-health gate before the next node.
.DESCRIPTION
    Follows Microsoft Learn "Prepare GPUs for Azure Local" (Using DDA):
      https://learn.microsoft.com/azure/azure-local/manage/gpu-preparation#using-dda
    Per node, in order (never two nodes at once):
      1. Read state. A node whose GPU is already dismounted (Get-VMHostAssignableDevice) with the mitigation INF bound
         is reported 'ready' and skipped (idempotent).
      2. Gates: every cluster node Up, no storage job running, every virtual disk Healthy, no VM on the node in a
         transitional state, no Azure Local VM in the resource group in a non-terminal provisioning state.
      3. Suspend-ClusterNode -Drain -Wait (workloads live-migrate to the other node).
      4. Copy the mitigation package (downloaded on the jump server, SHA-256 checked) to the node; Disable-PnpDevice;
         Dismount-VMHostAssignableDevice -Force; pnputil /add-driver <inf> /install; reboot only if pnputil asks (3010).
      5. Resume-ClusterNode; wait until no storage job runs and every virtual disk is Healthy.
    After the last node: Sync-AzureStackHci on one node so the GPU capability reaches Azure.
    Default is a plan (-WhatIf); -Execute changes the nodes. Values come from environment/azure-local/*.yml (gpu block)
    through Get-NIC26Config; the node credential is resolved in memory from identity.local_admin_*_secret.
.PARAMETER Node
    Limit the run to these node names (default: every gpu.hosts entry).
.PARAMETER Mode
    Plan (default) | Check (read back only, no gates) .
.PARAMETER Execute
    Apply the change. Without it the script prints the plan.
.PARAMETER EnvironmentPath
    Folder with the azure-local *.yml files (default: <repo>\environment\azure-local).
.PARAMETER StorageRepairTimeoutMinutes
    Maximum wait for storage repair after a node resumes (default 120).
.EXAMPLE
    .\Initialize-GpuHost.ps1 -Mode Check
    .\Initialize-GpuHost.ps1                 # plan
    .\Initialize-GpuHost.ps1 -Execute        # both nodes, one at a time
    .\Initialize-GpuHost.ps1 -Node <node-name> -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Node,
    [ValidateSet('Plan', 'Check')][string]$Mode = 'Plan',
    [switch]$Execute,
    [string]$EnvironmentPath,
    [ValidateRange(5, 480)][int]$StorageRepairTimeoutMinutes = 120
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run on the Windows jump server (WinRM to the nodes, credentials in memory).' }

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$cfgArgs = @{ Scope = 'azure-local' }
if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$cfg = (Get-NIC26Config @cfgArgs).values
$gpu = $cfg.gpu
if (-not $gpu) { throw 'No gpu block in the azure-local environment.' }
if ($gpu.assignment -ne 'dda') { throw "This script prepares DDA only (gpu.assignment = '$($gpu.assignment)')." }

$hosts = @($gpu.hosts | Where-Object { -not $Node -or $Node -contains $_.node })
if ($hosts.Count -eq 0) { throw 'No matching gpu.hosts entry.' }
$nodeIp = @{}
foreach ($n in $cfg.nodes) { $nodeIp[$n.name] = [string]$n.management_ip }

$user = Resolve-NIC26KeyVaultRef -Ref $cfg.identity.local_admin_username_secret -AsPlainText
$pass = Resolve-NIC26KeyVaultRef -Ref $cfg.identity.local_admin_password_secret
$cred = [pscredential]::new($user, $pass)
Remove-Variable -Name user, pass

function Write-Step([string]$Message) { Write-Information "$(Get-Date -Format 'HH:mm:ss') $Message" -InformationAction Continue }

$stateBlock = {
    param($HardwareId, $InfName)
    $dev = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like "$HardwareId*" })
    $assignable = @(Get-VMHostAssignableDevice -ErrorAction SilentlyContinue)
    $drivers = (pnputil /enum-drivers) -join "`n"
    $infInstalled = $drivers -match [regex]::Escape($InfName)
    [pscustomobject]@{
        Node         = $env:COMPUTERNAME
        Devices      = @($dev | ForEach-Object { [pscustomobject]@{ InstanceId = $_.InstanceId; Status = [string]$_.Status; FriendlyName = $_.FriendlyName; LocationPath = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationPaths -ErrorAction SilentlyContinue).Data | Select-Object -First 1 } })
        Assignable   = @($assignable | ForEach-Object { [pscustomobject]@{ InstanceId = $_.InstanceID; LocationPath = $_.LocationPath } })
        InfInstalled = [bool]$infInstalled
    }
}

$gateBlock = {
    param($NodeName)
    $issues = [System.Collections.Generic.List[string]]::new()
    foreach ($n in Get-ClusterNode) { if ([string]$n.State -ne 'Up') { $issues.Add("cluster node $($n.Name) is $($n.State)") } }
    $jobs = @(Get-StorageJob -ErrorAction SilentlyContinue | Where-Object { [string]$_.JobState -ne 'Completed' })
    if ($jobs.Count -gt 0) { $issues.Add("$($jobs.Count) storage job(s) running") }
    foreach ($vd in Get-VirtualDisk) { if ([string]$vd.HealthStatus -ne 'Healthy') { $issues.Add("virtual disk $($vd.FriendlyName) is $($vd.HealthStatus)") } }
    $vms = @(Get-VM -ErrorAction SilentlyContinue)
    foreach ($vm in $vms) { if ([string]$vm.State -notin 'Running', 'Off', 'Saved', 'Paused') { $issues.Add("VM $($vm.Name) on $NodeName is $($vm.State)") } }
    [pscustomobject]@{ Issues = @($issues); VmCount = $vms.Count }
}

$storageHealthyBlock = {
    $jobs = @(Get-StorageJob -ErrorAction SilentlyContinue | Where-Object { [string]$_.JobState -ne 'Completed' })
    $bad = @(Get-VirtualDisk | Where-Object { [string]$_.HealthStatus -ne 'Healthy' })
    # @($bad.FriendlyName) on an empty set is @($null) (Count 1) under StrictMode - enumerate instead
    [pscustomobject]@{ Jobs = @($jobs).Count; Unhealthy = @($bad | ForEach-Object { $_.FriendlyName }) }
}

function Get-ArcVmBusy {
    $rg = $cfg.vm_management.resource_group
    if (-not $rg) { return @() }
    $json = az stack-hci-vm list -g $rg --subscription $cfg.subscription_id -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
    # StrictMode-safe: the CLI returns provisioningState under properties or at the top level depending on the VM
    foreach ($vm in @($json | ConvertFrom-Json)) {
        $props = $vm.PSObject.Properties['properties']
        $state = if ($props -and $props.Value -and $props.Value.PSObject.Properties['provisioningState']) { $props.Value.provisioningState }
        elseif ($vm.PSObject.Properties['provisioningState']) { $vm.provisioningState } else { 'Unknown' }
        if ($state -notin 'Succeeded', 'Failed', 'Canceled') { "$($vm.name)=$state" }
    }
}

# --- state of every node ------------------------------------------------------------------------------------------------
$plan = foreach ($h in $hosts) {
    $ip = $nodeIp[$h.node]; if (-not $ip) { throw "Node $($h.node) not in nodes[]." }
    $s = Invoke-Command -ComputerName $ip -Credential $cred -Authentication Negotiate -ScriptBlock $stateBlock -ArgumentList $gpu.pci_hardware_id, $gpu.mitigation_driver.inf
    $dismounted = @($s.Assignable | Where-Object { $_.LocationPath -eq $h.location_path }).Count -gt 0
    [pscustomobject]@{
        Node = $h.node; Ip = $ip; LocationPath = $h.location_path
        GpuStatus = (@($s.Devices | ForEach-Object { "$($_.Status):$($_.FriendlyName)" }) -join ', ')
        Dismounted = $dismounted; InfInstalled = $s.InfInstalled
        Action = if ($dismounted -and $s.InfInstalled) { 'ready' } else { 'prepare' }
    }
}
$plan | Format-Table Node, LocationPath, GpuStatus, Dismounted, InfInstalled, Action -AutoSize | Out-String -Width 250 | Write-Information -InformationAction Continue
if ($Mode -eq 'Check') { return $plan }
$todo = @($plan | Where-Object Action -EQ 'prepare')
if ($todo.Count -eq 0) { Write-Step 'Every GPU host is ready for DDA.'; return $plan }
if (-not $Execute) { Write-Warning "Plan only: $($todo.Count) node(s) to prepare (drain, dismount, mitigation INF, resume). Re-run with -Execute."; return $plan }

# --- mitigation package on the jump server ------------------------------------------------------------------------------
$work = Join-Path ([IO.Path]::GetTempPath()) "nic26-gpu-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $work | Out-Null
$zip = Join-Path $work ([IO.Path]::GetFileName(([uri]$gpu.mitigation_driver.url).AbsolutePath))
Invoke-WebRequest -Uri $gpu.mitigation_driver.url -OutFile $zip -UseBasicParsing
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($hash -ne $gpu.mitigation_driver.sha256) { throw "Mitigation package hash $hash does not match gpu.mitigation_driver.sha256." }
Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
$inf = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Recurse -Filter $gpu.mitigation_driver.inf | Select-Object -First 1
if (-not $inf) { throw "$($gpu.mitigation_driver.inf) not found in the package." }
$infDir = $inf.Directory.FullName

try {
    foreach ($t in $todo) {
        Write-Step "=== $($t.Node) ==="
        $session = New-PSSession -ComputerName $t.Ip -Credential $cred -Authentication Negotiate
        try {
            $gate = Invoke-Command -Session $session -ScriptBlock $gateBlock -ArgumentList $t.Node
            $busy = @(Get-ArcVmBusy)
            if ($gate.Issues.Count -gt 0 -or $busy.Count -gt 0) {
                throw "Gate failed on $($t.Node): $((@($gate.Issues) + $busy) -join '; ')"
            }
            if (-not $PSCmdlet.ShouldProcess($t.Node, 'Drain, dismount GPU, install mitigation INF, resume')) { continue }

            Write-Step "Draining $($t.Node) ($($gate.VmCount) VM(s) on it)"
            Invoke-Command -Session $session -ArgumentList $t.Node -ScriptBlock { param($n) Suspend-ClusterNode -Name $n -Drain -Wait -ErrorAction Stop | Out-Null; (Get-ClusterNode -Name $n).DrainStatus }

            $dest = $gpu.mitigation_driver.host_folder
            Invoke-Command -Session $session -ArgumentList $dest -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null }
            Copy-Item -Path (Join-Path $infDir '*') -Destination $dest -ToSession $session -Force

            $r = Invoke-Command -Session $session -ArgumentList $gpu.pci_hardware_id, $t.LocationPath, (Join-Path $dest $gpu.mitigation_driver.inf) -ScriptBlock {
                param($HardwareId, $LocationPath, $InfPath)
                $dev = Get-PnpDevice | Where-Object { $_.InstanceId -like "$HardwareId*" } | Where-Object { ((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_LocationPaths).Data | Select-Object -First 1) -eq $LocationPath }
                if (-not $dev) { throw "No GPU at $LocationPath" }
                $already = @(Get-VMHostAssignableDevice -ErrorAction SilentlyContinue | Where-Object LocationPath -EQ $LocationPath).Count -gt 0
                if (-not $already) {
                    if ([string]$dev.Status -ne 'Error') { Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false }
                    Dismount-VMHostAssignableDevice -LocationPath $LocationPath -Force
                }
                $out = pnputil /add-driver $InfPath /install 2>&1 | Out-String
                $rc = $LASTEXITCODE
                pnputil /scan-devices | Out-Null
                [pscustomobject]@{ PnpUtilExit = $rc; Output = $out.Trim(); Reboot = ($rc -eq 3010) }
            }
            Write-Step "pnputil exit $($r.PnpUtilExit)"
            if ($r.PnpUtilExit -notin 0, 3010, 259) { throw "pnputil failed on $($t.Node): $($r.Output)" }
            if ($r.Reboot) {
                Write-Step "Reboot required on $($t.Node); restarting"
                Remove-PSSession $session; $session = $null
                Restart-Computer -ComputerName $t.Ip -Credential $cred -Wait -For WinRM -Timeout 1800 -Force
                $session = New-PSSession -ComputerName $t.Ip -Credential $cred -Authentication Negotiate
            }
            Write-Step "Resuming $($t.Node)"
            Invoke-Command -Session $session -ArgumentList $t.Node -ScriptBlock { param($n) Resume-ClusterNode -Name $n -Failback Policy -ErrorAction Stop | Out-Null; [string](Get-ClusterNode -Name $n).State }

            $deadline = (Get-Date).AddMinutes($StorageRepairTimeoutMinutes)
            do {
                Start-Sleep -Seconds 30
                $h = Invoke-Command -Session $session -ScriptBlock $storageHealthyBlock
                Write-Step "storage: $($h.Jobs) job(s), unhealthy: $(@($h.Unhealthy) -join ',')"
            } while (($h.Jobs -gt 0 -or @($h.Unhealthy).Count -gt 0) -and (Get-Date) -lt $deadline)
            if ($h.Jobs -gt 0 -or @($h.Unhealthy).Count -gt 0) { throw "Storage not healthy $StorageRepairTimeoutMinutes min after resuming $($t.Node); stopping before the next node." }
        }
        finally { if ($session) { Remove-PSSession $session } }
    }
    Invoke-Command -ComputerName $todo[0].Ip -Credential $cred -Authentication Negotiate -ScriptBlock { Sync-AzureStackHCI } | Out-Null
    Write-Step 'Sync-AzureStackHCI done.'
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

# --- read back ----------------------------------------------------------------------------------------------------------
foreach ($h in $hosts) {
    Invoke-Command -ComputerName $nodeIp[$h.node] -Credential $cred -Authentication Negotiate -ScriptBlock $stateBlock -ArgumentList $gpu.pci_hardware_id, $gpu.mitigation_driver.inf |
        Select-Object Node, InfInstalled, @{ n = 'Gpu'; e = { ($_.Devices | ForEach-Object { "$($_.Status):$($_.FriendlyName)" }) -join ', ' } }, @{ n = 'Assignable'; e = { ($_.Assignable.LocationPath) -join ', ' } }
}
