#Requires -Version 7.0
<#
.SYNOPSIS
    Automation identity helpers: sign in as the automation identity and check (read-only) that it holds every role it needs.
.DESCRIPTION
    Dot-source this file, then:

      Connect-NIC26AutomationIdentity   signs in with the identity named by the automation_identity block of the
                                        environment file (a user-assigned managed identity on the jump server, or a
                                        service principal whose app ID and secret are read from Key Vault references)
                                        and returns an ARM access token, ready for
                                        Invoke-AzStackHciArcInitialization -ArmAccessToken (and -AccountID).
      Test-NIC26AutomationIdentityRoles read-only: compares the identity's role assignments with
                                        automation/landing-zones/azure-local/automation-identity-roles.json and reports
                                        every missing, unconstrained or extra assignment.

    Nothing here writes to Azure. Token and secret values are never printed, logged or written to disk; the token is a
    SecureString unless -AsPlainText is given (Invoke-AzStackHciArcInitialization takes a string; keep it in memory).
    Sources: Microsoft Learn "Assign required permissions for Azure Local deployment" (azloc-2609) and "Register Azure
    Local with Azure Arc" (ArmAccessToken); the role table is in automation/landing-zones/azure-local/README.md.
.EXAMPLE
    . .\automation\shared\scripts\NIC26.AutomationIdentity.ps1
    $cfg = Get-NIC26Config -Scope azure-local
    $id = Connect-NIC26AutomationIdentity -AutomationIdentity $cfg.automation_identity -TenantId $cfg.tenant_id -SubscriptionId $cfg.subscription_id -AsPlainText
    # on each node: Invoke-AzStackHciArcInitialization ... -ArmAccessToken $id.Token -AccountID $id.AccountId
.EXAMPLE
    Test-NIC26AutomationIdentityRoles -PrincipalId $principalId -SubscriptionId $cfg.subscription_id -Names $names -SimplifiedProvisioning |
        Format-Table Status, ScopeKey, Role, Key
.NOTES
    Author: Kristopher Turner
    TaskReference: automation identity (landing-zone S3)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NIC26AutomationIdentityRoleMap {
    <#
    .SYNOPSIS
        Reads the role map (single source shared with the landing-zone Bicep and Terraform).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string]$Path = (Join-Path $PSScriptRoot '..' '..' 'landing-zones' 'azure-local' 'automation-identity-roles.json')
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Role map not found: $Path" }
    $map = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if (-not $map.PSObject.Properties['assignments'] -or -not $map.PSObject.Properties['role_display_names']) {
        throw "Role map '$Path' must contain role_display_names and assignments."
    }
    return $map
}

function Get-NIC26AutomationIdentityRequirement {
    <#
    .SYNOPSIS
        Expands the role map into the required (scope, role) pairs for one subscription and name catalog.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Names,

        [Parameter()]
        [switch]$SimplifiedProvisioning,

        [Parameter()]
        [string]$RoleMapPath
    )
    $mapArgs = @{}
    if ($RoleMapPath) { $mapArgs.Path = $RoleMapPath }
    $map = Get-NIC26AutomationIdentityRoleMap @mapArgs
    foreach ($key in 'rg_azl', 'rg_sec', 'kv_azl', 'kv_ops') {
        if (-not $Names.Contains($key) -or [string]::IsNullOrWhiteSpace([string]$Names[$key])) { throw "Names must contain '$key'." }
    }
    $rgBase = "/subscriptions/$SubscriptionId/resourceGroups"
    $scopeIds = @{
        rg_azl = "$rgBase/$($Names['rg_azl'])"
        rg_sec = "$rgBase/$($Names['rg_sec'])"
        kv_azl = "$rgBase/$($Names['rg_sec'])/providers/Microsoft.KeyVault/vaults/$($Names['kv_azl'])"
        kv_ops = "$rgBase/$($Names['rg_sec'])/providers/Microsoft.KeyVault/vaults/$($Names['kv_ops'])"
    }
    $features = if ($SimplifiedProvisioning) { @('core', 'simplified_provisioning') } else { @('core') }
    foreach ($a in $map.assignments) {
        if ($a.feature -notin $features) { continue }
        if (-not $scopeIds.ContainsKey($a.scope)) { throw "Role map item '$($a.key)' has an unknown scope '$($a.scope)'." }
        $delegable = @()
        if ($a.PSObject.Properties['delegable_roles']) { $delegable = @($a.delegable_roles | ForEach-Object { $map.role_display_names.$_ }) }
        [pscustomobject]@{
            Key            = $a.key
            ScopeKey       = $a.scope
            Scope          = $scopeIds[$a.scope]
            Role           = $map.role_display_names.($a.role)
            Feature        = $a.feature
            DelegableRoles = $delegable
            Purpose        = $a.purpose
            Source         = $a.source
        }
    }
}

function Connect-NIC26AutomationIdentity {
    <#
    .SYNOPSIS
        Signs in as the automation identity and returns an ARM access token for Invoke-AzStackHciArcInitialization.
    .DESCRIPTION
        managed-identity: Connect-AzAccount -Identity, with -AccountId set to the client ID from -ClientId or the
        managed_identity_client_id_secret reference (needed when the jump server carries more than one identity).
        service-principal: the app ID and secret are resolved from service_principal_app_id_secret and
        service_principal_secret_secret with the CURRENT sign-in (operator, Key Vault Secrets User on the ops vault),
        then Connect-AzAccount -ServicePrincipal. The new context is process-scoped (-Scope Process) and becomes current.
        Returns { Type, AccountId, TenantId, SubscriptionId, ExpiresOn, Token }. Token is a SecureString unless -AsPlainText.
    .PARAMETER AutomationIdentity
        The automation_identity block of the environment file.
    .PARAMETER ClientId
        Client ID of the user-assigned identity; overrides managed_identity_client_id_secret.
    .PARAMETER ResourceUrl
        Token audience; default is the Resource Manager endpoint of the signed-in environment.
    .PARAMETER SecretResolver
        Resolves a keyvault:// reference to a SecureString; default Resolve-NIC26KeyVaultRef (NIC26.Automation).
    .PARAMETER AsPlainText
        Return the token as a string (Invoke-AzStackHciArcInitialization -ArmAccessToken takes a string). Memory only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$AutomationIdentity,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$SubscriptionId,

        [Parameter()]
        [ValidatePattern('^$|^[0-9a-fA-F-]{36}$')]
        [string]$ClientId = '',

        [Parameter()]
        [string]$ResourceUrl = '',

        [Parameter()]
        [scriptblock]$SecretResolver = { param([string]$Ref) Resolve-NIC26KeyVaultRef -Ref $Ref },

        [Parameter()]
        [switch]$AsPlainText
    )

    $type = if ($AutomationIdentity.Contains('type')) { [string]$AutomationIdentity['type'] } else { '' }
    $connect = @{ Tenant = $TenantId; Subscription = $SubscriptionId; Scope = 'Process'; SkipContextPopulation = $true; ErrorAction = 'Stop' }
    switch ($type) {
        'managed-identity' {
            $connect.Identity = $true
            $accountId = $ClientId
            if (-not $accountId -and $AutomationIdentity.Contains('managed_identity_client_id_secret') -and $AutomationIdentity['managed_identity_client_id_secret']) {
                $secure = & $SecretResolver ([string]$AutomationIdentity['managed_identity_client_id_secret'])
                $accountId = ConvertFrom-SecureString -SecureString $secure -AsPlainText
            }
            if ($accountId) { $connect.AccountId = $accountId }
        }
        'service-principal' {
            foreach ($k in 'service_principal_app_id_secret', 'service_principal_secret_secret') {
                if (-not $AutomationIdentity.Contains($k) -or -not $AutomationIdentity[$k]) { throw "automation_identity.$k is required for type service-principal." }
            }
            $appId = ConvertFrom-SecureString -SecureString (& $SecretResolver ([string]$AutomationIdentity['service_principal_app_id_secret'])) -AsPlainText
            $spSecret = & $SecretResolver ([string]$AutomationIdentity['service_principal_secret_secret'])
            $connect.ServicePrincipal = $true
            $connect.Credential = [pscredential]::new($appId, $spSecret)
        }
        default { throw "automation_identity.type must be managed-identity or service-principal (got '$type')." }
    }

    $null = Connect-AzAccount @connect
    $context = Get-AzContext
    if (-not $context -or -not $context.Account) { throw 'Sign-in as the automation identity returned no Az context.' }

    $audience = $ResourceUrl
    if (-not $audience) { $audience = [string]$context.Environment.ResourceManagerUrl }
    $tokenResponse = Get-AzAccessToken -ResourceUrl $audience -AsSecureString -ErrorAction Stop
    $token = $tokenResponse.Token
    if ($token -is [string]) {
        # Older Az.Accounts returns a string: copy it into a SecureString without a plain-text conversion cmdlet.
        $secureToken = [securestring]::new()
        foreach ($ch in $token.ToCharArray()) { $secureToken.AppendChar($ch) }
        $secureToken.MakeReadOnly()
        $token = $secureToken
    }
    if ($AsPlainText) { $token = ConvertFrom-SecureString -SecureString $token -AsPlainText }

    [pscustomobject]@{
        Type           = $type
        AccountId      = [string]$context.Account.Id
        TenantId       = $TenantId
        SubscriptionId = $SubscriptionId
        ExpiresOn      = $tokenResponse.ExpiresOn
        Token          = $token
    }
}

function Test-NIC26AutomationIdentityRoles {
    <#
    .SYNOPSIS
        Read-only check: does the automation identity hold every role of automation-identity-roles.json?
    .DESCRIPTION
        Reads the principal's role assignments (Get-AzRoleAssignment -ObjectId) and the delegable role IDs
        (Get-AzRoleDefinition), then returns one row per requirement with Status:
          Present        assigned at that scope
          Inherited      assigned at a parent scope (resource group or subscription)
          CoveredByOwner Owner at that scope or above (works, but broader than needed)
          Unconstrained  Role Based Access Control Administrator without an ABAC condition (too broad)
          Constrained-Mismatch  condition present but it does not name every delegable role
          Missing        not assigned
        and one row with Status NotRequired for every other assignment the principal holds (for review).
        -FailOnGap throws when any requirement is Missing, Unconstrained or Constrained-Mismatch.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$PrincipalId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Names,

        [Parameter()]
        [switch]$SimplifiedProvisioning,

        [Parameter()]
        [string]$RoleMapPath,

        [Parameter()]
        [switch]$FailOnGap
    )

    $reqArgs = @{ SubscriptionId = $SubscriptionId; Names = $Names; SimplifiedProvisioning = $SimplifiedProvisioning }
    if ($RoleMapPath) { $reqArgs.RoleMapPath = $RoleMapPath }
    $requirements = @(Get-NIC26AutomationIdentityRequirement @reqArgs)
    $assignments = @(Get-AzRoleAssignment -ObjectId $PrincipalId -ErrorAction Stop)
    $roleIds = @{}
    foreach ($name in @($requirements | ForEach-Object { $_.DelegableRoles } | Sort-Object -Unique)) {
        $roleIds[$name] = [string](Get-AzRoleDefinition -Name $name -ErrorAction Stop).Id
    }

    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gaps = 0
    foreach ($r in $requirements) {
        $status = 'Missing'
        $match = $null
        $sameRole = @($assignments | Where-Object { $_.RoleDefinitionName -eq $r.Role })
        $exact = @($sameRole | Where-Object { $_.Scope.TrimEnd('/') -ieq $r.Scope })
        $parent = @($sameRole | Where-Object { $r.Scope.StartsWith($_.Scope.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase) })
        if ($exact) { $status = 'Present'; $match = $exact[0] }
        elseif ($parent) { $status = 'Inherited'; $match = $parent[0] }
        else {
            $owner = @($assignments | Where-Object { $_.RoleDefinitionName -eq 'Owner' -and ($_.Scope.TrimEnd('/') -ieq $r.Scope -or $r.Scope.StartsWith($_.Scope.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) })
            if ($owner) { $status = 'CoveredByOwner'; $match = $owner[0] }
        }
        if ($match -and $r.DelegableRoles.Count -gt 0 -and $status -ne 'CoveredByOwner') {
            $condition = [string]$match.Condition
            if ([string]::IsNullOrWhiteSpace($condition)) { $status = 'Unconstrained' }
            else {
                $missingIds = @($r.DelegableRoles | Where-Object { $condition -notmatch [regex]::Escape($roleIds[$_]) })
                if ($missingIds) { $status = 'Constrained-Mismatch' }
            }
        }
        if ($match) { [void]$used.Add([string]$match.RoleAssignmentId) }
        if ($status -in 'Missing', 'Unconstrained', 'Constrained-Mismatch') { $gaps++ }
        [pscustomobject]@{
            Status   = $status
            Key      = $r.Key
            ScopeKey = $r.ScopeKey
            Role     = $r.Role
            Scope    = $r.Scope
            Feature  = $r.Feature
            Purpose  = $r.Purpose
            Source   = $r.Source
        }
    }
    foreach ($a in $assignments) {
        if ($used.Contains([string]$a.RoleAssignmentId)) { continue }
        [pscustomobject]@{
            Status   = 'NotRequired'
            Key      = ''
            ScopeKey = ''
            Role     = $a.RoleDefinitionName
            Scope    = $a.Scope
            Feature  = ''
            Purpose  = 'Held by the identity but not in automation-identity-roles.json; review (least privilege)'
            Source   = ''
        }
    }
    if ($FailOnGap -and $gaps -gt 0) { throw "Automation identity is missing or over-broad on $gaps required role assignment(s); run without -FailOnGap for the list." }
}
