#Requires -Version 7.0
#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Azure Copilot Observability Agent (preview) prerequisites, on-demand use only (D-047, D-054; T-5.7.2, T-6.3.2):
    the Azure Monitor workspace that holds Azure Monitor issues, Issue Contributor on it, and each listed subscription's
    defaultAzureMonitorWorkspace association. Default is a plan (what-if); -Execute changes Azure. Rerunnable.
.DESCRIPTION
    Inputs (G5, nothing lab-specific in this file):
      environment/shared/environment.yml        subscriptions map, location, tags
      environment/azure-local/environment.yml   observability_agent { amw_name, resource_group, associate_subscriptions,
                                                issue_contributors[] } (schema: automation/shared/schemas/
                                                azure-local.environment.schema.json)
    Steps, each idempotent:
      1. Microsoft.Monitor resource provider registered in the workspace subscription and every associated subscription.
      2. bicep/modules/observability-agent.bicep deployed to the monitoring resource group (Microsoft.Monitor/accounts with
         the merged tags, Issue Contributor role assignments with deterministic names).
      3. PUT /subscriptions/{id}/providers/Microsoft.Monitor/settings/default { defaultAzureMonitorWorkspace } per listed
         subscription, only when the current value differs (Learn: Use Azure Monitor issues - Associate an AMW with a
         subscription, https://learn.microsoft.com/azure/azure-monitor/aiops/issues-how-to#associate-an-amw-with-a-subscription).
      4. Read-back: workspace state and tags, Issue Contributor assignments on the workspace, association per subscription.
    No Microsoft.Monitor/observabilityAgents resource is created (autonomous deep investigations are billed; the
    on-demand chat and Investigate work without it). Investigations query the resources' own Log Analytics workspaces
    (design/azure-local/monitoring-design.md), which this script does not change.
    Runs in the caller's Az context; pin it per process first (Disable-AzContextAutosave -Scope Process; Set-AzContext
    -Tenant <tenant> -Scope Process). Never prints a secret (there are none in these inputs).
.PARAMETER EnvironmentPath
    Repository environment folder that holds shared\environment.yml and azure-local\environment.yml (default: <repo>/environment).
.PARAMETER SettingsApiVersion
    API version of Microsoft.Monitor/settings (preview-only operation).
.PARAMETER ReadBackPath
    Optional file for the read-back JSON.
.PARAMETER Execute
    Apply the changes. Without it the script prints the plan and the current state only.
.EXAMPLE
    ./Set-ObservabilityAgentPrereqs.ps1                       # plan + current state
.EXAMPLE
    ./Set-ObservabilityAgentPrereqs.ps1 -Execute -ReadBackPath ./amw-readback.json
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$EnvironmentPath,
    [string]$SettingsApiVersion = '2025-06-03-preview',
    [string]$ReadBackPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo = (Resolve-Path (Join-Path $root '..\..\..')).Path
if (-not $EnvironmentPath) { $EnvironmentPath = Join-Path $repo 'environment' }
$template = Join-Path $root 'bicep\modules\observability-agent.bicep'
$issueContributorRoleId = '8d7ecc5c-f27b-43cf-883f-46409d445502'   # built-in Issue Contributor (modules/built-in-roles.bicep)

function Write-Step([string]$Message) { Write-Information -MessageData "[observability-agent] $Message" -InformationAction Continue }

function Invoke-Arm {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('GET', 'PUT')][string]$Method = 'GET', [object]$Body, [switch]$AllowNotFound)
    $p = @{ Path = $Path; Method = $Method }
    if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    $r = Invoke-AzRestMethod @p
    if ($r.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($r.StatusCode -ge 400) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
    if ([string]::IsNullOrWhiteSpace($r.Content)) { return $null }
    return ($r.Content | ConvertFrom-Json -Depth 20)
}

function Get-Association([string]$SubscriptionId) {
    $s = Invoke-Arm -Path "/subscriptions/$SubscriptionId/providers/Microsoft.Monitor/settings/default?api-version=$SettingsApiVersion" -AllowNotFound
    if ($null -eq $s -or -not ($s.PSObject.Properties.Name -contains 'properties') -or $null -eq $s.properties) { return '' }
    if ($s.properties.PSObject.Properties.Name -contains 'defaultAzureMonitorWorkspace') { return [string]$s.properties.defaultAzureMonitorWorkspace }
    return ''
}

# ------------------------------------------------------------------ inputs
$sharedFile = Join-Path $EnvironmentPath 'shared\environment.yml'
$azlFile = Join-Path $EnvironmentPath 'azure-local\environment.yml'
foreach ($f in $sharedFile, $azlFile) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing input file $f." } }
$shared = Get-Content -LiteralPath $sharedFile -Raw | ConvertFrom-Yaml
$azl = Get-Content -LiteralPath $azlFile -Raw | ConvertFrom-Yaml
if (-not $azl.ContainsKey('observability_agent')) { throw "$azlFile has no observability_agent block." }
$oa = $azl.observability_agent
foreach ($k in 'amw_name', 'resource_group', 'associate_subscriptions') { if (-not $oa.ContainsKey($k)) { throw "observability_agent.$k is missing." } }

$amwSubKey = 'azure_local'   # the workspace lives in the Azure Local monitoring resource group (design: monitoring-design.md)
$amwSub = [string]$shared.subscriptions[$amwSubKey]
$amwRg = [string]$oa.resource_group
$amwName = [string]$oa.amw_name
$amwId = "/subscriptions/$amwSub/resourceGroups/$amwRg/providers/Microsoft.Monitor/accounts/$amwName"
$assoc = [ordered]@{}
foreach ($k in $oa.associate_subscriptions) {
    if (-not $shared.subscriptions.ContainsKey($k)) { throw "associate_subscriptions key '$k' is not in shared subscriptions." }
    $assoc[$k] = [string]$shared.subscriptions[$k]
}
$contributors = @(if ($oa.ContainsKey('issue_contributors')) { $oa.issue_contributors } else { @() })
$tags = @{}
foreach ($t in $shared.tags.Keys) { $tags[$t] = [string]$shared.tags[$t] }
if ($azl.ContainsKey('tags')) { foreach ($t in $azl.tags.Keys) { $tags[$t] = [string]$azl.tags[$t] } }
$tags['workload'] = 'monitoring'
$tags['managed-by'] = 'script'
$location = [string]$shared.location
if (-not $Execute) { Write-Warning 'Plan only (default): nothing is changed. Re-run with -Execute to apply.' }
# Every context switch names the tenant: without it Az can pick the home-tenant (delegated) projection of the same
# subscription, whose identity cannot write role assignments.
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Sign in and pin the tenant first (Set-AzContext -Tenant <tenant> -Scope Process -WhatIf:$false).' }
$tenantId = [string]$ctx.Tenant.Id

# ------------------------------------------------------------------ 1. resource provider
$allSubs = @($amwSub) + @($assoc.Values) | Select-Object -Unique
foreach ($s in $allSubs) {
    $null = Set-AzContext -Tenant $tenantId -Subscription $s -Scope Process -WhatIf:$false
    $state = (Get-AzResourceProvider -ProviderNamespace Microsoft.Monitor | Select-Object -First 1).RegistrationState
    Write-Step "Microsoft.Monitor in subscription key $(@($shared.subscriptions.Keys | Where-Object { $shared.subscriptions[$_] -eq $s })[0]): $state"
    if ($state -ne 'Registered' -and $Execute -and $PSCmdlet.ShouldProcess("subscription $s", 'Register-AzResourceProvider Microsoft.Monitor')) {
        $null = Register-AzResourceProvider -ProviderNamespace Microsoft.Monitor
        for ($i = 0; $i -lt 60; $i++) {
            if ((Get-AzResourceProvider -ProviderNamespace Microsoft.Monitor | Select-Object -First 1).RegistrationState -eq 'Registered') { break }
            Start-Sleep -Seconds 5
        }
        Write-Step "  -> $((Get-AzResourceProvider -ProviderNamespace Microsoft.Monitor | Select-Object -First 1).RegistrationState)"
    }
}

# ------------------------------------------------------------------ 2. workspace + Issue Contributor (Bicep)
$null = Set-AzContext -Tenant $tenantId -Subscription $amwSub -Scope Process -WhatIf:$false
$params = @{
    amw_name           = $amwName
    location           = $location
    tags               = $tags
    issue_contributors = @($contributors | ForEach-Object { @{ object_id = [string]$_.object_id; type = [string]$_.type } })
}
$dep = @{ ResourceGroupName = $amwRg; TemplateFile = $template; TemplateParameterObject = $params; Name = 'dep-nic26-observability-agent' }
if ($Execute) {
    if ($PSCmdlet.ShouldProcess("$amwRg/$amwName", 'deploy observability-agent.bicep')) {
        $r = New-AzResourceGroupDeployment @dep
        Write-Step "Deployment $($r.DeploymentName): $($r.ProvisioningState)"
        if ($r.ProvisioningState -ne 'Succeeded') { throw "Deployment did not succeed: $($r.ProvisioningState)" }
    }
}
elseif ((Get-AzResourceProvider -ProviderNamespace Microsoft.Monitor | Select-Object -First 1).RegistrationState -eq 'Registered') {
    Get-AzResourceGroupDeploymentWhatIfResult @dep | Out-String | Write-Output
}
else { Write-Step "What-if skipped: Microsoft.Monitor is not registered yet (step 1 registers it with -Execute)." }

# ------------------------------------------------------------------ 3. subscription association
foreach ($k in $assoc.Keys) {
    $s = $assoc[$k]
    $current = Get-Association $s
    if ($current -ieq $amwId) { Write-Step "Association ${k}: already $amwName"; continue }
    Write-Step "Association ${k}: '$current' -> $amwName"
    if ($Execute -and $PSCmdlet.ShouldProcess("subscription key $k", "set defaultAzureMonitorWorkspace = $amwName")) {
        $null = Invoke-Arm -Method PUT -Path "/subscriptions/$s/providers/Microsoft.Monitor/settings/default?api-version=$SettingsApiVersion" -Body @{ properties = @{ defaultAzureMonitorWorkspace = $amwId } }
    }
}

# ------------------------------------------------------------------ 4. read-back
$null = Set-AzContext -Tenant $tenantId -Subscription $amwSub -Scope Process -WhatIf:$false
$amw = Get-AzResource -ResourceId $amwId -ErrorAction SilentlyContinue
$ras = @(if ($amw) { Get-AzRoleAssignment -Scope $amwId | Where-Object { $_.RoleDefinitionId -match $issueContributorRoleId -and $_.Scope -ieq $amwId } })
$readBack = [ordered]@{
    timestamp_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    workspace          = [ordered]@{
        name              = $amwName
        resource_group    = $amwRg
        exists            = [bool]$amw
        provisioningState = if ($amw) { [string]$amw.Properties.provisioningState } else { '' }
        tags              = if ($amw) { $amw.Tags } else { @{} }
    }
    issue_contributors = @(foreach ($c in $contributors) {
            [ordered]@{ name = [string]$c.name; type = [string]$c.type; assigned = [bool]($ras | Where-Object ObjectId -EQ ([string]$c.object_id)) }
        })
    associations       = @(foreach ($k in $assoc.Keys) {
            $v = Get-Association $assoc[$k]
            [ordered]@{ subscription_key = $k; default_workspace = ($v -split '/')[-1]; matches = ($v -ieq $amwId) }
        })
}
$json = $readBack | ConvertTo-Json -Depth 10
if ($ReadBackPath) { $json | Set-Content -LiteralPath $ReadBackPath -Encoding utf8NoBOM }
$json | Write-Output
