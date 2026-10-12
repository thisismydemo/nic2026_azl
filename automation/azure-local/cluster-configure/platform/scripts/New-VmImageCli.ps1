#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the Azure Local VM images listed in environment/azure-local/environment.yml (vm_images) with az stack-hci-vm,
    each on its storage path, and merges the standard tags after create. storage-design.md section 6; plan T-5.4.1.
.DESCRIPTION
    Source 'marketplace': publisher/offer/sku/version from the Azure Marketplace (Learn: Create Azure Local VM image using
    Azure Marketplace images). Source 'vhd': image_path is a local cluster path or a SAS URL to a VHD(X) (used for the AVD
    image exported from the Azure Compute Gallery, T-6.1.4).
    Idempotent: an image that is Succeeded is kept (tags merged again); one still provisioning is reported (with -Wait the
    script polls it); a Failed image is reported and left for an operator decision unless -RecreateFailed is given.
    Tags: az stack-hci-vm image create --tags and image update both fail on this build (extension serializer bug), so tags
    are merged with az tag update on the resource ID. Azure PowerShell is out of scope for Azure Local VM resources here.
    Values come only from environment/shared/environment.yml and environment/azure-local/environment.yml (plan rule G5).
.PARAMETER Name
    Limit the run to these image names (default: every vm_images entry).
.PARAMETER Wait
    Poll each image until Succeeded or Failed (download of a marketplace image takes 15 to 90 minutes).
.EXAMPLE
    .\New-VmImageCli.ps1 -WhatIf
    .\New-VmImageCli.ps1 -Wait -LogFile .\image.log
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute or -WhatIf); they never run on their own.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$EnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\azure-local\environment.yml'),
    [string]$SharedEnvironmentFile = (Join-Path $PSScriptRoot '..\..\..\..\..\environment\shared\environment.yml'),
    [string[]]$Name,
    [switch]$Wait,
    [ValidateRange(5, 240)][int]$TimeoutMinutes = 120,
    [switch]$RecreateFailed,
    [string]$LogFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
$azExe = (Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $azExe) { throw 'Azure CLI (az) not found.' }
$envy = Get-Content -LiteralPath $EnvironmentFile -Raw | ConvertFrom-Yaml
$shared = Get-Content -LiteralPath $SharedEnvironmentFile -Raw | ConvertFrom-Yaml
$sub = [string]$envy.subscription_id
$rg = [string]$envy.vm_management.resource_group
$location = [string]$shared.location
$cl = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.ExtendedLocation/customLocations/$($envy.vm_management.custom_location)"
$hci = "/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.AzureStackHCI"

function L([string]$m) { $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"; $line; if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $line } }
function Invoke-ImgAz([string[]]$a) {
    $out = & $azExe @a --subscription $sub --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw ($out -replace '\s+', ' ').Trim() }
    return $out
}
function Get-ImageState([string]$type, [string]$n) {
    $j = & $azExe resource show --ids "$hci/$type/$n" --subscription $sub --only-show-errors -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $j) { return $null }
    $p = ($j | ConvertFrom-Json).properties
    [pscustomobject]@{
        State    = [string]$p.provisioningState
        Status   = [string]$p.status.provisioningStatus.status
        Progress = $p.status.progressPercentage
        Error    = [string]$p.status.errorMessage
        SizeMb   = $p.status.downloadStatus.downloadSizeInMb
    }
}
function Set-ImageTag([string]$id, [string]$workload) {
    $t = @()
    foreach ($k in $shared.tags.Keys) { $t += "$k=$($shared.tags[$k])" }
    $t += "workload=$workload", 'managed-by=script'
    $null = Invoke-ImgAz (@('tag', 'update', '--resource-id', $id, '--operation', 'Merge', '--tags') + $t)
}

$images = @($envy.vm_images)
if ($Name) { $images = @($images | Where-Object { $Name -contains $_.name }) }
foreach ($img in $images) {
    # Marketplace images are marketplaceGalleryImages; VHD images are galleryImages.
    $type = if ($img.source -eq 'marketplace') { 'marketplaceGalleryImages' } else { 'galleryImages' }
    $id = "$hci/$type/$($img.name)"
    $workload = if ($img.ContainsKey('workload')) { [string]$img.workload } else { 'azure-local' }
    $s = Get-ImageState $type $img.name
    if ($s -and $s.State -eq 'Failed') {
        if (-not $RecreateFailed) { L "$($img.name): Failed ($($s.Error)) - rerun with -RecreateFailed to delete and create again"; continue }
        if ($PSCmdlet.ShouldProcess($img.name, 'Delete failed image')) { $null = Invoke-ImgAz @('stack-hci-vm', 'image', 'delete', '-g', $rg, '--name', $img.name, '--yes'); $s = $null }
    }
    if (-not $s -and $img.source -eq 'gallery-version') {
        # Azure Compute Gallery version -> temporary managed disk -> SAS -> image create (avd/images/azure-local).
        $tagTable = @{}; foreach ($k in $shared.tags.Keys) { $tagTable[$k] = [string]$shared.tags[$k] }
        $tagTable['workload'] = $workload; $tagTable['managed-by'] = 'script'
        $import = Join-Path $PSScriptRoot '..\..\..\..\avd\images\azure-local\scripts\Import-AzureLocalImage.ps1'
        $galSub = ([string]$img.gallery_image_version_id -split '/')[2]
        if ($PSCmdlet.ShouldProcess($img.name, "Import gallery version $($img.gallery_image_version_id) on $($img.storage_path)")) {
            L "$($img.name): importing gallery version (temporary disk $($img.temp_disk_name) in $($img.temp_disk_resource_group))"
            $res = & $import -AvdSubscriptionId $galSub -AzlSubscriptionId $sub -GalleryImageVersionId $img.gallery_image_version_id `
                -ImageName $img.name -CustomLocationId $cl -ImageResourceGroup $rg -Location $location `
                -TempDiskResourceGroup $img.temp_disk_resource_group -TempDiskName $img.temp_disk_name `
                -StoragePathId "$hci/storageContainers/$($img.storage_path)" -SasDurationSeconds 14400 -Tags $tagTable -SecurityType $(if ($img.ContainsKey('security_type')) { [string]$img.security_type } else { '' }) -Execute -Confirm:$false
            L "$($img.name): import returned $res"
        }
        continue
    }
    if (-not $s) {
        $spId = "$hci/storageContainers/$($img.storage_path)"
        $a = @('stack-hci-vm', 'image', 'create', '-g', $rg, '--custom-location', $cl, '--location', $location, '--name', $img.name,
            '--os-type', $img.os_type, '--storage-path-id', $spId)
        if ($img.source -eq 'marketplace') {
            $a += '--publisher', $img.publisher, '--offer', $img.offer, '--sku', $img.sku
            if ($img.ContainsKey('version') -and $img.version -and $img.version -ne 'latest') { $a += '--version', [string]$img.version }
        }
        else {
            $a += '--image-path', $img.image_path
        }
        if ($PSCmdlet.ShouldProcess($img.name, "Create image ($($img.source)) on $($img.storage_path)")) {
            L "$($img.name): creating from $($img.source) on $($img.storage_path)"
            # The create call returns when ARM accepts the PUT or when the download finishes (CLI long-running op).
            try { $null = Invoke-ImgAz $a } catch { L "$($img.name): create returned an error: $($_.Exception.Message)" }
        }
        else { continue }
    }
    else {
        L "$($img.name): exists ($($s.State), status $($s.Status), $($s.Progress) %)"
    }
    if ($Wait) {
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        do {
            $s = Get-ImageState $type $img.name
            if (-not $s) { L "$($img.name): not found after create"; break }
            L "$($img.name): $($s.State) / $($s.Status) / $($s.Progress) %"
            if ($s.State -in 'Succeeded', 'Failed') { break }
            Start-Sleep -Seconds 60
        } while ((Get-Date) -lt $deadline)
        if ($s -and $s.State -ne 'Succeeded') { L "$($img.name): not Succeeded within $TimeoutMinutes min ($($s.State) $($s.Error))" }
    }
    if ((Get-ImageState $type $img.name) -and $PSCmdlet.ShouldProcess($img.name, 'Merge tags')) {
        try { Set-ImageTag $id $workload; L "$($img.name): tags merged" }
        catch { L "$($img.name): tag merge failed (rerun after provisioning ends): $($_.Exception.Message)" }
    }
}
exit 0
