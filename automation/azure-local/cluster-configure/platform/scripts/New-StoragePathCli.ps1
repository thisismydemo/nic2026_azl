#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the Azure Local storage paths from environment.yml (storage.storage_paths) with az stack-hci-vm (Azure
    PowerShell out of scope; CLI uses an allowed API version). storage-design.md section 6.
.DESCRIPTION
    Each folder must already exist on its CSV (a missing folder leaves a failed, immutable storage path - known
    issue); New-ClusterWorkloadVolume.ps1 plus the folder step create them. Idempotent: existing Succeeded paths are kept.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\shared\environment.yml'),
    [string]$SubscriptionId,
    [string]$ResourceGroupName,
    [string]$CustomLocationName,
    [string]$Location
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
$azExe = (Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
# Lab values come only from environment/** (plan rule G5); parameters override.
if (-not $SubscriptionId) { $SubscriptionId = [string]$envy.subscription_id }
if (-not $ResourceGroupName) { $ResourceGroupName = [string]$envy.vm_management.resource_group }
if (-not $CustomLocationName) { $CustomLocationName = [string]$envy.vm_management.custom_location }
if (-not $Location) { $Location = [string](Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml).location }
$cl = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.ExtendedLocation/customLocations/$CustomLocationName"
foreach ($sp in $envy.storage.storage_paths) {
    $state = & $azExe stack-hci-vm storagepath show -g $ResourceGroupName --name $sp.name --subscription $SubscriptionId --query properties.provisioningState -o tsv --only-show-errors 2>$null
    if ($state -eq 'Succeeded') { "$($sp.name): exists"; continue }
    if ($PSCmdlet.ShouldProcess($sp.name, "Create storage path $($sp.path)")) {
        $out = & $azExe stack-hci-vm storagepath create -g $ResourceGroupName --custom-location $cl --location $Location --name $sp.name --path $sp.path --subscription $SubscriptionId --only-show-errors 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "$($sp.name): $(($out -replace '\s+', ' ').Trim())" }
        # stack-hci-vm storagepath create --tags fails client-side (extension serializer bug, 12 Oct 2026): tag with az tag update
        $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/storageContainers/$($sp.name)"
        $null = & $azExe tag update --resource-id $id --operation Merge --tags project=nic26 environment=demo workload=azure-local "volume=$($sp.volume)" --only-show-errors 2>&1
        "$($sp.name): created ($($sp.path)), tagged"
    }
}
