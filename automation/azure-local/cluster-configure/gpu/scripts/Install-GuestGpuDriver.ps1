#Requires -Version 5.1
<#
.SYNOPSIS
    Inside a DDA GPU session host: installs the NVIDIA data center driver for the passed-through GPU and applies the
    Azure Virtual Desktop GPU acceleration policies (local policy registry values). Idempotent.
.DESCRIPTION
    Runs in the guest (Windows 11 Enterprise multi-session or Windows Server), elevated - locally, through
    az connectedmachine run-command, or from the AVD session-host build. Windows PowerShell 5.1 compatible because a
    fresh session host has no PowerShell 7.
      1. Finds the NVIDIA GPU (PCI\VEN_10DE). If the NVIDIA driver of -DriverVersion is already bound, skips the install.
      2. Downloads the installer from -DriverUrl (HTTPS) and runs it silently (-s -noreboot -clean).
      3. Sets the policies from Learn "Enable GPU acceleration for Azure Virtual Desktop"
         (https://learn.microsoft.com/azure/virtual-desktop/graphics-enable-gpu-acceleration):
           Use hardware graphics adapters for all RDS sessions        bEnumerateHWBeforeSW = 1
           Prioritize H.264/AVC 444 graphics mode                     AVC444ModePreferred  = 1
           Configure H.264/AVC hardware encoding                      AVCHardwareEncodePreferred = 1
         H.265/HEVC hardware encoding is set with the Azure Virtual Desktop administrative template (GPO) or the Intune
         settings catalog, not here. Domain GPOs or Intune win over these local values when they set the same policy.
      4. Reports nvidia-smi (name, driver, driver model) and whether a restart is pending.
    The driver version and URL are parameters (values in environment/azure-local/gpu.yml, gpu.guest_driver).
.PARAMETER DriverUrl
    HTTPS URL of the NVIDIA data center driver installer for Windows.
.PARAMETER DriverVersion
    Expected driver version as nvidia-smi reports it (e.g. 553.62).
.PARAMETER Restart
    Restart the VM when the install or the policies need it.
.EXAMPLE
    .\Install-GuestGpuDriver.ps1 -DriverUrl https://example.invalid/driver.exe -DriverVersion 0.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^https://')][string]$DriverUrl,
    [Parameter(Mandatory)][string]$DriverVersion,
    [switch]$Restart
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$gpu = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' })
if ($gpu.Count -eq 0) { throw 'No NVIDIA PCI device in this VM: attach the GPU first (Set-VmGpuAssignment.ps1).' }

$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
function Get-NvidiaState {
    if (-not (Test-Path -LiteralPath $smi)) { return $null }
    # one argument each, no spaces inside (nvidia-smi rejects 'name, driver_version')
    $line = & $smi '--query-gpu=name,driver_version,driver_model.current' '--format=csv,noheader' 2>$null | Select-Object -First 1
    if (-not $line) { return $null }
    $f = @($line -split ',\s*')
    if ($f.Count -lt 3) { return [pscustomobject]@{ Name = $null; Driver = $null; DriverModel = $null; Raw = [string]$line } }
    [pscustomobject]@{ Name = $f[0]; Driver = $f[1]; DriverModel = $f[2]; Raw = [string]$line }
}

$needsRestart = $false
$state = Get-NvidiaState
if ($state -and $state.Driver -eq $DriverVersion) {
    Write-Output "Driver $DriverVersion already installed ($($state.Name), $($state.DriverModel))."
}
elseif ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Install NVIDIA data center driver $DriverVersion")) {
    $dir = Join-Path $env:ProgramData 'nic26\gpu'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $exe = Join-Path $dir ([IO.Path]::GetFileName(([uri]$DriverUrl).AbsolutePath))
    if (-not (Test-Path -LiteralPath $exe)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DriverUrl -OutFile $exe -UseBasicParsing
    }
    $sig = Get-AuthenticodeSignature -FilePath $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'NVIDIA') { throw "Installer signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)" }
    $p = Start-Process -FilePath $exe -ArgumentList '-s', '-noreboot', '-clean' -Wait -PassThru
    Write-Output "NVIDIA installer exit code $($p.ExitCode)."
    if ($p.ExitCode -notin 0, 1, 3010) { throw "NVIDIA installer failed with exit code $($p.ExitCode)." }
    $needsRestart = $true
}

# AVD GPU acceleration policies (local policy registry; same values the ADMX policies write)
$ts = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$values = [ordered]@{ bEnumerateHWBeforeSW = 1; AVC444ModePreferred = 1; AVCHardwareEncodePreferred = 1 }
if (-not (Test-Path $ts)) { New-Item -Path $ts -Force | Out-Null }
foreach ($k in $values.Keys) {
    $cur = (Get-ItemProperty -Path $ts -Name $k -ErrorAction SilentlyContinue)
    if (-not $cur -or $cur.$k -ne $values[$k]) {
        if ($PSCmdlet.ShouldProcess("$ts\$k", "Set $($values[$k])")) { New-ItemProperty -Path $ts -Name $k -PropertyType DWord -Value $values[$k] -Force | Out-Null; $needsRestart = $true }
    }
}

$state = Get-NvidiaState
[pscustomobject]@{
    Computer     = $env:COMPUTERNAME
    Gpu          = if ($state) { $state.Name } else { ($gpu | Select-Object -First 1).FriendlyName }
    Driver       = if ($state) { $state.Driver } else { 'not reported (restart pending?)' }
    DriverModel  = if ($state) { $state.DriverModel } else { '' }
    Policies     = ($values.Keys -join ', ')
    RestartNeeded = $needsRestart
}
if ($needsRestart -and $Restart -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Restart')) { Restart-Computer -Force }
