# Shared helpers for the cluster-deploy scripts (dot-sourced). No secret value ever passes through these functions.
#Requires -Version 7.0
Set-StrictMode -Version Latest

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
    return $json
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
        $output = & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE" }
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
    $reported = if ($body.properties.PSObject.Properties.Name -contains 'reportedProperties') { $body.properties.reportedProperties } else { $null }
    $validation = if ($reported -and $reported.PSObject.Properties.Name -contains 'validationStatus') { $reported.validationStatus } else { $null }
    $deployment = if ($reported -and $reported.PSObject.Properties.Name -contains 'deploymentStatus') { $reported.deploymentStatus } else { $null }
    $steps = @()
    foreach ($src in @($validation, $deployment)) {
        if ($src -and $src.PSObject.Properties.Name -contains 'steps') {
            $steps += @($src.steps | ForEach-Object { [pscustomobject]@{ Name = $_.name; Status = $_.status; Start = $_.startTimeUtc; End = $_.endTimeUtc } })
        }
    }
    return [pscustomobject]@{
        Exists            = $true
        ProvisioningState = $body.properties.provisioningState
        DeploymentMode    = $body.properties.deploymentMode
        ValidationStatus  = if ($validation) { $validation.status } else { $null }
        DeploymentStatus  = if ($deployment) { $deployment.status } else { $null }
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