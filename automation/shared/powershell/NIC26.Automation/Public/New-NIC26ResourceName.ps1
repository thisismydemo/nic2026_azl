function New-NIC26ResourceName {
    <#
    .SYNOPSIS
        Generates a resource name that follows design\shared\naming-standard.md (the only place names are built).
    .DESCRIPTION
        Pattern <type>-iic-nic26-<purpose>-eus-<nn>; storage accounts and the compute gallery drop hyphens; Key Vault
        3-24 characters without consecutive hyphens; NetBIOS names <= 15; policy/Entra/image-definition names are
        global (no region). The type registry (Private\Get-NIC26NameRegistry.ps1) drives everything; adding a type is
        one table entry. The generated name is validated with Test-NIC26ResourceName and the function throws with the
        violated rule (and the computed length for storage accounts and Key Vaults).
    .PARAMETER Type
        Registry type abbreviation (rg, vnet, snet, nsg, pep, kv, st, law, dcr, dce, dcra, rsv, id, init, pol, asg, mc,
        gal, imgdef, it, vdws, vdpool, vdag, vdscaling, vm, vmazl, cl, arb, lnet, img, budget, rp, dnspr, spn, grp,
        clus, node, bmc, sw, fw, og, jmp, sessionhost, vlan, sp, csv, share, ...).
    .PARAMETER Purpose
        Short lowercase purpose segment (hyphen-separated). Optional only for lab-wide singletons (law, gal, vdws).
        For derived names (nic, osdisk, datadisk, vhd, bmc, peer) it is the parent resource name.
    .PARAMETER Instance
        Two-digit instance, 1-99 (padded to 01).
    .PARAMETER Region
        Region short code (default from NamingDefaults.psd1 or NIC26_REGION). Ignored for global types.
    .PARAMETER Org
        Organization token (default from NamingDefaults.psd1 or NIC26_ORG).
    .PARAMETER Token
        Lab token present in every name (default from NamingDefaults.psd1 or NIC26_TOKEN).
    .PARAMETER Suffix
        Extra trailing segment for templates that need one (peer target, VLAN id, secret field).
    .EXAMPLE
        New-NIC26ResourceName -Type kv -Purpose ops            # kv-iic-nic26-ops-eus-01
    .EXAMPLE
        New-NIC26ResourceName -Type st -Purpose fslogix        # stiicnic26fslogixeus01
    .EXAMPLE
        New-NIC26ResourceName -Type sessionhost -Purpose az -Instance 2   # nic26-avd-az02
    .OUTPUTS
        System.String
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure function: computes and returns a string, changes no state. The name is fixed by automation/CONTRACT.md section 4.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,

        [Parameter(Position = 1)]
        [AllowEmptyString()]
        [string]$Purpose = '',

        [Parameter()]
        [ValidateRange(1, 99)]
        [int]$Instance = 1,

        [Parameter()]
        [ValidatePattern('^[a-z0-9]{2,8}$')]
        [string]$Region = (Get-NIC26NamingDefault -Name Region),

        [Parameter()]
        [ValidatePattern('^[a-z0-9]{2,8}$')]
        [string]$Org = (Get-NIC26NamingDefault -Name Org),

        [Parameter()]
        [ValidatePattern('^[a-z0-9]{3,8}$')]
        [string]$Token = (Get-NIC26NamingDefault -Name Token),

        [Parameter()]
        [AllowEmptyString()]
        [string]$Suffix = ''
    )

    $registry = Get-NIC26NameRegistry
    $typeKey = Resolve-NIC26NameType -Type $Type
    if (-not $typeKey) {
        throw "Unknown resource-name type '$Type'. Known types: $($registry.Keys -join ', '). Add new types to Private\Get-NIC26NameRegistry.ps1."
    }
    $entry = $registry[$typeKey]
    if (-not $entry.Generated) {
        throw "Type '$typeKey' ($($entry.Description)) is a fixed/exempt name and is never generated. Use the required name and validate it with Test-NIC26ResourceName."
    }

    # --- purpose ----------------------------------------------------------------------------------------------------
    $purposeValue = $Purpose.Trim().ToLowerInvariant()
    if (-not $entry.PurposeAllowed) {
        if ($purposeValue) {
            throw "Type '$typeKey' does not take a -Purpose (template '$($entry.Template)')."
        }
    }
    else {
        if ($entry.PurposeCompact) {
            $purposeValue = $purposeValue -replace '[-_]', ''
        }
        if (-not $purposeValue -and $entry.DefaultPurpose) {
            $purposeValue = $entry.DefaultPurpose
        }
        if (-not $purposeValue -and -not $entry.PurposeOptional) {
            throw "Type '$typeKey' requires -Purpose ($($entry.Description)); example: $($entry.Example)."
        }
        if ($purposeValue) {
            if ($entry.PurposeValidSet -and ($purposeValue -notin $entry.PurposeValidSet)) {
                throw "Purpose '$purposeValue' is not valid for type '$typeKey'. Allowed: $($entry.PurposeValidSet -join ', ')."
            }
            if ($purposeValue -notmatch $entry.PurposeRegex) {
                throw "Purpose '$purposeValue' for type '$typeKey' must match $($entry.PurposeRegex) (lowercase letters, digits, single hyphens)."
            }
        }
    }

    # --- suffix -----------------------------------------------------------------------------------------------------
    $suffixValue = $Suffix.Trim().ToLowerInvariant()
    if ($entry.Template -like '*{suffix}*') {
        if (-not $suffixValue) {
            throw "Type '$typeKey' requires -Suffix ($($entry.SuffixMeaning)); example: $($entry.Example)."
        }
        if ($suffixValue -notmatch '^[a-z0-9]+([.-][a-z0-9]+)*$') {
            throw "Suffix '$suffixValue' for type '$typeKey' must be lowercase letters, digits, hyphens or dots."
        }
    }
    elseif ($suffixValue) {
        throw "Type '$typeKey' does not take a -Suffix (template '$($entry.Template)')."
    }

    if ($entry.Global -and $PSBoundParameters.ContainsKey('Region')) {
        Write-Verbose "Type '$typeKey' is global; -Region '$Region' is ignored."
    }

    # --- build ------------------------------------------------------------------------------------------------------
    $template = $entry.Template
    if (-not $purposeValue -and $entry.PurposeOptional) {
        $template = $template.Replace('-{purpose}', '').Replace('{purpose}', '')
    }
    $name = $template.
    Replace('{type}', $typeKey).
    Replace('{org}', $Org.ToLowerInvariant()).
    Replace('{token}', $Token.ToLowerInvariant()).
    Replace('{purpose}', $purposeValue).
    Replace('{region}', $Region.ToLowerInvariant()).
    Replace('{instance}', ('{0:D2}' -f $Instance)).
    Replace('{suffix}', $suffixValue)

    $check = Test-NIC26ResourceName -Name $name -Type $typeKey -Token $Token -Detailed
    if (-not $check.IsValid) {
        throw "Generated name '$name' (type '$typeKey', length $($name.Length)) violates the naming standard: $($check.Reasons -join '; ')"
    }
    return $name
}
