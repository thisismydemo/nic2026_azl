# Shared helpers for the cluster-deploy scripts (dot-sourced). No secret value ever passes through these functions.
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ClusterDeploySolutionRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Get-ClusterDeployRepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

function Import-ClusterDeployAutomationModule {
    <#
    .SYNOPSIS
        Imports automation/shared/powershell/NIC26.Automation (config loader, converters, Key Vault resolver, retry, log).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Optional)
    $manifest = Join-Path (Get-ClusterDeployRepoRoot) 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        if ($Optional) { return $false }
        throw "NIC26.Automation module not found at $manifest (automation/shared is a prerequisite)."
    }
    Import-Module $manifest -Force -ErrorAction Stop
    # This orchestrator invokes retry helpers after nested stage functions return; expose the
    # exported command in the caller scope as well as the module scope.
    $retry = Join-Path (Get-ClusterDeployRepoRoot) 'automation\shared\powershell\NIC26.Automation\Public\Invoke-NIC26WithRetry.ps1'
    if ((Test-Path -LiteralPath $retry) -and -not (Get-Command Invoke-NIC26WithRetry -ErrorAction SilentlyContinue)) { . $retry }
    return $true
}

function Write-ClusterDeployLog {
    <#
    .SYNOPSIS
        Information-stream logging (names, IDs, counts and durations only; never values). Uses Write-NIC26Log when loaded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Verbose', 'Info', 'Warning', 'Error')][string]$Level = 'Info'
    )
    if (Get-Command -Name Write-NIC26Log -ErrorAction SilentlyContinue) {
        Write-NIC26Log -Message $Message -Level $Level -Source 'cluster-deploy'
        return
    }
    switch ($Level) {
        'Verbose' { Write-Verbose $Message }
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error $Message }
        default { Write-Information -MessageData "[cluster-deploy] $Message" -InformationAction Continue }
    }
}

function Test-ClusterDeployCommand {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-ClusterDeployInputs {
    <#
    .SYNOPSIS
        Reads the canonical inputs (terraform.generated.tfvars.json or the example file for a dry run) as an object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$InputFile)
    if (-not (Test-Path -LiteralPath $InputFile)) { throw "Input file not found: $InputFile. Run the Generate stage (ConvertTo-NIC26TfVars) first." }
    $json = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json -Depth 50
    foreach ($required in 'subscription_id', 'cluster_name', 'kv_azl_name', 'witness', 'nodes', 'names') {
        if (-not ($json.PSObject.Properties.Name -contains $required)) { throw "Input file is missing '$required'." }
    }
    if ($json.nodes -isnot [array] -or $json.nodes.Count -eq 0) {
        throw 'Input nodes must be a nonempty array of named node objects.'
    }
    $nodeNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($node in $json.nodes) {
        if ($node -isnot [pscustomobject] -or -not $node.PSObject.Properties['name'] -or
            $node.name -isnot [string] -or [string]::IsNullOrWhiteSpace($node.name)) {
            throw 'Every input node must have a nonblank string name.'
        }
        if ($node.name -ne $node.name.Trim() -or -not $nodeNames.Add($node.name)) {
            throw 'Input node names must be unique case-insensitively and have no surrounding whitespace.'
        }
    }
    return $json
}

function Get-ClusterDeployArcMachineName {
    <#
    .SYNOPSIS
        Microsoft.HybridCompute/machines name of an input node: inputs.arc_machine_names[<host name>] when set (simplified
        machine provisioning names the Arc machine <device-id>-1), otherwise the host name. Same rule as main.bicep and
        terraform/main.tf.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Node,
        [Parameter(Mandatory)][object]$Inputs
    )
    $map = if ($Inputs.PSObject.Properties.Name -contains 'arc_machine_names') { $Inputs.arc_machine_names } else { $null }
    # Indexed lookup: under StrictMode .PSObject.Properties.Name throws on an empty map ({} from the generated inputs).
    $entry = if ($map) { $map.PSObject.Properties[[string]$Node.name] } else { $null }
    $arc = if ($entry) { [string]$entry.Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($arc)) { return [string]$Node.name }
    return $arc
}

function Get-ClusterDeploySecretName {
    <#
    .SYNOPSIS
        Cluster-vault names of the two ECE secrets: local_admin_secret_name / witness_key_secret_name when set, otherwise
        the quickstart convention <cluster_name>-LocalAdminCredential / -WitnessStorageKey. Same rule as main.bicep and
        terraform/main.tf.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][object]$Inputs)
    $pick = { param($prop, $suffix)
        if ($Inputs.PSObject.Properties.Name -contains $prop -and $Inputs.$prop) { [string]$Inputs.$prop } else { "$($Inputs.cluster_name)-$suffix" } }
    return [pscustomobject]@{ LocalAdmin = (& $pick 'local_admin_secret_name' 'LocalAdminCredential'); WitnessKey = (& $pick 'witness_key_secret_name' 'WitnessStorageKey') }
}

function Assert-ClusterDeployAzContext {
    <#
    .SYNOPSIS
        Requires an Az context on the expected subscription; never prints tokens.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)
    if (-not (Test-ClusterDeployCommand -Name Get-AzContext)) { throw 'Az.Accounts is not installed (Install-PSResource Az.Accounts).' }
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount (operator sign-in) first.' }
    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        [void](Set-AzContext -WhatIf:$false -Subscription $SubscriptionId -ErrorAction Stop)
    }
}

function Invoke-ClusterDeployNative {
    <#
    .SYNOPSIS
        Runs a native tool (az, terraform) and throws on a non-zero exit code. Arguments are logged, output is passed through.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [switch]$PassThru
    )
    Write-ClusterDeployLog -Level Verbose -Message "$FilePath $($ArgumentList -join ' ')"
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        # stderr is captured separately so a failure reports the tool's own error text (the 05:40 Validate run logged only
        # "exited with code 1"); stdout keeps its shape for -PassThru callers that parse JSON.
        $all = & $FilePath @ArgumentList 2>&1
        $stderr = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { $_.ToString() })
        $output = $all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
        if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE`n$($stderr -join "`n")" }
        if ($stderr.Count -gt 0) { Write-ClusterDeployLog -Level Verbose -Message ($stderr -join "`n") }
        if ($PassThru) { return $output }
        if ($null -ne $output) { $output | ForEach-Object { Write-Information -MessageData $_ -InformationAction Continue } }
    }
    finally {
        Set-Location -LiteralPath $previous
    }
}

function Get-ClusterDeploymentSettingsState {
    <#
    .SYNOPSIS
        READ-ONLY: GET clusters/deploymentSettings/default and return the reported validation / deployment status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ClusterName,
        [string]$ApiVersion = '2025-09-15-preview'
    )
    $path = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/clusters/$ClusterName/deploymentSettings/default?api-version=$ApiVersion"
    $response = Invoke-AzRestMethod -Path $path -Method GET
    if ($response.StatusCode -eq 404) {
        return [pscustomobject]@{ Exists = $false; ProvisioningState = $null; ValidationStatus = $null; DeploymentStatus = $null; Steps = @() }
    }
    if ($response.StatusCode -ge 400) { throw "GET deploymentSettings failed: HTTP $($response.StatusCode)" }
    $body = $response.Content | ConvertFrom-Json -Depth 50
    # Reported status objects can be empty ({}) or lack fields while a pass starts: an indexed Properties lookup is safe under
    # StrictMode, whereas .PSObject.Properties.Name on an empty object throws "property 'Name' cannot be found".
    $field = { param($o, $n) if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$n]; if ($p) { $p.Value } else { $null } }
    $reported = & $field $body.properties 'reportedProperties'
    $validation = & $field $reported 'validationStatus'
    $deployment = & $field $reported 'deploymentStatus'
    $steps = @()
    foreach ($src in @($validation, $deployment)) {
        if (& $field $src 'steps') {
            $steps += @($src.steps | Where-Object { & $field $_ 'name' } | ForEach-Object {
                    [pscustomobject]@{ Name = (& $field $_ 'name'); Status = (& $field $_ 'status'); Start = (& $field $_ 'startTimeUtc'); End = (& $field $_ 'endTimeUtc') } })
        }
    }
    return [pscustomobject]@{
        Exists            = $true
        ProvisioningState = $body.properties.provisioningState
        DeploymentMode    = $body.properties.deploymentMode
        ValidationStatus  = & $field $validation 'status'
        DeploymentStatus  = & $field $deployment 'status'
        Steps             = $steps
    }
}

function ConvertTo-ClusterDeployResult {
    <#
    .SYNOPSIS
        Uniform check/result object {check, result, evidence} used by the read-only test scripts.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Check,
        [Parameter(Mandatory)][ValidateSet('pass', 'fail', 'skip')][string]$Result,
        [string]$Evidence = ''
    )
    return [pscustomobject]@{ check = $Check; result = $Result; evidence = $Evidence; checkedAt = (Get-Date).ToUniversalTime().ToString('o') }
}

function Resolve-ClusterDeployPassOutcome {
    <#
    .SYNOPSIS
        Decides whether a Validate or Deploy pass has finished, from the ARM deployment state of THIS submission and the
        deploymentSettings status. A status left over from an earlier pass is never an outcome: with Bicep the ARM
        deployment of this submission must itself be terminal first. Returns Success, Failed, Error, or $null (keep polling).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Bicep', 'Terraform')][string]$Tool,
        [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Pass,
        [string]$ArmState,
        [string]$ValidationStatus,
        [string]$DeploymentStatus
    )
    $status = if ($Pass -eq 'Validate') { $ValidationStatus } else { $DeploymentStatus }
    if ($Tool -eq 'Bicep') {
        if ($ArmState -in 'Failed', 'Canceled') { return 'Failed' }
        if ($ArmState -ne 'Succeeded') { return $null }
    }
    if ($status -in 'Success', 'Failed', 'Error') { return $status }
    return $null
}

function Test-ClusterDeploySecretUsable {
    <#
    .SYNOPSIS
        Returns $null when a Key Vault secret object can be used for a pass of the given length, otherwise the reason.
        Reads metadata only (Enabled, Expires); never the value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][object]$Secret,
        [Parameter(Mandatory)][datetime]$ValidUntil
    )
    if ($null -eq $Secret) { return 'missing' }
    if ($Secret.PSObject.Properties['Enabled'] -and $null -ne $Secret.Enabled -and -not [bool]$Secret.Enabled) { return 'disabled' }
    $expires = if ($Secret.PSObject.Properties['Expires']) { $Secret.Expires } else { $null }
    if ($null -ne $expires -and ([datetime]$expires).ToUniversalTime() -le $ValidUntil.ToUniversalTime()) { return 'expires before the pass can finish' }
    return $null
}

# ------------------------------------------------------------------ pre-Deploy gate: Arc machine names vs MocArb lookup
# Simplified machine provisioning names each node's Arc machine <device-id>-1 (edgeMachines/<node>
# properties.arcMachineResourceId), not the host name. A MocArb package whose DeployVmoArcExtension resolves the Arc machine
# from $env:COMPUTERNAME then looks for an Arc machine that does not exist. Test-ClusterDeployArcNameGate.ps1 reads that
# package on the seed node READ-ONLY and these functions refuse the Deploy pass when both are true.

function Get-ClusterDeployDeviceIdArcName {
    <#
    .SYNOPSIS
        Nodes whose Arc machine name (arc_machine_names) differs from the host name: the device-ID names of simplified
        machine provisioning. Empty when every Arc machine carries its host name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][object]$Inputs)
    $rows = foreach ($node in @($Inputs.nodes)) {
        $arc = Get-ClusterDeployArcMachineName -Node $node -Inputs $Inputs
        if (-not [string]::Equals($arc, [string]$node.name, [StringComparison]::OrdinalIgnoreCase)) {
            [pscustomobject]@{ Node = [string]$node.name; ArcMachineName = $arc }
        }
    }
    return @($rows)
}

function Test-ClusterDeployMocArbArcNameBug {
    <#
    .SYNOPSIS
        Parses one MocArb package script and reports whether its DeployVmoArcExtension function (or class method) reads
        $env:COMPUTERNAME. Pure: the content is passed in and parsed, never executed.
    .OUTPUTS
        { Path, FunctionFound, UsesComputerName, Lines }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$Path = ''
    )
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$tokens, [ref]$parseErrors)
    $definitions = @($ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -match '(^|:)DeployVmoArcExtension$') -or
                ($node -is [System.Management.Automation.Language.FunctionMemberAst] -and $node.Name -eq 'DeployVmoArcExtension')
            }, $true))
    $lines = foreach ($definition in $definitions) {
        $definition.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals($node.VariablePath.UserPath, 'env:COMPUTERNAME', [StringComparison]::OrdinalIgnoreCase)
            }, $true) | ForEach-Object { $_.Extent.StartLineNumber }
    }
    $lines = @($lines | Sort-Object -Unique)
    return [pscustomobject]@{ Path = $Path; FunctionFound = $definitions.Count -gt 0; UsesComputerName = $lines.Count -gt 0; Lines = $lines }
}

function Get-ClusterDeployArcNameGateResult {
    <#
    .SYNOPSIS
        Decides the pre-Deploy gate from the inputs (arc_machine_names) and the MocArb findings of the seed node.
    .DESCRIPTION
        Pass     every Arc machine carries its host name, or the package defines DeployVmoArcExtension without
                 $env:COMPUTERNAME.
        Refuse   device-ID Arc names AND the lookup is present (BugPresent); or device-ID Arc names and no package file
                 defines DeployVmoArcExtension (Unverified). -AcceptUnverified turns Unverified (never BugPresent) into a
                 pass with a warning, as an explicit owner decision.
    .OUTPUTS
        { Result, Reason, SeedNode, RenamedNodes, Findings, Message }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [string]$SeedNode = '',
        [string[]]$SearchedRoot = @(),
        [switch]$AcceptUnverified
    )
    $renamed = @(Get-ClusterDeployDeviceIdArcName -Inputs $Inputs)
    $defining = @($Finding | Where-Object { $_.FunctionFound })
    $buggy = @($Finding | Where-Object { $_.UsesComputerName })
    $names = ($renamed | ForEach-Object { "$($_.Node) -> $($_.ArcMachineName)" }) -join ', '
    $where = if ($SeedNode) { "on seed node $SeedNode" } else { 'on the seed node' }
    if ($renamed.Count -eq 0) {
        $result = 'Pass'; $reason = 'HostNames'
        $message = 'Pre-Deploy gate passed: every Arc machine carries its host name, so a $env:COMPUTERNAME lookup in DeployVmoArcExtension finds it.'
    }
    elseif ($buggy.Count -gt 0) {
        $result = 'Refuse'; $reason = 'BugPresent'
        $files = ($buggy | ForEach-Object { "$($_.Path) line $($_.Lines -join ',')" }) -join '; '
        $message = "Deploy refused (pre-Deploy gate): the MocArb package $where resolves the Arc machine in DeployVmoArcExtension from `$env:COMPUTERNAME ($files), but simplified machine provisioning named this cluster's Arc machines by device ID ($names). That step would look for an Arc machine named after the host, which does not exist. Do not start the Deploy pass with this package: deploy with Arc machines named after their hosts, or with a MocArb package that does not read `$env:COMPUTERNAME there, then run the gate again (Test-ClusterDeployArcNameGate.ps1)."
    }
    elseif ($defining.Count -gt 0) {
        $result = 'Pass'; $reason = 'LookupAbsent'
        $message = "Pre-Deploy gate passed: DeployVmoArcExtension in the MocArb package $where does not read `$env:COMPUTERNAME ($(@($defining.Path) -join '; ')); the device-ID Arc names ($names) are safe for it."
    }
    elseif ($AcceptUnverified) {
        $result = 'Pass'; $reason = 'AcceptedUnverified'
        $message = "Pre-Deploy gate passed UNVERIFIED by explicit decision (-AcceptUnverified): no MocArb file $where defines DeployVmoArcExtension (searched $($SearchedRoot -join ', ')), and the Arc machines are named by device ID ($names)."
    }
    else {
        $result = 'Refuse'; $reason = 'Unverified'
        $message = "Deploy refused (pre-Deploy gate): the Arc machines are named by device ID ($names), and no MocArb package file $where defines DeployVmoArcExtension (searched $($SearchedRoot -join ', ')), so the `$env:COMPUTERNAME lookup cannot be ruled out. Point the gate at the package (-SearchRoot or -PackageFile) and run it again, or pass -AcceptUnverified as an explicit owner decision."
    }
    return [pscustomobject]@{ Result = $result; Reason = $reason; SeedNode = $SeedNode; RenamedNodes = $renamed; Findings = @($Finding); Message = $message }
}

function Assert-ClusterDeployArcNameGate {
    <#
    .SYNOPSIS
        Throws the gate's message when it refuses the Deploy pass; otherwise logs it and returns the gate result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Inputs,
        [AllowEmptyCollection()][object[]]$Finding = @(),
        [string]$SeedNode = '',
        [string[]]$SearchedRoot = @(),
        [switch]$AcceptUnverified
    )
    $gate = Get-ClusterDeployArcNameGateResult -Inputs $Inputs -Finding $Finding -SeedNode $SeedNode -SearchedRoot $SearchedRoot -AcceptUnverified:$AcceptUnverified
    if ($gate.Result -eq 'Refuse') { throw $gate.Message }
    $level = if ($gate.Reason -eq 'AcceptedUnverified') { 'Warning' } else { 'Info' }
    Write-ClusterDeployLog -Message $gate.Message -Level $level
    return $gate
}
