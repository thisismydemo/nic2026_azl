#Requires -Version 7.0
<#
.SYNOPSIS
    Checks that the jump server session can run the demo scripts (modules, context, files, guards). Read-only.
.DESCRIPTION
    Pass/fail list: PowerShell 7.4+, Windows host, no transcript, required modules present, Azure CLI, Az context,
    NIC26.Automation loadable, environment files load for the requested scope(s), the secret map exists, the demo
    state folder is writable, no fault lock is active. Exit code 0 when nothing is RED (use -PassThru to get the rows
    without exiting).
.PARAMETER Scope
    azure-local | avd | all (default all) - which environment scope(s) to load.
.PARAMETER SkipAzure
    Skip the Az context and Azure CLI checks (offline authoring).
.PARAMETER PassThru
    Return the check rows instead of exiting with a code.
.EXAMPLE
    ./Test-DemoPrerequisites.ps1 -Scope azure-local
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [Parameter()]
    [ValidateSet('azure-local', 'avd', 'all')]
    [string] $Scope = 'all',

    [switch] $SkipAzure,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$checks = [System.Collections.Generic.List[pscustomobject]]::new()

$checks.Add((New-DemoCheck -Section 'host' -Name 'PowerShell 7.4 or later' -Passed ($PSVersionTable.PSVersion -ge [version]'7.4') -Detail $PSVersionTable.PSVersion.ToString()))
$checks.Add((New-DemoCheck -Section 'host' -Name 'Windows host (K-8)' -Passed (Test-DemoWindowsHost) -Detail $(if (Test-DemoWindowsHost) { 'Windows' } else { 'not Windows' })))
$checks.Add((New-DemoCheck -Section 'host' -Name 'No transcript active' -Passed (-not (Test-DemoTranscriptActive))))

$requiredModules = @(
    @{ Name = 'Az.Accounts'; Why = 'context' }, @{ Name = 'Az.KeyVault'; Why = 'Copy-DemoSecrets' }, @{ Name = 'Az.Resources'; Why = 'ARB, role assignments' },
    @{ Name = 'Az.Compute'; Why = 'Azure-realm hosts' }, @{ Name = 'Az.DesktopVirtualization'; Why = 'AVD state' }, @{ Name = 'Az.RecoveryServices'; Why = 'ASR' },
    @{ Name = 'Az.OperationalInsights'; Why = 'Insights queries' }, @{ Name = 'Az.Storage'; Why = 'FSLogix share metadata' },
    @{ Name = 'Microsoft.Graph.Groups'; Why = 'Switch-UserHostPool' }, @{ Name = 'Microsoft.Graph.Users'; Why = 'Switch-UserHostPool' },
    @{ Name = 'powershell-yaml'; Why = 'environment files, secret map' }
)
foreach ($m in $requiredModules) {
    $found = Get-Module -ListAvailable -Name $m.Name | Sort-Object -Property Version -Descending | Select-Object -First 1
    $checks.Add((New-DemoCheck -Section 'modules' -Name $m.Name -Passed ($null -ne $found) -Detail $(if ($found) { "v$($found.Version) ($($m.Why))" } else { "missing ($($m.Why))" })))
}
$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version.Major -eq 5 } | Select-Object -First 1
$checks.Add((New-DemoCheck -Section 'modules' -Name 'Pester 5 (tests only)' -Passed ($null -ne $pester) -Skipped:($null -eq $pester) -Detail $(if ($pester) { "v$($pester.Version)" } else { 'not installed; tests cannot run here' })))

if ($SkipAzure) {
    $checks.Add((New-DemoCheck -Section 'azure' -Name 'Az context' -Skipped -Detail '-SkipAzure'))
    $checks.Add((New-DemoCheck -Section 'azure' -Name 'Azure CLI (az stack-hci-vm)' -Skipped -Detail '-SkipAzure'))
}
else {
    $checks.Add((New-DemoCheck -Section 'azure' -Name 'Az context' -Passed (Test-DemoAzContext) -Detail $(if (Test-DemoAzContext) { 'signed in' } else { 'run Connect-AzAccount' })))
    $az = Get-Command -Name az -ErrorAction SilentlyContinue
    $checks.Add((New-DemoCheck -Section 'azure' -Name 'Azure CLI (az stack-hci-vm)' -Passed ($null -ne $az) -Detail $(if ($az) { 'present' } else { 'missing (Azure Local realm VM stop/start)' })))
}

$sharedModule = Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'powershell' 'NIC26.Automation' 'NIC26.Automation.psd1'
$checks.Add((New-DemoCheck -Section 'repo' -Name 'NIC26.Automation module' -Passed (Test-Path -LiteralPath $sharedModule) -Detail 'automation/shared/powershell/NIC26.Automation'))
$secretMap = Join-Path $PSScriptRoot '..' '..' '..' '..' 'environment' 'shared' 'secret-map.yml'
$checks.Add((New-DemoCheck -Section 'repo' -Name 'secret-map.yml (names only)' -Passed (Test-Path -LiteralPath $secretMap) -Detail 'environment/shared/secret-map.yml'))

$scopes = if ($Scope -eq 'all') { @('azure-local', 'avd') } else { @($Scope) }
foreach ($s in $scopes) {
    try {
        $null = Get-DemoConfig -Scope $s
        $checks.Add((New-DemoCheck -Section 'repo' -Name "environment files load ($s)" -Passed $true -Detail 'schema valid'))
    }
    catch {
        $checks.Add((New-DemoCheck -Section 'repo' -Name "environment files load ($s)" -Passed $false -Detail (($_.Exception.Message -split "`n")[0])))
    }
}

try {
    $root = Get-DemoStateRoot
    $probe = Join-Path $root ('probe-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $probe -Value 'ok' -Encoding ascii
    Remove-Item -LiteralPath $probe -Force
    $checks.Add((New-DemoCheck -Section 'state' -Name 'Demo state folder writable' -Passed $true -Detail 'NIC26_DEMO_STATE_DIR or LOCALAPPDATA\nic26-demo'))
}
catch {
    $checks.Add((New-DemoCheck -Section 'state' -Name 'Demo state folder writable' -Passed $false -Detail (($_.Exception.Message -split "`n")[0])))
}
$locks = @(Get-DemoFaultLock -Scope all)
$checks.Add((New-DemoCheck -Section 'state' -Name 'No fault lock active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ') + ' - run the matching Undo-* script' })))

Write-DemoCheckTable -Check $checks.ToArray() -Title 'Demo prerequisites'
$code = Get-DemoCheckExitCode -Check $checks.ToArray()
if ($PassThru) { return $checks.ToArray() }
exit $code
