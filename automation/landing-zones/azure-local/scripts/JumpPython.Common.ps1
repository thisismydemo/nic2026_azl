#Requires -Version 7.0
<#
.SYNOPSIS
    Installs and inventories pinned all-users Python and the shared template-rendering environment.
.DESCRIPTION
    Called by Install-JumpTools; versions and artifact hashes come from its canonical manifest.
    The Windows runtime does not replace the Linux Ansible control node.
.NOTES
    Author: Kristopher Turner
    Contact: kris@hybridsolutions.cloud
    Version: 1.0.0
    TaskReference: T-3.1.3b
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JumpPythonLayout {
    param([System.Collections.IDictionary]$Spec)
    $root = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
    foreach ($directory in @($Spec.Python.InstallDirectory, $Spec.Python.RendererDirectory)) {
        if ([string]::IsNullOrWhiteSpace($directory) -or [IO.Path]::IsPathRooted($directory) -or $directory -match '(^|[\\/])\.\.([\\/]|$)|:') { throw 'Python directories must be relative to machine Program Files.' }
    }
    $runtime = [IO.Path]::GetFullPath((Join-Path $root $Spec.Python.InstallDirectory))
    $renderer = [IO.Path]::GetFullPath((Join-Path $root $Spec.Python.RendererDirectory))
    foreach ($directory in @($runtime, $renderer)) {
        if (-not $directory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Python directory escapes machine scope.' }
        $current = $directory
        while ($current -ne $root) {
            if (Test-Path -LiteralPath $current) {
                if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Python machine path traverses a reparse point.' }
            }
            $current = Split-Path -Parent $current
        }
    }
    [pscustomobject]@{ Runtime=$runtime; Python=(Join-Path $runtime 'python.exe'); Renderer=$renderer; RendererPython=(Join-Path $renderer 'Scripts/python.exe') }
}

function Get-JumpPythonProbe {
    param([string]$Interpreter, [switch]$Renderer)
    if (-not (Test-Path -LiteralPath $Interpreter -PathType Leaf)) { return $null }
    $code = 'import json,sys,struct,ssl,pip; print(json.dumps({"version":".".join(map(str,sys.version_info[:3])),"bits":struct.calcsize("P")*8,"pip":pip.__version__,"ssl":ssl.OPENSSL_VERSION}))'
    if ($Renderer) { $code = 'import json,sys,struct,ssl,jinja2,yaml,markupsafe,importlib.metadata; print(json.dumps({"version":".".join(map(str,sys.version_info[:3])),"bits":struct.calcsize("P")*8,"packages":{n:importlib.metadata.version(n) for n in ["Jinja2","PyYAML","MarkupSafe"]}}))' }
    $result = & $Interpreter -I -c $code 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $result | ConvertFrom-Json
}

function Get-JumpPythonRegistration {
    param([string]$Version)
    $minor = ($Version -split '\.')[0..1] -join '.'
    $key = 'HKLM:\SOFTWARE\Python\PythonCore\' + $minor + '\InstallPath'
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    return (Get-Item -LiteralPath $key).GetValue('')
}

function Get-InstalledJumpPythonVersion {
    param([System.Collections.IDictionary]$Spec)
    $layout = Get-JumpPythonLayout -Spec $Spec
    if (-not (Test-Path -LiteralPath $layout.Python -PathType Leaf)) { return $null }
    $signature = Get-AuthenticodeSignature -LiteralPath $layout.Python
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Spec.Python.Publisher) { return $null }
    if ((Get-Item -LiteralPath $layout.Python).VersionInfo.ProductVersion -cne $Spec.Version) { return $null }
    $registration = Get-JumpPythonRegistration -Version $Spec.Version
    if (-not $registration -or $registration.TrimEnd('\') -ine $layout.Runtime) { return $null }
    $runtime = Get-JumpPythonProbe -Interpreter $layout.Python
    $renderer = Get-JumpPythonProbe -Interpreter $layout.RendererPython -Renderer
    if ($null -eq $runtime -or $null -eq $renderer -or $runtime.version -cne $Spec.Version -or $renderer.version -cne $Spec.Version -or $runtime.bits -ne 64 -or $renderer.bits -ne 64) { return $null }
    foreach ($package in $Spec.Python.Packages) { if ($renderer.packages.($package.Name) -cne $package.Version) { return $null } }
    $path = @([Environment]::GetEnvironmentVariable('Path', 'Machine') -split ';' | ForEach-Object { $_.TrimEnd('\') })
    if ($layout.Runtime -notin $path -or (Join-Path $layout.Runtime 'Scripts') -notin $path -or [Environment]::GetEnvironmentVariable('NIC26_PYTHON', 'Machine') -ine $layout.RendererPython) { return $null }
    return $Spec.Version
}

function Assert-JumpPythonArtifact {
    param([string]$Installer, [string]$WheelDirectory, [System.Collections.IDictionary]$Spec)
    if ($Spec.Python.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Installer -Algorithm SHA256).Hash -ine $Spec.Python.Sha256) { throw 'Python installer hash mismatch.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Installer
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -cne $Spec.Python.Publisher) { throw 'Python installer signature mismatch.' }
    foreach ($package in $Spec.Python.Packages) {
        if ($package.File -notmatch '^[A-Za-z0-9_.-]+\.whl$' -or $package.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $WheelDirectory $package.File) -Algorithm SHA256).Hash -ine $package.Sha256) { throw 'Pinned renderer wheel hash mismatch.' }
    }
}

function Invoke-JumpPythonSetup {
    [CmdletBinding(SupportsShouldProcess)]
    param([System.Collections.IDictionary]$Spec)
    $layout = Get-JumpPythonLayout -Spec $Spec
    $pin = $Spec.Python
    if ($pin.DownloadUrl -notmatch '^https://www\.python\.org/ftp/python/[0-9.]+/python-[0-9.]+-amd64\.exe$') { throw 'Python installer source is not the pinned official x64 source.' }
    foreach ($package in $pin.Packages) {
        if ($package.Url -notmatch '^https://files\.pythonhosted\.org/packages/' -or $package.File -notmatch '^[A-Za-z0-9_.-]+\.whl$') { throw 'Renderer wheel source pin is invalid.' }
    }
    $lockFile = Join-Path $PSScriptRoot 'jump-python.requirements.lock.txt'
    $expected = @($pin.Packages | ForEach-Object { '{0}=={1} --hash=sha256:{2}' -f $_.Name, $_.Version, $_.Sha256 }) -join "`n"
    if ((Get-Content -LiteralPath $lockFile -Raw).Trim().Replace("`r`n", "`n") -cne $expected) { throw 'Renderer requirements lock and manifest pins disagree.' }
    if (-not $PSCmdlet.ShouldProcess('Machine Python and shared renderer', 'Install pinned verified artifacts')) { return }
    if (-not (Test-JumpElevated)) { throw 'Python machine installation requires elevation.' }
    # The shared secure-staging helper reserves a unique administrator/SYSTEM-only directory.
    $staging = New-JumpMsixStagingDirectory
    try {
        $installer = Join-Path $staging 'python-installer.exe'
        $wheels = Join-Path $staging 'wheels'
        New-Item -Path $wheels -ItemType Directory | Out-Null
        Invoke-WebRequest -Uri $pin.DownloadUrl -OutFile $installer -TimeoutSec 120
        foreach ($package in $pin.Packages) { Invoke-WebRequest -Uri $package.Url -OutFile (Join-Path $wheels $package.File) -TimeoutSec 60 }
        Assert-JumpPythonArtifact -Installer $installer -WheelDirectory $wheels -Spec $Spec
        $runtime = Get-JumpPythonProbe -Interpreter $layout.Python
        if ($null -ne $runtime -and $runtime.version -cne $Spec.Version) { throw 'Different machine Python version present; review upgrade scope first.' }
        if ($null -eq $runtime) {
            $arguments = '/quiet InstallAllUsers=1 TargetDir="' + $layout.Runtime + '" Include_pip=1 Include_launcher=1 InstallLauncherAllUsers=1 PrependPath=1 Include_test=0 Include_tcltk=1'
            $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
            if ($process.ExitCode -ne 0) { throw "Python installer exit $($process.ExitCode); no restart attempted." }
        }
        $runtime = Get-JumpPythonProbe -Interpreter $layout.Python
        if ($null -eq $runtime -or $runtime.version -cne $Spec.Version -or $runtime.bits -ne 64) { throw 'Pinned x64 runtime acceptance failed.' }
        if (-not (Test-Path -LiteralPath $layout.RendererPython -PathType Leaf)) {
            & $layout.Python -I -m venv $layout.Renderer
            if ($LASTEXITCODE -ne 0) { throw 'Shared renderer environment creation failed.' }
        }
        & $layout.RendererPython -I -m pip install --disable-pip-version-check --no-index --only-binary=:all: --find-links $wheels --require-hashes -r $lockFile
        if ($LASTEXITCODE -ne 0) { throw 'Offline locked renderer dependency setup failed.' }
        & $layout.RendererPython -I -m pip check
        if ($LASTEXITCODE -ne 0) { throw 'Renderer dependency consistency check failed.' }
        [Environment]::SetEnvironmentVariable('NIC26_PYTHON', $layout.RendererPython, 'Machine')
        if (Get-InstalledJumpPythonVersion -Spec $Spec) { return }
        throw 'Python machine/renderer registration and pins failed final verification.'
    }
    finally {
        $verifiedStaging = [IO.Path]::GetFullPath($staging)
        $stagingRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'JumpTools/MSIXStaging')).TrimEnd('\') + '\'
        if (-not $verifiedStaging.StartsWith($stagingRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected Python staging cleanup path; retained.' }
        Remove-Item -LiteralPath $verifiedStaging -Recurse -Force -ErrorAction Stop
    }
}
