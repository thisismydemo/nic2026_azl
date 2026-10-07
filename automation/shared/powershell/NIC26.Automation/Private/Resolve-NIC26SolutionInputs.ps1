function Resolve-NIC26SolutionInputs {
    <#
    .SYNOPSIS
        Shared converter core: resolves the declared inputs of a solution from the config and the names catalog.
    .DESCRIPTION
        Rules (CONTRACT.md section 3 and 10):
        - only inputs declared in solution.yml are emitted, looked up by canonical name (top-level key of the merged
          config values; an optional 'path' in the manifest selects a nested key, e.g. secret_refs.jump_admin_password);
        - a missing required input fails the conversion (all missing names are reported at once);
        - optional inputs use 'default' when present, otherwise they are omitted;
        - source: generated inputs (tokens, resolved secrets, the names object) are never emitted and never fail;
        - a short alias table (Get-NIC26InputAliasMap) maps design synonyms (region_short, lab_token, p2s_pool, ...)
          to the schema key when the input has no 'path';
        - type secret-ref values must be keyvault://<vault>/<secret> strings; anything else is refused;
        - values are type-checked against the declared type (string, int, bool, list, map, secret-ref).
    .OUTPUTS
        Ordered dictionary { manifest, inputs, names, solution_root }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Manifest,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config
    )

    $values = ConvertTo-NIC26ConfigValues -Config $Config
    $aliases = Get-NIC26InputAliasMap
    $secretRefPattern = '^keyvault://[a-z0-9-]{3,24}/[A-Za-z0-9-]+$'

    $inputs = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($inputDef in @($Manifest['inputs'])) {
        $name = [string]$inputDef['name']
        $type = [string]$inputDef['type']
        $required = [bool]$inputDef['required']
        $source = [string]$inputDef['source']
        $path = ''
        if ($inputDef.Contains('path') -and $inputDef['path']) {
            $path = [string]$inputDef['path']
        }

        if ($source -eq 'generated') {
            # Run-time values (registration tokens, resolved secrets, the names object) never come from files.
            Write-Verbose "Input '$name' is generated at run time; not emitted by the converters."
            continue
        }

        $lookup = Get-NIC26ConfigValue -Values $values -Name $name -Path $path
        if (-not $lookup.Found -and -not $path -and $aliases.ContainsKey($name)) {
            $lookup = Get-NIC26ConfigValue -Values $values -Name $aliases[$name]
            if ($lookup.Found) {
                Write-Verbose "Input '$name' resolved through its canonical alias '$($aliases[$name])'."
            }
        }
        $value = $lookup.Value
        $found = $lookup.Found -and ($null -ne $value)

        if (-not $found) {
            if ($inputDef.Contains('default') -and $null -ne $inputDef['default']) {
                $value = Copy-NIC26Value -Value $inputDef['default']
                $found = $true
            }
            elseif ($required) {
                $where = if ($path) { "path '$path'" } else { "top-level key '$name'" }
                $missing.Add("$name ($where)")
                continue
            }
            else {
                continue
            }
        }

        switch ($type) {
            'secret-ref' {
                if (($value -isnot [string]) -or ($value -notmatch $secretRefPattern)) {
                    $problems.Add("input '$name' is type secret-ref and must be a keyvault://<vault>/<secret> reference string; refusing to emit anything else (secret values never enter generated files)")
                    continue
                }
            }
            'string' {
                if ($value -is [System.Collections.IDictionary] -or (($value -is [System.Collections.IEnumerable]) -and ($value -isnot [string]))) {
                    $problems.Add("input '$name' is type string but the config value is a $($value.GetType().Name)")
                    continue
                }
                $value = [string]$value
            }
            'int' {
                if ($value -is [string] -and $value -match '^-?\d+$') { $value = [long]$value }
                if ($value -isnot [int] -and $value -isnot [long] -and $value -isnot [int16] -and $value -isnot [byte]) {
                    $problems.Add("input '$name' is type int but the config value is '$value' ($($value.GetType().Name))")
                    continue
                }
            }
            'bool' {
                if ($value -isnot [bool]) {
                    $problems.Add("input '$name' is type bool but the config value is '$value' ($($value.GetType().Name))")
                    continue
                }
            }
            'list' {
                if (($value -is [string]) -or ($value -is [System.Collections.IDictionary]) -or ($value -isnot [System.Collections.IEnumerable])) {
                    $problems.Add("input '$name' is type list but the config value is a $($value.GetType().Name)")
                    continue
                }
                $value = [object[]](Copy-NIC26Value -Value $value)
            }
            'map' {
                if ($value -isnot [System.Collections.IDictionary]) {
                    $problems.Add("input '$name' is type map but the config value is a $($value.GetType().Name)")
                    continue
                }
                $value = Copy-NIC26Value -Value $value
            }
            default {
                $problems.Add("input '$name' has unsupported type '$type'")
                continue
            }
        }
        $inputs[$name] = $value
    }

    if ($missing.Count -gt 0) {
        $problems.Insert(0, "required input(s) missing from the config: $($missing -join ', ')")
    }
    if ($problems.Count -gt 0) {
        throw "Cannot generate inputs for solution '$($Manifest['name'])':$([Environment]::NewLine)$($problems -join [Environment]::NewLine)"
    }

    $names = Resolve-NIC26NameCatalog -Catalog $Manifest['names'] -Values $values

    Write-NIC26Log -Message "Resolved $($inputs.Count) input(s) and $($names.Count) name(s) for solution '$($Manifest['name'])'" -Level Verbose

    return [ordered]@{
        manifest      = $Manifest
        inputs        = $inputs
        names         = $names
        solution_root = $Manifest['solution_root']
    }
}
