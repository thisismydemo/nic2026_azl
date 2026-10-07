#Requires -Version 7.0
<#
.SYNOPSIS
    Reports the placeholders that remain in the environment files, so a deployment does not start with values that only look valid.
.DESCRIPTION
    Schema validation accepts an all-zero GUID and cannot read a comment. This check reads every *.yml in environment\<scope>
    (secret-map.yml is skipped, it has its own shape) and lists each line that still holds a placeholder:
      - an all-zero GUID (00000000-0000-0000-0000-000000000000);
      - a TODO(<task>) comment;
      - a VERIFY comment.
    Read-only. Prints one row per finding (file, line, key, kind, task) and a summary; with -FailOnPlaceholder it exits 1 when
    any all-zero GUID or TODO remains (VERIFY is reported but does not fail the run). Run it before a deployment, and in a
    pipeline with -FailOnPlaceholder.
.PARAMETER Scope
    One or more of shared, azure-local, avd. Default: all three.
.PARAMETER EnvironmentRoot
    Folder that holds the scope folders. Default: <repo>\environment.
.PARAMETER FailOnPlaceholder
    Exit with code 1 when an all-zero GUID or a TODO remains.
.EXAMPLE
    ./Test-EnvironmentReadiness.ps1
.EXAMPLE
    ./Test-EnvironmentReadiness.ps1 -Scope azure-local -FailOnPlaceholder
#>
[CmdletBinding()]
param(
    [ValidateSet('shared', 'azure-local', 'avd')]
    [string[]] $Scope = @('shared', 'azure-local', 'avd'),

    [string] $EnvironmentRoot = (Join-Path $PSScriptRoot '..\..\..\environment'),

    [switch] $FailOnPlaceholder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$zeroGuid = '00000000-0000-0000-0000-000000000000'
$findings = [System.Collections.Generic.List[object]]::new()
$missing = [System.Collections.Generic.List[string]]::new()

foreach ($s in $Scope) {
    $folder = Join-Path $EnvironmentRoot $s
    if (-not (Test-Path -LiteralPath $folder)) { $missing.Add($s); continue }
    $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object { $_.Extension -in @('.yml', '.yaml') -and $_.Name -notin @('secret-map.yml', 'secret-map.yaml') })
    if ($files.Count -eq 0) { $missing.Add($s); continue }
    foreach ($file in $files) {
        $topKey = ''
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            $lineNo++
            if ($line -match '^([A-Za-z_][\w-]*):') { $topKey = $Matches[1] }
            $key = if ($line -match '^\s*(?:-\s*)?([A-Za-z_][\w-]*):') { $Matches[1] } else { $topKey }
            $task = if ($line -match 'TODO\(([^)]*)\)') { $Matches[1] } else { '' }
            if ($line.Contains($zeroGuid)) {
                $findings.Add([pscustomobject]@{ Scope = $s; File = $file.Name; Line = $lineNo; Key = $key; Kind = 'ZeroGuid'; Task = $task })
            }
            elseif ($task) {
                $findings.Add([pscustomobject]@{ Scope = $s; File = $file.Name; Line = $lineNo; Key = $key; Kind = 'Todo'; Task = $task })
            }
            if ($line -match '\bVERIFY\b' -and -not $line.Contains($zeroGuid) -and -not $task) {
                $findings.Add([pscustomobject]@{ Scope = $s; File = $file.Name; Line = $lineNo; Key = $key; Kind = 'Verify'; Task = '' })
            }
        }
    }
}

foreach ($m in $missing) { Write-Warning "No environment files found for scope '$m' under $EnvironmentRoot." }
$findings | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
$blocking = @($findings | Where-Object Kind -in 'ZeroGuid', 'Todo')
Write-Information -InformationAction Continue ("Placeholders: {0} blocking (all-zero GUIDs and TODOs), {1} to verify, {2} scope(s) without files." -f $blocking.Count, @($findings | Where-Object Kind -eq 'Verify').Count, $missing.Count)
if ($FailOnPlaceholder -and ($blocking.Count -gt 0 -or $missing.Count -gt 0)) { exit 1 }
$findings
