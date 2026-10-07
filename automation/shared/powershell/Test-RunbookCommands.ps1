#Requires -Version 7.0
<#
.SYNOPSIS
Checks that every script command quoted in the runbooks exists and uses only parameters it declares.
.DESCRIPTION
Reads the fenced powershell blocks of the runbooks, parses each line that starts with `.\Something.ps1` (placeholders such
as <id> and ... are replaced first), finds the script under automation/ by file name and compares the named parameters
with its param block (plus the common parameters, and -WhatIf/-Confirm when the script supports ShouldProcess). A script
name that matches more than one file is checked against the file whose path shares the most segments with the nearest
preceding `cd` line of the same block. Read-only; changes nothing. Returns the findings; throws with -FailOnFinding.
.PARAMETER RunbookRoot
Folder of the runbooks (default: runbooks next to automation).
.PARAMETER AutomationRoot
Folder that holds the scripts (default: automation).
.PARAMETER FailOnFinding
Throw when anything is wrong.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string]$RunbookRoot,
    [string]$AutomationRoot,
    [switch]$FailOnFinding
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $RunbookRoot) { $RunbookRoot = Join-Path $repo 'runbooks' }
if (-not $AutomationRoot) { $AutomationRoot = Join-Path $repo 'automation' }

$common = @('Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable',
    'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction')
$scripts = @(Get-ChildItem -LiteralPath $AutomationRoot -Recurse -Filter '*.ps1' -File |
        Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' })

function Get-ScriptParameterInfo {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    $names = @()
    $shouldProcess = $false
    if ($ast.ParamBlock) {
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($attribute in $ast.ParamBlock.Attributes) {
            if ($attribute.TypeName.Name -eq 'CmdletBinding') {
                foreach ($argument in $attribute.NamedArguments) {
                    if ($argument.ArgumentName -eq 'SupportsShouldProcess') { $shouldProcess = $true }
                }
            }
        }
    }
    return [pscustomobject]@{ Names = $names; ShouldProcess = $shouldProcess }
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
$checked = 0
foreach ($runbook in (Get-ChildItem -LiteralPath $RunbookRoot -Recurse -Filter '*.md' -File | Where-Object { $_.FullName -notmatch '[\/]\.terraform[\/]' })) {
    $text = Get-Content -LiteralPath $runbook.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { continue }
    foreach ($block in [regex]::Matches($text, '(?ms)^```powershell\s*\r?\n(.*?)^```')) {
        $currentDirectory = ''
        foreach ($rawLine in ($block.Groups[1].Value -split '\r?\n')) {
            $line = ($rawLine -replace '\s+#.*$', '').Trim()
            if ($line -match '^cd\s+(\S+)') { $currentDirectory = $Matches[1]; continue }
            if ($line -notmatch '^\.\\[^\s]+\.ps1\b') { continue }
            $clean = $line -replace '<[^>]*>', 'x' -replace '\.\.\.', 'x' -replace '\$\w+', 'x'
            $parseErrors = $null
            $tokens = $null
            $parsed = [System.Management.Automation.Language.Parser]::ParseInput($clean, [ref]$tokens, [ref]$parseErrors)
            $command = $parsed.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $false)
            if ($null -eq $command) { continue }
            $scriptName = [System.IO.Path]::GetFileName($command.CommandElements[0].Extent.Text.Trim("'", '"'))
            $candidates = @($scripts | Where-Object { $_.Name -eq $scriptName })
            $checked++
            if ($candidates.Count -eq 0) {
                $findings.Add([pscustomobject]@{ Runbook = $runbook.Name; Script = $scriptName; Problem = 'script not found'; Line = $line })
                continue
            }
            $file = $candidates[0]
            if ($candidates.Count -gt 1) {
                $hint = ($currentDirectory -replace '^\.\\', '' -split '[\\/]') | Where-Object { $_ -and $_ -ne 'scripts' }
                $file = $candidates | Sort-Object { $p = $_.FullName; @($hint | Where-Object { $p -like "*$_*" }).Count } -Descending | Select-Object -First 1
            }
            $info = Get-ScriptParameterInfo -Path $file.FullName
            $allowed = @($info.Names) + $common + $(if ($info.ShouldProcess) { 'WhatIf', 'Confirm' } else { @() })
            foreach ($element in $command.CommandElements) {
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $parameterName = $element.ParameterName
                $matchesDeclared = @($allowed | Where-Object { $_ -eq $parameterName }).Count -gt 0
                if (-not $matchesDeclared) {
                    # PowerShell accepts an unambiguous prefix of a parameter name
                    $prefixMatches = @($allowed | Where-Object { $_ -like "$parameterName*" })
                    if ($prefixMatches.Count -ne 1) {
                        $findings.Add([pscustomobject]@{ Runbook = $runbook.Name; Script = $scriptName; Problem = "unknown parameter -$parameterName"; Line = $line })
                    }
                }
            }
        }
    }
}

$result = [pscustomobject]@{ Checked = $checked; Findings = $findings.ToArray() }
if ($FailOnFinding -and $findings.Count -gt 0) {
    throw ("Runbook command check failed:`n" + (($findings | ForEach-Object { "  $($_.Runbook): $($_.Script): $($_.Problem)" }) -join "`n"))
}
$result
