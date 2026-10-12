#Requires -Version 7.0
# Unit tests for NIC26.AutomationIdentity.ps1 (Connect-NIC26AutomationIdentity, Test-NIC26AutomationIdentityRoles).
# Every Az call is mocked: no sign-in, no token, no read or write against Azure. Values are neutral (zero / single-digit GUIDs).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
param()

BeforeDiscovery {
    # The role map ships with the Azure Local landing zone; an attendee repository without it (the AVD one) skips these tests.
    $script:HasRoleMap = Test-Path -LiteralPath (Join-Path $PSScriptRoot '..' '..' '..' 'landing-zones' 'azure-local' 'automation-identity-roles.json')
}

BeforeAll {
    # Stubs so the mocks bind when Az is not installed on the test host.
    foreach ($cmd in 'Connect-AzAccount', 'Get-AzContext', 'Get-AzAccessToken', 'Get-AzRoleAssignment', 'Get-AzRoleDefinition', 'Resolve-NIC26KeyVaultRef') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { New-Item -Path "function:global:$cmd" -Value { param() } | Out-Null }
    }
    . (Join-Path $PSScriptRoot '..' 'NIC26.AutomationIdentity.ps1')
    # Synthetic single-digit GUIDs built at run time: the shared-tree hygiene test allows no literal GUID except all-zero.
    function Get-TestGuid([string]$Digit) { '{0}-{1}-{1}-{1}-{2}' -f ($Digit * 8), ($Digit * 4), ($Digit * 12) }

    $script:Sub = '00000000-0000-0000-0000-000000000000'
    $script:Tenant = (Get-TestGuid '1')
    $script:Principal = (Get-TestGuid '2')
    $script:Names = @{ rg_azl = 'rg-iic-nic26-azl-eus-01'; rg_sec = 'rg-iic-nic26-azl-sec-eus-01'; kv_azl = 'kv-iic-nic26-azl-eus-01'; kv_ops = 'kv-iic-nic26-ops-eus-01' }
    $script:RbacAdminId = (Get-TestGuid '3')
    $script:CmrmId = (Get-TestGuid '4')

    function ConvertTo-TestSecure([string]$Value) { $sec = [securestring]::new(); foreach ($ch in $Value.ToCharArray()) { $sec.AppendChar($ch) }; $sec }

    # One assignment per requirement, at its exact scope; RBAC Administrator carries a condition naming both delegable IDs.
    function Get-FullAssignmentSet {
        param([switch]$SimplifiedProvisioning)
        $reqs = Get-NIC26AutomationIdentityRequirement -SubscriptionId $script:Sub -Names $script:Names -SimplifiedProvisioning:$SimplifiedProvisioning
        $i = 0
        foreach ($r in $reqs) {
            $i++
            $cond = if ($r.DelegableRoles.Count -gt 0) { "@Request[...RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$script:RbacAdminId, $script:CmrmId}" } else { $null }
            [pscustomobject]@{ RoleDefinitionName = $r.Role; Scope = $r.Scope; Condition = $cond; RoleAssignmentId = "ra-$i" }
        }
    }
}

Describe 'Get-NIC26AutomationIdentityRequirement' -Skip:(-not $script:HasRoleMap) {
    It 'expands the core roles to the four scopes' {
        $r = @(Get-NIC26AutomationIdentityRequirement -SubscriptionId $script:Sub -Names $script:Names)
        $r.Count | Should -Be 11
        ($r | Where-Object Key -EQ 'arc_onboarding').Scope | Should -Be "/subscriptions/$script:Sub/resourceGroups/rg-iic-nic26-azl-eus-01"
        ($r | Where-Object Key -EQ 'kv_secrets_officer').Scope | Should -Be "/subscriptions/$script:Sub/resourceGroups/rg-iic-nic26-azl-sec-eus-01/providers/Microsoft.KeyVault/vaults/kv-iic-nic26-azl-eus-01"
        @($r | Where-Object Feature -NE 'core') | Should -BeNullOrEmpty
    }
    It 'adds the simplified-provisioning roles on request' {
        $r = @(Get-NIC26AutomationIdentityRequirement -SubscriptionId $script:Sub -Names $script:Names -SimplifiedProvisioning)
        $r.Count | Should -Be 14
        ($r | Where-Object Key -EQ 'rbac_admin_rg').DelegableRoles | Should -Be @('Role Based Access Control Administrator', 'Azure Connected Machine Resource Manager')
    }
    It 'refuses an incomplete name catalog' {
        { Get-NIC26AutomationIdentityRequirement -SubscriptionId $script:Sub -Names @{ rg_azl = 'x' } } | Should -Throw '*rg_sec*'
    }
}

Describe 'Test-NIC26AutomationIdentityRoles (read-only, mocked)' -Skip:(-not $script:HasRoleMap) {
    BeforeEach {
        Mock Get-AzRoleDefinition {
            if ($Name -eq 'Role Based Access Control Administrator') { return [pscustomobject]@{ Id = $script:RbacAdminId } }
            return [pscustomobject]@{ Id = $script:CmrmId }
        }
    }

    It 'reports every requirement Present when all assignments exist' {
        Mock Get-AzRoleAssignment { Get-FullAssignmentSet -SimplifiedProvisioning }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names -SimplifiedProvisioning -FailOnGap)
        @($rows | Where-Object Status -NE 'Present') | Should -BeNullOrEmpty
        $rows.Count | Should -Be 14
        Should -Invoke Get-AzRoleAssignment -Times 1 -ParameterFilter { $ObjectId -eq $script:Principal }
    }

    It 'reports a missing role and throws with -FailOnGap' {
        Mock Get-AzRoleAssignment { Get-FullAssignmentSet | Where-Object RoleDefinitionName -NE 'Locks Contributor' }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names)
        ($rows | Where-Object Key -EQ 'locks_contributor').Status | Should -Be 'Missing'
        { Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names -FailOnGap } | Should -Throw '*1 required*'
    }

    It 'accepts a role inherited from the subscription and lists unrelated assignments as NotRequired' {
        Mock Get-AzRoleAssignment {
            @(Get-FullAssignmentSet | Where-Object RoleDefinitionName -NE 'Reader')
            [pscustomobject]@{ RoleDefinitionName = 'Reader'; Scope = "/subscriptions/$script:Sub"; Condition = $null; RoleAssignmentId = 'ra-sub-reader' }
            [pscustomobject]@{ RoleDefinitionName = 'Contributor'; Scope = "/subscriptions/$script:Sub"; Condition = $null; RoleAssignmentId = 'ra-sub-contrib' }
        }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names)
        ($rows | Where-Object Key -EQ 'reader').Status | Should -Be 'Inherited'
        ($rows | Where-Object { $_.Status -eq 'NotRequired' -and $_.Role -eq 'Contributor' }).Scope | Should -Be "/subscriptions/$script:Sub"
    }

    It 'flags Role Based Access Control Administrator without a condition as Unconstrained' {
        Mock Get-AzRoleAssignment {
            Get-FullAssignmentSet -SimplifiedProvisioning | ForEach-Object { if ($_.RoleDefinitionName -eq 'Role Based Access Control Administrator') { $_.Condition = $null }; $_ }
        }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names -SimplifiedProvisioning)
        @($rows | Where-Object Status -EQ 'Unconstrained').Key | Should -Be @('rbac_admin_rg', 'rbac_admin_kv')
    }

    It 'flags a condition that does not name every delegable role' {
        Mock Get-AzRoleAssignment {
            Get-FullAssignmentSet -SimplifiedProvisioning | ForEach-Object { if ($_.RoleDefinitionName -eq 'Role Based Access Control Administrator') { $_.Condition = "GuidEquals {$script:RbacAdminId}" }; $_ }
        }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names -SimplifiedProvisioning)
        ($rows | Where-Object Key -EQ 'rbac_admin_rg').Status | Should -Be 'Constrained-Mismatch'
        ($rows | Where-Object Key -EQ 'rbac_admin_kv').Status | Should -Be 'Present'
    }

    It 'reports Owner coverage separately' {
        Mock Get-AzRoleAssignment { [pscustomobject]@{ RoleDefinitionName = 'Owner'; Scope = "/subscriptions/$script:Sub"; Condition = $null; RoleAssignmentId = 'ra-owner' } }
        $rows = @(Test-NIC26AutomationIdentityRoles -PrincipalId $script:Principal -SubscriptionId $script:Sub -Names $script:Names)
        @($rows | Where-Object Status -NE 'CoveredByOwner') | Should -BeNullOrEmpty
    }
}

Describe 'Connect-NIC26AutomationIdentity (mocked)' -Skip:(-not $script:HasRoleMap) {
    BeforeEach {
        Mock Get-AzContext { [pscustomobject]@{ Account = [pscustomobject]@{ Id = (Get-TestGuid '5') }; Environment = [pscustomobject]@{ ResourceManagerUrl = 'https://management.example.test/' } } }
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-TestSecure 'not-a-real-token'); ExpiresOn = [datetimeoffset]::new(2030, 1, 1, 0, 0, 0, [timespan]::Zero) } }
        Mock Connect-AzAccount { [pscustomobject]@{} }
    }

    It 'signs in with the managed identity and the client ID from its Key Vault reference' {
        $resolver = { param([string]$Ref) if ($Ref -like '*client-id') { return (ConvertTo-TestSecure (Get-TestGuid '6')) }; throw 'unexpected ref' }
        $block = @{ type = 'managed-identity'; managed_identity_client_id_secret = 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-automation-identity-client-id' }
        $r = Connect-NIC26AutomationIdentity -AutomationIdentity $block -TenantId $script:Tenant -SubscriptionId $script:Sub -SecretResolver $resolver
        Should -Invoke Connect-AzAccount -Times 1 -ParameterFilter { $Identity -and $AccountId -eq (Get-TestGuid '6') -and $Tenant -eq $script:Tenant -and $Subscription -eq $script:Sub -and $Scope -eq 'Process' }
        Should -Invoke Get-AzAccessToken -Times 1 -ParameterFilter { $ResourceUrl -eq 'https://management.example.test/' }
        $r.Token | Should -BeOfType [securestring]
        $r.AccountId | Should -Be (Get-TestGuid '5')
        $r.Type | Should -Be 'managed-identity'
    }

    It 'uses -ClientId over the reference and returns a plain token only with -AsPlainText' {
        $resolver = { param([string]$Ref) throw "resolver must not be called for $Ref" }
        $block = @{ type = 'managed-identity'; managed_identity_client_id_secret = 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-automation-identity-client-id' }
        $r = Connect-NIC26AutomationIdentity -AutomationIdentity $block -TenantId $script:Tenant -SubscriptionId $script:Sub -ClientId (Get-TestGuid '7') -SecretResolver $resolver -AsPlainText
        Should -Invoke Connect-AzAccount -Times 1 -ParameterFilter { $AccountId -eq (Get-TestGuid '7') }
        $r.Token | Should -BeOfType [string]
        $r.Token | Should -Be 'not-a-real-token'
    }

    It 'signs in without -AccountId when no client ID is given (single identity on the VM)' {
        $r = Connect-NIC26AutomationIdentity -AutomationIdentity @{ type = 'managed-identity' } -TenantId $script:Tenant -SubscriptionId $script:Sub
        Should -Invoke Connect-AzAccount -Times 1 -ParameterFilter { $Identity -and -not $AccountId }
        $r | Should -Not -BeNullOrEmpty
    }

    It 'signs in as a service principal with the app ID and secret from Key Vault' {
        $resolver = { param([string]$Ref) if ($Ref -like '*app-id') { return (ConvertTo-TestSecure (Get-TestGuid '8')) }; return (ConvertTo-TestSecure 'not-a-real-value') }
        $block = @{
            type                            = 'service-principal'
            service_principal_app_id_secret = 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-automation-sp-app-id'
            service_principal_secret_secret = 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-automation-sp-secret'
        }
        $null = Connect-NIC26AutomationIdentity -AutomationIdentity $block -TenantId $script:Tenant -SubscriptionId $script:Sub -SecretResolver $resolver
        Should -Invoke Connect-AzAccount -Times 1 -ParameterFilter { $ServicePrincipal -and $Credential.UserName -eq (Get-TestGuid '8') -and -not $Identity }
    }

    It 'refuses a service principal without its Key Vault references' {
        { Connect-NIC26AutomationIdentity -AutomationIdentity @{ type = 'service-principal' } -TenantId $script:Tenant -SubscriptionId $script:Sub } | Should -Throw '*service_principal_app_id_secret*'
        Should -Invoke Connect-AzAccount -Times 0
    }

    It 'refuses an unknown type' {
        { Connect-NIC26AutomationIdentity -AutomationIdentity @{ type = 'user' } -TenantId $script:Tenant -SubscriptionId $script:Sub } | Should -Throw '*managed-identity or service-principal*'
    }

    It 'converts a plain-string token (older Az.Accounts) to a SecureString' {
        Mock Get-AzAccessToken { [pscustomobject]@{ Token = 'not-a-real-token'; ExpiresOn = [datetimeoffset]::UtcNow } }
        $r = Connect-NIC26AutomationIdentity -AutomationIdentity @{ type = 'managed-identity' } -TenantId $script:Tenant -SubscriptionId $script:Sub
        $r.Token | Should -BeOfType [securestring]
    }

    It 'writes nothing to the output, warning or information streams besides the result object' {
        $out = Connect-NIC26AutomationIdentity -AutomationIdentity @{ type = 'managed-identity' } -TenantId $script:Tenant -SubscriptionId $script:Sub 6>&1 3>&1
        @($out).Count | Should -Be 1
    }
}
