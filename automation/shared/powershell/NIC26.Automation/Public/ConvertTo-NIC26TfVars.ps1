function ConvertTo-NIC26TfVars {
    <#
    .SYNOPSIS
        Generates <solution>\terraform\terraform.generated.tfvars.json from the solution manifest and the canonical config.
    .DESCRIPTION
        Emits only the inputs declared in solution.yml (canonical snake_case names, matching variables.tf), plus
        "names" (map of string) resolved from the names catalog, plus a "_generated" marker object. Fails when a
        required input is missing or a name violates the naming standard. Secret-ref inputs are emitted only as
        keyvault://<vault>/<secret> strings. Without -Execute nothing is written: the JSON text is returned. With
        -Execute the file is written and its FileInfo returned; -WhatIf is honoured.
        Terraform warns about the undeclared "_generated" value; declare 'variable "_generated" { type = any; default = null }'
        in variables.tf to silence it, or ignore the warning.
    .PARAMETER Solution
        Solution folder, solution.yml path, or solution name (searched under automation\).
    .PARAMETER Config
        Object returned by Get-NIC26Config (its 'values' are used) or a dictionary of canonical values.
    .PARAMETER OutFile
        Override the output path (default <solution>\terraform\terraform.generated.tfvars.json).
    .PARAMETER Execute
        Write the file. Default is preview only.
    .EXAMPLE
        ConvertTo-NIC26TfVars -Solution lz-azure-local -Config (Get-NIC26Config -Scope azure-local) -Execute
    .OUTPUTS
        System.String (preview) or System.IO.FileInfo (with -Execute)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Function name is fixed by automation/CONTRACT.md section 3 (TfVars is the Terraform artefact name).')]
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
    if ('terraform' -notin @($manifest['tools'])) {
        throw "Solution '$($manifest['name'])' does not declare 'terraform' in tools; nothing to generate."
    }
    $resolved = Resolve-NIC26SolutionInputs -Manifest $manifest -Config $Config

    $document = [ordered]@{
        _generated = [ordered]@{
            tool             = 'NIC26.Automation ConvertTo-NIC26TfVars'
            solution         = $manifest['name']
            generated_at_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
            note             = (Get-NIC26GeneratedHeader -Tool 'ConvertTo-NIC26TfVars' -SolutionName $manifest['name'])[1]
        }
    }
    foreach ($name in $resolved.inputs.Keys) {
        $document[$name] = $resolved.inputs[$name]
    }
    $document['names'] = $resolved.names
    $content = ($document | ConvertTo-Json -Depth 100) + "`n"

    if (-not $OutFile) {
        $OutFile = Join-Path $root 'terraform' 'terraform.generated.tfvars.json'
    }

    if (-not $Execute) {
        Write-NIC26Log -Message "Preview only for '$($manifest['name'])' (pass -Execute to write $OutFile)" -Level Verbose
        return $content
    }
    if ($PSCmdlet.ShouldProcess($OutFile, 'Write generated Terraform variables file')) {
        return Write-NIC26GeneratedFile -Path $OutFile -Content $content
    }
}
