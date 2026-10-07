function Get-NIC26SolutionManifest {
    <#
    .SYNOPSIS
        Parses and validates a solution's solution.yml (automation\CONTRACT.md sections 2 and 10).
    .DESCRIPTION
        Validates the manifest against automation\shared\schemas\solution.schema.json and these extra rules:
        unique snake_case input names; secret-ref inputs must have source keyvault and vice versa; every names-catalog
        entry uses a known registry type; fixed-name catalog entries (pdnszone, fixedsubnet, imgver) carry 'name'.
        Missing optional sections (depends_on, secrets, names) default to empty. Adds solution_root and solution_path.
    .PARAMETER Path
        Solution folder, or the path of its solution.yml.
    .EXAMPLE
        Get-NIC26SolutionManifest -Path .\automation\landing-zones\avd
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $manifestPath = $Path
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $manifestPath = Join-Path $Path 'solution.yml'
    }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "solution.yml not found at '$manifestPath'."
    }
    $manifestPath = (Resolve-Path -LiteralPath $manifestPath).Path
    $root = Split-Path -Path $manifestPath -Parent

    $manifest = Import-NIC26Yaml -Path $manifestPath
    foreach ($optional in @('depends_on', 'secrets')) {
        if (-not $manifest.Contains($optional) -or $null -eq $manifest[$optional]) {
            $manifest[$optional] = @()
        }
    }
    if (-not $manifest.Contains('names') -or $null -eq $manifest['names']) {
        $manifest['names'] = [ordered]@{}
    }
    foreach ($listKey in @('inputs', 'outputs')) {
        if ($manifest.Contains($listKey) -and $null -eq $manifest[$listKey]) {
            $manifest[$listKey] = @()
        }
    }

    $schemaFile = Join-Path (Get-NIC26SchemaRoot) 'solution.schema.json'
    $null = Test-NIC26JsonSchema -Object $manifest -SchemaFile $schemaFile -Subject "Solution manifest '$manifestPath'"

    # --- extra rules ------------------------------------------------------------------------------------------------
    $problems = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($inputDef in @($manifest['inputs'])) {
        $inputName = [string]$inputDef['name']
        if (-not $seen.Add($inputName)) {
            $problems.Add("input '$inputName' is declared more than once")
        }
        $inputType = [string]$inputDef['type']
        $source = [string]$inputDef['source']
        if ($inputType -eq 'secret-ref' -and $source -notin @('keyvault', 'generated')) {
            $problems.Add("input '$inputName' is type secret-ref and must have source: keyvault (a reference) or source: generated (run-time value, never emitted)")
        }
        if ($source -eq 'keyvault' -and $inputType -ne 'secret-ref') {
            $problems.Add("input '$inputName' has source: keyvault and must be type secret-ref")
        }
        if ($inputDef.Contains('default') -and $null -ne $inputDef['default'] -and $inputType -eq 'secret-ref') {
            $problems.Add("input '$inputName' is a secret-ref and must not carry a default")
        }
    }

    $registry = Get-NIC26NameRegistry
    foreach ($key in @($manifest['names'].Keys)) {
        $catalogEntry = $manifest['names'][$key]
        $catalogType = ''
        if ($catalogEntry.Contains('type') -and $null -ne $catalogEntry['type']) { $catalogType = [string]$catalogEntry['type'] }
        $hasFixed = ($catalogEntry.Contains('fixed') -and $null -ne $catalogEntry['fixed']) -or ($catalogEntry.Contains('name') -and $null -ne $catalogEntry['name'])
        $isExempt = $catalogEntry.Contains('exempt') -and [bool]$catalogEntry['exempt']
        $typeKey = Resolve-NIC26NameType -Type $catalogType
        if (-not $typeKey) {
            if (-not ($hasFixed -and $isExempt)) {
                $problems.Add("names.$key uses unknown type '$catalogType' (known: $($registry.Keys -join ', ')); Azure-fixed names need 'fixed' plus 'exempt: true'")
            }
            continue
        }
        $registryEntry = $registry[$typeKey]
        if (-not $registryEntry.Generated -and -not $hasFixed) {
            $problems.Add("names.$key (type '$catalogType') is a fixed/exempt name and must specify 'fixed' (or 'name')")
        }
        if ($registryEntry.Generated -and $hasFixed -and -not $isExempt) {
            $problems.Add("names.$key (type '$catalogType') is generated; remove 'fixed'/'name' and use purpose/instance/region/suffix")
        }
        if ($typeKey -eq 'peer' -and -not $hasFixed) {
            $hasPair = ($catalogEntry.Contains('from') -and $catalogEntry.Contains('to')) -or ($catalogEntry.Contains('purpose') -and $catalogEntry.Contains('suffix'))
            if (-not $hasPair) { $problems.Add("names.$key (peering) needs 'from' and 'to' (catalog keys or literals)") }
        }
        if ($typeKey -ne 'peer' -and $registryEntry.PurposeIsParentName -and -not $hasFixed -and -not ($catalogEntry.Contains('parent') -or $catalogEntry.Contains('purpose'))) {
            $problems.Add("names.$key (type '$typeKey') needs 'parent' (the catalog key of the VM/node) or 'purpose'")
        }
    }

    if ($problems.Count -gt 0) {
        throw "Solution manifest '$manifestPath' is invalid:$([Environment]::NewLine)$($problems -join [Environment]::NewLine)"
    }

    $manifest['solution_root'] = $root
    $manifest['solution_path'] = $manifestPath
    return $manifest
}
