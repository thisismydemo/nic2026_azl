function Write-NIC26GeneratedFile {
    <#
    .SYNOPSIS
        Writes generated content as UTF-8 (no BOM) with LF line endings, creating the folder; returns the FileInfo.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }
    $normalized = ($Content -replace "`r`n", "`n")
    if (-not $normalized.EndsWith("`n")) {
        $normalized += "`n"
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $normalized, $encoding)
    Write-NIC26Log -Message "Wrote $Path ($($normalized.Length) chars)" -Level Verbose
    return Get-Item -LiteralPath $Path
}
