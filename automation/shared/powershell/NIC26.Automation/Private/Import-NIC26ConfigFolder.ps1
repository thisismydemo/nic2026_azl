function Import-NIC26ConfigFolder {
    <#
    .SYNOPSIS
        Loads and deep-merges every *.yml / *.yaml file in one folder (sorted by name; secret-map.yml is skipped, it has its own shape and is read through secret_map_path) and validates the result against a schema.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SchemaFile,

        [Parameter(Mandatory)]
        [string]$Scope
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Environment folder for scope '$Scope' not found: $Path. Create it from automation\shared\examples\environment.$Scope.example.yml."
    }

    $files = @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in @('.yml', '.yaml') -and $_.Name -notin @('secret-map.yml', 'secret-map.yaml') } | Sort-Object -Property Name)
    if ($files.Count -eq 0) {
        throw "No *.yml files found in '$Path' for scope '$Scope'. Copy automation\shared\examples\environment.$Scope.example.yml there and fill in your values."
    }

    $merged = [ordered]@{}
    foreach ($file in $files) {
        Write-Verbose "Loading $($file.FullName)"
        $data = Import-NIC26Yaml -Path $file.FullName
        $merged = Merge-NIC26Hashtable -Base $merged -Overlay $data
    }

    $null = Test-NIC26JsonSchema -Object $merged -SchemaFile $SchemaFile -Subject "Environment config for scope '$Scope' ($($files.Name -join ', '))"

    return @{
        Values = $merged
        Files  = @($files.FullName)
    }
}
