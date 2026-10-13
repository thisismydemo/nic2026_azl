#Requires -Version 7.0
<#
.SYNOPSIS
    Imports, checks, starts and monitors an Azure Local solution update with additional content (OEM Solution Builder
    Extension), with the handling a DDA GPU VM needs (it cannot live-migrate and would block the node drain).
.DESCRIPTION
    Follows Microsoft Learn "Update Azure Local by using PowerShell":
      https://learn.microsoft.com/azure/azure-local/update/update-via-powershell-23h2
    and "Understand update phases" / "Troubleshoot solution updates":
      https://learn.microsoft.com/azure/azure-local/update/update-phases-23h2
      https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2

    Stages (-Stage, default State; nothing changes without -Execute):
      State    Get-SolutionUpdateEnvironment and Get-SolutionUpdate on the monitor node, plus the gates below.
      Import   Learn step 3. Verifies the package on this machine (XML signature of the discovery and inventory xml, and
               with -VerifyPayload the SHA-256 of every payload file against the signed inventory), creates the import
               folder on the infrastructure volume, copies the three files over WinRM (skipped when the same hash is
               already there), Add-SolutionUpdate -SourceFolder, then waits until the update leaves
               AdditionalContentRequired (Ready).
      Check    Learn step 4. Gates, then Start-SolutionUpdate -PrepareOnly and wait for ReadyToInstall (or report the
               failed readiness checks with Title/Severity/Remediation and stop).
      Start    Learn step 5. Gates; for every DDA GPU VM (gpu.vms): AVD session host drain mode (allowNewSession false),
               refuse if it has sessions, az stack-hci-vm stop; then Start-SolutionUpdate. Continues with Monitor.
      Monitor  Learn step 6. Polls Get-SolutionUpdate and the newest Get-SolutionUpdateRun (deepest InProgress/Error step)
               every -PollSeconds on the monitor node (falls back to the other node while one reboots) and prints each
               change, until Installed or a failed state. On failure prints the failing step and its error and stops;
               the documented resume is Get-SolutionUpdate -Id <id> | Start-SolutionUpdate (Learn step 7) after the
               cause is fixed: run this script again with -Stage Start -Execute.
      Post     Learn step 8. Starts the GPU VMs, re-enables new sessions, waits for the session hosts to be Available,
               reads Get-SolutionUpdateEnvironment and checks the DDA device is still assigned on the host.
      All      Import, Check, Start (with Monitor), Post.

    Gates (Check, Start): every cluster node Up, no storage job running, every virtual disk Healthy, environment
    HealthState not Failure/Error.

    Values come from environment/azure-local/*.yml (solution_update, gpu.vms, nodes, identity) through Get-NIC26Config;
    the node credential is resolved from Key Vault in memory and never printed. Run on the Windows jump server with
    Azure PowerShell and Azure CLI signed in to the Azure Local subscription. Start-SolutionUpdate prompts for confirmation;
    over remoting nobody can answer, so the script passes -Confirm:$false (the -Execute switch is the confirmation).
.PARAMETER Stage
    State (default) | Import | Check | Start | Monitor | Post | All.
.PARAMETER Execute
    Apply the stage. Without it the script prints what it would do.
.PARAMETER VerifyPayload
    Import: expand the payload zip on this machine and compare every file with the signed inventory (slow, ~1 GB).
.PARAMETER SkipGpuVmHandling
    Start/Post: do not drain/stop/start the DDA GPU VMs.
.PARAMETER StartTimeoutMinutes
    Post: how long to wait for a GPU VM started through Azure to run on the host (default 20).
.PARAMETER HostStartFallback
    Post: if the Azure start does not reach the host in time, start the clustered VM role on the host (Start-ClusterGroup).
    A host-side power change syncs back to Azure on this build. Off by default.
.PARAMETER PollSeconds
    Monitor poll interval (default 60).
.PARAMETER TimeoutHours
    Monitor timeout (default 8).
.PARAMETER EnvironmentPath
    Folder with the azure-local *.yml files (default: <repo>\environment\azure-local).
.EXAMPLE
    .\Invoke-SolutionUpdate.ps1                               # state and gates
    .\Invoke-SolutionUpdate.ps1 -Stage Import -Execute -VerifyPayload
    .\Invoke-SolutionUpdate.ps1 -Stage Check -Execute         # PrepareOnly readiness check
    .\Invoke-SolutionUpdate.ps1 -Stage Start -Execute         # GPU VM drain/stop, start, monitor to Installed
    .\Invoke-SolutionUpdate.ps1 -Stage Post -Execute          # GPU VM back, host pool, versions
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute or -WhatIf); they never run on their own.')]
[CmdletBinding()]
param(
    [ValidateSet('State', 'Import', 'Check', 'Start', 'Monitor', 'Post', 'All')][string]$Stage = 'State',
    [switch]$Execute,
    [switch]$VerifyPayload,
    [switch]$SkipGpuVmHandling,
    [ValidateRange(15, 600)][int]$PollSeconds = 60,
    [ValidateRange(1, 24)][int]$TimeoutHours = 8,
    [ValidateRange(5, 120)][int]$StartTimeoutMinutes = 20,
    [switch]$HostStartFallback,
    [string]$EnvironmentPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Run on the Windows jump server (WinRM to the nodes, credentials in memory).' }

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
Import-Module (Join-Path $repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
$cfgArgs = @{ Scope = 'azure-local' }
if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$cfg = (Get-NIC26Config @cfgArgs).values
$su = $cfg.solution_update
if (-not $su) { throw 'No solution_update block in the azure-local environment.' }

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null }
}
function Write-Step([string]$Message) { Write-Information "$((Get-Date).ToUniversalTime().ToString('HH:mm:ss'))Z $Message" -InformationAction Continue }

$nodeIp = [ordered]@{}
foreach ($n in $cfg.nodes) { $nodeIp[[string]$n.name] = [string]$n.management_ip }
$monitorNode = [string](Get-Prop $su 'monitor_node'); if (-not $monitorNode) { $monitorNode = @($nodeIp.Keys)[-1] }
$nodeOrder = @($monitorNode) + @($nodeIp.Keys | Where-Object { $_ -ne $monitorNode })
$updateId = $null   # resolved from the node: <cluster>/<PackageType><Version>

$user = Resolve-NIC26KeyVaultRef -Ref $cfg.identity.local_admin_username_secret -AsPlainText
$pass = Resolve-NIC26KeyVaultRef -Ref $cfg.identity.local_admin_password_secret
$cred = [pscredential]::new($user, $pass)
Remove-Variable -Name user, pass

function Invoke-OnCluster {
    # Runs on the first reachable node in $nodeOrder (a node may be rebooting during the update).
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [switch]$NoFallback)
    $errs = @()
    foreach ($n in $nodeOrder) {
        try {
            $r = Invoke-Command -ComputerName $nodeIp[$n] -Credential $cred -Authentication Negotiate -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
            return [pscustomobject]@{ Node = $n; Result = $r }
        }
        catch { $errs += "$n : $($_.Exception.Message)"; if ($NoFallback) { break } }
    }
    throw "No node answered: $($errs -join ' | ')"
}

# --- node-side script blocks (Windows PowerShell 5.1 on the node) --------------------------------------------------------
$stateBlock = {
    param($PackageType, $Version)
    $envr = Get-SolutionUpdateEnvironment
    $u = @(Get-SolutionUpdate | Where-Object { [string]$_.PackageType -eq $PackageType -and [string]$_.Version -eq $Version }) | Select-Object -First 1
    $step = $null; $runState = $null; $runId = $null; $runStart = $null
    if ($u) {
        $runs = @()
        try { $runs = @($u | Get-SolutionUpdateRun -ErrorAction Stop) } catch { $runs = @() }   # no run yet
        $run = $runs | Sort-Object { $_.TimeStarted } | Select-Object -Last 1
        if ($run) {
            $runState = [string]$run.State; $runId = [string]$run.ResourceId; $runStart = $run.TimeStarted
            $script:best = $null
            function Find-Active($s, $path, $depth) {
                if ($null -eq $s) { return }
                $p = if ($path) { "$path > $($s.Name)" } else { [string]$s.Name }
                if ([string]$s.Status -in 'InProgress', 'Error') {
                    if (-not $script:best -or $depth -ge $script:best.Depth) { $script:best = [pscustomobject]@{ Path = $p; Status = [string]$s.Status; Error = [string]$s.ErrorMessage; Depth = $depth } }
                }
                foreach ($c in @($s.Steps)) { Find-Active $c $p ($depth + 1) }
            }
            $prog = $run.Progress
            if ($prog) { foreach ($c in @($prog.Steps)) { Find-Active $c '' 1 } }
            $step = $script:best
        }
    }
    [pscustomobject]@{
        Node = $env:COMPUTERNAME
        EnvState = [string]$envr.State; EnvHealth = [string]$envr.HealthState
        CurrentVersion = [string]$envr.CurrentVersion; CurrentSbeVersion = [string]$envr.CurrentSbeVersion
        PackageVersions = (@($envr.PackageVersions | ForEach-Object { "$($_.PackageType): $($_.Version)" }) -join ', ')
        UpdateId = if ($u) { [string]$u.ResourceId } else { $null }
        UpdateState = if ($u) { [string]$u.State } else { $null }
        UpdateStateProperties = if ($u) { [string]$u.UpdateStateProperties } else { $null }
        UpdateHealth = if ($u) { [string]$u.HealthState } else { $null }
        RunId = $runId; RunState = $runState; RunStart = $runStart
        StepPath = if ($step) { $step.Path } else { $null }
        StepStatus = if ($step) { $step.Status } else { $null }
        StepError = if ($step) { $step.Error } else { $null }
        AllUpdates = (@(Get-SolutionUpdate | ForEach-Object { "$($_.ResourceId)=$($_.State)" }) -join '; ')
    }
}
$gateBlock = {
    $issues = @()
    foreach ($n in Get-ClusterNode) { if ([string]$n.State -ne 'Up') { $issues += "cluster node $($n.Name) is $($n.State)" } }
    $jobs = @(Get-StorageJob -ErrorAction SilentlyContinue | Where-Object { [string]$_.JobState -ne 'Completed' })
    if ($jobs.Count -gt 0) { $issues += "$($jobs.Count) storage job(s) running" }
    foreach ($vd in Get-VirtualDisk) { if ([string]$vd.HealthStatus -ne 'Healthy') { $issues += "virtual disk $($vd.FriendlyName) is $($vd.HealthStatus)" } }
    $h = [string](Get-SolutionUpdateEnvironment).HealthState
    if ($h -in 'Failure', 'Error') { $issues += "environment HealthState $h" }
    , $issues
}

function Get-UpdateState {
    $r = Invoke-OnCluster -ScriptBlock $stateBlock -ArgumentList ([string]$su.package_type), ([string]$su.version)
    $r.Result | Add-Member -NotePropertyName ReadFrom -NotePropertyValue $r.Node -Force -PassThru
}
function Assert-Gates {
    $g = (Invoke-OnCluster -ScriptBlock $gateBlock).Result
    $issues = @($g | Where-Object { $_ })
    if ($issues.Count -gt 0) { throw "Gates failed: $($issues -join '; ')" }
    Write-Step 'Gates: every node Up, no storage job, every virtual disk Healthy, environment health OK.'
}
function Show-State($s) {
    Write-Step ("Environment {0}/{1} solution {2} SBE {3} [{4}] (read on {5})" -f $s.EnvState, $s.EnvHealth, $s.CurrentVersion, $s.CurrentSbeVersion, $s.PackageVersions, $s.ReadFrom)
    Write-Step ("Target {0} {1}: {2} {3} health {4}; run {5}" -f $su.package_type, $su.version, $(if ($s.UpdateId) { $s.UpdateId } else { '(not offered)' }), $s.UpdateState, $s.UpdateHealth, $s.RunState)
}
function Wait-UpdateState {
    param([string[]]$Until, [string[]]$FailOn, [int]$TimeoutMinutes, [switch]$ShowSteps)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes); $last = ''
    while ($true) {
        $s = $null
        try { $s = Get-UpdateState } catch { Write-Step "poll: $($_.Exception.Message)" }
        if ($s) {
            $line = "{0} | {1} | run {2}" -f $s.UpdateState, $s.UpdateStateProperties, $s.RunState
            if ($ShowSteps -and $s.StepPath) { $line += " | $($s.StepStatus): $($s.StepPath)" }
            if ($line -ne $last) { Write-Step "[$($s.ReadFrom)] $line"; $last = $line }
            if ($s.UpdateState -in $Until) { return $s }
            if ($s.UpdateState -in $FailOn) { return $s }
        }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutMinutes min waiting for $($Until -join '/')." }
        Start-Sleep -Seconds $PollSeconds
    }
}

# --- package verification (on this machine) ------------------------------------------------------------------------------
function Test-SbePackage {
    $folder = [string](Get-Prop $su 'package_folder')
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { throw "solution_update.package_folder '$folder' not found on this machine." }
    $name = "$($su.package_type)_*_$($su.version)"
    $inv = @(Get-ChildItem -LiteralPath $folder -Filter "$name.xml")
    $zip = @(Get-ChildItem -LiteralPath $folder -Filter "$name.zip")
    $disc = @(Get-ChildItem -LiteralPath $folder -Filter 'SBE_Discovery_*.xml')
    if ($inv.Count -ne 1 -or $zip.Count -ne 1 -or $disc.Count -ne 1) { throw "Expected one discovery xml, one $name.xml and one $name.zip in $folder (Learn step 3)." }
    Add-Type -AssemblyName System.Security
    foreach ($f in @($disc[0], $inv[0])) {
        $x = [xml]::new(); $x.PreserveWhitespace = $true; $x.Load($f.FullName)
        $sig = $x.GetElementsByTagName('Signature', 'http://www.w3.org/2000/09/xmldsig#')
        if ($sig.Count -lt 1) { throw "$($f.Name): no XML signature." }
        $sx = [System.Security.Cryptography.Xml.SignedXml]::new($x); $sx.LoadXml([System.Xml.XmlElement]$sig[0])
        $cert = $null
        foreach ($k in $sx.KeyInfo) { if ($k -is [System.Security.Cryptography.Xml.KeyInfoX509Data]) { $cert = @($k.Certificates)[0]; break } }
        if (-not $cert) { throw "$($f.Name): no signing certificate in KeyInfo." }
        $chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
        $chainOk = $chain.Build($cert)
        if (-not $sx.CheckSignature($cert, $true) -or -not $chainOk) { throw "$($f.Name): signature or certificate chain invalid." }
        Write-Step "$($f.Name): XML signature valid, signer '$($cert.Subject)', issuer '$($cert.Issuer)'."
    }
    $x = [xml](Get-Content -LiteralPath $inv[0].FullName -Raw)
    $bom = @($x.SBEDetailedMetadata.SbeSWBom.File)
    Write-Step "Signed inventory lists $($bom.Count) payload files with SHA-256."
    if ($VerifyPayload) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) "nic26-sbe-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            Expand-Archive -LiteralPath $zip[0].FullName -DestinationPath $tmp
            $bad = @(foreach ($b in $bom) {
                    $p = Join-Path $tmp ([string]$b.RelativePath)
                    if (-not (Test-Path -LiteralPath $p)) { "$($b.RelativePath) missing"; continue }
                    if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne [string]$b.Hash) { "$($b.RelativePath) hash mismatch" }
                })
            if ($bad.Count -gt 0) { throw "Payload check failed: $($bad -join '; ')" }
            Write-Step "Payload: all $($bom.Count) files match the signed inventory."
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    @($disc[0], $inv[0], $zip[0])
}

# --- GPU VM handling (DDA: no live migration) ----------------------------------------------------------------------------
$gpuVms = @(if (-not $SkipGpuVmHandling -and (Get-Prop $cfg 'gpu')) { @(Get-Prop $cfg.gpu 'vms') | Where-Object { $_ } })
$hp = Get-Prop $su 'avd_host_pool'
function Get-SessionHostUri([string]$ComputerName) {
    if (-not $hp) { return $null }
    $sub = [string](Get-Prop $cfg.subscriptions ([string]$hp.subscription_key))
    $base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$($hp.resource_group)/providers/Microsoft.DesktopVirtualization/hostPools/$($hp.name)/sessionHosts"
    $list = az rest --method get --url "$($base)?api-version=2024-04-03" -o json --only-show-errors | ConvertFrom-Json
    $sh = @($list.value | Where-Object { ($_.name -split '/')[-1] -like "$ComputerName.*" -or ($_.name -split '/')[-1] -eq $ComputerName }) | Select-Object -First 1
    if (-not $sh) { return $null }
    [pscustomobject]@{ Uri = "$base/$(($sh.name -split '/')[-1])?api-version=2024-04-03"; Status = [string]$sh.properties.status; Sessions = [int]$sh.properties.sessions; AllowNew = [bool]$sh.properties.allowNewSession }
}
function Set-SessionHostDrain([string]$ComputerName, [bool]$AllowNewSession) {
    $sh = Get-SessionHostUri $ComputerName
    if (-not $sh) { Write-Step "No session host for $ComputerName in $($hp.name) - skipped."; return }
    if ($sh.AllowNew -ne $AllowNewSession) {
        $body = @{ properties = @{ allowNewSession = $AllowNewSession } } | ConvertTo-Json -Compress
        $bodyFile = New-TemporaryFile; Set-Content -LiteralPath $bodyFile -Value $body
        try { az rest --method patch --url $sh.Uri --body "@$bodyFile" --only-show-errors -o none } finally { Remove-Item $bodyFile -Force }
        if ($LASTEXITCODE -ne 0) { throw "Session host $ComputerName allowNewSession=$AllowNewSession failed." }
    }
    $sh = Get-SessionHostUri $ComputerName
    Write-Step "Session host $ComputerName allowNewSession=$($sh.AllowNew) status=$($sh.Status) sessions=$($sh.Sessions)"
    $sh
}
function Get-ArcVmPower([string]$Name) {
    $j = az stack-hci-vm show -g $cfg.vm_management.resource_group --name $Name --subscription $cfg.subscription_id -o json --only-show-errors | ConvertFrom-Json
    $st = Get-Prop (Get-Prop $j 'properties') 'status'
    [string](Get-Prop $st 'powerState')
}
function Stop-GpuVms {
    foreach ($vm in $gpuVms) {
        $sh = Set-SessionHostDrain ([string]$vm.computer_name) $false
        if ($sh -and $sh.Sessions -gt 0) { throw "$($vm.computer_name) has $($sh.Sessions) session(s); sign them out first (drain mode is on)." }
        $pw = Get-ArcVmPower $vm.name
        if ($pw -eq 'Running') {
            Write-Step "Stopping $($vm.name) (DDA GPU VM, cannot live-migrate)."
            az stack-hci-vm stop -g $cfg.vm_management.resource_group --name $vm.name --subscription $cfg.subscription_id --only-show-errors -o none
            if ($LASTEXITCODE -ne 0) { throw "az stack-hci-vm stop $($vm.name) failed." }
        }
        Write-Step "$($vm.name) power state: $(Get-ArcVmPower $vm.name)"
    }
}
function Get-HostVmState([string]$Name) {
    # State of the clustered VM role on the host (Hyper-V name = Azure name + unique suffix on this build)
    foreach ($n in $nodeIp.Keys) {
        $st = Invoke-Command -ComputerName $nodeIp[$n] -Credential $cred -Authentication Negotiate -ScriptBlock {
            param($Prefix) $v = Get-VM | Where-Object { $_.Name -like "$Prefix*" } | Select-Object -First 1; if ($v) { [string]$v.State }
        } -ArgumentList $Name
        if ($st) { return $st }
    }
    'NotFound'
}
function Start-GpuVms {
    foreach ($vm in $gpuVms) {
        if ((Get-HostVmState $vm.name) -ne 'Running' -and (Get-ArcVmPower $vm.name) -ne 'Running') {
            Write-Step "Starting $($vm.name) (az stack-hci-vm start --no-wait)."
            az stack-hci-vm start -g $cfg.vm_management.resource_group --name $vm.name --subscription $cfg.subscription_id --no-wait --only-show-errors -o none
            if ($LASTEXITCODE -ne 0) { Write-Warning "az stack-hci-vm start $($vm.name) returned $LASTEXITCODE (a previous operation may still be running)." }
            $deadline = (Get-Date).AddMinutes($StartTimeoutMinutes)
            while ((Get-HostVmState $vm.name) -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 30 }
            if ((Get-HostVmState $vm.name) -ne 'Running') {
                # 12 Oct 2026: after the rolling SBE update the Azure start stayed InProgress and never reached the host.
                # A host-side power-on is synced back to Azure on this build; it runs only with -HostStartFallback.
                if (-not $HostStartFallback) { throw "$($vm.name) did not start within $StartTimeoutMinutes min (Azure: $(Get-ArcVmPower $vm.name)). Re-run -Stage Post -Execute -HostStartFallback to start the clustered VM role on the host." }
                Write-Step "Azure start did not reach the host; Start-ClusterGroup for $($vm.name) (-HostStartFallback)."
                Invoke-OnCluster -ScriptBlock {
                    param($Prefix) $g = Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' -and $_.Name -like "$Prefix*" } | Select-Object -First 1
                    Start-ClusterGroup -Name $g.Name -Wait 300 | Out-Null
                } -ArgumentList ([string]$vm.name) | Out-Null
            }
        }
        Write-Step "$($vm.name) host state: $(Get-HostVmState $vm.name); Azure power state: $(Get-ArcVmPower $vm.name)"
        # Hyper-V name on this build = Azure name lowercased + unique suffix; read the DDA device on the owning node
        foreach ($n in $nodeIp.Keys) {
            $dda = Invoke-Command -ComputerName $nodeIp[$n] -Credential $cred -Authentication Negotiate -ScriptBlock {
                param($Prefix)
                $v = Get-VM | Where-Object { $_.Name -like "$Prefix*" } | Select-Object -First 1
                if ($v) {
                    # Azure Local assigns from a resource pool (ResourcePoolName ArcVMGpuPool, LocationPath empty): report
                    # the pool and the host's dismounted (assignable) devices, which is where the GPU comes from
                    $d = @(Get-VMAssignableDevice -VMName $v.Name -ErrorAction SilentlyContinue)
                    $hostDev = @(Get-VMHostAssignableDevice -ErrorAction SilentlyContinue | ForEach-Object { $_.LocationPath })
                    "$($v.State) on $env:COMPUTERNAME, $($d.Count) DDA device(s) $((@($d | ForEach-Object { if ($_.LocationPath) { $_.LocationPath } else { "pool $($_.ResourcePoolName)" } }) -join ',')); host assignable $($hostDev -join ',')"
                }
            } -ArgumentList ([string]$vm.name)
            if ($dda) {
                Write-Step "$($vm.name) DDA: $dda"
                $expected = @($cfg.gpu.hosts | ForEach-Object { [string]$_.location_path } | Select-Object -Unique)
                if (-not @($expected | Where-Object { $dda -like "*$_*" })) { Write-Warning "$($vm.name): the assigned device is not at a gpu.hosts location path ($($expected -join ', ')) - check PCI enumeration after the firmware update." }
                break
            }
        }
        $deadline = (Get-Date).AddMinutes(20)
        do {
            $sh = Set-SessionHostDrain ([string]$vm.computer_name) $true
            if (-not $sh -or $sh.Status -eq 'Available') { break }
            Start-Sleep -Seconds 30
        } while ((Get-Date) -lt $deadline)
    }
}

# --- stages --------------------------------------------------------------------------------------------------------------
$s = Get-UpdateState
Show-State $s
$updateId = $s.UpdateId
$stages = if ($Stage -eq 'All') { 'Import', 'Check', 'Start', 'Post' } else { @($Stage) }
if ($Stage -eq 'State') { (Invoke-OnCluster -ScriptBlock $gateBlock).Result | ForEach-Object { if ($_) { Write-Warning "Gate: $_" } }; return $s }
if (-not $Execute) {
    Write-Warning "Plan only ($($stages -join ', ')): nothing changed. Re-run with -Execute. GPU VMs handled: $(@($gpuVms | ForEach-Object { $_.name }) -join ', ')"
    return $s
}

foreach ($st in $stages) {
    switch ($st) {
        'Import' {
            if ($s.UpdateState -and $s.UpdateState -notin 'AdditionalContentRequired') { Write-Step "Import skipped: update state is $($s.UpdateState)."; break }
            $files = Test-SbePackage
            $session = New-PSSession -ComputerName $nodeIp[$monitorNode] -Credential $cred -Authentication Negotiate
            try {
                Invoke-Command -Session $session -ScriptBlock { param($p) if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory | Out-Null } } -ArgumentList $su.import_folder
                foreach ($f in $files) {
                    $local = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                    $dest = Join-Path $su.import_folder $f.Name
                    $remote = Invoke-Command -Session $session -ScriptBlock { param($p) if (Test-Path $p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } } -ArgumentList $dest
                    if ($remote -eq $local) { Write-Step "$($f.Name) already in the import folder (same SHA-256)."; continue }
                    Write-Step "Copying $($f.Name) ($([math]::Round($f.Length / 1MB)) MB) to $monitorNode."
                    Copy-Item -LiteralPath $f.FullName -Destination $dest -ToSession $session -Force
                    $remote = Invoke-Command -Session $session -ScriptBlock { param($p) (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash } -ArgumentList $dest
                    if ($remote -ne $local) { throw "$($f.Name): SHA-256 after copy differs." }
                }
                Write-Step "Add-SolutionUpdate -SourceFolder $($su.import_folder)"
                Invoke-Command -Session $session -ScriptBlock { param($p) Add-SolutionUpdate -SourceFolder $p } -ArgumentList $su.import_folder | Out-Null
            }
            finally { Remove-PSSession $session }
            $s = Wait-UpdateState -Until 'Ready', 'ReadyToInstall', 'Installed' -FailOn 'Invalid', 'Recalled' -TimeoutMinutes 45
            $updateId = $s.UpdateId
            if ($s.UpdateState -notin 'Ready', 'ReadyToInstall', 'Installed') { throw "Import ended in $($s.UpdateState): $($s.UpdateStateProperties)" }
        }
        'Check' {
            if ($s.UpdateState -in 'ReadyToInstall', 'Installed', 'Installing') { Write-Step "Check skipped: $($s.UpdateState)."; break }
            Assert-Gates
            Write-Step "Start-SolutionUpdate -PrepareOnly ($updateId)"
            (Invoke-OnCluster -NoFallback -ScriptBlock { param($id) Get-SolutionUpdate -Id $id | Start-SolutionUpdate -PrepareOnly -Confirm:$false } -ArgumentList $updateId).Result | ForEach-Object { Write-Step "Run: $_" }
            $s = Wait-UpdateState -Until 'ReadyToInstall' -FailOn 'HealthCheckFailed', 'PreparationFailed', 'DownloadFailed' -TimeoutMinutes 120 -ShowSteps
            if ($s.UpdateState -ne 'ReadyToInstall') {
                $fails = (Invoke-OnCluster -ScriptBlock { param($id) (Get-SolutionUpdate -Id $id).HealthCheckResult | Where-Object { $_.Status -ne 'SUCCESS' } | ForEach-Object { "$($_.Severity) $($_.Title): $($_.Description) -> $($_.Remediation)" } } -ArgumentList $updateId).Result
                $fails | ForEach-Object { Write-Warning $_ }
                throw "Readiness check ended in $($s.UpdateState) (step: $($s.StepPath) $($s.StepError))."
            }
            $warn = (Invoke-OnCluster -ScriptBlock { param($id) (Get-SolutionUpdate -Id $id).HealthCheckResult | Where-Object { $_.Status -ne 'SUCCESS' } | ForEach-Object { "$($_.Severity) $($_.Title)" } } -ArgumentList $updateId).Result
            @($warn) | Where-Object { $_ } | ForEach-Object { Write-Warning "Readiness: $_" }
        }
        'Start' {
            if ($s.UpdateState -eq 'Installed') { Write-Step 'Already installed.'; break }
            if ($s.UpdateState -ne 'Installing') {
                Assert-Gates
                if ($gpuVms.Count -gt 0) { Stop-GpuVms }
                Write-Step "Start-SolutionUpdate ($updateId)"
                (Invoke-OnCluster -NoFallback -ScriptBlock { param($id) Get-SolutionUpdate -Id $id | Start-SolutionUpdate -Confirm:$false } -ArgumentList $updateId).Result | ForEach-Object { Write-Step "Run: $_" }
            }
            $s = Wait-UpdateState -Until 'Installed' -FailOn 'InstallationFailed', 'HealthCheckFailed', 'PreparationFailed', 'DownloadFailed' -TimeoutMinutes ($TimeoutHours * 60) -ShowSteps
            if ($s.UpdateState -ne 'Installed') {
                Write-Warning "Failing step: $($s.StepPath)"
                Write-Warning "Error: $($s.StepError)"
                Write-Warning "Run $($s.RunId). Fix the documented cause, then: Get-SolutionUpdate -Id $updateId | Start-SolutionUpdate (Learn step 7) = this script -Stage Start -Execute."
                throw "Update ended in $($s.UpdateState)."
            }
            Write-Step "Installed. Run $($s.RunId) started $($s.RunStart)."
        }
        'Monitor' {
            $s = Wait-UpdateState -Until 'Installed', 'ReadyToInstall' -FailOn 'InstallationFailed', 'HealthCheckFailed', 'PreparationFailed', 'DownloadFailed' -TimeoutMinutes ($TimeoutHours * 60) -ShowSteps
        }
        'Post' {
            # firmware can reset UEFI variables or re-enumerate PCI: read Secure Boot, BIOS and the cluster state per node
            foreach ($n in $nodeIp.Keys) {
                $r = Invoke-Command -ComputerName $nodeIp[$n] -Credential $cred -Authentication Negotiate -ScriptBlock {
                    $sb = try { Confirm-SecureBootUEFI } catch { 'n/a' }
                    "$env:COMPUTERNAME BIOS $((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion) SecureBoot $sb cluster node $((Get-ClusterNode -Name $env:COMPUTERNAME).State)"
                }
                Write-Step $r
            }
            (Invoke-OnCluster -ScriptBlock $gateBlock).Result | ForEach-Object { if ($_) { Write-Warning "Gate: $_" } }
            if ($gpuVms.Count -gt 0) { Start-GpuVms }
            $s = Get-UpdateState
            Show-State $s
        }
    }
}
$s
