#Requires -Version 7.0
<#
.SYNOPSIS
    Builds (and optionally executes) the ordered teardown plan of the Azure Local landing zone, S9..S1 (design §10.4).
.DESCRIPTION
    Default is -WhatIf: prints and writes the ordered plan, deletes nothing. -Execute performs the steps with ShouldProcess.
    Order (design §10.4): S7 management -> S6 BC/DR (vault must hold no protected or replicated items) -> S5 witness
    (only when no cluster exists in the cluster resource group; CanNotDelete lock removed first) -> S4 monitoring ->
    S3 ops vault deleted AND purged, cluster vault deleted (purge after the 7-day retention; security resource group
    stays until then unless -IncludeSecurityResourceGroup) -> S2 remote peerings on the hub/identity/management VNets
    removed only when deploy_platform_scope_items is boolean true; otherwise preserved. Then the network resource group -> S1 ownership-gated policy assignments, budget, remaining resource groups.
    Never touches: hub VNet beyond its peering, VPN gateway, P2S, DCs, Bastion, platform vaults, management group.
    Every deletion inside the subscription is checked against the subscription prefix; the ONLY cross-subscription
    deletions are the remote-side peering resources whose IDs are built from the input VNet IDs plus the catalog names.
.PARAMETER Config
    Canonical config object (Get-NIC26Config -Scope azure-local): subscription_id, names, hub_vnet_id, identity_spoke_vnet_id, management_spoke_vnet_id, flags.
.PARAMETER PlanPath
    Where to write the plan JSON (default teardown-plan.generated.json next to the solution).
.PARAMETER Execute
    Perform the deletions.
.PARAMETER IncludeSecurityResourceGroup
    Also delete the security resource group (only after the cluster vault's retention has passed or with the next-instance plan).
.EXAMPLE
    ./New-LzTeardownPlan.ps1 -Config (Get-NIC26Config -Scope azure-local)
    ./New-LzTeardownPlan.ps1 -Config $cfg -Execute
.NOTES
    Author: Kristopher Turner
    Contact: kris@hybridsolutions.cloud
    Version: 1.2.0
    Requires Az.Accounts, Az.Resources, Az.Network, Az.KeyVault, Az.RecoveryServices. Rotate copied credentials in their
    source systems at lab close (keyvault-and-secrets.md §6) - a manual step listed in the plan.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)] [object] $Config,
    [string] $PlanPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'teardown-plan.generated.json'),
    [switch] $Execute,
    [switch] $IncludeSecurityResourceGroup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sub = [string] $Config.subscription_id
if ($sub -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Config.subscription_id is not a GUID.' }
$subPrefix = "/subscriptions/$sub/"
$n = $Config.names

function Test-LzConfigKey {
    # Config is an OrderedDictionary from Get-NIC26Config or a PSCustomObject from JSON (tests); support both.
    param([object] $Object, [string] $Key)
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) }
    return $null -ne $Object.PSObject.Properties[$Key]
}

function ConvertTo-LzStep {
    param([string] $Stage, [string] $Action, [string] $Target, [string] $Note = '', [bool] $CrossSubscription = $false, [string] $Manual = '')
    [pscustomobject]@{ Stage = $Stage; Action = $Action; Target = $Target; Note = $Note; CrossSubscription = $CrossSubscription; Manual = $Manual; Status = 'planned' }
}

function Get-LzArmCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidatePattern('^/subscriptions/')][string] $CollectionPath)
    $first = [uri]('https://management.azure.com' + $CollectionPath)
    $next = $first
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()
    while ($null -ne $next) {
        if ($next.Scheme -ne 'https' -or $next.Host -ne 'management.azure.com' -or
            $next.Port -ne 443 -or $next.UserInfo -or $next.Fragment -or
            -not $next.AbsolutePath.Equals($first.AbsolutePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Protection inventory continuation leaves the authorized ARM collection.'
        }
        if (-not $seen.Add($next.AbsoluteUri)) { throw 'Protection inventory pagination cycle.' }
        $response = Invoke-AzRestMethod -Method GET -Path $next.PathAndQuery -ErrorAction Stop
        if ([int]$response.StatusCode -ne 200) { throw "Protection inventory returned HTTP $($response.StatusCode)." }
        $body = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($body -isnot [System.Collections.IDictionary] -or -not $body.Contains('value') -or $body['value'] -isnot [array]) {
            throw 'Protection inventory response is not a collection.'
        }
        foreach ($item in $body['value']) {
            if ($null -eq $item) { throw 'Protection inventory contains a null record.' }
            $items.Add($item)
        }
        $next = $null
        if ($body.Contains('nextLink') -and -not [string]::IsNullOrWhiteSpace([string]$body['nextLink'])) {
            $next = [uri]$body['nextLink']
            if (-not $next.IsAbsoluteUri) { throw 'Protection inventory continuation is not an absolute URI.' }
        }
    }
    return ,$items.ToArray()
}

function Assert-LzVaultUnprotected {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $VaultId)
    # Vault-wide endpoints include all backup workloads and all ASR fabrics/containers.
    $backup = Get-LzArmCollection -CollectionPath "$VaultId/backupProtectedItems?api-version=2025-08-01"
    if ($backup.Count -gt 0) { throw "Vault still holds $($backup.Count) backup item(s); stop." }
    $replication = Get-LzArmCollection -CollectionPath "$VaultId/replicationProtectedItems?api-version=2025-08-01"
    if ($replication.Count -gt 0) { throw "Vault still holds $($replication.Count) replication item(s); stop." }
}

function Assert-LzClusterAbsent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ResourceGroupName)
    $clusters = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.AzureStackHCI/clusters' -ErrorAction Stop)
    if ($clusters.Count -gt 0) { throw 'An Azure Local cluster still exists; stop.' }
}

function Test-LzArmResourcePresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^/subscriptions/')][string] $ResourceId,
        [Parameter(Mandatory)][string] $ApiVersion
    )
    $response = Invoke-AzRestMethod -Method GET -Path "$($ResourceId)?api-version=$ApiVersion" -ErrorAction Stop
    $body = $response.Content | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ([int]$response.StatusCode -eq 200) {
        if ($body -isnot [System.Collections.IDictionary] -or -not $body.Contains('id') -or
            -not ([string]$body['id']).Equals($ResourceId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Resource presence response does not identify the expected resource.'
        }
        return $true
    }
    if ([int]$response.StatusCode -eq 404 -and $body -is [System.Collections.IDictionary] -and
        $body.Contains('error') -and $body['error'] -is [System.Collections.IDictionary] -and
        $body['error'].Contains('code') -and $body['error']['code'] -in @('ResourceNotFound', 'ResourceGroupNotFound')) {
        return $false
    }
    throw "Resource presence read returned HTTP $($response.StatusCode); absence not proven."
}

function Get-LzTeardownPlan {
    [CmdletBinding()]
    param([object] $Config, [switch] $IncludeSecurityResourceGroup)
    $ownsPlatformItems = $false
    if (Test-LzConfigKey $Config 'deploy_platform_scope_items') {
        if ($Config.deploy_platform_scope_items -isnot [bool]) {
            throw 'Config.deploy_platform_scope_items must be a boolean.'
        }
        $ownsPlatformItems = $Config.deploy_platform_scope_items
    }
    $peeringAction = $ownsPlatformItems ? 'delete-peering' : 'keep'
    $policyAction = $ownsPlatformItems ? 'delete-policy-assignments' : 'keep'
    $identityNote = $ownsPlatformItems ?
        'Remove template-owned groups/PIM and initiative with their dedicated tooling.' :
        'Remove workload-owned groups/PIM with their dedicated tooling; preserve the platform-owned management-group initiative.'
    $rg = { param($k) "$subPrefix" + "resourceGroups/$($n.$k)" }
    $steps = @(
        ConvertTo-LzStep 'S9' 'manual'  'Test-LandingZone.ps1' 'Run once more and keep the report before teardown.' -Manual 'yes'
        ConvertTo-LzStep 'S8' 'manual'  'copied credentials' 'Rotate every COPIED credential in its source system (keyvault-and-secrets.md §6); delete the Entra device object of the jump server.' -Manual 'yes'
        ConvertTo-LzStep 'S7' 'delete-rg' (& $rg 'rg_mgmt') 'Jump server, NIC, disks.'
        ConvertTo-LzStep 'S6' 'check'    "$(& $rg 'rg_bcdr')/providers/Microsoft.RecoveryServices/vaults/$($n.rsv_azl)" 'Vault must hold no protected items and no replicated items (Day-2 removes them first).'
        ConvertTo-LzStep 'S6' 'delete-rg' (& $rg 'rg_bcdr') 'Recovery Services vault and ASR cache storage.'
        ConvertTo-LzStep 'S5' 'check'    (& $rg 'rg_azl') 'No Microsoft.AzureStackHCI/clusters may exist: the witness is deleted only after the cluster is gone.'
        ConvertTo-LzStep 'S5' 'remove-locks' "$(& $rg 'rg_azl')/providers/Microsoft.Storage/storageAccounts/$($n.st_witness)" 'The deployment places a CanNotDelete lock on the witness.'
        ConvertTo-LzStep 'S5' 'delete-rg' (& $rg 'rg_azl') 'Witness (and voucher) storage; cluster-owned resources must already be gone.'
        ConvertTo-LzStep 'S4' 'delete-rg' (& $rg 'rg_mon') 'Workspace, action group, DCE.'
        ConvertTo-LzStep 'S3' 'delete-kv-purge' $n.kv_ops 'Ops vault: delete and purge (purge protection off, K-5).'
        ConvertTo-LzStep 'S3' 'delete-kv' $n.kv_azl 'Cluster vault: delete only; purge after the 7-day retention or use instance 02 (K-5).'
        ConvertTo-LzStep 'S3' ($IncludeSecurityResourceGroup ? 'delete-rg' : 'keep') (& $rg 'rg_sec') 'Security resource group stays until the cluster vault can be purged (design §10.4).'
        ConvertTo-LzStep 'S2' $peeringAction "$($Config.hub_vnet_id)/virtualNetworkPeerings/$($n.peer_hub_to_spoke)" 'Platform hub peering stays unless this configuration owns platform-scope delivery.' -CrossSubscription $true
    )
    if ((Test-LzConfigKey $Config 'enable_identity_peering') -and [bool]$Config.enable_identity_peering) {
        $steps += ConvertTo-LzStep 'S2' $peeringAction "$($Config.identity_spoke_vnet_id)/virtualNetworkPeerings/$($n.peer_identity_to_spoke)" 'Platform identity peering follows the ownership gate.' -CrossSubscription $true
    }
    if ((Test-LzConfigKey $Config 'enable_management_peering') -and [bool]$Config.enable_management_peering) {
        $steps += ConvertTo-LzStep 'S2' $peeringAction "$($Config.management_spoke_vnet_id)/virtualNetworkPeerings/$($n.peer_mgmt_to_spoke)" 'Platform management peering follows the ownership gate.' -CrossSubscription $true
    }
    $steps += @(
        ConvertTo-LzStep 'S2' 'delete-rg' (& $rg 'rg_net') 'VNet, NSGs, route table, own private DNS zones and their links (links on the identity/AVD VNets are children of our zone). A REUSED shared zone is never deleted.'
        ConvertTo-LzStep 'S1' $policyAction "$subPrefix" "Ownership-gated assignments named $($n.asg_allowed_locations), $($n.asg_require_tags_rg)-*, $($n.asg_inherit_tags)-*, $($n.asg_activity_log)."
        ConvertTo-LzStep 'S1' 'delete-budget' "${subPrefix}providers/Microsoft.Consumption/budgets/$($n.budget_azl)" ''
        ConvertTo-LzStep 'S1' 'delete-rg' (& $rg 'rg_dr') 'Must be empty (failback done).'
        ConvertTo-LzStep 'S1' 'manual' 'Entra groups and PIM eligibilities' $identityNote -Manual 'yes'
    )
    return $steps
}

$plan = Get-LzTeardownPlan -Config $Config -IncludeSecurityResourceGroup:$IncludeSecurityResourceGroup
foreach ($s in $plan) {
    if (-not $s.CrossSubscription -and $s.Target.StartsWith('/subscriptions/', [System.StringComparison]::OrdinalIgnoreCase) -and -not $s.Target.StartsWith($subPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Plan integrity error: step targets another subscription: $($s.Target)"
    }
}
$plan | Format-Table Stage, Action, Target, Manual -AutoSize | Out-String | Write-Information -InformationAction Continue
# Writing the plan file is not destructive; it is always produced (also under -WhatIf).
$plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PlanPath -Encoding utf8
if (-not $Execute) {
    Write-Warning "WhatIf (default): nothing was deleted. Plan written to $PlanPath. Re-run with -Execute to tear down."
    return $plan
}

$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
if ($ctx.Subscription.Id -ne $sub) { $null = Set-AzContext -WhatIf:$false -SubscriptionId $sub }

foreach ($step in $plan) {
    if ($step.Manual) { $step.Status = 'manual'; continue }
    if (-not $PSCmdlet.ShouldProcess($step.Target, "$($step.Stage) $($step.Action)")) { $step.Status = 'skipped'; continue }
    try {
        switch ($step.Action) {
            'check' {
                if ($step.Stage -eq 'S5') {
                    if (Test-LzArmResourcePresent -ResourceId $step.Target -ApiVersion '2021-04-01') {
                        Assert-LzClusterAbsent -ResourceGroupName (Split-Path $step.Target -Leaf)
                    }
                }
                else {
                    if (Test-LzArmResourcePresent -ResourceId $step.Target -ApiVersion '2025-02-01') {
                        Assert-LzVaultUnprotected -VaultId $step.Target
                    }
                }
                $step.Status = 'ok'
            }
            'remove-locks' {
                foreach ($lock in @(Get-AzResourceLock -Scope $step.Target -AtScope -ErrorAction SilentlyContinue)) {
                    if ($lock.LockId.StartsWith($subPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { $null = Remove-AzResourceLock -LockId $lock.LockId -Force }
                }
                $step.Status = 'ok'
            }
            'delete-rg' {
                $name = Split-Path $step.Target -Leaf
                if (Get-AzResourceGroup -Name $name -ErrorAction SilentlyContinue) { $null = Remove-AzResourceGroup -Name $name -Force }
                $step.Status = 'deleted'
            }
            'delete-kv-purge' {
                $kv = Get-AzKeyVault -VaultName $step.Target -ErrorAction SilentlyContinue
                if ($kv) { Remove-AzKeyVault -VaultName $step.Target -ResourceGroupName $kv.ResourceGroupName -Force; Remove-AzKeyVault -VaultName $step.Target -Location $kv.Location -InRemovedState -Force }
                $step.Status = 'deleted+purged'
            }
            'delete-kv' {
                $kv = Get-AzKeyVault -VaultName $step.Target -ErrorAction SilentlyContinue
                if ($kv) { Remove-AzKeyVault -VaultName $step.Target -ResourceGroupName $kv.ResourceGroupName -Force }
                $step.Status = 'deleted (soft-deleted; purge after retention)'
            }
            'delete-peering' {
                $parts = $step.Target -split '/'
                $peerSub = $parts[2]; $peerRg = $parts[4]; $vnetName = $parts[8]; $peerName = $parts[-1]
                $null = Set-AzContext -WhatIf:$false -SubscriptionId $peerSub
                try { Remove-AzVirtualNetworkPeering -Name $peerName -VirtualNetworkName $vnetName -ResourceGroupName $peerRg -Force -ErrorAction SilentlyContinue }
                finally { $null = Set-AzContext -WhatIf:$false -SubscriptionId $sub }
                $step.Status = 'deleted'
            }
            'delete-policy-assignments' {
                $prefixes = @($n.asg_allowed_locations, $n.asg_require_tags_rg, $n.asg_inherit_tags, $n.asg_activity_log)
                Get-AzPolicyAssignment -Scope "/subscriptions/$sub" -ErrorAction SilentlyContinue | Where-Object { $name = $_.Name; $prefixes | Where-Object { $name -eq $_ -or $name -like "$_-*" } } | ForEach-Object { $null = Remove-AzPolicyAssignment -Id $_.Id }
                $step.Status = 'deleted'
            }
            'delete-budget' {
                $null = Remove-AzConsumptionBudget -Name $n.budget_azl -ErrorAction SilentlyContinue
                $step.Status = 'deleted'
            }
            'keep' { $step.Status = 'kept' }
            default { $step.Status = 'unknown action' }
        }
    }
    catch { $step.Status = "failed: $($_.Exception.Message)"; Write-Warning "$($step.Stage) $($step.Action) $($step.Target): $($_.Exception.Message)"; break }
}
$plan | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PlanPath -Encoding utf8
return $plan
