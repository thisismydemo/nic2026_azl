<#
.SYNOPSIS
    Deploys the nic26-clus01 logical networks and NSGs (network-design §4.6, D-048) in the order Microsoft documents.
.DESCRIPTION
    Learn (Create network security groups, prerequisites): a static logical network (and a static NIC) exists before
    NSGs are created. So the deployment runs in two passes:
      1. logical networks only (bicep/networks-only.generated.bicepparam: no NSGs);
      2. NSGs and their rules, then the same logical networks again with the NSG attached (bicep/main.generated.bicepparam).
    Default: what-if of both passes. -Execute deploys (incremental; never deletes). Run only after SDN enabled by Arc
    finished and more than 5 minutes have passed (known issue on this release). API 2026-04-01-preview (allowed on this release).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$TenantId,
    [ValidateSet('All', 'Networks', 'Nsgs')][string]$Pass = 'All',
    [switch]$Execute
)
$ErrorActionPreference = 'Stop'
$null = Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -WarningAction SilentlyContinue
$bicepRoot = Join-Path $PSScriptRoot '..\bicep'
$passes = [ordered]@{ Networks = 'networks-only.generated.bicepparam'; Nsgs = 'main.generated.bicepparam' }
foreach ($p in $passes.Keys) {
    if ($Pass -ne 'All' -and $Pass -ne $p) { continue }
    $name = "dep-iic-nic26-azl-sdn-$($p.ToLower())-" + (Get-Date -Format 'yyyyMMddHHmm')
    $common = @{ ResourceGroupName = $ResourceGroupName; TemplateFile = (Join-Path $bicepRoot 'main.bicep'); TemplateParameterFile = (Join-Path $bicepRoot $passes[$p]) }
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
