function ConvertTo-NIC26BicepParam {
    <#
    .SYNOPSIS
        Generates <solution>\bicep\main.generated.bicepparam from the solution manifest and the canonical config.
    .DESCRIPTION
        Emits only the inputs declared in solution.yml (by canonical snake_case name, same casing as the manifest, so
        main.bicep declares e.g. 'param tenant_id string'), plus 'param names = { ... }' resolved from the names catalog
        with New-NIC26ResourceName. Fails when a required input is missing or a name violates the naming standard.
        Secret-ref inputs are emitted only as keyvault://<vault>/<secret> strings; never a value.
        Without -Execute nothing is written: the generated text is returned for review. With -Execute the file is
        written (UTF-8, LF) and its FileInfo returned; -WhatIf is honoured.
    .PARAMETER Solution
        Solution folder, solution.yml path, or solution name (searched under automation\).
    .PARAMETER Config
        Object returned by Get-NIC26Config (its 'values' are used) or a dictionary of canonical values.
    .PARAMETER OutFile
        Override the output path (default <solution>\bicep\main.generated.bicepparam).
    .PARAMETER Execute
        Write the file. Default is preview only.
    .EXAMPLE
        $cfg = Get-NIC26Config -Scope avd
        ConvertTo-NIC26BicepParam -Solution lz-avd -Config $cfg -Execute
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
    if ('bicep' -notin @($manifest['tools'])) {
        throw "Solution '$($manifest['name'])' does not declare 'bicep' in tools; nothing to generate."
    }
    $resolved = Resolve-NIC26SolutionInputs -Manifest $manifest -Config $Config

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($header in (Get-NIC26GeneratedHeader -Tool 'ConvertTo-NIC26BicepParam' -SolutionName $manifest['name'])) {
        $lines.Add("// $header")
    }
    $lines.Add("using './main.bicep'")
    $lines.Add('')
    foreach ($name in $resolved.inputs.Keys) {
        $lines.Add("param $name = $(ConvertTo-NIC26BicepLiteral -Value $resolved.inputs[$name])")
    }
    $lines.Add('')
    $lines.Add("param names = $(ConvertTo-NIC26BicepLiteral -Value $resolved.names)")
    $content = ($lines -join "`n") + "`n"

    if (-not $OutFile) {
        $OutFile = Join-Path $root 'bicep' 'main.generated.bicepparam'
    }

    if (-not $Execute) {
        Write-NIC26Log -Message "Preview only for '$($manifest['name'])' (pass -Execute to write $OutFile)" -Level Verbose
        return $content
    }
    if ($PSCmdlet.ShouldProcess($OutFile, 'Write generated Bicep parameter file')) {
        return Write-NIC26GeneratedFile -Path $OutFile -Content $content
    }
}
