function Get-NIC26Config {
    <#
    .SYNOPSIS
        Loads, merges and schema-validates the environment configuration for a scope (shared, azure-local, avd).
    .DESCRIPTION
        Reads every *.yml in environment\shared (always) and, for azure-local / avd, every *.yml in environment\<scope>;
        files in a folder are deep-merged in file-name order (later files win). Each merged folder is validated against
        automation\shared\schemas\<scope>.environment.schema.json (JSON Schema draft 2020-12, via Test-Json; unknown keys
        are rejected). Returns an ordered dictionary with snake_case keys:
            scope        the requested scope
            sources      files loaded per scope
            shared       the shared values
            azure_local  or avd: the scope values (absent for -Scope shared)
            values       shared merged with the scope values (scope wins) - the canonical lookup the converters use
        Requires the powershell-yaml module: Install-PSResource powershell-yaml -Scope CurrentUser.
    .PARAMETER Scope
        shared | azure-local | avd
    .PARAMETER Path
        Folder with the scope's *.yml files. Default: <repo>\environment\<scope>.
    .PARAMETER SharedPath
        Folder with the shared *.yml files. Default: <repo>\environment\shared, or the 'shared' sibling of -Path when -Path is given.
    .PARAMETER SchemaRoot
        Folder with the *.schema.json files. Default: <automation>\shared\schemas next to this module ($env:NIC26_SCHEMA_ROOT overrides).
    .EXAMPLE
        $cfg = Get-NIC26Config -Scope avd
        $cfg.values.tenant_id
    .EXAMPLE
        Get-NIC26Config -Scope azure-local -Path C:\lab\env\azure-local -SharedPath C:\lab\env\shared
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('shared', 'azure-local', 'avd')]
        [string]$Scope,

        [Parameter()]
        [string]$Path,

        [Parameter()]
        [string]$SharedPath,

        [Parameter()]
        [string]$SchemaRoot
    )

    if (-not $SchemaRoot) {
        $SchemaRoot = Get-NIC26SchemaRoot
    }
    $environmentRoot = Join-Path (Get-NIC26RepoRoot) 'environment'

    if ($Scope -eq 'shared') {
        if ($Path -and -not $SharedPath) {
            $SharedPath = $Path
        }
    }
    elseif (-not $Path) {
        $Path = Join-Path $environmentRoot $Scope
    }
    if (-not $SharedPath) {
        if ($Path -and $Scope -ne 'shared') {
            $SharedPath = Join-Path (Split-Path -Path $Path -Parent) 'shared'
        }
        else {
            $SharedPath = Join-Path $environmentRoot 'shared'
        }
    }

    $shared = Import-NIC26ConfigFolder -Path $SharedPath -SchemaFile (Join-Path $SchemaRoot 'shared.environment.schema.json') -Scope 'shared'

    $result = [ordered]@{
        scope   = $Scope
        sources = [ordered]@{ shared = $shared.Files }
        shared  = $shared.Values
    }

    if ($Scope -eq 'shared') {
        $result['values'] = Copy-NIC26Value -Value $shared.Values
        Write-NIC26Log -Message "Loaded shared config from $($shared.Files.Count) file(s) in $SharedPath" -Level Verbose
        return $result
    }

    $scopeData = Import-NIC26ConfigFolder -Path $Path -SchemaFile (Join-Path $SchemaRoot "$Scope.environment.schema.json") -Scope $Scope
    $scopeKey = $Scope.Replace('-', '_')
    $result.sources[$scopeKey] = $scopeData.Files
    $result[$scopeKey] = $scopeData.Values
    $result['values'] = Merge-NIC26Hashtable -Base $shared.Values -Overlay $scopeData.Values
    Write-NIC26Log -Message "Loaded '$Scope' config: $($shared.Files.Count) shared file(s), $($scopeData.Files.Count) scope file(s); $($result.values.Count) top-level keys" -Level Verbose
    return $result
}
