#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the repository's quality checks from one place, so CI and a developer run the same thing.
.DESCRIPTION
    Checks: Analyzer (PSScriptAnalyzer, one file at a time), Pester (one child process per suite, nothing is deployed),
    Bicep (az bicep build of every main.bicep), Terraform (fmt -check, init -backend=false, validate per folder),
    Packer (init and validate -syntax-only per folder) and Links (relative Markdown links resolve).
    A missing tool is Skipped on a developer machine and Failed when the CI environment variable is set.
.PARAMETER Root
    Repository root. Defaults to three folders above this script.
.PARAMETER Check
    Which checks to run; All runs the six in the order above.
.PARAMETER Plan
    List what would run and run nothing.
.PARAMETER ResultPath
    Write the result objects as JSON to this file.
.PARAMETER PassThru
    Return the result objects instead of setting the exit code.
.PARAMETER PesterTimeoutSeconds
    Time limit for one Pester suite.
.EXAMPLE
    ./Invoke-CiChecks.ps1 -Check Links
#>
[CmdletBinding()]
[OutputType([pscustomobject[]])]
param(
    [string] $Root = (Join-Path $PSScriptRoot '..' '..' '..'),
    [ValidateSet('Analyzer', 'Pester', 'Bicep', 'Terraform', 'Packer', 'Links', 'All')]
    [string[]] $Check = 'All',
    [switch] $Plan,
    [string] $ResultPath,
    [switch] $PassThru,
    [int] $PesterTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Folders that are never scanned.
$script:CiSkip = '(^|/)(node_modules|\.terraform|\.git|follow-along-site)(/|$)'

# All files under automation (or the whole root) with one of the extensions, as relative forward-slash paths.
function Get-CiFiles {
    param([string] $Root, [string] $Sub, [string[]] $Filter)
    $base = if ($Sub) { Join-Path $Root $Sub } else { $Root }
    if (-not (Test-Path -LiteralPath $base)) { return }
    $full = (Resolve-Path -LiteralPath $Root).Path
    foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Include $Filter -Force)) {
        $rel = [IO.Path]::GetRelativePath($full, $f.FullName).Replace('\', '/')
        if ($rel -notmatch $script:CiSkip) { $rel }
    }
}

# PowerShell files the analyzer checks.
function Get-CiAnalyzerTargets { param([string] $Root) @(Get-CiFiles -Root $Root -Sub 'automation' -Filter '*.ps1', '*.psm1', '*.psd1' | Sort-Object) }

# Pester suites, without test fixtures.
function Get-CiPesterTargets { param([string] $Root) @(Get-CiFiles -Root $Root -Sub 'automation' -Filter '*.Tests.ps1' | Where-Object { $_ -notmatch '(^|/)fixtures(/|$)' } | Sort-Object) }

# Bicep entry templates.
function Get-CiBicepTargets { param([string] $Root) @(Get-CiFiles -Root $Root -Sub 'automation' -Filter 'main.bicep' | Sort-Object) }

# Folders that hold Terraform files.
function Get-CiTerraformFolders { param([string] $Root) @(Get-CiFiles -Root $Root -Sub 'automation' -Filter '*.tf' | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique | ForEach-Object { $_.Replace('\', '/') }) }

# Folders that hold Packer templates.
function Get-CiPackerFolders { param([string] $Root) @(Get-CiFiles -Root $Root -Sub 'automation' -Filter '*.pkr.hcl' | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique | ForEach-Object { $_.Replace('\', '/') }) }

# Markdown files in the whole repository.
function Get-CiMarkdownFiles { param([string] $Root) @(Get-CiFiles -Root $Root -Sub '' -Filter '*.md' | Sort-Object) }

# One result object.
function Get-CiResult {
    param([string] $Check, [string] $Target, [ValidateSet('Passed', 'Failed', 'Skipped')] [string] $Status, [string] $Detail = '')
    [pscustomobject]@{ Check = $Check; Target = $Target; Status = $Status; Detail = $Detail }
}

# Result for a missing tool: Failed in CI, Skipped on a developer machine.
function Get-CiMissingToolResult {
    param([string] $Check, [string] $Target, [string] $Tool)
    Get-CiResult $Check $Target $(if ($env:CI) { 'Failed' } else { 'Skipped' }) "$Tool not found"
}

# Runs a native command, returns exit code and the first lines of its error output.
function Invoke-CiNative {
    param([string] $File, [string[]] $Arguments)
    $err = [System.Collections.Generic.List[string]]::new()
    $null = & $File @Arguments 2>&1 | ForEach-Object { $err.Add([string]$_) }
    [pscustomobject]@{ Exit = $LASTEXITCODE; Output = (($err | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' | ') }
}

# PSScriptAnalyzer, one file at a time; Error and Warning fail.
function Invoke-CiAnalyzer {
    param([string] $Root, [switch] $Plan)
    $targets = Get-CiAnalyzerTargets -Root $Root
    if ($Plan) { return $targets | ForEach-Object { Get-CiResult 'Analyzer' $_ 'Skipped' 'plan only' } }
    if (-not (Get-Module PSScriptAnalyzer -ListAvailable)) { throw 'PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer).' }
    Import-Module PSScriptAnalyzer
    $settings = Join-Path $Root 'automation/shared/powershell/PSScriptAnalyzerSettings.psd1'
    foreach ($t in $targets) {
        $findings = @(Invoke-ScriptAnalyzer -Path (Join-Path $Root $t) -Settings $settings | Where-Object Severity -in 'Error', 'Warning')
        if ($findings.Count -gt 0) { Get-CiResult 'Analyzer' $t 'Failed' ((($findings | Select-Object -First 5) | ForEach-Object { '{0}:{1}' -f $_.RuleName, $_.Line }) -join ', ') }
        else { Get-CiResult 'Analyzer' $t 'Passed' }
    }
}

# Pester suites, one child process each, sequentially.
function Invoke-CiPester {
    param([string] $Root, [int] $TimeoutSeconds, [switch] $Plan)
    $targets = Get-CiPesterTargets -Root $Root
    if ($Plan) { return $targets | ForEach-Object { Get-CiResult 'Pester' $_ 'Skipped' 'plan only' } }
    $pwsh = (Get-Process -Id $PID).Path
    foreach ($t in $targets) {
        $path = (Join-Path $Root $t).Replace("'", "''")
        # Preserve download/validation errors after the introductory line. Bound each diagnostic,
        # retaining both its beginning and end when large, without altering failure status.
        $cmd = "Set-Location -LiteralPath '$((Resolve-Path -LiteralPath $Root).Path.Replace("'", "''"))'; Import-Module Pester -MinimumVersion 5.5.0; `$c = New-PesterConfiguration; `$c.Run.Path = '$path'; `$c.Run.PassThru = `$true; `$c.Output.Verbosity = 'None'; `$r = Invoke-Pester -Configuration `$c; 'RESULT passed=' + `$r.PassedCount + ' failed=' + `$r.FailedCount + ' skipped=' + `$r.SkippedCount; `$r.Failed | Select-Object -First 3 | ForEach-Object { `$message = [regex]::Replace([string]`$_.ErrorRecord.Exception.Message, '\s+', ' ').Trim(); if (`$message.Length -gt 4096) { `$message = `$message.Substring(0, 1536) + ' ... ' + `$message.Substring(`$message.Length - 2555) }; 'FAILEDTEST ' + `$_.ExpandedPath + ' :: ' + `$message }"
        $info = [Diagnostics.ProcessStartInfo]::new($pwsh)
        foreach ($a in '-NoProfile', '-NonInteractive', '-Command', $cmd) { $info.ArgumentList.Add($a) }
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($info)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $null = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $proc.Kill($true)
            Get-CiResult 'Pester' $t 'Failed' "timed out after $TimeoutSeconds s"
            continue
        }
        $stdoutText = $stdout.GetAwaiter().GetResult()
        $line = ($stdoutText -split "`r?`n" | Where-Object { $_ -match '^RESULT ' } | Select-Object -Last 1)
        if (-not $line) { Get-CiResult 'Pester' $t 'Failed' 'no RESULT line (the suite did not finish)' }
        elseif ($line -match 'failed=(\d+)' -and [int]$Matches[1] -gt 0) {
            $failedTests = @($stdoutText -split "`r?`n" | Where-Object { $_ -match '^FAILEDTEST ' } | Select-Object -First 3) -join ' | '
            Get-CiResult 'Pester' $t 'Failed' ($line + ' ' + $failedTests)
        }
        else { Get-CiResult 'Pester' $t 'Passed' $line }
    }
}

# az bicep build of every main.bicep.
function Invoke-CiBicep {
    param([string] $Root, [switch] $Plan)
    $targets = Get-CiBicepTargets -Root $Root
    if ($Plan) { return $targets | ForEach-Object { Get-CiResult 'Bicep' $_ 'Skipped' 'plan only' } }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $targets | ForEach-Object { Get-CiMissingToolResult 'Bicep' $_ 'az' } }
    foreach ($t in $targets) {
        $r = Invoke-CiNative az @('bicep', 'build', '--file', (Join-Path $Root $t), '--stdout')
        if ($r.Exit -eq 0) { Get-CiResult 'Bicep' $t 'Passed' } else { Get-CiResult 'Bicep' $t 'Failed' $r.Output }
    }
}

# terraform fmt, init without a backend, validate; one result per folder.
function Invoke-CiTerraform {
    param([string] $Root, [switch] $Plan)
    $targets = Get-CiTerraformFolders -Root $Root
    if ($Plan) { return $targets | ForEach-Object { Get-CiResult 'Terraform' $_ 'Skipped' 'plan only' } }
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { return $targets | ForEach-Object { Get-CiMissingToolResult 'Terraform' $_ 'terraform' } }
    foreach ($t in $targets) {
        $dir = Join-Path $Root $t
        $failed = $null
        foreach ($step in @(@('fmt', @('fmt', '-check', '-diff')), @('init', @('init', '-backend=false', '-input=false', '-no-color')), @('validate', @('validate', '-no-color')))) {
            $r = Invoke-CiNative terraform (@("-chdir=$dir") + $step[1])
            if ($r.Exit -ne 0) { $failed = "$($step[0]): $($r.Output)"; break }
        }
        if ($failed) { Get-CiResult 'Terraform' $t 'Failed' $failed } else { Get-CiResult 'Terraform' $t 'Passed' }
    }
}

# packer init and validate -syntax-only per folder.
function Invoke-CiPacker {
    param([string] $Root, [switch] $Plan)
    $targets = Get-CiPackerFolders -Root $Root
    if ($Plan) { return $targets | ForEach-Object { Get-CiResult 'Packer' $_ 'Skipped' 'plan only' } }
    if (-not (Get-Command packer -ErrorAction SilentlyContinue)) { return $targets | ForEach-Object { Get-CiMissingToolResult 'Packer' $_ 'packer' } }
    foreach ($t in $targets) {
        $dir = Join-Path $Root $t
        $r = Invoke-CiNative packer @('init', $dir)
        if ($r.Exit -ne 0) { Get-CiResult 'Packer' $t 'Failed' "init: $($r.Output)"; continue }
        $r = Invoke-CiNative packer @('validate', '-syntax-only', $dir)
        if ($r.Exit -eq 0) { Get-CiResult 'Packer' $t 'Passed' } else { Get-CiResult 'Packer' $t 'Failed' "validate: $($r.Output)" }
    }
}

# Relative Markdown links must resolve; code blocks and inline code are ignored.
function Invoke-CiLinks {
    param([string] $Root, [switch] $Plan)
    $files = Get-CiMarkdownFiles -Root $Root
    if ($Plan) { return $files | ForEach-Object { Get-CiResult 'Links' $_ 'Skipped' 'plan only' } }
    $fullRoot = (Resolve-Path -LiteralPath $Root).Path
    $checked = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $files) {
        $dir = Split-Path (Join-Path $fullRoot $f) -Parent
        $inFence = $false
        $dead = [System.Collections.Generic.List[string]]::new()
        foreach ($line in [IO.File]::ReadLines((Join-Path $fullRoot $f))) {
            if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }
            $text = [regex]::Replace($line, '`[^`]*`', '')
            foreach ($m in [regex]::Matches($text, '(?<!!)\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)|!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')) {
                $target = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
                if ($target -match '^(https?:|mailto:|#)') { continue }
                $checked++
                $clean = [uri]::UnescapeDataString((($target -split '[#?]')[0]))
                if ($clean -and -not (Test-Path -LiteralPath (Join-Path $dir $clean))) { $dead.Add($target) }
            }
        }
        if ($dead.Count -gt 0) { $failures.Add((Get-CiResult 'Links' $f 'Failed' (($dead | Select-Object -First 5) -join ', '))) }
    }
    if ($failures.Count -gt 0) { return $failures }
    Get-CiResult 'Links' '(all markdown files)' 'Passed' ('{0} files, {1} links checked' -f @($files).Count, $checked)
}

if ($MyInvocation.InvocationName -ne '.') {
    $root = (Resolve-Path -LiteralPath $Root).Path
    $order = 'Analyzer', 'Pester', 'Bicep', 'Terraform', 'Packer', 'Links'
    $selected = if ($Check -contains 'All') { $order } else { $order | Where-Object { $Check -contains $_ } }
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $selected) {
        Write-Information "== $c" -InformationAction Continue
        $out = switch ($c) {
            'Analyzer' { Invoke-CiAnalyzer -Root $root -Plan:$Plan }
            'Pester' { Invoke-CiPester -Root $root -TimeoutSeconds $PesterTimeoutSeconds -Plan:$Plan }
            'Bicep' { Invoke-CiBicep -Root $root -Plan:$Plan }
            'Terraform' { Invoke-CiTerraform -Root $root -Plan:$Plan }
            'Packer' { Invoke-CiPacker -Root $root -Plan:$Plan }
            'Links' { Invoke-CiLinks -Root $root -Plan:$Plan }
        }
        foreach ($r in @($out)) { if ($r) { $results.Add($r) } }
    }
    if ($ResultPath) { $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8 }
    $summary = $results | Group-Object Check, Status | ForEach-Object { [pscustomobject]@{ Check = $_.Group[0].Check; Status = $_.Group[0].Status; Count = $_.Count } }
    $summary | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    foreach ($r in ($results | Where-Object Status -eq 'Failed')) { Write-Information ('FAILED {0}: {1} - {2}' -f $r.Check, $r.Target, $r.Detail) -InformationAction Continue }
    # On GitHub Actions a workflow command turns each failure into a public annotation, so the cause is readable without log access.
    if ($env:GITHUB_ACTIONS) {
        foreach ($r in ($results | Where-Object Status -eq 'Failed')) {
            $msg = ('{0}' -f $r.Detail) -replace '%', '%25' -replace '\r', '%0D' -replace '\n', '%0A'
            [Console]::Out.WriteLine(('::error title={0} {1}::{2}' -f $r.Check, ($r.Target -replace '[,:]', '_'), $msg))
        }
    }
    if ($PassThru) { return $results.ToArray() }
    exit $(if (@($results | Where-Object Status -eq 'Failed').Count -gt 0) { 1 } else { 0 })
}
