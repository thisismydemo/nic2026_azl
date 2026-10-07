#Requires -Version 7.0
<#
.SYNOPSIS
Checks relative links and heading anchors in every Markdown file under a root.
.DESCRIPTION
Read-only. A link is broken when its target file does not exist or when its #anchor matches no heading in the target
Markdown file (GitHub slug rules: lower case, punctuation removed, spaces to hyphens). External links are not checked.
Returns one object per broken link; with -FailOnBroken the script exits with code 1 when anything is broken.
.PARAMETER Root
Repository root. Defaults to the repository that contains this script.
.PARAMETER IgnoreTarget
File names that are git-ignored (private tenant data) and so absent from a clean clone; links to them are not checked.
.PARAMETER FailOnBroken
Exit with code 1 when any link is broken (for CI).
.EXAMPLE
./Test-MarkdownLinks.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path,

    [string[]]$IgnoreTarget = @('live-inventory.json'),

    [switch]$FailOnBroken
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HeadingSlug {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Heading)

    $slug = $Heading.ToLowerInvariant().Replace('`', '')
    $slug = [regex]::Replace($slug, '[^\p{L}\p{N}\s\-_]', '')
    return ($slug.Trim() -replace '\s', '-')
}

$files = @(Get-ChildItem -Path $Root -Recurse -Filter '*.md' -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.terraform|\.git|node_modules)[\\/]' })

$slugs = @{}
foreach ($file in $files) {
    $set = [System.Collections.Generic.HashSet[string]]::new()
    $inFence = $false
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        if ($line -match '^```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line -match '^#{1,6}\s+(.*?)\s*#*\s*$') { [void]$set.Add((Get-HeadingSlug -Heading $Matches[1])) }
    }
    $slugs[$file.FullName] = $set
}

$broken = foreach ($file in $files) {
    $text = Get-Content -LiteralPath $file.FullName -Raw
    if (-not $text) { continue }
    foreach ($match in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
        $target = $match.Groups[1].Value
        if ($target -match '^(https?:|mailto:)') { continue }
        if ($IgnoreTarget -contains ($target -split '#')[0]) { continue }
        $parts = $target -split '#', 2
        $path = $parts[0]
        $anchor = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        if (-not $path -and -not $anchor) { continue }
        $full = if ($path) { [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName ([uri]::UnescapeDataString($path)))) } else { $file.FullName }
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\', '/')
        if ($path -and -not (Test-Path -LiteralPath $full)) {
            [pscustomobject]@{ File = $relative; Link = $target; Problem = 'target file not found' }
            continue
        }
        if ($anchor -and $slugs.ContainsKey($full) -and -not $slugs[$full].Contains($anchor.ToLowerInvariant())) {
            [pscustomobject]@{ File = $relative; Link = $target; Problem = 'anchor not found' }
        }
    }
}

$broken = @($broken)
$broken
if ($FailOnBroken -and $broken.Count -gt 0) { exit 1 }
