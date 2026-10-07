#Requires -Version 7.0
<#
.SYNOPSIS
    Pre-session reset: removes every REVERSIBLE Day-2 control by calling each control's own remove step, so the
    readiness gate shows red in outline §2.6 and the controls are re-applied live in §3. -WhatIf is the default.
.DESCRIPTION
    Reads day2-controls.yml, resolves each reversible control's remove script under automation/azure-local/, and
    lists exactly what it would remove (control, outline section, script path, present/missing). With -Execute the
    remove scripts run with -Execute in reverse outline order (3.5 -> 3.1); the removed keys are recorded in the demo
    state folder so Restore-Day2Controls.ps1 knows what to re-apply. Controls marked reversible: false (backup,
    Site Recovery, PIM, security baseline, workload platform) are listed as KEPT and never touched. A control whose
    remove script does not exist blocks -Execute unless -SkipMissing.
.PARAMETER Control
    Restrict to these control keys.
.PARAMETER RegistryPath
    day2-controls.yml (default: next to this script's folder).
.PARAMETER Execute
    Run the remove steps.
.PARAMETER SkipMissing
    Skip controls whose remove script is not present instead of refusing.
.PARAMETER PassThru
    Return the plan rows.
.EXAMPLE
    ./Reset-Day2Controls.ps1
    ./Reset-Day2Controls.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject[]])]
param(
    [Parameter()]
    [string[]] $Control = @(),

    [Parameter()]
    [string] $RegistryPath,

    [switch] $Execute,
    [switch] $SkipMissing,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }
if (-not (Get-Command -Name ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { Import-Module powershell-yaml -ErrorAction Stop }

if (-not $RegistryPath) { $RegistryPath = Join-Path $PSScriptRoot '..' 'day2-controls.yml' }
$registry = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $RegistryPath -Raw) -Ordered
$solutionRoot = Join-Path $PSScriptRoot '..' '..' '..' 'azure-local'
$statePath = Join-Path (Get-DemoStateRoot) 'day2-reset.json'

$plan = foreach ($c in $registry.controls) {
    $key = [string]$c.key
    if ($Control.Count -gt 0 -and $key -notin $Control) { continue }
    $reversible = [bool]$c.reversible
    $scriptPath = if ($reversible -and $c.remove_script) { Join-Path $solutionRoot ([string]$c.solution) ([string]$c.remove_script) } else { '' }
    $exists = ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf))
    $stepArguments = @{}
    if ($c.Contains('remove_args') -and $c.remove_args) { foreach ($k in $c.remove_args.Keys) { $stepArguments[[string]$k] = $c.remove_args[$k] } }
    [pscustomobject]@{
        Key      = $key
        Outline  = [string]$c.outline
        Name     = [string]$c.name
        Action   = $(if (-not $reversible) { 'KEEP (not reversible by design)' } elseif ($exists) { 'remove' } else { 'remove step MISSING' })
        Script   = $(if ($scriptPath) { [System.IO.Path]::GetRelativePath($solutionRoot, $scriptPath) } else { '' })
        Result   = ''
        Arguments = $stepArguments
    }
}
$plan = @($plan | Sort-Object -Property Outline -Descending)

Write-DemoScreen -InputObject '== Reset Day-2 controls: exactly what would be removed ==' -Raw
$plan | Format-Table -Property Outline, Key, Action, Script -AutoSize | Out-String -Width 200 | Write-DemoScreen

$toRemove = @($plan | Where-Object { $_.Action -eq 'remove' })
$missing = @($plan | Where-Object { $_.Action -like '*MISSING*' })
if (-not $Execute) {
    Write-DemoPlan -Lines @($toRemove | ForEach-Object { "remove $($_.Key) ($($_.Outline)) via $($_.Script)" }) -ScriptName 'Reset-Day2Controls.ps1'
    if ($missing.Count -gt 0) { Write-Warning "Remove steps missing for: $(@($missing.Key) -join ', ') (the cluster-configure solutions own them)." }
    if ($PassThru) { return $plan }
    return
}
if ($missing.Count -gt 0 -and -not $SkipMissing) {
    throw "Refusing to reset: remove steps missing for $(@($missing.Key) -join ', '). Add them in the owning solution or pass -SkipMissing."
}

$removed = [System.Collections.Generic.List[string]]::new()
foreach ($row in $toRemove) {
    $fullPath = Join-Path $solutionRoot $row.Script
    if ($PSCmdlet.ShouldProcess($row.Key, "run $($row.Script) -Execute")) {
        try {
            $null = Invoke-DemoControlStep -ScriptPath $fullPath -Arguments $row.Arguments -Execute
            $row.Result = 'removed'
            $removed.Add($row.Key)
        }
        catch {
            $row.Result = 'FAILED: ' + (($_.Exception.Message -split "`n")[0])
        }
    }
}
[pscustomobject]@{ RemovedAt = [DateTime]::UtcNow.ToString('o'); Controls = $removed.ToArray() } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8
$plan | Format-Table -Property Outline, Key, Action, Result -AutoSize | Out-String -Width 200 | Write-DemoScreen
Write-DemoScreen -InputObject ('Reset recorded in {0}. Re-apply live with Restore-Day2Controls.ps1 -Execute (or one control at a time with -Control <key>).' -f $statePath) -Raw
if ($PassThru) { return $plan }
