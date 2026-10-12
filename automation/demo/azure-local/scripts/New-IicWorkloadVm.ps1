#Requires -Version 7.0
<#
.SYNOPSIS
    Seeds the IIC workload VMs (app and data tiers) on the cluster as Azure Local VMs with az stack-hci-vm, from
    environment/azure-local/environment.yml (workload_vms). Plan T-5.5.2; storage-design.md section 5 VM inventory.
.DESCRIPTION
    Per VM, in Microsoft's order (Learn: Create network interfaces; Create Azure Local VMs enabled by Azure Arc):
      1. network interface nic-<vm>-01 on the tier logical network with the tier NSG and the static IP;
      2. data disks vhd-<vm>-<nn> on the VM's storage path;
      3. the VM: image, custom vCPU/memory (--hardware-profile), Trusted launch (secure boot + vTPM), storage path,
         guest management on, NIC and data disks attached, local administrator from the ops Key Vault;
      4. tags merged with az tag update (create --tags is unreliable on this build) on the machine, NIC and disks.
    Idempotent: every resource that exists (Succeeded) is kept; nothing is deleted or changed. WhatIf is the default
    (lists the plan); -Execute creates. The local administrator pair is read from Key Vault; with -CreateMissingSecret a
    missing pair is generated in memory (CSPRNG) and written to the vault - the password is never printed.
    The az CLI is run through its own Python (not az.cmd) so cmd.exe never parses the password; the password is still on
    that child process's command line for the duration of the call (same residual as the documented CLI usage).
    No domain join: the design names none for the IIC estate. Azure PowerShell is out of scope for Azure Local VM
    resources on this build; Az.KeyVault is used for the vault only.
.PARAMETER Name
    Limit the run to these VM resource names (default: every workload_vms.vms entry).
.EXAMPLE
    .\New-IicWorkloadVm.ps1                                   # plan only
    .\New-IicWorkloadVm.ps1 -Execute -CreateMissingSecret     # create
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute or -WhatIf); they never run on their own.')]
[CmdletBinding()]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\environment\shared\environment.yml'),
    [string[]]$Name,
    [string]$NewAdminUsername = 'iicadmin',
    [switch]$CreateMissingSecret,
    [switch]$Execute,
    [string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml

$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$sub = [string]$envy.subscription_id
$rg = [string]$envy.vm_management.resource_group
$location = [string]$shared.location
$cl = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ExtendedLocation/customLocations/$($envy.vm_management.custom_location)"
$hci = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI"

function L([string]$m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }

# az through the CLI's own Python on Windows (no cmd.exe parsing of arguments); plain az elsewhere.
$azCmd = (Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $azCmd) { throw 'Azure CLI (az) not found.' }
$azPython = if ($IsWindows) { Join-Path (Split-Path (Split-Path $azCmd -Parent) -Parent) 'python.exe' } else { $null }
function Invoke-WlAz([string[]]$Arguments, [switch]$Quiet) {
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    if ($azPython -and (Test-Path -LiteralPath $azPython)) { $start.FileName = $azPython; foreach ($p in '-IBm', 'azure.cli') { [void]$start.ArgumentList.Add($p) } }
    else { $start.FileName = $azCmd }
    foreach ($a in $Arguments + @('--subscription', $sub, '--only-show-errors')) { [void]$start.ArgumentList.Add($a) }
    $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($start)
    $o = $proc.StandardOutput.ReadToEndAsync(); $e = $proc.StandardError.ReadToEndAsync(); $proc.WaitForExit()
    $r = [pscustomobject]@{ ExitCode = $proc.ExitCode; Out = $o.GetAwaiter().GetResult(); Err = $e.GetAwaiter().GetResult() }
    $proc.Dispose()
    if ($r.ExitCode -ne 0 -and -not $Quiet) { throw (($r.Err -replace '\s+', ' ').Trim()) }
    return $r
}
function Get-State([string]$id) {
    $r = Invoke-WlAz @('resource', 'show', '--ids', $id, '--query', 'properties.provisioningState', '-o', 'tsv') -Quiet
    if ($r.ExitCode -ne 0) { return '' } ; return $r.Out.Trim()
}
function Set-Tag([string]$id, [string]$tier) {
    $t = @(); foreach ($k in $shared.tags.Keys) { $t += "$k=$($shared.tags[$k])" }
    $t += 'workload=iic', "tier=$tier", 'managed-by=script'
    $null = Invoke-WlAz (@('tag', 'update', '--resource-id', $id, '--operation', 'Merge', '--tags') + $t)
}
function Split-SecretRef([string]$ref) {
    if ($ref -notmatch '^keyvault://([^/]+)/(.+)$') { throw "Not a keyvault:// reference: $ref" }
    return @{ Vault = $Matches[1]; Name = $Matches[2] }
}
function New-Password {
    # 28 characters, letters/digits plus '-', '_', '.', first character a letter; all four classes guaranteed.
    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.'
    $all = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($s.Length)]) }
    while ($chars.Count -lt 27) { $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    $shuffled = $chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) }
    $first = $sets[0][[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($sets[0].Length)]
    return "$first$(-join $shuffled)"
}
function ConvertTo-Secure([string]$s) { $ss = [securestring]::new(); foreach ($c in $s.ToCharArray()) { $ss.AppendChar($c) }; $ss.MakeReadOnly(); return $ss }
function Read-Secret($ref) {
    # Retries transient vault/token errors; a secret that does not exist returns $null.
    for ($n = 1; $n -le 4; $n++) {
        try {
            $v = Get-AzKeyVaultSecret -VaultName $ref.Vault -Name $ref.Name -AsPlainText -ErrorAction Stop
            return $v
        }
        catch {
            if ($_.Exception.Message -match 'SecretNotFound|not found') { return $null }
            if ($n -eq 4) { throw "Key Vault read of $($ref.Name) failed: $($_.Exception.Message)" }
            Start-Sleep -Seconds (5 * $n)
        }
    }
}
function Get-AdminCredential {
    # Pin the Az context of THIS process to the lab tenant and subscription: other sessions on the machine may switch the
    # saved default context (a vault rejects tokens from another tenant with AKV10032).
    $null = Set-AzContext -Tenant ([string]$shared.tenant_id) -Subscription $sub -Scope Process -WhatIf:$false
    $u = Split-SecretRef $envy.workload_vms.local_admin_username_secret
    $p = Split-SecretRef $envy.workload_vms.local_admin_password_secret
    $user = Read-Secret $u; $pass = Read-Secret $p
    if ($user -and $pass) { return @{ User = $user; Pass = $pass } }
    if (-not $CreateMissingSecret) { throw "Local administrator secrets $($u.Name)/$($p.Name) missing in $($u.Vault); rerun with -CreateMissingSecret." }
    $expires = (Get-Date).ToUniversalTime().AddDays(90)
    $tag = @{ project = [string]$shared.tags.project; workload = 'iic'; 'managed-by' = 'script' }
    if (-not $user) { $user = $NewAdminUsername; $null = Set-AzKeyVaultSecret -VaultName $u.Vault -Name $u.Name -SecretValue (ConvertTo-Secure $user) -Expires $expires -Tag $tag -ContentType 'username' }
    if (-not $pass) { $pass = New-Password; $null = Set-AzKeyVaultSecret -VaultName $p.Vault -Name $p.Name -SecretValue (ConvertTo-Secure $pass) -Expires $expires -Tag $tag -ContentType 'password' }
    L "local administrator pair written to $($u.Vault) ($($u.Name), $($p.Name)); value not shown"
    return @{ User = $user; Pass = $pass }
}

$vms = @($envy.workload_vms.vms)
if ($Name) { $vms = @($vms | Where-Object { $Name -contains $_.name }) }
$cred = $null
foreach ($vm in $vms) {
    $tier = [string]$vm.tier
    $nicName = "nic-$($vm.name)-01"
    $nicId = "$hci/networkInterfaces/$nicName"
    $spId = "$hci/storageContainers/$($vm.storage_path)"
    $machineId = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.HybridCompute/machines/$($vm.name)"
    $disks = @(if ($vm.ContainsKey('data_disks') -and $vm.data_disks) { $vm.data_disks })

    # 1. NIC
    if ((Get-State $nicId) -eq 'Succeeded') { L "${nicName}: exists" }
    elseif (-not $Execute) { L "PLAN $nicName on $($vm.logical_network) ip $($vm.ip_address) nsg $($vm.nsg)" }
    else {
        $a = @('stack-hci-vm', 'network', 'nic', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $nicName, '--subnet-id', $vm.logical_network)
        if ($vm.ContainsKey('ip_address') -and $vm.ip_address) { $a += '--ip-address', $vm.ip_address }
        if ($vm.ContainsKey('nsg') -and $vm.nsg) { $a += '--network-security-group', $vm.nsg }
        $null = Invoke-WlAz $a; Set-Tag $nicId $tier; L "${nicName}: created ($(Get-State $nicId)), tagged"
    }

    # 2. Data disks
    $diskNames = @()
    for ($i = 0; $i -lt $disks.Count; $i++) {
        $dn = 'vhd-{0}-{1:00}' -f $vm.name, ($i + 1); $diskNames += $dn
        $did = "$hci/virtualHardDisks/$dn"
        $dyn = if ($disks[$i].ContainsKey('dynamic')) { ([bool]$disks[$i].dynamic).ToString().ToLower() } else { 'true' }
        if ((Get-State $did) -eq 'Succeeded') { L "${dn}: exists" }
        elseif (-not $Execute) { L "PLAN $dn $($disks[$i].size_gb) GB dynamic=$dyn on $($vm.storage_path)" }
        else {
            $null = Invoke-WlAz @('stack-hci-vm', 'disk', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $dn,
                '--size-gb', [string]$disks[$i].size_gb, '--dynamic', $dyn, '--storage-path-id', $spId)
            Set-Tag $did $tier; L "${dn}: created ($(Get-State $did)), tagged"
        }
    }

    # 3. VM
    $vmState = Get-State "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default"
    if ($vmState -eq 'Succeeded') { L "$($vm.name): exists"; if ($Execute) { Set-Tag $machineId $tier } ; continue }
    if (-not $Execute) { L "PLAN $($vm.name) ($($vm.computer_name)) $($vm.vcpu) vCPU $($vm.memory_mb) MB image $($vm.image) on $($vm.storage_path), TrustedLaunch, disks [$($diskNames -join ', ')]"; continue }
    if ($vmState) { L "$($vm.name): present in state '$vmState' - left for an operator decision"; continue }
    if (-not $cred) { $cred = Get-AdminCredential | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1 }
    $a = @('stack-hci-vm', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $vm.name,
        '--computer-name', $vm.computer_name, '--image', $vm.image, '--os-type', 'Windows', '--nics', $nicName,
        '--hardware-profile', 'vm-size=Custom', "processors=$($vm.vcpu)", "memory-mb=$($vm.memory_mb)",
        '--storage-path-id', $spId, '--security-type', 'TrustedLaunch', '--enable-secure-boot', 'true', '--enable-vtpm', 'true',
        '--enable-agent', 'true', '--authentication-type', 'password', '--admin-username', $cred.User, '--admin-password', $cred.Pass)
    if ($diskNames) { $a += @('--attach-data-disks') + $diskNames }
    L "$($vm.name): creating"
    $r = Invoke-WlAz $a -Quiet
    $a = $null
    if ($r.ExitCode -ne 0) {
        # The CLI error text never contains the password (it is not echoed by ARM); keep it short anyway.
        $msg = ($r.Err -replace [regex]::Escape($cred.Pass), '***' -replace '\s+', ' ').Trim()
        L "$($vm.name): create failed: $($msg.Substring(0, [Math]::Min(600, $msg.Length)))"; continue
    }
    Set-Tag $machineId $tier
    L "$($vm.name): created ($(Get-State "$machineId/providers/Microsoft.AzureStackHCI/virtualMachineInstances/default")), tagged"
}
