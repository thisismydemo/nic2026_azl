#Requires -Version 7.0
<#
.SYNOPSIS
    Toggles Defender for Servers on the landing-zone subscription (outline §3.5, design §7.3). Apply = the configured
    plan (defender_servers_plan, P2); Remove = Free. Default -WhatIf; -Execute changes the subscription. Reversible.
.DESCRIPTION
    Bicep: the same template is deployed with the parameter override defender_servers_plan=off for Remove (ARM cannot
    delete a pricing; "off" IS the remove). Terraform: apply / destroy (destroy resets the plan to Free).
.EXAMPLE
    .\Set-DefenderServersPlan.ps1 -Action Apply -Execute
    .\Set-DefenderServersPlan.ps1 -Action Remove -Execute
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

if ($Tool -eq 'Bicep' -and $Action -eq 'Remove') {
    # Remove = redeploy with the plan off (what-if first, create with -Execute) — handled as an Apply with an override.
    Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-defender' -Action Apply -Tool Bicep -DeploymentScope sub -ExtraBicepParameters @{ defender_servers_plan = 'off' } -Execute:$Execute
    return
}
Invoke-Day2Solution -SolutionRoot $solutionRoot -SolutionName 'cluster-configure-defender' -Action $Action -Tool $Tool -DeploymentScope sub -BackendConfig $BackendConfig -Execute:$Execute
