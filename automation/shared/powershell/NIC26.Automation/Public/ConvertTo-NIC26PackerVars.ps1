function ConvertTo-NIC26PackerVars {
    <#
    .SYNOPSIS
        Generates <solution>\packer\windows11.generated.auto.pkrvars.json (Packer variable file) from the solution manifest and the canonical config.
    .DESCRIPTION
        Packer variables carry their own names (iso_path, switch_name, ...), so a manifest input maps to one with the optional
        'packer_var' field in solution.yml. Only inputs that declare 'packer_var' are emitted (Packer rejects variables the
        template does not declare); a dotted 'packer_var' such as customizer_tokens.install_teams_app builds a map(string)
        (values become strings, booleans lower-case). A catalog name called 'vm_name' is emitted as the vm_name variable.
        Inputs of type secret-ref are never emitted: user names and passwords are resolved in memory by the build wrapper
        (scripts\Invoke-PackerBuild.ps1 resolves the build account and sets PKR_VAR_* only in the Packer child process).
        Fails when a required input is missing. Without -Execute nothing is written: the JSON text is returned. With
        -Execute the file is written (UTF-8, LF) and its FileInfo returned; -WhatIf is honoured.
    .PARAMETER Solution
        Solution folder, solution.yml path, or solution name (searched under automation\).
    .PARAMETER Config
        Object returned by Get-NIC26Config (its 'values' are used) or a dictionary of canonical values.
    .PARAMETER OutFile
        Override the output path (default <solution>\packer\windows11.generated.auto.pkrvars.json).
    .PARAMETER Execute
        Write the file. Default is preview only.
    .EXAMPLE
        ConvertTo-NIC26PackerVars -Solution avd-images-packer-hyperv -Config (Get-NIC26Config -Scope avd) -Execute
    .OUTPUTS
        System.String (preview) or System.IO.FileInfo (with -Execute)
    #>
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

    $root = Resolve-NIC26SolutionPath -Solution $Solution
    $manifest = Get-NIC26SolutionManifest -Path $root
    if ('packer' -notin @($manifest['tools'])) {
        throw "Solution '$($manifest['name'])' does not declare 'packer' in tools; nothing to generate."
    }
    $resolved = Resolve-NIC26SolutionInputs -Manifest $manifest -Config $Config

    $document = [ordered]@{}
    foreach ($inputDef in @($manifest['inputs'])) {
        $name = [string]$inputDef['name']
        if (-not $inputDef.Contains('packer_var') -or -not $inputDef['packer_var']) { continue }
        if ([string]$inputDef['type'] -eq 'secret-ref') { continue }
        if (-not $resolved.inputs.Contains($name)) { continue }
        $value = $resolved.inputs[$name]
        $parts = ([string]$inputDef['packer_var']) -split '\.'
        if ($parts.Count -eq 1) {
            $document[$parts[0]] = $value
            continue
        }
        if (-not $document.Contains($parts[0])) { $document[$parts[0]] = [ordered]@{} }
        $text = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { [string]$value }
        $document[$parts[0]][$parts[1]] = $text
    }
    if ($resolved.names.Contains('vm_name')) { $document['vm_name'] = [string]$resolved.names['vm_name'] }
    $content = ($document | ConvertTo-Json -Depth 20) + "`n"

    if (-not $OutFile) {
        $OutFile = Join-Path $root 'packer' 'windows11.generated.auto.pkrvars.json'
    }
    if (-not $Execute) {
        Write-NIC26Log -Message "Preview only for '$($manifest['name'])' (pass -Execute to write $OutFile)" -Level Verbose
        return $content
    }
    if ($PSCmdlet.ShouldProcess($OutFile, 'Write generated Packer variable file')) {
        return Write-NIC26GeneratedFile -Path $OutFile -Content $content
    }
}
