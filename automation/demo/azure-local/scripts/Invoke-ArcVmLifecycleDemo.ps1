#Requires -Version 7.0
<#
.SYNOPSIS
    Azure Local outline 4.4 "VM lifecycle through Arc": creates, inspects and deletes the live demo VM with az stack-hci-vm,
    from environment/azure-local/environment.yml (demo_vm_lifecycle), and times every step for the run sheet.
.DESCRIPTION
    Stages (run one at a time, or -Stage All for a full dry run: Create, Show, Remove):
      Create  network interface nic-<vm>-01 on the logical network (address from its pool, the logical network's NSG
              applies), then the VM from the gallery image on the storage path: custom vCPU/memory, Trusted launch
              (secure boot + vTPM), guest management on, local administrator from the ops Key Vault (workload_vms pair).
              Timed: NIC created; VM request accepted (the VM instance resource first appears in Azure, the moment the
              portal shows "deployment in progress"); VM create finished; power state Running; Arc agent Connected.
              Tags merged with az tag update (create --tags is unreliable on this build) on the machine and NIC.
              Guest network check (default on, -GuestNetworkCheck $false skips it): once the VM runs, the script reads
              the guest over PowerShell Direct (shared/scripts/NIC26.GuestNetwork.ps1), waits up to
              -GatewayTimeoutMinutes for the default gateway from the logical network's DHCP (no in-guest route is ever
              added, owner 12 Oct 2026) and, when the Arc agent is not Connected, re-triggers guest management
              (az stack-hci-vm update --enable-agent true; Learn: Manage Azure Local VMs - the first-boot agent
              download does not retry on its own). Timed: dhcp-gateway, arc-agent-connected.
      Show    read-back of what the presenter inspects: power state, image, size, security profile, storage path, NIC,
              IP, logical network and its NSG, Arc agent status, extensions, tags; plus the rehearsal VM if present.
      Remove  deletes the VM (az stack-hci-vm delete), then the NIC, then the Arc machine resource if one is left,
              and verifies that no VM, NIC, virtual hard disk or machine with the VM's name remains. Timed.
    Idempotent: Create keeps what exists; Remove skips what is gone. WhatIf is the default (prints the plan); -Execute
    changes Azure. Never touches any other VM. The password is never printed; it is passed to the CLI's own Python (no
    cmd.exe parsing) and stays on that child process's command line for the call (same residual as the documented CLI).
    Azure PowerShell is out of scope for Azure Local VM resources on this build; Az.KeyVault is used for the vault only.
.PARAMETER Stage
    Create, Show, Remove or All.
.PARAMETER Target
    Live (default: demo_vm_lifecycle.name, created and deleted on stage) or Rehearsal (demo_vm_lifecycle.rehearsal_vm,
    the standing VM kept running for the inspect step; tagged purpose=<rehearsal_purpose_tag>).
.PARAMETER GuestNetworkCheck
    Wait for the DHCP-supplied gateway and get guest management Connected after Create (default $true). Adds no route.
.PARAMETER TimingFile
    Optional JSON file the step timings are written to (for the run sheet).
.EXAMPLE
    .\Invoke-ArcVmLifecycleDemo.ps1 -Stage All                          # plan only
    .\Invoke-ArcVmLifecycleDemo.ps1 -Stage All -Execute -TimingFile .\44-dry-run.json
    .\Invoke-ArcVmLifecycleDemo.ps1 -Stage Remove -Execute              # reset after the session
    .\Invoke-ArcVmLifecycleDemo.ps1 -Stage Create -Target Rehearsal -Execute   # standing rehearsal VM (kept running)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute); they never run on their own.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'TimeoutMinutes and LogFile are read inside the script-scope helper functions.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Create', 'Show', 'Remove', 'All')][string]$Stage,
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\environment\shared\environment.yml'),
    [ValidateSet('Live', 'Rehearsal')][string]$Target = 'Live',
    [bool]$GuestNetworkCheck = $true,
    [ValidateRange(1, 120)][int]$GatewayTimeoutMinutes = 15,
    [switch]$Execute,
    [int]$TimeoutMinutes = 30,
    [string]$LogFile,
    [string]$TimingFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml

$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$demo = $envy.demo_vm_lifecycle
if (-not $demo) { throw "demo_vm_lifecycle missing in $EnvironmentFile" }
$sub = [string]$envy.subscription_id
$rg = [string]$envy.vm_management.resource_group
$location = [string]$shared.location
$cl = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ExtendedLocation/customLocations/$($envy.vm_management.custom_location)"
$hci = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI"
$vmName = if ($Target -eq 'Rehearsal') { [string]$demo.rehearsal_vm } else { [string]$demo.name }
$computerName = if ($Target -eq 'Rehearsal') { [string]$demo.rehearsal_computer_name } else { [string]$demo.computer_name }
if (-not $vmName -or -not $computerName) { throw "demo_vm_lifecycle: name/computer_name for target $Target missing in $EnvironmentFile" }
$nicName = "nic-$vmName-01"
$nicId = "$hci/networkInterfaces/$nicName"
$spId = "$hci/storageContainers/$($demo.storage_path)"
$machineId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$vmName"
$vmiId = "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
$timings = [System.Collections.Generic.List[object]]::new()

function L([string]$m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }
function T([string]$step, [datetime]$from, [string]$detail = '') {
    $s = [Math]::Round(((Get-Date) - $from).TotalSeconds, 1)
    $timings.Add([pscustomobject]@{ step = $step; seconds = $s; atUtc = (Get-Date).ToUniversalTime().ToString('o'); detail = $detail })
    L ("TIMING {0}: {1} s {2}" -f $step, $s, $detail)
}

# az through the CLI's own Python on Windows (no cmd.exe parsing of arguments); plain az elsewhere.
$azCmd = (Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $azCmd) { throw 'Azure CLI (az) not found.' }
$azPython = if ($IsWindows) { Join-Path (Split-Path (Split-Path $azCmd -Parent) -Parent) 'python.exe' } else { $null }
function New-AzStart([string[]]$Arguments) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    if ($azPython -and (Test-Path -LiteralPath $azPython)) { $start.FileName = $azPython; foreach ($p in '-IBm', 'azure.cli') { [void]$start.ArgumentList.Add($p) } }
    else { $start.FileName = $azCmd }
    foreach ($a in $Arguments + @('--subscription', $sub, '--only-show-errors')) { [void]$start.ArgumentList.Add($a) }
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    return $start
}
function Invoke-DAz([string[]]$Arguments, [switch]$Quiet) {
    $proc = [System.Diagnostics.Process]::Start((New-AzStart $Arguments))
    $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync(); $proc.WaitForExit()
    $r = [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $e.GetAwaiter().GetResult() }
    $proc.Dispose()
    if ($r.ExitCode -ne 0 -and -not $Quiet) { throw (($r.Err -replace '\s+', ' ').Trim()) }
    return $r
}
function Get-Json([string]$id) {
    $r = Invoke-DAz @('resource', 'show', '--ids', $id, '-o', 'json') -Quiet
    if ($r.ExitCode -ne 0 -or -not $r.Out.Trim()) { return $null }
    return ($r.Out | ConvertFrom-Json -Depth 30)
}
function Get-State([string]$id) { $j = Get-Json $id; if ($j) { return [string]$j.properties.provisioningState }; return '' }
function Get-Prop($o, [string]$path) {
    foreach ($p in $path.Split('.')) { if ($null -eq $o) { return $null }; if ($o.PSObject.Properties.Name -contains $p) { $o = $o.$p } else { return $null } }
    return $o
}
function Set-Tag([string]$id) {
    $t = @(); foreach ($k in $shared.tags.Keys) { $t += "$k=$($shared.tags[$k])" }
    $t += "workload=$($demo.workload_tag)", 'managed-by=script'
    if ($Target -eq 'Rehearsal' -and $demo.rehearsal_purpose_tag) { $t += "purpose=$($demo.rehearsal_purpose_tag)" }
    $null = Invoke-DAz (@('tag', 'update', '--resource-id', $id, '--operation', 'Merge', '--tags') + $t)
}
function Split-SecretRef([string]$ref) {
    if ($ref -notmatch '^keyvault://([^/]+)/(.+)$') { throw "Not a keyvault:// reference: $ref" }
    return @{ Vault = $Matches[1]; Name = $Matches[2] }
}
function Get-AdminCredential {
    # Pin the Az context of THIS process to the configured tenant and subscription (other sessions may switch the saved default).
    Disable-AzContextAutosave -Scope Process | Out-Null
    $null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription $sub -Scope Process -WhatIf:$false
    $u = Split-SecretRef $envy.workload_vms.local_admin_username_secret
    $p = Split-SecretRef $envy.workload_vms.local_admin_password_secret
    $user = Get-AzKeyVaultSecret -VaultName $u.Vault -Name $u.Name -AsPlainText -ErrorAction Stop
    $pass = Get-AzKeyVaultSecret -VaultName $p.Vault -Name $p.Name -AsPlainText -ErrorAction Stop
    if (-not $user -or -not $pass) { throw "Local administrator secrets $($u.Name)/$($p.Name) missing in $($u.Vault) (New-IicWorkloadVm.ps1 -CreateMissingSecret creates them)." }
    return @{ User = $user; Pass = $pass }
}

function Invoke-Create {
    L "== Create $vmName ($computerName) $($demo.vcpu) vCPU $($demo.memory_mb) MB, image $($demo.image), $($demo.logical_network), $($demo.storage_path), $($demo.security_type)"
    # 1. NIC
    if ((Get-State $nicId) -eq 'Succeeded') { L "${nicName}: exists" }
    elseif (-not $Execute) { L "PLAN $nicName on $($demo.logical_network) (address from the pool, logical network NSG)" }
    else {
        $t0 = Get-Date
        $null = Invoke-DAz @('stack-hci-vm', 'network', 'nic', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $nicName, '--subnet-id', $demo.logical_network)
        T 'nic-created' $t0 (Get-State $nicId)
        Set-Tag $nicId
    }
    # 2. VM
    $vmState = Get-State $vmiId
    if ($vmState -eq 'Succeeded') { L "${vmName}: exists"; if ($Execute) { Set-Tag $machineId; if ($GuestNetworkCheck) { Invoke-GuestNetworkCheck (Get-Date) } }; return }
    if (-not $Execute) { L "PLAN $vmName from $($demo.image) on $($demo.storage_path), NIC $nicName"; return }
    if ($vmState) { throw "${vmName}: present in state '$vmState' - stop, operator decision (no improvised fix)" }
    $cred = Get-AdminCredential
    $a = @('stack-hci-vm', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $vmName,
        '--computer-name', $computerName, '--image', $demo.image, '--os-type', 'Windows', '--nics', $nicName,
        '--hardware-profile', 'vm-size=Custom', "processors=$($demo.vcpu)", "memory-mb=$($demo.memory_mb)",
        '--storage-path-id', $spId, '--security-type', $demo.security_type, '--enable-secure-boot', 'true', '--enable-vtpm', 'true',
        '--enable-agent', 'true', '--authentication-type', 'password', '--admin-username', $cred.User, '--admin-password', $cred.Pass)
    L "${vmName}: submitting create"
    $t0 = Get-Date
    $proc = [System.Diagnostics.Process]::Start((New-AzStart $a))
    $a = $null
    $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync()
    $accepted = $false
    while (-not $proc.HasExited) {
        if (-not $accepted -and (Get-State $vmiId)) { $accepted = $true; T 'vm-request-accepted' $t0 "provisioningState $(Get-State $vmiId)" }
        if (((Get-Date) - $t0).TotalMinutes -gt $TimeoutMinutes) { L "${vmName}: create still running after $TimeoutMinutes min - left running, stop"; break }
        Start-Sleep -Seconds 3
    }
    if ($proc.HasExited) {
        $err = ($e.GetAwaiter().GetResult() -replace [regex]::Escape($cred.Pass), '***' -replace '\s+', ' ').Trim()
        $null = $o.GetAwaiter().GetResult()
        $code = $proc.ExitCode; $proc.Dispose()
        if (-not $accepted) { T 'vm-request-accepted' $t0 'seen only at completion' }
        if ($code -ne 0) { T 'vm-create-failed' $t0; throw "${vmName}: create failed: $($err.Substring(0, [Math]::Min(800, $err.Length)))" }
        T 'vm-create-finished' $t0 "provisioningState $(Get-State $vmiId)"
    }
    $cred = $null
    Set-Tag $machineId
    # 3. Running and Arc agent Connected
    if ($GuestNetworkCheck) { Invoke-GuestNetworkCheck $t0; return }
    $running = $false; $connected = $false
    while (((Get-Date) - $t0).TotalMinutes -le $TimeoutMinutes -and -not ($running -and $connected)) {
        $vmi = Get-Json $vmiId; $m = Get-Json $machineId
        if (-not $running -and (Get-Prop $vmi 'properties.status.powerState') -eq 'Running') { $running = $true; T 'vm-running' $t0 }
        if (-not $connected -and (Get-Prop $m 'properties.status') -eq 'Connected') { $connected = $true; T 'arc-agent-connected' $t0 }
        if (-not ($running -and $connected)) { Start-Sleep -Seconds 10 }
    }
    if (-not $connected) { L "${vmName}: Arc agent not Connected within $TimeoutMinutes min (running=$running)" }
}

function Invoke-GuestNetworkCheck([datetime]$t0) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline -and (Get-Prop (Get-Json $vmiId) 'properties.status.powerState') -ne 'Running') { Start-Sleep -Seconds 10 }
    T 'vm-running' $t0
    if ((Get-Prop (Get-Json $machineId) 'properties.status') -eq 'Connected') { T 'arc-agent-connected' $t0 'already Connected'; return }
    if (-not (Get-Command Resolve-NIC26KeyVaultRef -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -ErrorAction Stop
    }
    . (Join-Path $PSScriptRoot '..\..\..\shared\scripts\NIC26.GuestNetwork.ps1')
    Disable-AzContextAutosave -Scope Process | Out-Null
    $null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription $sub -Scope Process -WhatIf:$false
    $nodeCred = [pscredential]::new([string](Resolve-NIC26KeyVaultRef -Ref $envy.identity.local_admin_username_secret -AsPlainText),
        (Resolve-NIC26KeyVaultRef -Ref $envy.identity.local_admin_password_secret))
    $guestUser = [string](Resolve-NIC26KeyVaultRef -Ref $envy.workload_vms.local_admin_username_secret -AsPlainText)
    $guestCred = [pscredential]::new("$computerName\$guestUser", (Resolve-NIC26KeyVaultRef -Ref $envy.workload_vms.local_admin_password_secret))
    $lnet = @($envy.logical_networks | Where-Object { $_.name -eq $demo.logical_network })[0]
    $st = Wait-NIC26GuestDhcpGateway -NodeAddress @($envy.nodes | ForEach-Object { [string]$_.management_ip }) -NodeCredential $nodeCred -VmName $vmName -GuestCredential $guestCred -ExpectedGateway ([string]$lnet.gateway) -TimeoutMinutes $GatewayTimeoutMinutes
    T 'dhcp-gateway' $t0 "$($st.DhcpGateway); Azure 443 from the guest $($st.EndpointReachable)"
    if ((Get-Prop (Get-Json $machineId) 'properties.status') -eq 'Connected') { T 'arc-agent-connected' $t0; return }
    $g = Invoke-NIC26GuestManagementRetry -SubscriptionId $sub -ResourceGroup $rg -VmName $vmName -TimeoutMinutes ([Math]::Max(1, [int]($deadline - (Get-Date)).TotalMinutes))
    if ($g.Status -eq 'Connected') { T 'arc-agent-connected' $t0 "$(if ($g.Retriggered) { 'after guest management re-trigger' })" }
    else { L "${vmName}: Arc agent $($g.Status) after the guest management re-trigger" }
}

function Show-Vm([string]$name) {
    $mId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$name"
    $vmi = Get-Json "$mId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
    if (-not $vmi) { L "${name}: not present"; return }
    $m = Get-Json $mId
    $nics = @(Get-Prop $vmi 'properties.networkProfile.networkInterfaces' | ForEach-Object { $_.id })
    L "${name}: provisioning $(Get-Prop $vmi 'properties.provisioningState'), power $(Get-Prop $vmi 'properties.status.powerState')"
    L "  image $((Get-Prop $vmi 'properties.storageProfile.imageReference.id') -replace '.*/'), size $(Get-Prop $vmi 'properties.hardwareProfile.vmSize') $(Get-Prop $vmi 'properties.hardwareProfile.processors') vCPU $(Get-Prop $vmi 'properties.hardwareProfile.memoryMB') MB"
    L "  security $(Get-Prop $vmi 'properties.securityProfile.securityType') secureBoot $(Get-Prop $vmi 'properties.securityProfile.uefiSettings.secureBootEnabled') vTPM $(Get-Prop $vmi 'properties.securityProfile.enableTPM')"
    L "  storage path $((Get-Prop $vmi 'properties.storageProfile.vmConfigStoragePathId') -replace '.*/')"
    foreach ($n in $nics) {
        $nic = Get-Json $n
        $ipc = @(Get-Prop $nic 'properties.ipConfigurations')
        foreach ($c in $ipc) { L "  nic $($n -replace '.*/') ip $(Get-Prop $c 'properties.privateIPAddress') lnet $((Get-Prop $c 'properties.subnet.id') -replace '.*/') nicNsg $((Get-Prop $nic 'properties.networkSecurityGroup.id') -replace '.*/')" }
        foreach ($c in $ipc) {
            # az resource show's default API version omits the NSG on a logical network; the stack-hci-vm extension shows it.
            $lr = Invoke-DAz @('stack-hci-vm', 'network', 'lnet', 'show', '--ids', (Get-Prop $c 'properties.subnet.id'), '-o', 'json') -Quiet
            $ln = if ($lr.ExitCode -eq 0) { $lr.Out | ConvertFrom-Json -Depth 30 } else { $null }
            $lnNsg = @(Get-Prop $ln 'properties.subnets') | ForEach-Object { (Get-Prop $_ 'properties.networkSecurityGroup.id') -replace '.*/' }
            L "  logical network NSG $($lnNsg -join ',')"
        }
    }
    L "  arc agent $(Get-Prop $m 'properties.status') version $(Get-Prop $m 'properties.agentVersion') os $(Get-Prop $m 'properties.osSku')"
    $gai = Get-Prop $vmi 'properties.guestAgentInstallStatus'
    $gaiErr = @(Get-Prop $gai 'errorDetails') | Where-Object { $_ } | ForEach-Object { "$(Get-Prop $_ 'code')" }
    L "  guest management install $(Get-Prop $gai 'status') $($gaiErr -join ',')"
    $ext = Invoke-DAz @('resource', 'list', '-g', $rg, '--resource-type', 'Microsoft.HybridCompute/machines/extensions', '--query', "[?starts_with(id, '$mId/')].name", '-o', 'tsv') -Quiet
    L "  extensions: $((($ext.Out -split "`r?`n") | Where-Object { $_ }) -join ', ')"
    $tags = Get-Prop $m 'tags'
    L "  tags: $(if ($tags) { ($tags.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ' })"
}

function Invoke-Show {
    L "== Show"
    $t0 = Get-Date
    Show-Vm $vmName
    T 'inspect-readback' $t0
    if ($Target -eq 'Live' -and $demo.rehearsal_vm) { Show-Vm ([string]$demo.rehearsal_vm) }
}

function Invoke-Remove {
    L "== Remove $vmName"
    $vmState = Get-State $vmiId
    if (-not $Execute) { L "PLAN delete $vmName (state '$vmState'), then $nicName, then the Arc machine if left$(if ($Target -eq 'Live') { "; keep $($demo.rehearsal_vm)" })"; return }
    if ($vmState) {
        $t0 = Get-Date
        $null = Invoke-DAz @('stack-hci-vm', 'delete', '-g', $rg, '--name', $vmName, '--yes')
        T 'vm-deleted' $t0
    }
    else { L "${vmName}: not present" }
    if (Get-State $nicId) {
        $t0 = Get-Date
        $null = Invoke-DAz @('stack-hci-vm', 'network', 'nic', 'delete', '-g', $rg, '--name', $nicName, '--yes')
        T 'nic-deleted' $t0
    }
    else { L "${nicName}: not present" }
    if (Get-Json $machineId) {
        $t0 = Get-Date
        $null = Invoke-DAz @('resource', 'delete', '--ids', $machineId)
        T 'arc-machine-deleted' $t0
    }
    else { L "Arc machine ${vmName}: not present" }
    # Verify nothing with the VM's name is left. The resource list lags a direct read by seconds (dry run 12 Oct: the machine
    # was already 404 on show and still listed 4 s later), so re-read for up to a minute before reporting a leftover.
    for ($n = 1; $n -le 6; $n++) {
        $left = Invoke-DAz @('resource', 'list', '-g', $rg, '--query', "[?contains(name, '$vmName')].{n:name,t:type}", '-o', 'tsv')
        $vhd = Invoke-DAz @('stack-hci-vm', 'disk', 'list', '-g', $rg, '--query', "[?contains(name, '$vmName')].name", '-o', 'tsv')
        $rest = @((($left.Out + "`n" + $vhd.Out) -split "`r?`n") | Where-Object { $_.Trim() })
        if (-not $rest) { break }
        Start-Sleep -Seconds 10
    }
    if ($rest) { L "LEFT OVER: $($rest -join '; ')" } else { L "verified: no VM, NIC, virtual hard disk or machine named *$vmName* in $rg" }
}

L "Invoke-ArcVmLifecycleDemo -Stage $Stage -Target $Target ($vmName) $(if ($Execute) { '-Execute' } else { '(plan only)' })"
if ($Stage -in 'Create', 'All') { Invoke-Create }
if ($Stage -in 'Show', 'All') { Invoke-Show }
if ($Stage -in 'Remove', 'All') { Invoke-Remove }
if ($TimingFile -and $timings.Count) { $timings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TimingFile -Encoding utf8; L "timings written to $TimingFile" }
