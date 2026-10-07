#Requires -Version 7.0
<#
.SYNOPSIS
    Stage S-1: decommission of the PREVIOUS Azure Local deployment in the landing-zone subscription (design §10.2, decision P-10).
.DESCRIPTION
    DESTRUCTIVE. Two-step, owner-gated, fail-closed:

    1. REVIEW run (default; also the only possible run without -Execute): enumerates every resource in the target
       subscription (read-only), classifies it into the ordered dependency layers below (unknown types land in layer 800
       with a blocker note so the owner sees them; resource groups in layer 999), inspects locks at/above scope, Key Vault
       soft-delete/purge-protection state and Arc machine extensions, and writes the candidate file (generated timestamp +
       SHA-256 of the item list) for the owner to edit. Nothing is deleted.
    2. DELETE run: requires -Execute AND -ConfirmDeleteList <edited candidate file>. The approved file must be the
       reviewed candidate file: same subscription, same itemsHash as the CURRENT enumeration (a resource added or removed
       since the review invalidates the approval), not older than 24 h (-AllowStaleList overrides). Approval is ONLY an
       object with approved=true and an id - a bare string is rejected with the whole list. Each approved entry is
       re-validated against the live resource (same id, same type) immediately before deletion; items are deleted in
       layer order; after every delete the script polls until the resource is gone (-DeleteTimeoutMinutes) before the
       next dependent layer; the run stops at the first failure inside a layer unless -ContinueOnError.
       Locks are never removed automatically: a locked item is skipped as blocked unless -RemoveLocks AND the approval
       entry carries removeLock=true; removed locks are recorded and RESTORED when the delete fails.
       Key Vaults with soft delete DISABLED are deleted permanently: the approval entry must carry acknowledgePermanent=true.
       -PurgeKeyVaults purges a soft-deleted vault only when purge protection is off, after it reached the removed state,
       and verifies the purge; purge failures are reported distinctly.
       Resource groups are a SECOND phase (-DeleteEmptyResourceGroups): re-enumerates ALL resources of the group, refuses
       when any remain, re-checks right before the delete.
    -WhatIf on an -Execute run validates everything (list, hash, staleness, approvals) and deletes NOTHING.
    Every run (review, whatif, execute) writes a durable audit JSON next to the candidate file: operator, tenant,
    subscription, mode, reviewed hash, every action with timestamp/status/error/correlation id, lock changes, final state,
    skipped and left-behind items. Every Az call is pinned to the verified context (-DefaultProfile); tenant and
    subscription are verified again immediately before the destructive phase. Nothing outside -SubscriptionId is ever read
    or changed. Physical node reimaging is NOT done here (OS-provisioning solution).
.PARAMETER SubscriptionId
    The ONLY subscription this script may read or change.
.PARAMETER CandidateListPath
    Candidate file written by the review run (default: decommission-candidates.generated.json next to the solution).
.PARAMETER AuditPath
    Audit JSON path (default: decommission-audit-<utc timestamp>.generated.json next to the candidate file).
.PARAMETER Execute
    Required for deletion, together with -ConfirmDeleteList.
.PARAMETER ConfirmDeleteList
    Path to the owner-approved, edited candidate file (items: {id, type, approved: true[, removeLock: true][, acknowledgePermanent: true]}).
.PARAMETER RemoveLocks
    Allow lock removal for approved items whose entry has removeLock=true (locks are restored if the delete fails).
.PARAMETER DeleteEmptyResourceGroups
    Second phase: delete approved resource groups that are verified empty.
.PARAMETER PurgeKeyVaults
    Purge approved, soft-deleted vaults without purge protection after the delete is verified.
.PARAMETER ContinueOnError
    Continue with the next item after a failure (default: stop at the first failure of a layer).
.PARAMETER AllowStaleList
    Accept an approved file older than 24 hours.
.PARAMETER DeleteTimeoutMinutes
    How long to wait for a resource to disappear after its delete call (default 10).
.PARAMETER PollIntervalSeconds
    Poll interval for the wait (default 15).
.EXAMPLE
    ./Remove-PreviousAzureLocalDeployment.ps1 -SubscriptionId $sub                      # review: writes the candidate file + audit
    ./Remove-PreviousAzureLocalDeployment.ps1 -SubscriptionId $sub -Execute -ConfirmDeleteList ./approved.json -WhatIf
    ./Remove-PreviousAzureLocalDeployment.ps1 -SubscriptionId $sub -Execute -ConfirmDeleteList ./approved.json
    ./Remove-PreviousAzureLocalDeployment.ps1 -SubscriptionId $sub -Execute -ConfirmDeleteList ./approved.json -DeleteEmptyResourceGroups
.NOTES
    Requires Az.Accounts, Az.Resources, Az.KeyVault and an Az context with Owner on the subscription. Prints names and IDs only.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [string] $CandidateListPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'decommission-candidates.generated.json'),
    [string] $AuditPath,
    [switch] $Execute,
    [string] $ConfirmDeleteList,
    [switch] $RemoveLocks,
    [switch] $DeleteEmptyResourceGroups,
    [switch] $PurgeKeyVaults,
    [switch] $ContinueOnError,
    [switch] $AllowStaleList,
    [ValidateRange(1, 180)] [int] $DeleteTimeoutMinutes = 10,
    [ValidateRange(0, 300)] [int] $PollIntervalSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants
# Ordered dependency layers (first deleted first). Types outside this list are enumerated generically into layer 800.
$script:TypeOrder = @(
    'Microsoft.Insights/metricAlerts'
    'Microsoft.Insights/scheduledQueryRules'
    'Microsoft.Insights/activityLogAlerts'
    'Microsoft.AlertsManagement/actionRules'
    'Microsoft.AzureStackHCI/virtualMachineInstances'
    'Microsoft.AzureStackHCI/clusters'
    'Microsoft.ExtendedLocation/customLocations'
    'Microsoft.ResourceConnector/appliances'
    'Microsoft.AzureStackHCI/logicalNetworks'
    'Microsoft.AzureStackHCI/marketplaceGalleryImages'
    'Microsoft.AzureStackHCI/galleryImages'
    'Microsoft.AzureStackHCI/storageContainers'
    'Microsoft.AzureStackHCI/networkInterfaces'
    'Microsoft.AzureStackHCI/virtualHardDisks'
    'Microsoft.Edge/sites'
    'Microsoft.HybridCompute/machines'
    'Microsoft.HybridCompute/privateLinkScopes'
    'Microsoft.DataReplication/replicationVaults'
    'Microsoft.DataReplication/replicationFabrics'
    'Microsoft.DependencyMap/maps'                      # discoverySources are children of the map
    'Microsoft.ApplicationMigration/MySQLDiscovery'     # verify the exact type string live; otherwise the generic layer catches it
    'Microsoft.Migrate/migrateProjects'
    'Microsoft.Migrate/assessmentProjects'
    'Microsoft.Migrate/moveCollections'
    'Microsoft.OffAzure/VMwareSites'
    'Microsoft.OffAzure/HyperVSites'
    'Microsoft.OffAzure/ServerSites'
    'Microsoft.OffAzure/ImportSites'
    'Microsoft.OffAzure/MasterSites'
    'Microsoft.RecoveryServices/vaults'
    'Microsoft.Attestation/attestationProviders'
    'Microsoft.KeyVault/vaults'
    'Microsoft.OperationsManagement/solutions'
    'Microsoft.Insights/dataCollectionRules'
    'Microsoft.Insights/dataCollectionEndpoints'
    'Microsoft.OperationalInsights/workspaces'
    'Microsoft.Network/networkSecurityGroups'
    'Microsoft.Storage/storageAccounts'
    'Microsoft.ManagedIdentity/userAssignedIdentities'
)
$script:OtherLayer = 800
$script:RgLayer = 999
$script:RgType = 'Microsoft.Resources/resourceGroups'
$script:SubPrefix = "/subscriptions/$SubscriptionId/"
$script:SubScope = "/subscriptions/$SubscriptionId"
$script:StaleHours = 24

if (-not $AuditPath) {
    $AuditPath = Join-Path (Split-Path -Parent $CandidateListPath) ("decommission-audit-{0:yyyyMMdd-HHmmss}.generated.json" -f (Get-Date).ToUniversalTime())
}

# ---------------------------------------------------------------- audit
$script:Audit = [ordered]@{
    runId            = [guid]::NewGuid().Guid
    mode             = 'review'
    startedUtc       = (Get-Date).ToUniversalTime().ToString('o')
    finishedUtc      = $null
    operator         = $null
    tenantId         = $null
    subscriptionId   = $SubscriptionId
    candidateListPath = $CandidateListPath
    approvedListPath = $ConfirmDeleteList
    reviewedListHash = $null
    currentListHash  = $null
    switches         = [ordered]@{ removeLocks = [bool]$RemoveLocks; deleteEmptyResourceGroups = [bool]$DeleteEmptyResourceGroups; purgeKeyVaults = [bool]$PurgeKeyVaults; continueOnError = [bool]$ContinueOnError; allowStaleList = [bool]$AllowStaleList }
    actions          = [System.Collections.Generic.List[object]]::new()
    lockChanges      = [System.Collections.Generic.List[object]]::new()
    arcExtensions    = [System.Collections.Generic.List[object]]::new()
    finalState       = [System.Collections.Generic.List[object]]::new()
    leftBehind       = [System.Collections.Generic.List[object]]::new()
    result           = 'started'
    error            = $null
}

function Add-LzAudit {
    param([string] $Action, [string] $Status, [string] $Id = '', [string] $Type = '', [string] $ErrorText = '', [string] $CorrelationId = '')
    $entry = [ordered]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); action = $Action; status = $Status; id = $Id; type = $Type; error = $ErrorText; correlationId = $CorrelationId }
    $script:Audit.actions.Add([pscustomobject]$entry)
}

function Write-LzAudit {
    $script:Audit.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    # The audit is written on EVERY run, including -WhatIf (it records that nothing was deleted): -WhatIf:$false on purpose.
    $dir = Split-Path -Parent $AuditPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
    [pscustomobject]$script:Audit | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $AuditPath -Encoding utf8 -WhatIf:$false
}

# ---------------------------------------------------------------- helpers
function Test-LzInTargetSubscription {
    param([Parameter(Mandatory)][string] $ResourceId)
    return $ResourceId.StartsWith($script:SubPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LzErrorClass {
    # none          : provider/type not registered or nothing of that kind -> treated as "no resources"
    # notfound      : the specific resource does not exist
    # authorization : RBAC / token problems -> abort the run
    # transport     : anything else (throttling, timeouts, 5xx, unknown) -> abort the run (fail closed)
    param([Parameter(Mandatory)] $ErrorRecord)
    $msg = $ErrorRecord.Exception.Message
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) { $msg += ' | ' + $inner.Message; $inner = $inner.InnerException }
    if ($msg -match 'NoRegisteredProviderFound|InvalidResourceType|ResourceTypeNotSupported|No registered resource provider|could not be found in the namespace|is not registered') { return 'none' }
    if ($msg -match 'ResourceNotFound|ResourceGroupNotFound|NotFound|could not be found|does not exist|was not found') { return 'notfound' }
    if ($msg -match 'AuthorizationFailed|Forbidden|\b403\b|\b401\b|Unauthorized|does not have authorization|InvalidAuthenticationToken|ExpiredAuthenticationToken|AADSTS') { return 'authorization' }
    return 'transport'
}

function Get-LzCorrelationId {
    param($ErrorRecord)
    if (-not $ErrorRecord) { return '' }
    $m = [regex]::Match([string]$ErrorRecord.Exception.Message, '(?i)correlation\s*id\W+([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})')
    return ($m.Success ? $m.Groups[1].Value : '')
}

function Invoke-LzRead {
    # Runs a read-only Az call; returns @() for "none"/"notfound", aborts the run for authorization/transport errors.
    param([Parameter(Mandatory)][scriptblock] $Call, [Parameter(Mandatory)][string] $What, [switch] $NotFoundIsEmpty)
    try { return @(& $Call) }
    catch {
        $class = Get-LzErrorClass $_
        if ($class -eq 'none') { Add-LzAudit -Action "read:$What" -Status 'none' -ErrorText $_.Exception.Message; return @() }
        if ($class -eq 'notfound' -and $NotFoundIsEmpty) { return @() }
        Add-LzAudit -Action "read:$What" -Status "aborted:$class" -ErrorText $_.Exception.Message -CorrelationId (Get-LzCorrelationId $_)
        throw "Discovery failed closed ($class) while reading $What : $($_.Exception.Message)"
    }
}

function Get-LzListHash {
    param([object[]] $Items)
    $canonical = ($Items | ForEach-Object { "$($_.id.ToLowerInvariant())|$($_.type.ToLowerInvariant())" } | Sort-Object) -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-LzLockScope {
    param([string] $LockId)
    return ($LockId -replace '(?i)/providers/Microsoft\.Authorization/locks/[^/]+$', '')
}

function ConvertTo-LzLockRecord {
    param($Lock)
    $props = $Lock.Properties
    $level = ($props.PSObject.Properties | Where-Object { $_.Name -ieq 'level' } | Select-Object -First 1).Value
    $notes = ($props.PSObject.Properties | Where-Object { $_.Name -ieq 'notes' } | Select-Object -First 1).Value
    [pscustomobject]@{
        lockId = [string]$Lock.LockId
        name   = [string]$Lock.Name
        scope  = Get-LzLockScope -LockId ([string]$Lock.LockId)
        level  = [string]$level
        notes  = [string]$notes
    }
}

function Get-LzEffectiveLocks {
    # Locks AT the resource plus inherited locks from its resource group and the subscription.
    param([Parameter(Mandatory)][string] $ResourceId, [string] $ResourceGroupName, [hashtable] $Cache)
    $locks = @()
    $locks += Invoke-LzRead -What "locks at $ResourceId" -NotFoundIsEmpty { Get-AzResourceLock -Scope $ResourceId -AtScope @script:Az }
    if ($ResourceGroupName) {
        if (-not $Cache.ContainsKey("rg:$ResourceGroupName")) {
            $Cache["rg:$ResourceGroupName"] = @(Invoke-LzRead -What "locks on resource group $ResourceGroupName" -NotFoundIsEmpty { Get-AzResourceLock -ResourceGroupName $ResourceGroupName -AtScope @script:Az })
        }
        $locks += $Cache["rg:$ResourceGroupName"]
    }
    if (-not $Cache.ContainsKey('sub')) {
        $Cache['sub'] = @(Invoke-LzRead -What 'locks on the subscription' -NotFoundIsEmpty { Get-AzResourceLock -Scope $script:SubScope -AtScope @script:Az })
    }
    $locks += $Cache['sub']
    return @($locks | Where-Object { $_ } | ForEach-Object { ConvertTo-LzLockRecord $_ } | Where-Object { Test-LzInTargetSubscription -ResourceId $_.lockId } | Sort-Object lockId -Unique)
}

function Get-LzKeyVaultState {
    param([string] $VaultName)
    $kv = Invoke-LzRead -What "key vault $VaultName" -NotFoundIsEmpty { Get-AzKeyVault -VaultName $VaultName @script:Az } | Select-Object -First 1
    if (-not $kv) { return $null }
    [pscustomobject]@{
        softDeleteEnabled      = [bool]$kv.EnableSoftDelete
        purgeProtectionEnabled = [bool]$kv.EnablePurgeProtection
        location               = [string]$kv.Location
    }
}

function ConvertTo-LzCandidate {
    param([string] $Id, [string] $Name, [string] $Type, [string] $ResourceGroup, [string] $Location, [int] $Order)
    [ordered]@{
        id            = $Id
        name          = $Name
        type          = $Type
        resourceGroup = $ResourceGroup
        location      = $Location
        order         = $Order
        approved      = $false
        locks         = @()
        blocked       = $false
        blocker       = ''
        childExtensions = @()
        keyVault      = $null
        permanentDeletion = $false
    }
}

function Get-LzDecommissionCandidates {
    [CmdletBinding()]
    param()
    $lockCache = @{}
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1) ordered, known types
    for ($i = 0; $i -lt $script:TypeOrder.Count; $i++) {
        $type = $script:TypeOrder[$i]
        $found = @(Invoke-LzRead -What "resources of type $type" { Get-AzResource -ResourceType $type @script:Az })
        foreach ($r in $found) {
            if (-not $r -or -not (Test-LzInTargetSubscription -ResourceId $r.ResourceId)) { continue }
            if (-not $seen.Add($r.ResourceId)) { continue }
            $items.Add((ConvertTo-LzCandidate -Id $r.ResourceId -Name $r.Name -Type $r.ResourceType -ResourceGroup $r.ResourceGroupName -Location $r.Location -Order $i))
        }
    }

    # 2) EVERYTHING else in the subscription (generic enumeration) -> layer 800 with a blocker note
    $all = @(Invoke-LzRead -What 'all resources in the subscription' { Get-AzResource @script:Az })
    foreach ($r in $all) {
        if (-not $r -or -not (Test-LzInTargetSubscription -ResourceId $r.ResourceId)) { continue }
        if (-not $seen.Add($r.ResourceId)) { continue }
        $c = ConvertTo-LzCandidate -Id $r.ResourceId -Name $r.Name -Type $r.ResourceType -ResourceGroup $r.ResourceGroupName -Location $r.Location -Order $script:OtherLayer
        $c.blocker = 'TYPE NOT IN THE ORDERED DECOMMISSION LIST: owner must decide (extend the type list, delete manually, or keep). Deleted last and generically if approved.'
        $items.Add($c)
    }

    # 3) per-item inspection: locks, Key Vault state, Arc extensions
    foreach ($c in $items) {
        $c.locks = @(Get-LzEffectiveLocks -ResourceId $c.id -ResourceGroupName $c.resourceGroup -Cache $lockCache)
        if ($c.locks.Count -gt 0) {
            $c.blocked = $true
            $c.blocker = (($c.blocker ? "$($c.blocker) " : '') + "LOCKED by $($c.locks.name -join ', ') at/above scope: skipped unless -RemoveLocks AND removeLock=true on this entry.").Trim()
        }
        if ($c.type -ieq 'Microsoft.KeyVault/vaults') {
            $c.keyVault = Get-LzKeyVaultState -VaultName $c.name
            if ($c.keyVault -and -not $c.keyVault.softDeleteEnabled) {
                $c.permanentDeletion = $true
                $c.blocker = (($c.blocker ? "$($c.blocker) " : '') + 'SOFT DELETE DISABLED: deletion is PERMANENT and unrecoverable - the approval entry must carry acknowledgePermanent=true.').Trim()
            }
        }
        if ($c.type -ieq 'Microsoft.HybridCompute/machines') {
            $ext = @(Invoke-LzRead -What "extensions of $($c.name)" -NotFoundIsEmpty { Get-AzResource -ResourceId "$($c.id)/extensions" -ApiVersion '2024-07-10' @script:Az })
            $c.childExtensions = @($ext | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
            foreach ($e in $c.childExtensions) { $script:Audit.arcExtensions.Add([pscustomobject]@{ machine = $c.id; extension = $e; note = 'child resource; deleted by the resource provider with the machine - verified by the post-delete poll of the machine, never assumed' }) }
        }
    }

    # 4) resource groups (second phase only)
    $rgs = @(Invoke-LzRead -What 'resource groups' { Get-AzResourceGroup @script:Az })
    foreach ($rg in $rgs) {
        if (-not $rg -or -not (Test-LzInTargetSubscription -ResourceId $rg.ResourceId)) { continue }
        $c = ConvertTo-LzCandidate -Id $rg.ResourceId -Name $rg.ResourceGroupName -Type $script:RgType -ResourceGroup $rg.ResourceGroupName -Location $rg.Location -Order $script:RgLayer
        $c.blocker = 'Resource group: deleted only in the second phase (-DeleteEmptyResourceGroups) and only when verified empty.'
        $c.locks = @(Get-LzEffectiveLocks -ResourceId $rg.ResourceId -ResourceGroupName $rg.ResourceGroupName -Cache $lockCache)
        if ($c.locks.Count -gt 0) { $c.blocked = $true; $c.blocker += " LOCKED by $($c.locks.name -join ', ')." }
        $items.Add($c)
    }
    return @($items | ForEach-Object { [pscustomobject]$_ } | Sort-Object order, type, name)
}

function Write-LzCandidateFile {
    param([object[]] $Candidates, [string] $Hash)
    [pscustomobject]@{
        schema         = 'decommission-candidates/2'
        subscriptionId = $SubscriptionId
        tenantId       = $script:Audit.tenantId
        generatedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        itemsHash      = $Hash
        instructions   = 'Review every item. Set "approved": true on items that may be deleted (add "removeLock": true to allow lock removal with -RemoveLocks; add "acknowledgePermanent": true on Key Vaults flagged permanentDeletion). Do NOT edit id/type or remove items (the itemsHash must still match the live subscription when you run -Execute -ConfirmDeleteList <this file>). Approval is valid for 24 hours.'
        items          = @($Candidates)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $CandidateListPath -Encoding utf8 -WhatIf:$false   # review artefact, not a destructive action
}

function Read-LzApprovedList {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $CurrentHash)
    if (-not (Test-Path -LiteralPath $Path)) { throw "ConfirmDeleteList not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($raw -is [array] -or -not $raw.PSObject.Properties['items']) { throw 'Refusing to run: the approved list must be the edited candidate file (object with subscriptionId, generatedUtc, itemsHash, items[]), not a bare array.' }
    foreach ($field in 'subscriptionId', 'generatedUtc', 'itemsHash') {
        if (-not $raw.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$raw.$field)) { throw "Refusing to run: the approved list lacks '$field'." }
    }
    if ([string]$raw.subscriptionId -ne $SubscriptionId) { throw "Refusing to run: the approved list was reviewed for subscription $($raw.subscriptionId), not $SubscriptionId." }
    $script:Audit.reviewedListHash = [string]$raw.itemsHash
    if ([string]$raw.itemsHash -ne $CurrentHash) { throw "Refusing to run: the approved list's itemsHash ($($raw.itemsHash)) does not match the current enumeration ($CurrentHash) - the subscription changed since the review; re-run the review and re-approve." }
    $generated = [datetime]::Parse([string]$raw.generatedUtc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $age = (Get-Date).ToUniversalTime() - $generated
    if ($age.TotalHours -gt $script:StaleHours -and -not $AllowStaleList) { throw "Refusing to run: the approved list is $([int]$age.TotalHours) h old (limit $($script:StaleHours) h); re-review or pass -AllowStaleList." }

    $bare = @($raw.items | Where-Object { $_ -is [string] -or $_ -is [ValueType] })
    if ($bare.Count -gt 0) { throw "Refusing to run: the approved list contains $($bare.Count) bare value(s) (first: '$($bare[0])'). A bare ID is NOT an approval - every item must be an object with approved=true and an id." }
    $approved = foreach ($e in $raw.items) {
        if (-not $e.PSObject.Properties['approved'] -or $e.approved -isnot [bool] -or -not $e.approved) { continue }
        if (-not $e.PSObject.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$e.id)) { throw 'Refusing to run: an approved entry has no id.' }
        [pscustomobject]@{
            id                   = ([string]$e.id).Trim()
            type                 = ($e.PSObject.Properties['type'] ? ([string]$e.type).Trim() : '')
            removeLock           = [bool]($e.PSObject.Properties['removeLock'] -and $e.removeLock -is [bool] -and $e.removeLock)
            acknowledgePermanent = [bool]($e.PSObject.Properties['acknowledgePermanent'] -and $e.acknowledgePermanent -is [bool] -and $e.acknowledgePermanent)
        }
    }
    return @($approved)
}

function Assert-LzContext {
    param([string] $Phase)
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        $null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
        $ctx = Get-AzContext
    }
    if ($ctx.Subscription.Id -ne $SubscriptionId) { throw "Context verification failed ($Phase): subscription is $($ctx.Subscription.Id), expected $SubscriptionId." }
    if ($script:Audit.tenantId -and $ctx.Tenant.Id -ne $script:Audit.tenantId) { throw "Context verification failed ($Phase): tenant changed from $($script:Audit.tenantId) to $($ctx.Tenant.Id)." }
    $script:Audit.tenantId = [string]$ctx.Tenant.Id
    $script:Audit.operator = [string]($ctx.Account.Id ?? $ctx.Account)
    $script:Az = @{ DefaultProfile = $ctx }
    Add-LzAudit -Action "context-verified:$Phase" -Status 'ok' -Id $script:SubScope
}

function Wait-LzResourceGone {
    param([Parameter(Mandatory)][string] $ResourceId, [switch] $IsResourceGroup)
    $deadline = (Get-Date).AddMinutes($DeleteTimeoutMinutes)
    while ($true) {
        try {
            $probe = if ($IsResourceGroup) { Get-AzResourceGroup -Name (Split-Path $ResourceId -Leaf) @script:Az } else { Get-AzResource -ResourceId $ResourceId @script:Az }
            if (-not $probe) { return $true }
        }
        catch {
            $class = Get-LzErrorClass $_
            if ($class -in 'notfound', 'none') { return $true }
            if ($class -eq 'authorization') { throw "Lost authorization while waiting for $ResourceId to disappear: $($_.Exception.Message)" }
            # transport: keep polling until the deadline
        }
        if ((Get-Date) -gt $deadline) { return $false }
        if ($PollIntervalSeconds -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
}

function Restore-LzLocks {
    param([object[]] $Locks, [string] $Reason)
    foreach ($l in $Locks) {
        try {
            $null = New-AzResourceLock -LockName $l.name -LockLevel $l.level -LockNotes ($l.notes ? $l.notes : 'restored by Remove-PreviousAzureLocalDeployment.ps1') -Scope $l.scope -Force @script:Az
            $script:Audit.lockChanges.Add([pscustomobject]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); change = 'restored'; lockId = $l.lockId; name = $l.name; level = $l.level; notes = $l.notes; scope = $l.scope; reason = $Reason })
        }
        catch {
            $script:Audit.lockChanges.Add([pscustomobject]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); change = 'restore-FAILED'; lockId = $l.lockId; name = $l.name; level = $l.level; notes = $l.notes; scope = $l.scope; reason = "$Reason; error: $($_.Exception.Message)" })
            Write-Warning "Lock $($l.name) at $($l.scope) could NOT be restored: $($_.Exception.Message)"
        }
    }
}

function Invoke-LzKeyVaultPurge {
    param([Parameter(Mandatory)] $Item)
    $state = $Item.keyVault
    if (-not $state -or -not $state.softDeleteEnabled) { return 'purge-not-applicable (soft delete disabled: already permanent)' }
    if ($state.purgeProtectionEnabled) { return 'purge-skipped: purge protection on (name reusable after the retention period)' }
    $deadline = (Get-Date).AddMinutes($DeleteTimeoutMinutes)
    $removed = $null
    while (-not $removed -and (Get-Date) -lt $deadline) {
        try { $removed = Get-AzKeyVault -VaultName $Item.name -Location $state.location -InRemovedState @script:Az | Select-Object -First 1 } catch { $removed = $null }
        if (-not $removed -and $PollIntervalSeconds -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
    }
    if (-not $removed) { return 'purge-FAILED: vault did not reach the removed state before the timeout' }
    try { Remove-AzKeyVault -VaultName $Item.name -Location $state.location -InRemovedState -Force @script:Az }
    catch { return "purge-FAILED: $($_.Exception.Message)" }
    $check = $null
    try { $check = Get-AzKeyVault -VaultName $Item.name -Location $state.location -InRemovedState @script:Az | Select-Object -First 1 } catch { $check = $null }
    return ($check ? 'purge-FAILED: vault still listed in removed state after purge' : 'purged')
}

function Test-LzPermanentVaultNotAcknowledged {
    # Re-inspects soft delete immediately before the delete. Unknown state is treated as permanent (fail closed).
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] $Approval)
    $Item.keyVault = Get-LzKeyVaultState -VaultName $Item.name
    $permanent = (-not $Item.keyVault) -or (-not $Item.keyVault.softDeleteEnabled)
    return ($permanent -and -not $Approval.acknowledgePermanent)
}

function Invoke-LzDelete {
    # Deletes one approved, re-validated item. Returns a status string. Never called under -WhatIf (ShouldProcess gate).
    param([Parameter(Mandatory)] $Item, [Parameter(Mandatory)] $Approval)
    $removedLocks = @()
    $lockCache = @{}
    # locks: skip unless both the switch and the per-entry flag allow removal
    $locks = @(Get-LzEffectiveLocks -ResourceId $Item.id -ResourceGroupName $Item.resourceGroup -Cache $lockCache)
    if ($locks.Count -gt 0) {
        if (-not ($RemoveLocks -and $Approval.removeLock)) {
            Add-LzAudit -Action 'delete' -Status 'blocked-by-lock' -Id $Item.id -Type $Item.type -ErrorText ("locks: " + ($locks.name -join ', '))
            return 'blocked-by-lock'
        }
        foreach ($l in $locks) {
            if (-not $PSCmdlet.ShouldProcess($l.lockId, "Remove lock $($l.name) ($($l.level))")) { return 'whatif' }
            $null = Remove-AzResourceLock -LockId $l.lockId -Force @script:Az
            $removedLocks += $l
            $script:Audit.lockChanges.Add([pscustomobject]@{ timestampUtc = (Get-Date).ToUniversalTime().ToString('o'); change = 'removed'; lockId = $l.lockId; name = $l.name; level = $l.level; notes = $l.notes; scope = $l.scope; reason = "approved removeLock for $($Item.id)" })
        }
    }
    try {
        if ($Item.type -ieq $script:RgType) {
            $null = Remove-AzResourceGroup -Name $Item.name -Force @script:Az
        }
        else {
            $null = Remove-AzResource -ResourceId $Item.id -Force @script:Az
        }
        Add-LzAudit -Action 'delete' -Status 'requested' -Id $Item.id -Type $Item.type
    }
    catch {
        $msg = $_.Exception.Message
        Add-LzAudit -Action 'delete' -Status 'failed' -Id $Item.id -Type $Item.type -ErrorText $msg -CorrelationId (Get-LzCorrelationId $_)
        if ($removedLocks.Count -gt 0) { Restore-LzLocks -Locks $removedLocks -Reason "delete of $($Item.id) failed" }
        return "failed: $msg"
    }
    $gone = Wait-LzResourceGone -ResourceId $Item.id -IsResourceGroup:($Item.type -ieq $script:RgType)
    if (-not $gone) {
        Add-LzAudit -Action 'wait-gone' -Status 'timeout' -Id $Item.id -Type $Item.type -ErrorText "still present after $DeleteTimeoutMinutes min"
        if ($removedLocks.Count -gt 0) { Restore-LzLocks -Locks $removedLocks -Reason "delete of $($Item.id) timed out" }
        return "failed: delete-timeout ($DeleteTimeoutMinutes min)"
    }
    Add-LzAudit -Action 'wait-gone' -Status 'verified-gone' -Id $Item.id -Type $Item.type
    $script:Audit.finalState.Add([pscustomobject]@{ id = $Item.id; type = $Item.type; state = 'gone' })
    if ($Item.type -ieq 'Microsoft.KeyVault/vaults' -and $PurgeKeyVaults) {
        $purge = Invoke-LzKeyVaultPurge -Item $Item
        Add-LzAudit -Action 'purge' -Status $purge -Id $Item.id -Type $Item.type
        return "deleted; $purge"
    }
    return 'deleted'
}

# ================================================================= run
try {
    Assert-LzContext -Phase 'start'
    $candidates = Get-LzDecommissionCandidates
    $currentHash = Get-LzListHash -Items $candidates
    $script:Audit.currentListHash = $currentHash
    Write-Information ("Found {0} candidate resource(s) in subscription {1} ({2} in the ordered layers, {3} other types, {4} resource groups, {5} locked, {6} vault(s) without soft delete):" -f $candidates.Count, $SubscriptionId, @($candidates | Where-Object { $_.order -lt $script:OtherLayer }).Count, @($candidates | Where-Object order -EQ $script:OtherLayer).Count, @($candidates | Where-Object order -EQ $script:RgLayer).Count, @($candidates | Where-Object blocked).Count, @($candidates | Where-Object permanentDeletion).Count) -InformationAction Continue
    $candidates | Select-Object order, type, name, resourceGroup, blocked, permanentDeletion | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

    # The candidate file is the review artefact; it is written on every run so the owner always sees the live list.
    Write-LzCandidateFile -Candidates $candidates -Hash $currentHash
    Add-LzAudit -Action 'write-candidate-list' -Status 'ok' -Id $CandidateListPath

    # ------------------------------------------------------------ review run (default)
    if (-not $Execute -or -not $ConfirmDeleteList) {
        if ($Execute -and -not $ConfirmDeleteList) {
            $script:Audit.result = 'refused'
            throw 'Refusing to delete: -Execute requires -ConfirmDeleteList <owner-approved, edited candidate file>. A review candidate list was written instead.'
        }
        $script:Audit.mode = 'review'
        $script:Audit.result = 'review-complete'
        Write-Warning "Review run (default): nothing was deleted. Candidate list written to $CandidateListPath for owner approval."
        return $candidates
    }

    # ------------------------------------------------------------ delete run (or its -WhatIf)
    $script:Audit.mode = $WhatIfPreference ? 'whatif' : 'execute'
    $approved = Read-LzApprovedList -Path $ConfirmDeleteList -CurrentHash $currentHash
    $outside = @($approved | Where-Object { -not (Test-LzInTargetSubscription -ResourceId $_.id) })
    if ($outside.Count -gt 0) { $script:Audit.result = 'refused'; throw "Refusing to run: the approved list contains $($outside.Count) ID(s) outside subscription $SubscriptionId (first: $($outside[0].id))." }
    Add-LzAudit -Action 'approved-list-validated' -Status 'ok' -Id $ConfirmDeleteList -ErrorText "$($approved.Count) approved entr(y/ies)"

    $byId = @{}
    foreach ($c in $candidates) { $byId[$c.id.ToLowerInvariant()] = $c }
    $work = foreach ($a in $approved) {
        $c = $byId[$a.id.ToLowerInvariant()]
        if (-not $c) { Add-LzAudit -Action 'match' -Status 'skipped:not-a-current-candidate' -Id $a.id -Type $a.type; $script:Audit.leftBehind.Add([pscustomobject]@{ id = $a.id; type = $a.type; reason = 'approved but not a current candidate' }); continue }
        if ($a.type -and $a.type -ine $c.type) { Add-LzAudit -Action 'match' -Status 'skipped:type-mismatch' -Id $a.id -Type $a.type -ErrorText "candidate type is $($c.type)"; $script:Audit.leftBehind.Add([pscustomobject]@{ id = $a.id; type = $a.type; reason = "type mismatch (live: $($c.type))" }); continue }
        [pscustomobject]@{ Candidate = $c; Approval = $a }
    }
    $work = @($work)
    $resources = @($work | Where-Object { $_.Candidate.type -ine $script:RgType } | Sort-Object { $_.Candidate.order }, { $_.Candidate.type }, { $_.Candidate.name })
    $groups = @($work | Where-Object { $_.Candidate.type -ieq $script:RgType } | Sort-Object { $_.Candidate.name })
    Write-Information ("{0} approved resource(s) in {1} layer(s); {2} approved resource group(s) ({3})." -f $resources.Count, @($resources | ForEach-Object { $_.Candidate.order } | Sort-Object -Unique).Count, $groups.Count, ($DeleteEmptyResourceGroups ? 'second phase enabled' : 'second phase NOT enabled: -DeleteEmptyResourceGroups missing')) -InformationAction Continue

    Assert-LzContext -Phase 'before-destructive-phase'
    $results = [System.Collections.Generic.List[object]]::new()
    $stop = $false

    # ---- phase 1: resources, layer by layer
    foreach ($layer in ($resources | ForEach-Object { $_.Candidate.order } | Sort-Object -Unique)) {
        foreach ($w in ($resources | Where-Object { $_.Candidate.order -eq $layer })) {
            $item = $w.Candidate
            if ($stop) { $results.Add([pscustomobject]@{ id = $item.id; type = $item.type; name = $item.name; status = 'not-attempted (earlier failure)' }); $script:Audit.leftBehind.Add([pscustomobject]@{ id = $item.id; type = $item.type; reason = 'not attempted after an earlier failure' }); continue }
            $status = 'skipped'
            try {
                # re-validate against the live resource immediately before deleting: same id, same type
                $live = Invoke-LzRead -What "live state of $($item.id)" -NotFoundIsEmpty { Get-AzResource -ResourceId $item.id @script:Az } | Select-Object -First 1
                if (-not $live) { $status = 'already-gone'; Add-LzAudit -Action 'revalidate' -Status 'already-gone' -Id $item.id -Type $item.type }
                elseif ([string]$live.ResourceType -ine $item.type) { $status = "failed: live type $($live.ResourceType) differs from approved type $($item.type)"; Add-LzAudit -Action 'revalidate' -Status 'type-changed' -Id $item.id -Type $item.type -ErrorText ([string]$live.ResourceType) }
                elseif ($item.type -ieq 'Microsoft.KeyVault/vaults' -and (Test-LzPermanentVaultNotAcknowledged -Item $item -Approval $w.Approval)) {
                    $status = 'refused: permanent deletion (soft delete disabled) not acknowledged - set acknowledgePermanent=true'
                    Add-LzAudit -Action 'delete' -Status 'refused:permanent-not-acknowledged' -Id $item.id -Type $item.type
                }
                elseif (-not $PSCmdlet.ShouldProcess($item.id, "Delete $($item.type)")) { $status = 'whatif'; Add-LzAudit -Action 'delete' -Status 'whatif' -Id $item.id -Type $item.type }
                else { $status = Invoke-LzDelete -Item $item -Approval $w.Approval }
            }
            catch { $status = "failed: $($_.Exception.Message)"; Add-LzAudit -Action 'delete' -Status 'failed' -Id $item.id -Type $item.type -ErrorText $_.Exception.Message -CorrelationId (Get-LzCorrelationId $_) }
            $results.Add([pscustomobject]@{ id = $item.id; type = $item.type; name = $item.name; status = $status })
            if ($status -like 'failed*' -and -not $ContinueOnError) { $stop = $true; Write-Warning "Stopping at the first failure in layer $layer ($($item.name)); pass -ContinueOnError to override." }
        }
        # no break: remaining layers are still walked so every approved item is recorded as not-attempted
    }

    # ---- phase 2: resource groups (only with -DeleteEmptyResourceGroups, only when empty, re-checked right before the delete)
    foreach ($w in $groups) {
        $item = $w.Candidate
        $status = 'deferred: resource groups need -DeleteEmptyResourceGroups'
        if ($DeleteEmptyResourceGroups -and -not $stop) {
            try {
                $remaining = @(Invoke-LzRead -What "resources in group $($item.name)" { Get-AzResource -ResourceGroupName $item.name @script:Az })   # any error is fatal
                if ($remaining.Count -gt 0) {
                    $status = "refused: $($remaining.Count) resource(s) remain ($(($remaining | Select-Object -First 5 | ForEach-Object { $_.ResourceType + '/' + $_.Name }) -join ', '))"
                    Add-LzAudit -Action 'delete-rg' -Status 'refused:not-empty' -Id $item.id -Type $item.type -ErrorText $status
                }
                elseif (-not $PSCmdlet.ShouldProcess($item.id, 'Delete EMPTY resource group')) { $status = 'whatif'; Add-LzAudit -Action 'delete-rg' -Status 'whatif' -Id $item.id -Type $item.type }
                else {
                    $recheck = @(Invoke-LzRead -What "re-check of group $($item.name)" { Get-AzResource -ResourceGroupName $item.name @script:Az })
                    if ($recheck.Count -gt 0) { $status = "refused: $($recheck.Count) resource(s) appeared before the delete"; Add-LzAudit -Action 'delete-rg' -Status 'refused:not-empty-on-recheck' -Id $item.id -Type $item.type }
                    else { $status = Invoke-LzDelete -Item $item -Approval $w.Approval }
                }
            }
            catch { $status = "failed: $($_.Exception.Message)"; Add-LzAudit -Action 'delete-rg' -Status 'failed' -Id $item.id -Type $item.type -ErrorText $_.Exception.Message }
            if ($status -like 'failed*' -and -not $ContinueOnError) { $stop = $true }
        }
        elseif ($stop) { $status = 'not-attempted (earlier failure)' }
        else { Add-LzAudit -Action 'delete-rg' -Status 'deferred' -Id $item.id -Type $item.type }
        $results.Add([pscustomobject]@{ id = $item.id; type = $item.type; name = $item.name; status = $status })
    }

    # ---- left-behind summary: every candidate that is not verified gone
    foreach ($c in $candidates) {
        $own = @($results | Where-Object { $_.id -ieq $c.id })
        $done = @($own | Where-Object { $_.status -like 'deleted*' -or $_.status -eq 'already-gone' })
        if ($done.Count -eq 0) {
            $reason = ($own.Count -gt 0) ? [string]$own[0].status : 'not approved'
            $script:Audit.leftBehind.Add([pscustomobject]@{ id = $c.id; type = $c.type; reason = $reason })
        }
    }
    $failures = @($results | Where-Object { $_.status -like 'failed*' }).Count
    $purgeFailures = @($results | Where-Object { $_.status -like '*purge-FAILED*' }).Count
    $script:Audit.result = ($failures -gt 0 -or $purgeFailures -gt 0) ? "completed-with-failures (deletes: $failures, purges: $purgeFailures)" : ($WhatIfPreference ? 'whatif-complete' : 'complete')
    $results | Format-Table type, name, status -AutoSize | Out-String | Write-Information -InformationAction Continue
    if ($purgeFailures -gt 0) { Write-Warning "$purgeFailures Key Vault purge(s) FAILED - see the audit file." }
    return $results
}
catch {
    if ($script:Audit.result -in 'started') { $script:Audit.result = 'aborted' }
    $script:Audit.error = $_.Exception.Message
    throw
}
finally {
    Write-LzAudit
    Write-Information "Audit written to $AuditPath" -InformationAction Continue
}
