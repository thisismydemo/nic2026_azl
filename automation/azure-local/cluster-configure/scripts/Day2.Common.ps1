# Shared helpers for every cluster-configure/<solution> script (dot-sourced). Nothing here changes Azure on its own:
# the generic driver Invoke-Day2Solution runs what-if / plan by default and applies, removes or destroys only with -Execute.
#Requires -Version 7.0
Set-StrictMode -Version Latest

function Get-Day2RepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\..')).Path
}

function Get-Day2ConfigureRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
}

function Import-Day2AutomationModule {
    [CmdletBinding()]
    [OutputType([bool])]
    param([switch]$Optional)
    $manifest = Join-Path (Get-Day2RepoRoot) 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1'
    if (-not (Test-Path -LiteralPath $manifest)) {
        if ($Optional) { return $false }
        throw "NIC26.Automation module not found at $manifest."
    }
    Import-Module $manifest -Force -ErrorAction Stop
    return $true
}

function Write-Day2Log {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Verbose', 'Info', 'Warning', 'Error')][string]$Level = 'Info', [string]$Source = 'cluster-configure')
    if (Get-Command -Name Write-NIC26Log -ErrorAction SilentlyContinue) { Write-NIC26Log -Message $Message -Level $Level -Source $Source; return }
    switch ($Level) {
        'Verbose' { Write-Verbose $Message }
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error $Message }
        default { Write-Information -MessageData "[$Source] $Message" -InformationAction Continue }
    }
}

function Test-Day2Command {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-Day2Inputs {
    <#
    .SYNOPSIS
        Reads a solution's canonical inputs: terraform.generated.tfvars.json, or terraform.example.tfvars.json with -AllowExample.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$SolutionRoot, [string]$InputFile, [switch]$AllowExample)
    $file = if ($InputFile) { $InputFile } else { Join-Path $SolutionRoot 'terraform\terraform.generated.tfvars.json' }
    if (-not (Test-Path -LiteralPath $file) -and $AllowExample) { $file = Join-Path $SolutionRoot 'terraform\terraform.example.tfvars.json' }
    if (-not (Test-Path -LiteralPath $file)) { throw "Input file not found: $file. Run ConvertTo-NIC26TfVars -Solution $SolutionRoot -Execute first." }
    $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -Depth 50
    foreach ($required in 'subscription_id', 'names') { if (-not ($json.PSObject.Properties.Name -contains $required)) { throw "Input file is missing '$required'." } }
    return $json
}

function Assert-Day2AzContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)
    if (-not (Test-Day2Command -Name Get-AzContext)) { throw 'Az.Accounts is not installed.' }
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
    if ($ctx.Subscription.Id -ne $SubscriptionId) { [void](Set-AzContext -WhatIf:$false -Subscription $SubscriptionId -ErrorAction Stop) }
}

function Invoke-Day2Native {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory, [switch]$PassThru)
    Write-Day2Log -Level Verbose -Message "$FilePath $($ArgumentList -join ' ')"
    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location -LiteralPath $WorkingDirectory }
        $output = & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) { throw "$FilePath exited with code $LASTEXITCODE" }
        if ($PassThru) { return $output }
        if ($null -ne $output) { $output | ForEach-Object { Write-Information -MessageData $_ -InformationAction Continue } }
    }
    finally { Set-Location -LiteralPath $previous }
}

function Get-Day2Resource {
    <#
    .SYNOPSIS
        READ-ONLY GET of an ARM path; returns the parsed body or $null on 404.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $r = Invoke-AzRestMethod -Path $Path -Method GET
    if ($r.StatusCode -eq 404) { return $null }
    if ($r.StatusCode -ge 400) { throw "GET $Path -> HTTP $($r.StatusCode)" }
    return ($r.Content | ConvertFrom-Json -Depth 50)
}

function New-Day2ControlState {
    <#
    .SYNOPSIS
        The contract object the demo script (Test-Day2Readiness) reads: { control, state: Applied|Removed|Partial, evidence }.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object factory; changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Control,
        [Parameter(Mandatory)][ValidateSet('Applied', 'Removed', 'Partial', 'Unknown')][string]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Evidence,
        [string]$Section = ''
    )
    return [pscustomobject]@{ control = $Control; state = $State; evidence = $Evidence; section = $Section; checkedAt = (Get-Date).ToUniversalTime().ToString('o') }
}

function Resolve-Day2State {
    <#
    .SYNOPSIS
        Applied when every expected item is present, Removed when none, Partial otherwise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Present, [Parameter(Mandatory)][int]$Expected)
    if ($Expected -le 0) { return 'Unknown' }
    if ($Present -ge $Expected) { return 'Applied' }
    if ($Present -le 0) { return 'Removed' }
    return 'Partial'
}

function Invoke-Day2Solution {
    <#
    .SYNOPSIS
        Generic Apply / Remove driver for one Day-2 solution (Bicep what-if/create, Terraform plan/apply/destroy, or a
        PowerShell remove block for resources Bicep cannot delete). Default -WhatIf: nothing changes without -Execute.
    .PARAMETER PreApplyCheck
        Optional script block run with the inputs object before an Apply; it throws to refuse (nothing has been sent to Azure).
    .PARAMETER RemoveWithAz
        Script block that deletes the solution's resources with Az cmdlets (used for -Action Remove with -Tool Bicep,
        because an ARM deployment cannot delete). Receives the inputs object; must honour $WhatIfPreference.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$SolutionRoot,
        [Parameter(Mandatory)][string]$SolutionName,
        [Parameter(Mandatory)][ValidateSet('Apply', 'Remove')][string]$Action,
        [Parameter(Mandatory)][ValidateSet('Bicep', 'Terraform')][string]$Tool,
        [ValidateSet('group', 'sub')][string]$DeploymentScope = 'group',
        [string]$ResourceGroupKey = 'rg_azl',
        [string]$BackendConfig,
        [hashtable]$ExtraBicepParameters = @{},
        [string]$Scope = 'azure-local',
        [scriptblock]$RemoveWithAz,
        [Parameter()][scriptblock]$PreApplyCheck,
        [switch]$Execute
    )
    if (-not $Execute) { $WhatIfPreference = $true }
    # Parameter guards first (before any config load or Azure call): deterministic refusals.
    if ($Tool -eq 'Terraform' -and -not $BackendConfig) { throw 'Terraform needs -BackendConfig <environment/.../backend.hcl> (contract §3); nothing was read or changed.' }
    if ($Tool -eq 'Bicep' -and $Action -eq 'Remove' -and -not $RemoveWithAz) { throw "$SolutionName has no Az remove block; use -Tool Terraform (destroy) instead." }
    foreach ($cmd in @('az') + $(if ($Tool -eq 'Terraform') { @('terraform') } else { @() })) {
        if (-not (Test-Day2Command -Name $cmd)) { throw "'$cmd' is not installed on this machine." }
    }
    [void](Import-Day2AutomationModule)
    $bicepDir = Join-Path $SolutionRoot 'bicep'
    $tfDir = Join-Path $SolutionRoot 'terraform'
    $tfVarsFile = Join-Path $tfDir 'terraform.generated.tfvars.json'
    $bicepParamFile = Join-Path $bicepDir 'main.generated.bicepparam'

    # Generate (local files only; never an Azure change)
    $config = Get-NIC26Config -Scope $Scope
    ConvertTo-NIC26BicepParam -Solution $SolutionRoot -Config $config -Execute | Out-Null
    ConvertTo-NIC26TfVars -Solution $SolutionRoot -Config $config -Execute | Out-Null
    $inputs = Get-Day2Inputs -SolutionRoot $SolutionRoot
    # Solution-specific refusals that must happen before any what-if or deployment (for example a start date that has passed).
    if ($Action -eq 'Apply' -and $PreApplyCheck) { & $PreApplyCheck $inputs }
    Assert-Day2AzContext -SubscriptionId $inputs.subscription_id
    $deploymentName = "$($inputs.names.deployment_name)-$($Action.ToLowerInvariant())"
    $target = "$SolutionName ($Action, $Tool) in subscription $($inputs.subscription_id)"

    if ($Tool -eq 'Bicep') {
        Invoke-Day2Native -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', (Join-Path $bicepDir 'main.bicep'), '--stdout') -PassThru | Out-Null
        $extra = @()
        foreach ($k in $ExtraBicepParameters.Keys) { $extra += @('--parameters', "$k=$($ExtraBicepParameters[$k])") }
        if ($Action -eq 'Apply') {
            $common = if ($DeploymentScope -eq 'sub') { @('deployment', 'sub', $null, '--location', $inputs.location) } else { @('deployment', 'group', $null, '--resource-group', $inputs.names.$ResourceGroupKey) }
            $common[2] = 'what-if'
            Invoke-Day2Native -FilePath 'az' -ArgumentList ($common + @('--subscription', $inputs.subscription_id, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--parameters', $bicepParamFile) + $extra)
            if (-not $Execute) { Write-Warning "WhatIf (default): $SolutionName would be applied. Re-run with -Execute."; return }
            if ($PSCmdlet.ShouldProcess($target, 'az deployment create')) {
                $common[2] = 'create'
                Invoke-Day2Native -FilePath 'az' -ArgumentList ($common + @('--subscription', $inputs.subscription_id, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--parameters', $bicepParamFile) + $extra)
            }
        }
        else {
            if (-not $Execute) { Write-Warning "WhatIf (default): listing what -Action Remove would delete for $SolutionName." }
            if ($Execute -and -not $PSCmdlet.ShouldProcess($target, 'remove resources')) { return }
            & $RemoveWithAz $inputs
        }
    }
    else {
        Invoke-Day2Native -FilePath 'terraform' -ArgumentList @('fmt', '-check', '-recursive') -WorkingDirectory $tfDir
        Invoke-Day2Native -FilePath 'terraform' -ArgumentList @('init', '-input=false', "-backend-config=$BackendConfig") -WorkingDirectory $tfDir
        Invoke-Day2Native -FilePath 'terraform' -ArgumentList @('validate') -WorkingDirectory $tfDir
        $planArgs = @('plan', '-input=false', "-var-file=$tfVarsFile", "-out=$SolutionName.tfplan") + $(if ($Action -eq 'Remove') { @('-destroy') } else { @() })
        Invoke-Day2Native -FilePath 'terraform' -ArgumentList $planArgs -WorkingDirectory $tfDir
        if (-not $Execute) { Write-Warning "WhatIf (default): plan written; nothing applied. Re-run with -Execute."; return }
        if ($PSCmdlet.ShouldProcess($target, "terraform apply ($Action)")) {
            Invoke-Day2Native -FilePath 'terraform' -ArgumentList @('apply', '-input=false', "$SolutionName.tfplan") -WorkingDirectory $tfDir
        }
    }
    Write-Day2Log -Message "$SolutionName $Action finished. Verify with ..\..\scripts\Get-Day2ControlState.ps1."
}

function Remove-Day2ArmResource {
    <#
    .SYNOPSIS
        Deletes one ARM resource by ID (honours WhatIf); reports when it is already absent (idempotent remove).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([Parameter(Mandatory)][string]$ResourceId, [Parameter(Mandatory)][string]$ApiVersion)
    $existing = Get-Day2Resource -Path "${ResourceId}?api-version=$ApiVersion"
    if (-not $existing) { Write-Day2Log -Message "absent (nothing to remove): $ResourceId"; return }
    if ($PSCmdlet.ShouldProcess($ResourceId, 'DELETE')) {
        $r = Invoke-AzRestMethod -Path "${ResourceId}?api-version=$ApiVersion" -Method DELETE
        if ($r.StatusCode -ge 400) { throw "DELETE $ResourceId -> HTTP $($r.StatusCode)" }
        Write-Day2Log -Message "deleted (HTTP $($r.StatusCode)): $ResourceId"
    }
}

function Test-Day2MaintenanceStart {
    <#
    .SYNOPSIS
        True when a maintenance-window start ('yyyy-MM-dd HH:mm' in the given time zone) is not in the past. The Azure Update
        Manager API accepts the current date or a later one; a replay after the original start date would otherwise fail
        halfway through the deployment. An unknown time zone name falls back to UTC.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StartDateTime,
        [string]$TimeZone,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $start = [datetime]::ParseExact($StartDateTime, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $zone = [TimeZoneInfo]::Utc
    if ($TimeZone) { try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone) } catch { $zone = [TimeZoneInfo]::Utc } }
    $startUtc = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::SpecifyKind($start, [DateTimeKind]::Unspecified), $zone)
    return ($startUtc.Date -ge $NowUtc.Date)
}