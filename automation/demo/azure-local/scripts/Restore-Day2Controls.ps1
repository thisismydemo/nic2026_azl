#Requires -Version 7.0
<#
.SYNOPSIS
    Re-applies the Day-2 controls (outline §3.1-§3.5 live beats) by calling each control's own apply step, in outline
    order. -WhatIf is the default; idempotent (apply steps are idempotent by contract).
.DESCRIPTION
    Reads day2-controls.yml and the record written by Reset-Day2Controls.ps1 (day2-reset.json). By default only the
    controls that the reset removed are re-applied; -All re-applies every control that has an apply script, -Control
    picks specific keys (one control per live beat). Lists exactly what it would apply; with -Execute runs the apply
    scripts with -Execute (3.1 -> 3.5) and removes the keys from the reset record as they succeed.
.PARAMETER Control
    Restrict to these control keys.
.PARAMETER All
    Re-apply every control with an apply step, not only the ones the reset removed.
.PARAMETER RegistryPath
    day2-controls.yml.
.PARAMETER Execute
    Run the apply steps.
.PARAMETER SkipMissing
    Skip controls whose apply script is not present instead of refusing.
.PARAMETER PassThru
    Return the plan rows.
.EXAMPLE
    ./Restore-Day2Controls.ps1 -Control insights -Execute       # the §3.1 live beat
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject[]])]
param(
    [Parameter()]
    [string[]] $Control = @(),

    [switch] $All,

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
$removedKeys = @()
if (Test-Path -LiteralPath $statePath) { $removedKeys = @((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).Controls) }

$plan = foreach ($c in $registry.controls) {
    $key = [string]$c.key
    if ($Control.Count -gt 0 -and $key -notin $Control) { continue }
    if ($Control.Count -eq 0 -and -not $All -and $key -notin $removedKeys) { continue }
    $scriptPath = if ($c.apply_script) { Join-Path $solutionRoot ([string]$c.solution) ([string]$c.apply_script) } else { '' }
    $exists = ($scriptPath -and (Test-Path -LiteralPath $scriptPath -PathType Leaf))
    $stepArguments = @{}
    if ($c.Contains('apply_args') -and $c.apply_args) { foreach ($k in $c.apply_args.Keys) { $stepArguments[[string]$k] = $c.apply_args[$k] } }
    [pscustomobject]@{
        Key     = $key
        Outline = [string]$c.outline
        Name    = [string]$c.name
        Action  = $(if ($exists) { 'apply' } else { 'apply step MISSING' })
        Script  = $(if ($scriptPath) { [System.IO.Path]::GetRelativePath($solutionRoot, $scriptPath) } else { '' })
        Result  = ''
        Arguments = $stepArguments
    }
}
$plan = @($plan | Sort-Object -Property Outline)

Write-DemoScreen -InputObject '== Restore Day-2 controls: exactly what would be applied ==' -Raw
if ($plan.Count -eq 0) { Write-DemoScreen -InputObject 'Nothing to restore (no reset record and no -Control/-All).' -Raw }
$plan | Format-Table -Property Outline, Key, Action, Script -AutoSize | Out-String -Width 200 | Write-DemoScreen

$toApply = @($plan | Where-Object { $_.Action -eq 'apply' })
$missing = @($plan | Where-Object { $_.Action -like '*MISSING*' })
if (-not $Execute) {
    Write-DemoPlan -Lines @($toApply | ForEach-Object { "apply $($_.Key) ($($_.Outline)) via $($_.Script)" }) -ScriptName 'Restore-Day2Controls.ps1'
    if ($PassThru) { return $plan }
    return
}
if ($missing.Count -gt 0 -and -not $SkipMissing) {
    throw "Refusing to restore: apply steps missing for $(@($missing.Key) -join ', '). Add them in the owning solution or pass -SkipMissing."
}

foreach ($row in $toApply) {
    $fullPath = Join-Path $solutionRoot $row.Script
    if ($PSCmdlet.ShouldProcess($row.Key, "run $($row.Script) -Execute")) {
        try {
            $null = Invoke-DemoControlStep -ScriptPath $fullPath -Arguments $row.Arguments -Execute
            $row.Result = 'applied'
            $removedKeys = @($removedKeys | Where-Object { $_ -ne $row.Key })
        }
        catch {
            $row.Result = 'FAILED: ' + (($_.Exception.Message -split "`n")[0])
        }
    }
}
if (Test-Path -LiteralPath $statePath) {
    if ($removedKeys.Count -eq 0) { Remove-Item -LiteralPath $statePath -Force }
    else { [pscustomobject]@{ RemovedAt = [DateTime]::UtcNow.ToString('o'); Controls = $removedKeys } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding utf8 }
}
$plan | Format-Table -Property Outline, Key, Action, Result -AutoSize | Out-String -Width 200 | Write-DemoScreen
Write-DemoScreen -InputObject 'Prove it: Test-Day2Readiness.ps1 (green when every control is back).' -Raw
if ($PassThru) { return $plan }
