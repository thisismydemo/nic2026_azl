function ConvertTo-NIC26AnsibleVars {
    <#
    .SYNOPSIS
        Generates <solution>\ansible\group_vars\generated.yml from the solution manifest and the canonical config.
    .DESCRIPTION
        Emits only the inputs declared in solution.yml (canonical snake_case names) plus 'names:' resolved from the
        names catalog. Fails when a required input is missing or a name violates the naming standard. Secret-ref
        inputs are emitted only as keyvault://<vault>/<secret> strings; playbooks resolve them at run time (never
        from a file). Without -Execute nothing is written: the YAML text is returned. With -Execute the file is
        written and its FileInfo returned; -WhatIf is honoured.
    .PARAMETER Solution
        Solution folder, solution.yml path, or solution name (searched under automation\).
    .PARAMETER Config
        Object returned by Get-NIC26Config (its 'values' are used) or a dictionary of canonical values.
    .PARAMETER OutFile
        Override the output path (default <solution>\ansible\group_vars\generated.yml).
    .PARAMETER Execute
        Write the file. Default is preview only.
    .EXAMPLE
        ConvertTo-NIC26AnsibleVars -Solution network-devices -Config (Get-NIC26Config -Scope azure-local) -Execute
    .OUTPUTS
        System.String (preview) or System.IO.FileInfo (with -Execute)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function name is fixed by automation/CONTRACT.md section 3 (group_vars is the Ansible artefact name).')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string], [System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Solution,

        [Parameter(Mandatory, Position = 1)]
        [AllowNull()]
        [object]$Config,

        [Parameter()]
        [string]$OutFile,

        [Parameter()]
        [switch]$Execute
    )

    Assert-NIC26YamlModule
    $root = Resolve-NIC26SolutionPath -Solution $Solution
    $manifest = Get-NIC26SolutionManifest -Path $root
    if ('ansible' -notin @($manifest['tools'])) {
        throw "Solution '$($manifest['name'])' does not declare 'ansible' in tools; nothing to generate."
    }
    $resolved = Resolve-NIC26SolutionInputs -Manifest $manifest -Config $Config

    $document = [ordered]@{}
    foreach ($name in $resolved.inputs.Keys) {
        $document[$name] = $resolved.inputs[$name]
    }
    $document['names'] = $resolved.names

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($header in (Get-NIC26GeneratedHeader -Tool 'ConvertTo-NIC26AnsibleVars' -SolutionName $manifest['name'])) {
        $lines.Add("# $header")
    }
    $lines.Add('---')
    $lines.Add((ConvertTo-Yaml -Data $document).TrimEnd())
    $content = ($lines -join "`n") + "`n"

    if (-not $OutFile) {
        $OutFile = Join-Path $root 'ansible' 'group_vars' 'generated.yml'
    }

    if (-not $Execute) {
        Write-NIC26Log -Message "Preview only for '$($manifest['name'])' (pass -Execute to write $OutFile)" -Level Verbose
        return $content
    }
    if ($PSCmdlet.ShouldProcess($OutFile, 'Write generated Ansible group_vars file')) {
        return Write-NIC26GeneratedFile -Path $OutFile -Content $content
    }
}
