#Requires -Version 7.0
<#
.SYNOPSIS
    Adds the required tags to every resource in the cluster resource group that lacks them (T-5.3.13): the Arc machines,
    their extensions, the Arc Resource Bridge, the custom location, the attestation provider, gallery images and anything
    else the cluster deployment or a later step created without tags.
.DESCRIPTION
    Merge only: a tag that already exists on a resource keeps its value (Bicep-deployed resources keep managed-by=bicep);
    only the missing keys are added. The tag set is the solution's 'tags' input (environment files: shared tags plus
    the Azure Local workload tag) plus managed-by (default 'script'). Resource groups whose managedBy property is set
    (managed resource groups) cannot be tagged by the caller and are reported, not changed. Default is a dry run that
    lists what would change; -Execute writes the tags and reads them back.
.PARAMETER InputFile
    terraform.generated.tfvars.json of cluster-deploy (subscription_id, tags, names.rg_azl).
.PARAMETER ManagedBy
    Value for the managed-by tag when a resource has none.
.PARAMETER ExcludeResourceType
    Types left alone. On Azure Local a tag write on a VM's disk or NIC is a full update that the node agent applies
    (12 Oct: a tag merge on two SOFS data disks surfaced VHDNotFound and left them provisioningState Failed), and the
    node extensions are re-tagged by Azure; the workload tracks tag those resources when they create them. The node
    extensions were tagged once on 12 Oct; pass -ExcludeResourceType @() to include everything again.
.PARAMETER Execute
    Apply the merge. Without it nothing changes.
.EXAMPLE
    .\Set-ClusterResourceTags.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json            # dry run
    .\Set-ClusterResourceTags.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -Execute   # merge + read back
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$ManagedBy = 'script',
    [string[]]$ExcludeResourceType = @('Microsoft.AzureStackHCI/virtualHardDisks', 'Microsoft.AzureStackHCI/networkInterfaces', 'Microsoft.HybridCompute/machines/extensions'),
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { $WhatIfPreference = $true }
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')

[void](Import-ClusterDeployAutomationModule)
$inputs = Get-ClusterDeployInputs -InputFile $InputFile
Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
$rg = [string]$inputs.names.rg_azl

$required = [ordered]@{}
foreach ($p in $inputs.tags.PSObject.Properties) { $required[$p.Name] = [string]$p.Value }
if (-not $required.Contains('managed-by')) { $required['managed-by'] = $ManagedBy }
foreach ($key in 'project', 'environment', 'workload') {
    if (-not $required.Contains($key)) { throw "Input tags are missing '$key' (environment files: tags.$key)." }
}

$results = [System.Collections.Generic.List[object]]::new()
# Resources being deleted refuse tag writes (InvalidResourceOperation); they are reported, not retried.
$resources = @(Get-AzResource -ResourceGroupName $rg -ExpandProperties | Where-Object { -not ($_.Properties -and $_.Properties.PSObject.Properties.Name -contains 'provisioningState' -and $_.Properties.provisioningState -eq 'Deleting') } |
        Where-Object { $type = $_.ResourceType; -not ($ExcludeResourceType | Where-Object { $_ -ieq $type }) })
foreach ($r in $resources) {
    # Azure tag names are case-insensitive (a 'Project' tag satisfies 'project'), so compare without case.
    $current = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
    if ($r.Tags) { foreach ($k in $r.Tags.Keys) { $current[$k] = $r.Tags[$k] } }
    $missing = @{}
    foreach ($k in $required.Keys) { if (-not $current.ContainsKey($k)) { $missing[$k] = $required[$k] } }
    $state = if ($missing.Count -eq 0) { 'compliant' } elseif ($Execute) { 'merged' } else { 'would merge' }
    if ($missing.Count -gt 0 -and $Execute -and $PSCmdlet.ShouldProcess($r.ResourceId, "merge tags $(@($missing.Keys) -join ',')")) {
        try { [void](Update-AzTag -ResourceId $r.ResourceId -Tag $missing -Operation Merge -WhatIf:$false) }
        catch { $state = "failed: $($_.Exception.Message)" }
    }
    $results.Add([pscustomobject]@{ name = $r.Name; type = $r.ResourceType; state = $state; added = (@($missing.Keys | Sort-Object) -join ',') })
}

# Managed resource groups (managedBy set) are owned by a resource provider; tags there are not ours to write.
$managed = @(Get-AzResourceGroup | Where-Object { $_.PSObject.Properties.Name -contains 'ManagedBy' -and $_.ManagedBy -and $_.ManagedBy -like "*/resourceGroups/$rg/*" })
foreach ($m in $managed) { $results.Add([pscustomobject]@{ name = $m.ResourceGroupName; type = 'managed resource group'; state = 'skipped (managedBy set)'; added = '' }) }

if ($Execute) {
    # Read back: every resource must now carry every required key.
    foreach ($row in @($results | Where-Object { $_.state -eq 'merged' })) {
        $res = $resources | Where-Object { $_.Name -eq $row.name -and $_.ResourceType -eq $row.type } | Select-Object -First 1
        $tags = [hashtable]::new([StringComparer]::OrdinalIgnoreCase)
        $read = (Get-AzTag -ResourceId $res.ResourceId).Properties.TagsProperty
        if ($read) { foreach ($k in $read.Keys) { $tags[$k] = $read[$k] } }
        $gap = @($required.Keys | Where-Object { -not $tags.ContainsKey($_) })
        $row.state = if ($gap.Count -eq 0) { 'merged (read back ok)' } else { "merged, read back missing $($gap -join ',')" }
    }
}
$results | Sort-Object type, name | Format-Table -AutoSize | Out-String -Width 220 | Write-Information -InformationAction Continue
$bad = @($results | Where-Object { $_.state -like 'failed*' -or $_.state -like '*missing*' })
Write-ClusterDeployLog -Message "tags: $(@($results).Count) item(s); compliant=$(@($results | Where-Object state -EQ 'compliant').Count); changed=$(@($results | Where-Object state -Like 'merged*').Count); problems=$($bad.Count)"
return $results
