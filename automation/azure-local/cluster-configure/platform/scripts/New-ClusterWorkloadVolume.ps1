#Requires -Version 7.0
<#
.SYNOPSIS
    Creates the workload Cluster Shared Volumes from storage.volumes[] on the cluster (outline §2.6 "create the workload
    volumes"; build runbook 3.8). There is no ARM surface for S2D volumes, so this runs New-Volume over WinRM from the
    jump server. Default -WhatIf; -Execute creates. Never deletes a volume.
.DESCRIPTION
    Credential: identity.local_admin_*_secret references resolved in memory (ops vault, operator sign-in, Windows jump
    server). Idempotent: an existing volume with the same friendly name is reported and skipped. Resiliency map:
    two-way-mirror -> Mirror / 2 copies; three-way-mirror -> Mirror / 3; nested-two-way-mirror -> Mirror with the
    NestedMirror template (2-node only). ReFS, CSVFS, thin provisioning (ProvisioningType Thin, 2306+).
.PARAMETER InputFile
    terraform.generated.tfvars.json of this solution (or the example for a dry run).
.EXAMPLE
    .\New-ClusterWorkloadVolume.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json
    .\New-ClusterWorkloadVolume.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1')
if (-not $Execute) { $WhatIfPreference = $true }
if (-not $IsWindows) { throw 'Refusing: credentials are handled here; run on the Windows jump server (contract §7, K-8).' }

[void](Import-Day2AutomationModule)
$inputs = Get-Day2Inputs -SolutionRoot (Join-Path $PSScriptRoot '..') -InputFile $InputFile
$volumes = @($inputs.storage.volumes)
if ($volumes.Count -eq 0) { Write-Day2Log -Message 'storage.volumes is empty; nothing to do.'; return }

$user = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_username_secret -AsPlainText
$pass = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_password_secret
$cred = [pscredential]::new($user, $pass)
$session = New-PSSession -ComputerName ([string]$inputs.nodes[0].management_ip) -Credential $cred -Authentication Negotiate
Remove-Variable -Name user, pass, cred -ErrorAction SilentlyContinue

try {
    $existing = @(Invoke-Command -Session $session -ScriptBlock { Get-VirtualDisk | Select-Object -ExpandProperty FriendlyName })
    $pool = Invoke-Command -Session $session -ScriptBlock { (Get-StoragePool -IsPrimordial $false | Select-Object -First 1).FriendlyName }
    $plan = foreach ($v in $volumes) {
        [pscustomobject]@{ Volume = $v.name; Resiliency = $v.resiliency; SizeGB = $v.size_gb; Pool = $pool; Exists = ($existing -contains $v.name); Action = if ($existing -contains $v.name) { 'keep' } else { 'create' } }
    }
    $plan | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    $pending = @($plan | Where-Object { $_.Action -eq 'create' })
    if ($pending.Count -eq 0) { Write-Day2Log -Message 'All volumes exist.'; return $plan }
    if (-not $Execute) { Write-Warning "WhatIf (default): $($pending.Count) volume(s) would be created. Re-run with -Execute."; return $plan }

    foreach ($p in $pending) {
        if ($PSCmdlet.ShouldProcess("$($p.Volume) ($($p.Resiliency), $($p.SizeGB) GB) on pool $($p.Pool)", 'New-Volume')) {
            Invoke-Command -Session $session -ArgumentList $p.Volume, $p.Resiliency, $p.SizeGB, $p.Pool -ScriptBlock {
                param($name, $resiliency, $sizeGb, $poolName)
                $common = @{ FriendlyName = $name; StoragePoolFriendlyName = $poolName; FileSystem = 'CSVFS_ReFS'; Size = ([int64]$sizeGb * 1GB); ProvisioningType = 'Thin' }
                switch ($resiliency) {
                    'two-way-mirror' { New-Volume @common -ResiliencySettingName Mirror -NumberOfDataCopies 2 }
                    'three-way-mirror' { New-Volume @common -ResiliencySettingName Mirror -NumberOfDataCopies 3 }
                    'nested-two-way-mirror' { New-Volume @common -StorageTierFriendlyNames NestedMirror -StorageTierSizes ([int64]$sizeGb * 1GB) }
                    default { throw "Unknown resiliency '$resiliency'" }
                }
            } | Select-Object FriendlyName, Size, HealthStatus | Out-String | Write-Information -InformationAction Continue
        }
    }
    return $plan
}
finally {
    if ($session) { Remove-PSSession -Session $session }
}
