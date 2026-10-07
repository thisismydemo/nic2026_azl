#Requires -Version 7.0
<#
.SYNOPSIS
    Applies or removes the Day-2 workload platform (outline §3.6): logical networks, marketplace images, storage paths,
    optional NSG. Default -WhatIf (what-if / plan only); -Execute changes Azure. Reversible for the live replay (D-014).
.DESCRIPTION
    Apply: Bicep what-if then create (or terraform plan/apply). Remove: Bicep cannot delete, so the Az remove block
    deletes images -> storage paths -> NSG -> logical networks in dependency order (idempotent: absent = nothing to do);
    Terraform uses plan -destroy / apply. Workload VOLUMES are not touched here (New-ClusterWorkloadVolume.ps1; removal
    is an owner data-loss action). A storage path must be empty (no VM disks / images) before it can be deleted.
.PARAMETER Action
    Apply | Remove
.PARAMETER Tool
    Bicep (demo path) | Terraform (parity; needs -BackendConfig)
.EXAMPLE
    .\Invoke-PlatformConfigure.ps1 -Action Apply                 # what-if only
    .\Invoke-PlatformConfigure.ps1 -Action Apply -Execute
    .\Invoke-PlatformConfigure.ps1 -Action Remove -Execute       # live replay: remove, then Apply again on stage
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Apply', 'Remove')][string]$Action,
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [string]$BackendConfig,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
$solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$removeWithAz = {
    param($inputs)
    $rg = "/subscriptions/$($inputs.subscription_id)/resourceGroups/$($inputs.names.rg_azl)/providers/Microsoft.AzureStackHCI"
    foreach ($img in @($inputs.marketplace_images)) {
        Remove-Day2ArmResource -ResourceId "$rg/marketplaceGalleryImages/$($inputs.names.("img_$($img.key)"))" -ApiVersion '2025-04-01-preview'
    }
    foreach ($sp in @($inputs.storage.storage_paths)) {
        Remove-Day2ArmResource -ResourceId "$rg/storageContainers/$($sp.name)" -ApiVersion '2025-02-01-preview'
    }
    if ($inputs.enable_network_security_group) {
        Remove-Day2ArmResource -ResourceId "$rg/networkSecurityGroups/$($inputs.names.nsg_azl_compute)" -ApiVersion '2025-02-01-preview'
    }
    foreach ($l in @($inputs.logical_networks)) {
        Remove-Day2ArmResource -ResourceId "$rg/logicalNetworks/$($l.name)" -ApiVersion '2024-10-01-preview'
    }
}

Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-platform' -Action $Action -Tool $Tool -DeploymentScope group -ResourceGroupKey rg_azl -BackendConfig $BackendConfig -RemoveWithAz $removeWithAz -Execute:$Execute
