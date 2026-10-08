#Requires -Version 7.0
# Pester 5 tests for scripts/: contract §7 safety rules (WhatIf default, -Execute required, approved list required for
# deletion, never outside the target subscription, no secret output). Az/Graph commands are stubbed - no Azure call is made.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stub functions that shadow Az/Graph cmdlets so the tests never call Azure; they are mocked by Pester.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'One synthetic all-zero subscription ID shared with stub functions that run in the scripts'' scope; removed in AfterAll.')]
param()

BeforeDiscovery {
    $script:ScriptDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
    $script:AllScripts = @(Get-ChildItem $script:ScriptDir -Filter '*.ps1' | Select-Object -ExpandProperty FullName)
    $script:StateChanging = @($script:AllScripts | Where-Object { (Split-Path $_ -Leaf) -notin @('Test-LandingZone.ps1', 'Test-JumpTools.ps1') })
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ScriptDir = Join-Path $script:Root 'scripts'
    $script:Sub = '00000000-0000-0000-0000-000000000000'
    $global:LzTestSub = $script:Sub   # stubs run in the scripts' scope, where $script: is not this file
    $script:Config = Get-Content (Join-Path $script:Root 'terraform\terraform.example.tfvars.json') -Raw | ConvertFrom-Json
    $script:Scratch = Join-Path ([System.IO.Path]::GetTempPath()) "lz-azl-tests-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $script:Scratch -Force | Out-Null

    # ---- stubs (functions shadow cmdlets, so no Az/Graph module is ever called) ----
    # Synthetic inventory for the decommission tests (all IDs inside the all-zero subscription).
    function Reset-LzInventory {
        $sub = $global:LzTestSub
        $global:LzInventory = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.HybridCompute/machines/old-node-01"; Name = 'old-node-01'; ResourceType = 'Microsoft.HybridCompute/machines'; ResourceGroupName = 'rg-old'; Location = 'eastus' }
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.AzureStackHCI/clusters/old-cluster"; Name = 'old-cluster'; ResourceType = 'Microsoft.AzureStackHCI/clusters'; ResourceGroupName = 'rg-old'; Location = 'eastus' }
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.KeyVault/vaults/kv-old-01"; Name = 'kv-old-01'; ResourceType = 'Microsoft.KeyVault/vaults'; ResourceGroupName = 'rg-old'; Location = 'eastus' }
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.Storage/storageAccounts/stold01"; Name = 'stold01'; ResourceType = 'Microsoft.Storage/storageAccounts'; ResourceGroupName = 'rg-old'; Location = 'eastus' }
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.Contoso/widgets/old-widget"; Name = 'old-widget'; ResourceType = 'Microsoft.Contoso/widgets'; ResourceGroupName = 'rg-old'; Location = 'eastus' }
        )
        $global:LzResourceGroups = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-old"; ResourceGroupName = 'rg-old'; Location = 'eastus' }
            [pscustomobject]@{ ResourceId = "/subscriptions/$sub/resourceGroups/rg-empty"; ResourceGroupName = 'rg-empty'; Location = 'eastus' }
        )
        $global:LzLocks = [System.Collections.Generic.List[object]]@(
            [pscustomobject]@{ LockId = "/subscriptions/$sub/resourceGroups/rg-old/providers/Microsoft.Storage/storageAccounts/stold01/providers/Microsoft.Authorization/locks/keep"; Name = 'keep'; Properties = [pscustomobject]@{ level = 'CanNotDelete'; notes = 'test' } }
        )
        $global:LzKvSoftDelete = $false
    }
    Reset-LzInventory
    function Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = $global:LzTestSub }; Tenant = [pscustomobject]@{ Id = $global:LzTestSub }; Account = [pscustomobject]@{ Id = 'user1@contoso.com' } } }
    function Set-AzContext { param($SubscriptionId, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function Get-AzResource {
        param($ResourceType, $ResourceGroupName, $ResourceId, $ApiVersion, [Parameter(ValueFromRemainingArguments)] $Rest)
        $inv = @($global:LzInventory)
        if ($ResourceId) { if ($ResourceId -like '*/extensions') { return }; return @($inv | Where-Object { $_.ResourceId -ieq $ResourceId }) }
        if ($ResourceType) { return @($inv | Where-Object { $_.ResourceType -ieq $ResourceType }) }
        if ($ResourceGroupName) { return @($inv | Where-Object { $_.ResourceGroupName -ieq $ResourceGroupName }) }
        return $inv
    }
    function Get-AzResourceGroup { param($Name, [Parameter(ValueFromRemainingArguments)] $Rest) if ($Name) { return @($global:LzResourceGroups | Where-Object ResourceGroupName -EQ $Name) }; return @($global:LzResourceGroups) }
    function Get-AzResourceLock {
        param($Scope, $ResourceGroupName, $LockId, [switch]$AtScope, [Parameter(ValueFromRemainingArguments)] $Rest)
        $scopeWanted = if ($ResourceGroupName) { "/subscriptions/$global:LzTestSub/resourceGroups/$ResourceGroupName" } else { $Scope }
        return @($global:LzLocks | Where-Object { ($_.LockId -replace '/providers/Microsoft\.Authorization/locks/[^/]+$', '') -ieq $scopeWanted })
    }
    function Remove-AzResourceLock { param($LockId, [switch]$Force, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function New-AzResourceLock { param($LockName, $LockLevel, $LockNotes, $Scope, [switch]$Force, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function Remove-AzResource { param($ResourceId, [switch]$Force, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function Remove-AzResourceGroup { param($Name, [switch]$Force, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function Get-AzKeyVault { param($VaultName, $Location, [switch]$InRemovedState, [Parameter(ValueFromRemainingArguments)] $Rest) if ($InRemovedState) { return }; [pscustomobject]@{ VaultName = $VaultName; Location = 'eastus'; EnableSoftDelete = $global:LzKvSoftDelete; EnablePurgeProtection = $false } }
    function Remove-AzKeyVault { param($VaultName, $Location, $ResourceGroupName, [switch]$InRemovedState, [switch]$Force, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function Get-AzResourceProvider { param($ProviderNamespace) [pscustomobject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = 'NotRegistered' } }
    function Get-AzProviderFeature { param($ProviderNamespace, $FeatureName) [pscustomobject]@{ RegistrationState = 'NotRegistered' } }
    function Register-AzResourceProvider { param($ProviderNamespace) }
    function Register-AzProviderFeature { param($ProviderNamespace, $FeatureName) }
    function Get-AzRoleDefinition { param($Name, $Id) [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = $Name } }
    function Get-AzRoleEligibilitySchedule { [CmdletBinding()] param($Scope, $Filter) }
    function Invoke-AzRestMethod { [CmdletBinding()] param($Method, $Path, $Payload) }
    function New-AzRoleEligibilityScheduleRequest { [CmdletBinding()] param($Name, $Scope, $PrincipalId, $RoleDefinitionId, $RequestType, $Justification, $ScheduleInfoStartDateTime, $ExpirationType, $ExpirationDuration, $TargetRoleEligibilityScheduleId) }
    function Get-AzRoleManagementPolicyAssignment { [CmdletBinding()] param($Scope) [pscustomobject]@{ RoleDefinitionId = '11111111-1111-1111-1111-111111111111'; PolicyId = "$Scope/providers/Microsoft.Authorization/roleManagementPolicies/test-policy" } }
    function Get-AzRoleManagementPolicy { [CmdletBinding()] param($Scope, $Name) [pscustomobject]@{ Rule = @([pscustomobject]@{ Id = 'Expiration_Admin_Eligibility'; MaximumDuration = 'P90D'; IsExpirationRequired = $true }) } }
    function Invoke-NIC26WithRetry { param([scriptblock]$ScriptBlock, $MaxMinutes, $Activity) & $ScriptBlock }
    function Get-MgGroup { param($Filter, $ConsistencyLevel, $CountVariable) }
    function New-MgGroup { param($DisplayName, $MailEnabled, $MailNickname, $SecurityEnabled, $Description) [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' } }
    function New-AzSubscriptionDeployment { param($Name, $TemplateFile, $TemplateParameterFile, $enabled_stages, [switch]$WhatIf, [Parameter(ValueFromRemainingArguments)] $Rest) [pscustomobject]@{ WhatIf = [bool]$WhatIf; Stages = $enabled_stages } }
    function Invoke-NIC26ArmDeployment { param($SubscriptionId, $Name, $Location, $TemplateFile, $ParameterFile, $ParameterOverrides, [switch]$Preview) }
    function New-AzManagementGroupDeployment { param($Name, $ManagementGroupId, $TemplateFile, [switch]$WhatIf, [Parameter(ValueFromRemainingArguments)] $Rest) }
    function az { param([Parameter(ValueFromRemainingArguments)] $Rest) $global:LASTEXITCODE = 0; if ($Rest -contains '--outfile') { Set-Content -Path $Rest[[array]::IndexOf($Rest, '--outfile') + 1] -Value '{}' } }
}

AfterAll {
    if (Test-Path $script:Scratch) { Remove-Item $script:Scratch -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($v in 'LzTestSub', 'LzInventory', 'LzResourceGroups', 'LzLocks', 'LzKvSoftDelete') { Remove-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'Script conventions (contract §7)' -Tag 'Scripts' {
    It '<_> parses, requires PowerShell 7, StrictMode, Stop and has comment-based help' -ForEach $script:AllScripts {
        $text = Get-Content $_ -Raw
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors) | Should -BeNullOrEmpty
        $text | Should -Match '#Requires -Version 7\.0'
        $text | Should -Match 'Set-StrictMode -Version Latest'
        $text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $text | Should -Match '(?s)<#.*\.SYNOPSIS.*\.DESCRIPTION.*#>'
    }
    It '<_> changes state only behind SupportsShouldProcess and -Execute' -ForEach $script:StateChanging {
        $text = Get-Content $_ -Raw
        $text | Should -Match 'SupportsShouldProcess'
        $text | Should -Match '\[switch\]\s*\$Execute'
    }
    It 'Test-LandingZone.ps1 is read-only (no Remove-/New-/Set-Az besides Set-AzContext)' {
        $text = Get-Content (Join-Path $script:ScriptDir 'Test-LandingZone.ps1') -Raw
        $text | Should -Not -Match '\b(Remove|New)-Az\w+'
        $text | Should -Not -Match '\bSet-Az(?!Context)\w+'
    }
    It 'Test-JumpTools.ps1 invokes verification only and exposes no execution mode' {
        $text = Get-Content (Join-Path $script:ScriptDir 'Test-JumpTools.ps1') -Raw
        $text | Should -Match 'Invoke-JumpTools -VerifyOnly -PassThru'
        $text | Should -Not -Match '\$Execute|\b(Remove|New|Set)-Az\w+'
    }
    It 'scripts that touch secrets say they run on the Windows jump server' {
        (Get-Content (Join-Path $script:ScriptDir 'Invoke-LzAzureLocalDeploy.ps1') -Raw) | Should -Match '(?i)windows.*jump server|jump server.*windows'
    }
}

Describe 'Remove-PreviousAzureLocalDeployment.ps1 (S-1)' -Tag 'Scripts', 'Destructive' {
    BeforeAll {
        $script:RemoveScript = Join-Path $script:ScriptDir 'Remove-PreviousAzureLocalDeployment.ps1'
        $script:Candidates = Join-Path $script:Scratch 'candidates.json'
        $script:Audit = Join-Path $script:Scratch 'audit.json'
        $script:MachineId = "/subscriptions/$script:Sub/resourceGroups/rg-old/providers/Microsoft.HybridCompute/machines/old-node-01"
        $script:KvId = "/subscriptions/$script:Sub/resourceGroups/rg-old/providers/Microsoft.KeyVault/vaults/kv-old-01"
        $script:LockedId = "/subscriptions/$script:Sub/resourceGroups/rg-old/providers/Microsoft.Storage/storageAccounts/stold01"
        $script:Common = @{ SubscriptionId = $script:Sub; CandidateListPath = $script:Candidates; AuditPath = $script:Audit; DeleteTimeoutMinutes = 1; PollIntervalSeconds = 0; WarningAction = 'SilentlyContinue'; InformationAction = 'SilentlyContinue' }

        # Runs a review, then returns the path of an approved copy with the given approvals applied (edits only approval flags).
        function New-ApprovedList {
            param([hashtable[]] $Approvals, [string] $Name = 'approved.json', [scriptblock] $Mutate)
            $null = & $script:RemoveScript @script:Common
            $doc = Get-Content $script:Candidates -Raw | ConvertFrom-Json
            foreach ($a in $Approvals) {
                $item = $doc.items | Where-Object { $_.id -ieq $a.id }
                foreach ($k in $a.Keys) { if ($k -ne 'id') { $item | Add-Member -NotePropertyName $k -NotePropertyValue $a[$k] -Force } }
            }
            if ($Mutate) { & $Mutate $doc }
            $path = Join-Path $script:Scratch $Name
            $doc | ConvertTo-Json -Depth 8 | Set-Content $path
            return $path
        }
    }
    BeforeEach {
        Reset-LzInventory
        Mock Remove-AzResource { $global:LzInventory = [System.Collections.Generic.List[object]]@($global:LzInventory | Where-Object { $_.ResourceId -ine $ResourceId }) }
        Mock Remove-AzResourceGroup { $global:LzResourceGroups = [System.Collections.Generic.List[object]]@($global:LzResourceGroups | Where-Object { $_.ResourceGroupName -ine $Name }) }
        Mock Remove-AzResourceLock { $global:LzLocks = [System.Collections.Generic.List[object]]@($global:LzLocks | Where-Object { $_.LockId -ine $LockId }) }
        Mock New-AzResourceLock {}
        Mock Remove-AzKeyVault {}
    }

    It 'default (review) run deletes nothing, lists every resource incl. unknown types, locks and permanent vaults, and writes an audit' {
        $result = & $script:RemoveScript @script:Common
        Should -Invoke Remove-AzResource -Times 0
        Should -Invoke Remove-AzResourceGroup -Times 0
        Should -Invoke Remove-AzResourceLock -Times 0
        $json = Get-Content $script:Candidates -Raw | ConvertFrom-Json
        $json.itemsHash | Should -Match '^[0-9a-f]{64}$'
        $json.generatedUtc | Should -Not -BeNullOrEmpty
        @($json.items).Count | Should -Be 7           # 5 resources + 2 resource groups
        @($json.items | Where-Object approved) | Should -BeNullOrEmpty
        $other = $json.items | Where-Object { $_.type -eq 'Microsoft.Contoso/widgets' }
        $other.order | Should -Be 800
        $other.blocker | Should -Match 'NOT IN THE ORDERED'
        ($json.items | Where-Object { $_.id -ieq $script:LockedId }).blocked | Should -BeTrue
        ($json.items | Where-Object { $_.id -ieq $script:KvId }).permanentDeletion | Should -BeTrue
        @($json.items | Where-Object { $_.type -eq 'Microsoft.Resources/resourceGroups' }).order | Should -Be @(999, 999)
        @($result).Count | Should -Be 7
        $audit = Get-Content $script:Audit -Raw | ConvertFrom-Json
        $audit.mode | Should -Be 'review'
        $audit.operator | Should -Be 'user1@contoso.com'
        $audit.subscriptionId | Should -Be $script:Sub
        $audit.result | Should -Be 'review-complete'
    }

    It 'refuses -Execute without -ConfirmDeleteList and still writes the audit' {
        { & $script:RemoveScript @script:Common -Execute } | Should -Throw '*ConfirmDeleteList*'
        Should -Invoke Remove-AzResource -Times 0
        (Get-Content $script:Audit -Raw | ConvertFrom-Json).result | Should -Be 'refused'
    }

    It 'discovery fails closed on an authorization error' {
        Mock Get-AzResource { throw 'AuthorizationFailed: The client does not have authorization to perform action Microsoft.Resources/subscriptions/resources/read' }
        { & $script:RemoveScript @script:Common } | Should -Throw '*fail*closed*authorization*'
        (Get-Content $script:Audit -Raw | ConvertFrom-Json).result | Should -Be 'aborted'
    }

    It 'rejects an approved list with bare string IDs' {
        $list = New-ApprovedList -Name 'bare.json' -Mutate { param($doc) $doc.items = @($doc.items) + @($script:MachineId) }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*bare*NOT an approval*'
        Should -Invoke Remove-AzResource -Times 0
    }

    It 'rejects a bare array (not the edited candidate file)' {
        $list = Join-Path $script:Scratch 'array.json'
        @(@{ id = $script:MachineId; approved = $true }) | ConvertTo-Json -AsArray | Set-Content $list
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*edited candidate file*'
    }

    It 'rejects an approved list whose itemsHash no longer matches the subscription' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:MachineId; approved = $true }) -Name 'hash.json' -Mutate { param($doc) $doc.itemsHash = ('0' * 64) }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*itemsHash*'
        Should -Invoke Remove-AzResource -Times 0
    }

    It 'rejects a stale approved list unless -AllowStaleList' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:MachineId; approved = $true }) -Name 'stale.json' -Mutate { param($doc) $doc.generatedUtc = (Get-Date).ToUniversalTime().AddHours(-30).ToString('o') }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*old*'
        Should -Invoke Remove-AzResource -Times 0
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false -AllowStaleList
        ($r | Where-Object id -EQ $script:MachineId).status | Should -Be 'deleted'
    }

    It 'rejects an approved list reviewed for another subscription' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:MachineId; approved = $true }) -Name 'othersub.json' -Mutate { param($doc) $doc.subscriptionId = '99999999-9999-9999-9999-999999999999' }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*reviewed for subscription*'
    }

    It '-WhatIf on an -Execute run validates the list and deletes nothing' {
        $bad = New-ApprovedList -Name 'whatif-bare.json' -Mutate { param($doc) $doc.items = @($doc.items) + @('bare-id') }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $bad -WhatIf } | Should -Throw '*bare*'
        $list = New-ApprovedList -Approvals @(@{ id = $script:MachineId; approved = $true }, @{ id = $script:KvId; approved = $true; acknowledgePermanent = $true }) -Name 'whatif.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -WhatIf
        Should -Invoke Remove-AzResource -Times 0
        Should -Invoke Remove-AzResourceLock -Times 0
        @($r | Where-Object status -EQ 'whatif').Count | Should -Be 2
        (Get-Content $script:Audit -Raw | ConvertFrom-Json).mode | Should -Be 'whatif'
    }

    It 'deletes only approved, re-validated items in layer order and verifies they are gone' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:MachineId; approved = $true }) -Name 'delete.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false
        Should -Invoke Remove-AzResource -Times 1 -Exactly -ParameterFilter { $ResourceId -ieq $script:MachineId }
        ($r | Where-Object id -EQ $script:MachineId).status | Should -Be 'deleted'
        @($r).Count | Should -Be 1
        $audit = Get-Content $script:Audit -Raw | ConvertFrom-Json
        @($audit.actions | Where-Object { $_.action -eq 'wait-gone' -and $_.status -eq 'verified-gone' }).Count | Should -Be 1
        @($audit.leftBehind).Count | Should -Be 6
        $audit.result | Should -Be 'complete'
    }

    It 'skips a locked item as blocked and never removes the lock without -RemoveLocks and removeLock=true' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:LockedId; approved = $true; removeLock = $true }) -Name 'locked.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false
        ($r | Where-Object id -EQ $script:LockedId).status | Should -Be 'blocked-by-lock'
        Should -Invoke Remove-AzResourceLock -Times 0
        Should -Invoke Remove-AzResource -Times 0
        $list2 = New-ApprovedList -Approvals @(@{ id = $script:LockedId; approved = $true }) -Name 'locked2.json'
        $r2 = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list2 -Confirm:$false -RemoveLocks
        ($r2 | Where-Object id -EQ $script:LockedId).status | Should -Be 'blocked-by-lock'
        Should -Invoke Remove-AzResourceLock -Times 0
    }

    It 'removes the lock only with -RemoveLocks + removeLock=true, records it, and restores it when the delete fails' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:LockedId; approved = $true; removeLock = $true }) -Name 'unlock.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false -RemoveLocks
        ($r | Where-Object id -EQ $script:LockedId).status | Should -Be 'deleted'
        Should -Invoke Remove-AzResourceLock -Times 1 -Exactly
        Should -Invoke New-AzResourceLock -Times 0
        $audit = Get-Content $script:Audit -Raw | ConvertFrom-Json
        @($audit.lockChanges | Where-Object change -EQ 'removed').Count | Should -Be 1
        # failure path: the delete throws -> the lock is restored with the same name/level/notes
        Reset-LzInventory
        Mock Remove-AzResource { throw 'InternalServerError (CorrelationId: 33333333-3333-3333-3333-333333333333)' }
        $list2 = New-ApprovedList -Approvals @(@{ id = $script:LockedId; approved = $true; removeLock = $true }) -Name 'unlock-fail.json'
        $r2 = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list2 -Confirm:$false -RemoveLocks
        ($r2 | Where-Object id -EQ $script:LockedId).status | Should -BeLike 'failed:*'
        Should -Invoke New-AzResourceLock -Times 1 -Exactly -ParameterFilter { $LockName -eq 'keep' -and $LockLevel -eq 'CanNotDelete' }
        $audit2 = Get-Content $script:Audit -Raw | ConvertFrom-Json
        @($audit2.lockChanges | Where-Object change -EQ 'restored').Count | Should -Be 1
        ($audit2.actions | Where-Object { $_.action -eq 'delete' -and $_.status -eq 'failed' }).correlationId | Should -Be '33333333-3333-3333-3333-333333333333'
    }

    It 'stops at the first failure in a layer unless -ContinueOnError' {
        Mock Remove-AzResource { if ($ResourceId -like '*/clusters/*') { throw 'boom' }; $global:LzInventory = [System.Collections.Generic.List[object]]@($global:LzInventory | Where-Object { $_.ResourceId -ine $ResourceId }) }
        $approvals = @(@{ id = "/subscriptions/$script:Sub/resourceGroups/rg-old/providers/Microsoft.AzureStackHCI/clusters/old-cluster"; approved = $true }, @{ id = $script:MachineId; approved = $true })
        $list = New-ApprovedList -Approvals $approvals -Name 'stop.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false
        ($r | Where-Object id -Like '*/clusters/*').status | Should -BeLike 'failed:*'
        ($r | Where-Object id -EQ $script:MachineId).status | Should -BeLike 'not-attempted*'
        Reset-LzInventory
        $list2 = New-ApprovedList -Approvals $approvals -Name 'continue.json'
        $r2 = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list2 -Confirm:$false -ContinueOnError
        ($r2 | Where-Object id -EQ $script:MachineId).status | Should -Be 'deleted'
    }

    It 'refuses to delete a Key Vault without soft delete unless acknowledgePermanent=true' {
        $list = New-ApprovedList -Approvals @(@{ id = $script:KvId; approved = $true }) -Name 'kv.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false
        ($r | Where-Object id -EQ $script:KvId).status | Should -BeLike 'refused: permanent deletion*'
        Should -Invoke Remove-AzResource -Times 0
        $list2 = New-ApprovedList -Approvals @(@{ id = $script:KvId; approved = $true; acknowledgePermanent = $true }) -Name 'kv-ack.json'
        $r2 = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list2 -Confirm:$false -PurgeKeyVaults
        ($r2 | Where-Object id -EQ $script:KvId).status | Should -BeLike 'deleted; purge-not-applicable*'
        Should -Invoke Remove-AzResource -Times 1 -Exactly
    }

    It 'resource groups are a second phase: deferred without the switch, refused while non-empty, deleted only when verified empty' {
        $rgOld = "/subscriptions/$script:Sub/resourceGroups/rg-old"; $rgEmpty = "/subscriptions/$script:Sub/resourceGroups/rg-empty"
        $list = New-ApprovedList -Approvals @(@{ id = $rgOld; approved = $true }, @{ id = $rgEmpty; approved = $true }) -Name 'rg.json'
        $r = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false
        @($r | Where-Object status -Like 'deferred*').Count | Should -Be 2
        Should -Invoke Remove-AzResourceGroup -Times 0
        $list2 = New-ApprovedList -Approvals @(@{ id = $rgOld; approved = $true }, @{ id = $rgEmpty; approved = $true }) -Name 'rg2.json'
        $r2 = & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list2 -Confirm:$false -DeleteEmptyResourceGroups
        ($r2 | Where-Object id -EQ $rgOld).status | Should -BeLike 'refused:*remain*'
        ($r2 | Where-Object id -EQ $rgEmpty).status | Should -Be 'deleted'
        Should -Invoke Remove-AzResourceGroup -Times 1 -Exactly -ParameterFilter { $Name -eq 'rg-empty' }
    }

    It 'refuses an approved list that contains an ID outside the target subscription' {
        $list = New-ApprovedList -Name 'outside.json' -Mutate { param($doc) $doc.items = @($doc.items) + @([pscustomobject]@{ id = '/subscriptions/99999999-9999-9999-9999-999999999999/resourceGroups/x/providers/Microsoft.HybridCompute/machines/m'; type = 'Microsoft.HybridCompute/machines'; approved = $true }) }
        { & $script:RemoveScript @script:Common -Execute -ConfirmDeleteList $list -Confirm:$false } | Should -Throw '*outside subscription*'
        Should -Invoke Remove-AzResource -Times 0
    }
}

Describe 'Register-LzProviders.ps1 (S0)' -Tag 'Scripts' {
    BeforeEach { Mock Register-AzResourceProvider {}; Mock Register-AzProviderFeature {} }
    It 'default run registers nothing' {
        $plan = & (Join-Path $script:ScriptDir 'Register-LzProviders.ps1') -SubscriptionId $script:Sub -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Register-AzResourceProvider -Times 0
        @($plan | Where-Object Kind -EQ 'Feature').Name | Should -Contain 'Microsoft.DeviceOnboarding/AzureLocalZTP'
        @($plan | Where-Object Kind -EQ 'Provider').Count | Should -BeGreaterOrEqual 24
    }
    It '-Execute registers the pending providers and the feature' {
        $null = & (Join-Path $script:ScriptDir 'Register-LzProviders.ps1') -SubscriptionId $script:Sub -Execute -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Register-AzResourceProvider -Times 1 -ParameterFilter { $ProviderNamespace -eq 'Microsoft.AzureStackHCI' }
        Should -Invoke Register-AzProviderFeature -Times 1 -ParameterFilter { $FeatureName -eq 'AzureLocalZTP' }
    }
}

Describe 'New-LzEntraGroups.ps1 (S0)' -Tag 'Scripts' {
    BeforeEach { Mock New-MgGroup { [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' } } }
    It 'default run creates nothing and reports the plan' {
        $out = Join-Path $script:Scratch 'groups.json'
        $plan = & (Join-Path $script:ScriptDir 'New-LzEntraGroups.ps1') -GroupNames @{ grp_azl_admins = 'grp-iic-nic26-azl-admins' } -OutputPath $out -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke New-MgGroup -Times 0
        $plan[0].Action | Should -Be 'create'
    }
    It '-Execute creates the missing group and writes only names and object IDs' {
        $out = Join-Path $script:Scratch 'groups2.json'
        $null = & (Join-Path $script:ScriptDir 'New-LzEntraGroups.ps1') -GroupNames @{ grp_azl_admins = 'grp-iic-nic26-azl-admins' } -OutputPath $out -Execute -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke New-MgGroup -Times 1
        (Get-Content $out -Raw | ConvertFrom-Json).group_object_ids.grp_azl_admins | Should -Be '22222222-2222-2222-2222-222222222222'
    }
}

Describe 'Initialize-LzPim.ps1 (S3)' -Tag 'Scripts' {
    BeforeEach { Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 201; Content = '{"properties":{"status":"Provisioned"}}' } } }
    It 'default run submits no request' {
        $plan = & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Invoke-AzRestMethod -Times 0
        @($plan).Count | Should -Be 9
        @($plan | Where-Object { -not $_.Scope.StartsWith("/subscriptions/$script:Sub") }) | Should -BeNullOrEmpty
    }
    It '-Execute submits one AdminAssign per missing eligibility' {
        $null = & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Invoke-AzRestMethod -Times 9 -Exactly -ParameterFilter { ($Payload | ConvertFrom-Json).properties.requestType -eq 'AdminAssign' }
        Should -Invoke Invoke-AzRestMethod -Times 9 -Exactly -ParameterFilter { ($Payload | ConvertFrom-Json).properties.scheduleInfo.expiration.type -eq 'AfterDuration' -and ($Payload | ConvertFrom-Json).properties.scheduleInfo.expiration.duration -eq 'P90D' -and $ErrorAction -eq 'Stop' }
    }
    It 'rejects a duration above policy without sending requests' {
        $prior = $env:NIC26_PIM_ELIGIBILITY_DURATION
        try {
            $env:NIC26_PIM_ELIGIBILITY_DURATION = 'P91D'
            { & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw '*exceeds the policy*'
            Should -Invoke Invoke-AzRestMethod -Times 0
        }
        finally { $env:NIC26_PIM_ELIGIBILITY_DURATION = $prior }
    }
    It 'propagates a service rejection as a terminating failure' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"code":"ExpirationRule"}}' } }
        { & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw '*ExpirationRule*'
    }
    It 'submits the configured principal and subscription-scoped role in the ARM payload' {
        $null = & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue
        Should -Invoke Invoke-AzRestMethod -Times 9 -Exactly -ParameterFilter {
            $body = $Payload | ConvertFrom-Json
            $Method -eq 'PUT' -and $Path.StartsWith("/subscriptions/$global:LzTestSub/") -and
            $body.properties.principalId -in @($script:Config.group_object_ids.grp_lab_operators, $script:Config.group_object_ids.grp_azl_admins, $script:Config.group_object_ids.grp_azl_operators) -and
            $body.properties.roleDefinitionId.StartsWith("/subscriptions/$global:LzTestSub/providers/Microsoft.Authorization/roleDefinitions/")
        }
    }
    It 'rejects an HTTP-success response carrying a denied request' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 201; Content = '{"properties":{"status":"Denied"}}' } }
        { & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw '*unsuccessful status*'
    }
    It 'rejects an HTTP-success response without a request status' {
        Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 201; Content = '{"properties":{}}' } }
        { & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw '*no request status*'
    }
    It 'preserves existing eligibility without new policy or grant requests' {
        Mock Get-AzRoleEligibilitySchedule {
            [pscustomobject]@{ Scope = $Scope; RoleDefinitionId = "/subscriptions/$global:LzTestSub/providers/Microsoft.Authorization/roleDefinitions/11111111-1111-1111-1111-111111111111"; Id = 'existing-schedule' }
        }
        $plan = & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue
        @($plan | Where-Object Action -NE 'none').Count | Should -Be 0
        Should -Invoke Invoke-AzRestMethod -Times 0
    }
    It 'does not mistake a denied schedule read for missing eligibility' {
        Mock Get-AzRoleEligibilitySchedule { throw 'Schedule read denied' }
        { & (Join-Path $script:ScriptDir 'Initialize-LzPim.ps1') -Config $script:Config -Execute -Confirm:$false -InformationAction SilentlyContinue } | Should -Throw '*Schedule read denied*'
        Should -Invoke Invoke-AzRestMethod -Times 0
    }
}

Describe 'New-LzTeardownPlan.ps1 (S9..S1)' -Tag 'Scripts', 'Destructive' {
    BeforeEach { Mock Remove-AzResourceGroup {}; Mock Remove-AzKeyVault {} }
    It 'default run deletes nothing and writes the ordered plan' {
        $planPath = Join-Path $script:Scratch 'teardown.json'
        $plan = & (Join-Path $script:ScriptDir 'New-LzTeardownPlan.ps1') -Config $script:Config -PlanPath $planPath -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Remove-AzResourceGroup -Times 0
        Should -Invoke Remove-AzKeyVault -Times 0
        Test-Path $planPath | Should -BeTrue
        ($plan | Select-Object -ExpandProperty Stage) | Select-Object -First 1 | Should -Be 'S9'
        ($plan | Select-Object -ExpandProperty Stage) | Select-Object -Last 1 | Should -Be 'S1'
    }
    It 'only standalone-owned remote-side peerings cross subscription, and they are marked' {
        $cfg = $script:Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $cfg.deploy_platform_scope_items = $true
        $plan = & (Join-Path $script:ScriptDir 'New-LzTeardownPlan.ps1') -Config $cfg -PlanPath (Join-Path $script:Scratch 't2.json') -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        $cross = @($plan | Where-Object CrossSubscription)
        $cross.Action | Should -Not -Contain 'delete-rg'
        foreach ($c in $cross) { $c.Action | Should -Be 'delete-peering' }
        $plan | Where-Object { $_.Action -eq 'keep' } | Select-Object -ExpandProperty Target | Should -Match 'rg-iic-nic26-azl-sec'
    }
}

Describe 'Teardown platform ownership boundary' -Tag 'Scripts', 'Destructive' {
    BeforeEach { Mock Get-AzContext { throw 'Unexpected Azure call during plan generation.' } }
    AfterEach { Should -Invoke Get-AzContext -Times 0 -Exactly }
    It 'keeps all three remote peerings and policies with a false or missing flag' -TestCases @(@{ Missing = $false }, @{ Missing = $true }) {
        param($Missing)
        $cfg = $script:Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $cfg.enable_identity_peering = $true
        $cfg.enable_management_peering = $true
        if ($Missing) { $cfg.PSObject.Properties.Remove('deploy_platform_scope_items') }
        else { $cfg.deploy_platform_scope_items = $false }
        $plan = & (Join-Path $script:ScriptDir 'New-LzTeardownPlan.ps1') -Config $cfg -PlanPath (Join-Path $script:Scratch 'ownership-default.json') -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        $cross = @($plan | Where-Object CrossSubscription)
        $cross.Count | Should -Be 3
        @($cross | Where-Object Action -ne 'keep').Count | Should -Be 0
        @($plan | Where-Object Action -eq 'delete-policy-assignments').Count | Should -Be 0
        @($plan | Where-Object Action -eq 'delete-rg').Count | Should -BeGreaterThan 0
    }
    It 'retains standalone-owned peering and policy removal when the flag is boolean true' {
        $cfg = $script:Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $cfg.deploy_platform_scope_items = $true
        $cfg.enable_identity_peering = $true
        $cfg.enable_management_peering = $true
        $plan = & (Join-Path $script:ScriptDir 'New-LzTeardownPlan.ps1') -Config $cfg -PlanPath (Join-Path $script:Scratch 'ownership-standalone.json') -InformationAction SilentlyContinue -WarningAction SilentlyContinue
        @($plan | Where-Object Action -eq 'delete-peering').Count | Should -Be 3
        @($plan | Where-Object Action -eq 'delete-policy-assignments').Count | Should -Be 1
    }
    It 'rejects a string false before writing a plan' {
        $cfg = $script:Config | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $cfg.deploy_platform_scope_items = 'false'
        $path = Join-Path $script:Scratch 'ownership-invalid.json'
        { & (Join-Path $script:ScriptDir 'New-LzTeardownPlan.ps1') -Config $cfg -PlanPath $path -InformationAction SilentlyContinue -WarningAction SilentlyContinue } | Should -Throw '*must be a boolean*'
        Test-Path $path | Should -BeFalse
    }
}

Describe 'Invoke-LzAzureLocalDeploy.ps1 (orchestrator)' -Tag 'Scripts' {
    BeforeAll { $script:Orchestrator = Join-Path $script:ScriptDir 'Invoke-LzAzureLocalDeploy.ps1'; $script:FakeParams = Join-Path $script:Scratch 'main.generated.bicepparam'; Set-Content $script:FakeParams "using 'main.bicep'" }
    BeforeEach { Mock Invoke-NIC26ArmDeployment { [pscustomobject]@{ WhatIf = [bool]$Preview; Stages = $ParameterOverrides.enabled_stages } } }

    It 'defaults to what-if: S1 runs the deployment with -WhatIf only' {
        $r = & $script:Orchestrator -Stage S1 -Config $script:Config -ParameterFile $script:FakeParams -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Invoke-NIC26ArmDeployment -Times 1 -Exactly -ParameterFilter { $Preview -and $ParameterOverrides.enabled_stages -contains 'S1' }
        Should -Invoke Invoke-NIC26ArmDeployment -Times 0 -ParameterFilter { -not $Preview }
        $r.IaC.WhatIf | Should -BeTrue
    }
    It 'passes only the requested IaC stages' {
        $null = & $script:Orchestrator -Stage S2, S4 -Config $script:Config -ParameterFile $script:FakeParams -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke Invoke-NIC26ArmDeployment -Times 1 -ParameterFilter { @($ParameterOverrides.enabled_stages).Count -eq 2 -and $ParameterOverrides.enabled_stages -contains 'S2' -and $ParameterOverrides.enabled_stages -contains 'S4' }
    }
    It 'leaves the management-group initiative and platform-scope items to their owners unless deploy_platform_scope_items is true' {
        Mock New-AzManagementGroupDeployment { }
        $null = & $script:Orchestrator -Stage S1 -Config $script:Config -ParameterFile $script:FakeParams -WarningAction SilentlyContinue -InformationAction SilentlyContinue
        Should -Invoke New-AzManagementGroupDeployment -Times 0
    }
    It 'S-1 with -Execute refuses to run without -ConfirmDeleteList' {
        { & $script:Orchestrator -Stage 'S-1' -Execute -Config $script:Config -ParameterFile $script:FakeParams -Confirm:$false -WarningAction SilentlyContinue -InformationAction SilentlyContinue } | Should -Throw '*ConfirmDeleteList*'
    }
    It 'S-1 is never in the default stage set' {
        $text = Get-Content $script:Orchestrator -Raw
        $text | Should -Match "\[string\[\]\] \`$Stage = @\('S0'"
        $text | Should -Not -Match "\`$Stage = @\('S-1'"
    }
    It 'never writes the jump credential to disk or output' {
        $text = Get-Content $script:Orchestrator -Raw
        $text | Should -Not -Match 'Set-Content[^\n]*\$(plain|pwd|cred)'
        $text | Should -Not -Match 'Out-File[^\n]*\$(plain|pwd|cred)'
        $text | Should -Match 'Start-Transcript is forbidden'
    }
}
