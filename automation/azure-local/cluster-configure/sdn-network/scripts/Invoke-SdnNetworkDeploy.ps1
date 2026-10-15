<#
.SYNOPSIS
    Deploys the logical networks and NSGs (network-design section 4.6) with Bicep, in the order Microsoft documents, from the environment file.
.DESCRIPTION
    Learn (Create network security groups, prerequisites): a static logical network (and a static NIC) exists before
    NSGs are created. So the deployment runs in two passes:
      1. logical networks only (deploy_network_security_groups = false);
      2. NSGs and their rules, then the same logical networks again with the NSG attached.
    Both parameter files are generated on every run from the environment file (sdn, logical_networks,
    network_security_groups, tags, location, vm_management) with ConvertTo-NIC26BicepParam and the solution manifest
    (../solution.yml); nothing is typed into a parameter file. Deployment names come from New-NIC26ResourceName -Type dep.
    Default: what-if of both passes. -Execute deploys (incremental; never deletes). Run only after SDN enabled by Arc
    finished and more than 5 minutes have passed (known issue on this release). API 2026-04-01-preview.
.PARAMETER EnvironmentPath
    Environment folder for Get-NIC26Config (default: <repo>\environment\azure-local).
.PARAMETER ResourceGroupName
    Optional override of vm_management.resource_group.
.PARAMETER SubscriptionId
    Optional override of subscription_id.
.PARAMETER TenantId
    Optional override of tenant_id.
.PARAMETER Pass
    All (default), Networks (pass 1) or Nsgs (pass 2).
.PARAMETER Execute
    Deploy. Without it only the what-if runs.
#>
[CmdletBinding()]
param(
    [string]$EnvironmentPath,
    [string]$ResourceGroupName,
    [string]$SubscriptionId,
    [string]$TenantId,
    [ValidateSet('All', 'Networks', 'Nsgs')][string]$Pass = 'All',
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$config = Get-NIC26Config @cfgArgs
$values = $config.values
if (-not $SubscriptionId) { $SubscriptionId = [string]$values.subscription_id }
if (-not $TenantId) { $TenantId = [string]$values.tenant_id }
if (-not $ResourceGroupName) { $ResourceGroupName = [string]$values.vm_management.resource_group }
$context = Get-NIC26NamingContext -Config $config

$solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$bicepRoot = Join-Path $solutionRoot 'bicep'
# Generated parameter files (never published, never edited by hand): pass 1 = networks only, pass 2 = NSGs + attachment.
$mainFile = Join-Path $bicepRoot 'main.generated.bicepparam'
$networksFile = Join-Path $bicepRoot 'networks-only.generated.bicepparam'
$text = ConvertTo-NIC26BicepParam -Solution $solutionRoot -Config $config
Set-Content -LiteralPath $mainFile -Value $text -NoNewline
Set-Content -LiteralPath $networksFile -Value ($text.TrimEnd() + "`nparam deploy_network_security_groups = false`n") -NoNewline

$null = Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -WarningAction SilentlyContinue -WhatIf:$false
$passes = [ordered]@{ Networks = $networksFile; Nsgs = $mainFile }
foreach ($p in $passes.Keys) {
    if ($Pass -ne 'All' -and $Pass -ne $p) { continue }
    $name = (New-NIC26ResourceName -Type dep -Purpose "azl-sdn-$($p.ToLowerInvariant())" -Org $context.Org -Token $context.Token) + '-' + (Get-Date -Format 'yyyyMMddHHmm')
    $common = @{ ResourceGroupName = $ResourceGroupName; TemplateFile = (Join-Path $bicepRoot 'main.bicep'); TemplateParameterFile = $passes[$p] }
    if (-not $Execute) {
        "What-if pass $p ($name):"
        (Get-AzResourceGroupDeploymentWhatIfResult @common -WarningAction SilentlyContinue).Changes | Where-Object ChangeType -NotIn 'Ignore', 'NoChange' |
            ForEach-Object { "  {0,-8} {1}" -f $_.ChangeType, (([string]$_.FullyQualifiedResourceId) -replace '^.*/providers/', '') }
        continue
    }
    $d = New-AzResourceGroupDeployment @common -Name $name -WarningAction SilentlyContinue
    "Pass $p - deployment $name : $($d.ProvisioningState)"
}
if (-not $Execute) { 'What-if only. Add -Execute to deploy.' }
