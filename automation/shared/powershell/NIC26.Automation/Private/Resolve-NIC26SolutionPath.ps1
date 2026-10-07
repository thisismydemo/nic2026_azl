function Resolve-NIC26SolutionPath {
    <#
    .SYNOPSIS
        Turns -Solution (a folder, a solution.yml path, or a solution name) into the solution folder.
    .DESCRIPTION
        A name is searched under the automation root (landing-zones, azure-local, avd, demo and their children) by
        folder name or by the 'name:' in solution.yml. Ambiguous or missing names throw.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Solution
    )

    if (Test-Path -LiteralPath $Solution -PathType Container) {
        $folder = (Resolve-Path -LiteralPath $Solution).Path
        if (-not (Test-Path -LiteralPath (Join-Path $folder 'solution.yml') -PathType Leaf)) {
            throw "Folder '$folder' has no solution.yml (automation/CONTRACT.md section 2)."
        }
        return $folder
    }
    if ((Test-Path -LiteralPath $Solution -PathType Leaf) -and ((Split-Path -Path $Solution -Leaf) -eq 'solution.yml')) {
        return (Split-Path -Path (Resolve-Path -LiteralPath $Solution).Path -Parent)
    }

    $root = Get-NIC26AutomationRoot
    $manifests = @(Get-ChildItem -LiteralPath $root -Recurse -Depth 4 -Filter 'solution.yml' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](Tests|fixtures|node_modules|\.terraform)[\\/]' })

    $matches = [System.Collections.Generic.List[string]]::new()
    foreach ($manifest in $manifests) {
        $folderName = Split-Path -Path $manifest.DirectoryName -Leaf
        if ($folderName -eq $Solution) {
            $matches.Add($manifest.DirectoryName)
            continue
        }
        $nameLine = Select-String -LiteralPath $manifest.FullName -Pattern '^\s*name:\s*["'']?([A-Za-z0-9-]+)' | Select-Object -First 1
        if ($nameLine -and $nameLine.Matches[0].Groups[1].Value -eq $Solution) {
            $matches.Add($manifest.DirectoryName)
        }
    }

    if ($matches.Count -eq 0) {
        throw "Solution '$Solution' not found: no folder or solution.yml with that name under '$root'. Pass the solution folder path instead."
    }
    if ($matches.Count -gt 1) {
        throw "Solution name '$Solution' is ambiguous: $($matches -join '; '). Pass the solution folder path instead."
    }
    return $matches[0]
}
