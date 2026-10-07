#Requires -Version 7.0
<#
.SYNOPSIS
    NIC 2026 demo support - common module (screen hygiene, safety guards, fault locks, mockable wrappers).
.DESCRIPTION
    Every demo script under automation\demo\ imports this module. It owns:
      - the screen-hygiene filter (Hide-DemoSensitiveText / Write-DemoScreen) that masks the tenant name and
        domain, GUIDs, the owner e-mail and every reference-environment prefix before text reaches a screen
        that could be recorded (patterns are assembled at run time so this tree never contains the strings);
      - the safety guards shared by the scripts (transcript detection, Windows-only assertion, typed
        confirmation, UNDO banner, -Execute gate helpers, pass/fail check tables and exit codes);
      - the fault-lock registry on the jump server so the fault helpers can refuse to stack faults;
      - thin, mockable wrappers around PowerShell remoting, Az, Microsoft Graph and the
        Azure Local cmdlets so every script can be unit-tested without Azure or any device.
    Nothing here prints a secret value; wrappers that touch Key Vault return SecureString objects only.
    Design: design/shared/keyvault-and-secrets.md §5, design/shared/management-plane.md §1.10,
    planning/sessions/azure-local/outline.md §2.6, §3.7, §4.2, §4.5, planning/sessions/avd/outline.md §8.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DemoModuleRoot = $PSScriptRoot
$script:HiddenTerms = [System.Collections.Generic.List[string]]::new()
$script:ConfigCache = @{}
$script:HiddenMarker = '[hidden]'

# Regular expressions the filter masks in addition to the registered literal terms. Nothing is built in: supply your own through
# screen_hidden_patterns in the environment file, the NIC26_DEMO_HIDDEN_PATTERNS variable (semicolon separated) or Add-DemoHiddenPattern.
$script:HiddenPatterns = [System.Collections.Generic.List[string]]::new()
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$sharedModule = Join-Path $PSScriptRoot '..' '..' '..' 'shared' 'powershell' 'NIC26.Automation' 'NIC26.Automation.psd1'
if (Test-Path -LiteralPath $sharedModule) {
    Import-Module $sharedModule -Force -Global
}

#region Screen hygiene -------------------------------------------------------------------------------------------------

function Add-DemoHiddenTerm {
    <#
    .SYNOPSIS
        Registers literal terms (tenant name, domain, e-mail, shared resource names) that the screen filter must mask.
    .PARAMETER Term
        One or more literal strings. Empty strings are ignored. Matching is case-insensitive.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Term
    )
    process {
        foreach ($t in $Term) {
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            if ($t.Length -lt 3) { continue }
            if (-not $script:HiddenTerms.Contains($t)) { $script:HiddenTerms.Add($t) }
        }
    }
}

function Add-DemoHiddenPattern {
    <#
    .SYNOPSIS
        Registers regular expressions (for example a naming prefix followed by any characters) that the screen filter must mask.
    .PARAMETER Pattern
        One or more .NET regular expressions. Invalid patterns are rejected, empty ones ignored. Matching is case-sensitive
        unless the pattern starts with (?i).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [AllowNull()]
        [string[]]$Pattern
    )
    process {
        foreach ($p in $Pattern) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try { $null = [regex]::new($p) } catch { throw "Invalid screen-hygiene pattern: $($_.Exception.Message)" }
            if (-not $script:HiddenPatterns.Contains($p)) { $script:HiddenPatterns.Add($p) }
        }
    }
}

function Get-DemoHiddenTermList {
    <#
    .SYNOPSIS
        Returns the currently registered literal hidden terms (for tests and diagnostics; never printed on stage).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]$script:HiddenTerms.ToArray()
}

function Clear-DemoHiddenTerm {
    <#
    .SYNOPSIS
        Clears the registered literal hidden terms and patterns.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if ($PSCmdlet.ShouldProcess('screen-hygiene term list', 'Clear')) {
        $script:HiddenTerms.Clear()
        $script:HiddenPatterns.Clear()
    }
}

function Initialize-DemoScreenHygiene {
    <#
    .SYNOPSIS
        Loads the hidden-term list from the merged environment config: tenant domain, tenant ID, subscription IDs,
        owner e-mail, and the optional screen_hidden_terms and screen_hidden_patterns lists.
    .PARAMETER Config
        A config object from Get-DemoConfig (hashtable or PSCustomObject).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    foreach ($key in @('tenant_domain', 'tenant_id', 'owner_email', 'hub_vnet_name', 'hub_resource_group_name', 'demo_user_domain')) {
        $value = Get-DemoConfigValue -Config $Config -Key $key
        if ($value) { Add-DemoHiddenTerm -Term ([string]$value) }
    }
    $subs = Get-DemoConfigValue -Config $Config -Key 'subscriptions'
    if ($subs) {
        foreach ($entry in (ConvertTo-DemoHashtable -InputObject $subs).GetEnumerator()) {
            if ($entry.Value) { Add-DemoHiddenTerm -Term ([string]$entry.Value) }
        }
    }
    $extra = Get-DemoConfigValue -Config $Config -Key 'screen_hidden_terms'
    if ($extra) { Add-DemoHiddenTerm -Term ([string[]]$extra) }
    $patterns = Get-DemoConfigValue -Config $Config -Key 'screen_hidden_patterns'
    if ($patterns) { Add-DemoHiddenPattern -Pattern ([string[]]$patterns) }
    if ($env:NIC26_DEMO_HIDDEN_PATTERNS) { Add-DemoHiddenPattern -Pattern ([string[]]($env:NIC26_DEMO_HIDDEN_PATTERNS -split ';')) }
    $tags = Get-DemoConfigValue -Config $Config -Key 'tags'
    if ($tags) {
        $owner = Get-DemoConfigValue -Config $tags -Key 'owner'
        if ($owner) { Add-DemoHiddenTerm -Term ([string]$owner) }
    }
}

function Hide-DemoSensitiveText {
    <#
    .SYNOPSIS
        The screen-hygiene filter: replaces tenant/domain/GUID/reference-environment strings with [hidden].
    .DESCRIPTION
        Applies, in order: the registered literal terms (longest first, case-insensitive), the registered
        patterns, and GUIDs (unless -KeepGuid). Works on strings and on anything
        else by formatting it with Out-String first.
    .PARAMETER InputObject
        Text or objects to filter.
    .PARAMETER Term
        Additional literal terms for this call only.
    .PARAMETER KeepGuid
        Do not mask GUIDs (default masks them; subscription and tenant IDs appear inside resource IDs).
    .EXAMPLE
        Get-AzResource | Format-Table | Out-String | Hide-DemoSensitiveText
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$InputObject,

        [Parameter()]
        [string[]]$Term = @(),

        [Parameter()]
        [switch]$KeepGuid
    )
    begin {
        $terms = @($script:HiddenTerms.ToArray()) + @($Term | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $terms = @($terms | Sort-Object -Property Length -Descending -Unique)
    }
    process {
        if ($null -eq $InputObject) { return }
        $lines = if ($InputObject -is [string]) { @($InputObject) } else { @(($InputObject | Out-String -Width 200) -split "`r?`n") }
        foreach ($line in $lines) {
            $text = [string]$line
            foreach ($t in $terms) {
                $text = [regex]::Replace($text, [regex]::Escape($t), $script:HiddenMarker, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            }
            foreach ($pattern in $script:HiddenPatterns) {
                $text = [regex]::Replace($text, $pattern, $script:HiddenMarker)
            }
            if (-not $KeepGuid) {
                $text = [regex]::Replace($text, $script:GuidPattern, $script:HiddenMarker)
            }
            $text
        }
    }
}

function Write-DemoScreen {
    <#
    .SYNOPSIS
        Writes text to the presenter screen through the screen-hygiene filter (Information stream, never Write-Host).
    .PARAMETER InputObject
        Text or objects. Objects are formatted with Out-String.
    .PARAMETER Raw
        Skip the filter (only for text that is already proven clean, e.g. literal headings).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyString()]
        [object]$InputObject,

        [Parameter()]
        [switch]$Raw
    )
    process {
        if ($null -eq $InputObject) { return }
        $lines = if ($Raw) {
            if ($InputObject -is [string]) { @($InputObject) } else { @(($InputObject | Out-String -Width 200) -split "`r?`n") }
        }
        else {
            @(Hide-DemoSensitiveText -InputObject $InputObject)
        }
        foreach ($line in $lines) {
            Write-Information -MessageData $line -Tags 'NIC26Demo' -InformationAction Continue
        }
    }
}

function Write-DemoUndo {
    <#
    .SYNOPSIS
        Prints the UNDO command for a disruptive action BEFORE the action runs (every fault helper calls this first).
    .PARAMETER Command
        The exact command line that reverses the action.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )
    Write-DemoScreen -InputObject '============================================================' -Raw
    Write-DemoScreen -InputObject ('UNDO (run this to reverse the action): ' + $Command)
    Write-DemoScreen -InputObject '============================================================' -Raw
}

function Write-DemoPlan {
    <#
    .SYNOPSIS
        Prints a dry-run/plan banner for the -WhatIf default path and the hint to add -Execute.
    .PARAMETER Lines
        The plan lines (names only).
    .PARAMETER ScriptName
        The invoking script (for the hint).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Lines = @(),

        [Parameter(Mandatory)]
        [string]$ScriptName
    )
    Write-DemoScreen -InputObject ("PLAN (WhatIf is the default; nothing changed). {0} line(s):" -f $Lines.Count) -Raw
    foreach ($l in $Lines) { Write-DemoScreen -InputObject ('  - ' + $l) }
    Write-DemoScreen -InputObject ("Re-run {0} with -Execute to apply (owner approval required)." -f $ScriptName) -Raw
}

#endregion

#region Guards ----------------------------------------------------------------------------------------------------------

function Test-DemoTranscriptActive {
    <#
    .SYNOPSIS
        Returns $true when Start-Transcript is recording in this host (reflection; NIC26_ASSUME_TRANSCRIPT forces $true).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:NIC26_ASSUME_TRANSCRIPT) { return $true }
    try {
        $ui = $Host.UI
        $type = $ui.GetType()
        while ($null -ne $type) {
            $property = $type.GetProperty('IsTranscribing', [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
            if ($null -ne $property) { return [bool]$property.GetValue($ui) }
            $type = $type.BaseType
        }
    }
    catch {
        Write-Verbose "Transcript detection via reflection failed: $($_.Exception.Message)"
    }
    return $false
}

function Test-DemoWindowsHost {
    <#
    .SYNOPSIS
        Returns $true on Windows (SecureString/DPAPI protect memory only there; K-8). NIC26_ASSUME_PLATFORM overrides for tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:NIC26_ASSUME_PLATFORM) { return ($env:NIC26_ASSUME_PLATFORM -eq 'Windows') }
    return [bool]$IsWindows
}

function Assert-DemoSecretSafeHost {
    <#
    .SYNOPSIS
        Throws unless the host is Windows and no transcript is active (required before any secret value is touched).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if (-not (Test-DemoWindowsHost)) {
        throw 'Refusing to run: secret values may only be handled on the Windows jump server (SecureString offers no memory protection elsewhere; design/shared/keyvault-and-secrets.md K-8).'
    }
    if (Test-DemoTranscriptActive) {
        throw 'Refusing to run while a PowerShell transcript is active (Start-Transcript). Run Stop-Transcript and retry; no value may ever reach a transcript (keyvault-and-secrets.md §5.7).'
    }
}

function Confirm-DemoTypedPhrase {
    <#
    .SYNOPSIS
        Requires the operator to type an exact phrase before a destructive action (node power-off).
    .PARAMETER Phrase
        The phrase that must be typed, e.g. 'POWER OFF nic26-01-n02'.
    .PARAMETER Provided
        A phrase supplied on the command line (non-interactive runs); must match exactly.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Phrase,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Provided = ''
    )
    if ($Provided) { return ($Provided -ceq $Phrase) }
    $typed = Read-DemoHostLine -Prompt ("Type exactly '{0}' to continue" -f $Phrase)
    return ($typed -ceq $Phrase)
}

function Read-DemoHostLine {
    <#
    .SYNOPSIS
        Read-Host wrapper (mockable).
    .PARAMETER Prompt
        Prompt text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )
    return [string](Read-Host -Prompt $Prompt)
}

function Read-DemoHostSecureLine {
    <#
    .SYNOPSIS
        Read-Host -AsSecureString wrapper (mockable); used when an externally issued value must be typed by the operator.
    .PARAMETER Prompt
        Prompt text.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )
    return Read-Host -Prompt $Prompt -AsSecureString
}

#endregion

#region Config ----------------------------------------------------------------------------------------------------------

function Get-DemoConfig {
    <#
    .SYNOPSIS
        Loads the merged environment config for a scope through Get-NIC26Config (cached per process; mockable).
    .PARAMETER Scope
        azure-local | avd | shared
    .PARAMETER Path
        Optional environment folder override (passed to Get-NIC26Config -Path).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('azure-local', 'avd', 'shared')]
        [string]$Scope,

        [Parameter()]
        [string]$Path
    )
    $cacheKey = "$Scope|$Path"
    if ($script:ConfigCache.ContainsKey($cacheKey)) { return $script:ConfigCache[$cacheKey] }
    if (-not (Get-Command -Name Get-NIC26Config -ErrorAction SilentlyContinue)) {
        throw 'NIC26.Automation is not loaded; import automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1 first.'
    }
    $params = @{ Scope = $Scope }
    if ($Path) { $params['Path'] = $Path }
    $config = Get-NIC26Config @params
    $script:ConfigCache[$cacheKey] = $config
    return $config
}

function Clear-DemoConfigCache {
    <#
    .SYNOPSIS
        Clears the per-process config cache (tests).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if ($PSCmdlet.ShouldProcess('config cache', 'Clear')) { $script:ConfigCache = @{} }
}

function ConvertTo-DemoHashtable {
    <#
    .SYNOPSIS
        Converts a PSCustomObject / ordered dictionary / hashtable to a plain hashtable (one level).
    .PARAMETER InputObject
        The object.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject
    )
    $result = @{}
    if ($null -eq $InputObject) { return $result }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in $InputObject.Keys) { $result[[string]$k] = $InputObject[$k] }
        return $result
    }
    foreach ($p in $InputObject.PSObject.Properties) { $result[$p.Name] = $p.Value }
    return $result
}

function Get-DemoConfigValue {
    <#
    .SYNOPSIS
        Reads a (dotted) key from a config object; returns $null when absent.
    .PARAMETER Config
        Hashtable or PSCustomObject.
    .PARAMETER Key
        Key or dotted path (e.g. identity.dns_zone).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config,

        [Parameter(Mandatory)]
        [string]$Key
    )
    $current = $Config
    foreach ($segment in ($Key -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $null }
            $current = $current[$segment]
        }
        else {
            $prop = $current.PSObject.Properties[$segment]
            if ($null -eq $prop) { return $null }
            $current = $prop.Value
        }
    }
    return $current
}

function Get-DemoNodeList {
    <#
    .SYNOPSIS
        Returns the cluster nodes from the azure-local config as objects {Name, ManagementIp, Raw}; Raw is the node entry as configured.
    .PARAMETER Config
        azure-local config (Get-DemoConfig -Scope azure-local).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    $nodes = @(Get-DemoConfigValue -Config $Config -Key 'nodes')
    if ($nodes.Count -eq 0) { throw 'The azure-local environment file declares no nodes.' }
    return @($nodes | ForEach-Object {
            [pscustomobject]@{
                Name         = [string](Get-DemoConfigValue -Config $_ -Key 'name')
                ManagementIp = [string](Get-DemoConfigValue -Config $_ -Key 'management_ip')
                Raw          = $_
            }
        })
}

function Get-DemoAvdNameSet {
    <#
    .SYNOPSIS
        Resolves the AVD control-plane names per realm from the naming standard (New-NIC26ResourceName) and the config.
    .PARAMETER Config
        avd config (merged with shared).
    .OUTPUTS
        PSCustomObject: Workspace, HostPoolResourceGroup, Realms = @{ azure|azl|hybrid = @{ HostPool; AppGroup; Group } }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    $org = [string](Get-DemoConfigValue -Config $Config -Key 'org')
    $token = [string](Get-DemoConfigValue -Config $Config -Key 'token')
    $region = [string](Get-DemoConfigValue -Config $Config -Key 'location_short')
    $nameParams = @{ Org = $org; Token = $token; Region = $region }
    $groups = Get-DemoConfigValue -Config $Config -Key 'entra_groups'
    $realms = @{}
    foreach ($realm in @('azure', 'azl', 'hybrid')) {
        $realms[$realm] = [pscustomobject]@{
            HostPool = New-NIC26ResourceName -Type vdpool -Purpose $realm @nameParams
            AppGroup = New-NIC26ResourceName -Type vdag -Purpose $realm @nameParams
            Group    = [string](Get-DemoConfigValue -Config $groups -Key "avd_$realm")
        }
    }
    return [pscustomobject]@{
        Workspace             = New-NIC26ResourceName -Type vdws @nameParams
        HostPoolResourceGroup = New-NIC26ResourceName -Type rg -Purpose 'avd' @nameParams
        HostsResourceGroup    = New-NIC26ResourceName -Type rg -Purpose 'avd-hosts' @nameParams
        AzlHostsResourceGroup = New-NIC26ResourceName -Type rg -Purpose 'azl' @nameParams   # Azure Local realm VMs live in the cluster resource group (owned by the Azure Local landing zone, conflict A8)
        ArcResourceGroup      = New-NIC26ResourceName -Type rg -Purpose 'avd-arc' @nameParams
        # VM resource name for a session host (computer name nic26-avd-az01 -> vm-iic-nic26-avd-az-eus-01; azl: vm-iic-nic26-avd-azl-01). Hybrid VMs are named by their computer name.
        VmName                = { param([string]$Realm, [int]$Instance) if ($Realm -eq 'azl') { New-NIC26ResourceName -Type vmazl -Purpose 'avd' -Instance $Instance @nameParams } else { New-NIC26ResourceName -Type vm -Purpose 'avd-az' -Instance $Instance @nameParams } }.GetNewClosure()
        Realms                = $realms
    }
}

function Get-DemoAzlNameSet {
    <#
    .SYNOPSIS
        Resolves the Azure Local lab names the demo scripts need from the naming standard and the config.
    .PARAMETER Config
        azure-local config (merged with shared).
    .OUTPUTS
        PSCustomObject: ClusterName, DnsZone, ClusterResourceGroup, BcdrResourceGroup, RecoveryVault, RecoveryPlan,
        KvOps, KvAzl, LogAnalyticsWorkspaceId, RemotingTarget (cluster FQDN when a DNS zone exists, else the first node).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object]$Config
    )
    $org = [string](Get-DemoConfigValue -Config $Config -Key 'org')
    $token = [string](Get-DemoConfigValue -Config $Config -Key 'token')
    $region = [string](Get-DemoConfigValue -Config $Config -Key 'location_short')
    $nameParams = @{ Org = $org; Token = $token; Region = $region }
    $clusterName = [string](Get-DemoConfigValue -Config $Config -Key 'cluster_name')
    $dnsZone = [string](Get-DemoConfigValue -Config $Config -Key 'identity.dns_zone')
    $nodes = Get-DemoNodeList -Config $Config
    $remoting = if ($dnsZone) { "$clusterName.$dnsZone" } else { $nodes[0].Name }
    return [pscustomobject]@{
        ClusterName             = $clusterName
        DnsZone                 = $dnsZone
        Nodes                   = $nodes
        RemotingTarget          = $remoting
        ClusterResourceGroup    = New-NIC26ResourceName -Type rg -Purpose 'azl' @nameParams
        BcdrResourceGroup       = New-NIC26ResourceName -Type rg -Purpose 'azl-bcdr' @nameParams
        RecoveryVault           = New-NIC26ResourceName -Type rsv -Purpose 'azl' @nameParams
        RecoveryPlan            = New-NIC26ResourceName -Type rp -Purpose 'tier1' @nameParams
        KvOps                   = New-NIC26ResourceName -Type kv -Purpose 'ops' @nameParams
        KvAzl                   = New-NIC26ResourceName -Type kv -Purpose 'azl' @nameParams
        LogAnalyticsWorkspaceId = [string](Get-DemoConfigValue -Config $Config -Key 'log_analytics_workspace_id')
    }
}

function ConvertFrom-DemoSecretRef {
    <#
    .SYNOPSIS
        Splits keyvault://<vault>/<secret> into VaultName, SecretName and BaseName (secret name without -username/-password/-secret).
    .PARAMETER Ref
        The reference.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^keyvault://[a-z0-9-]{3,24}/[A-Za-z0-9-]+$')]
        [string]$Ref
    )
    $null = $Ref -match '^keyvault://(?<vault>[a-z0-9-]{3,24})/(?<secret>[A-Za-z0-9-]+)$'
    $secretName = $Matches['secret']
    $base = $secretName -replace '-(username|password|secret|client-id)$', ''
    return [pscustomobject]@{ VaultName = $Matches['vault']; SecretName = $secretName; BaseName = $base }
}

#endregion

#region Checks / results ------------------------------------------------------------------------------------------------

function New-DemoCheck {
    <#
    .SYNOPSIS
        Builds one red/green check result row.
    .PARAMETER Section
        Grouping label (outline section or area).
    .PARAMETER Name
        Check name.
    .PARAMETER Passed
        $true green, $false red.
    .PARAMETER Detail
        Short detail (names/counts only).
    .PARAMETER Skipped
        Marks the check as not evaluated (shown as grey, does not fail the run).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure object constructor; changes no state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [bool]$Passed = $false,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Detail = '',

        [Parameter()]
        [switch]$Skipped
    )
    $status = if ($Skipped) { 'SKIP' } elseif ($Passed) { 'GREEN' } else { 'RED' }
    return [pscustomobject]@{
        Section = $Section
        Check   = $Name
        Status  = $status
        Detail  = $Detail
    }
}

function Write-DemoCheckTable {
    <#
    .SYNOPSIS
        Prints a red/green table through the screen filter and a summary line.
    .PARAMETER Check
        Rows from New-DemoCheck.
    .PARAMETER Title
        Heading.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Check,

        [Parameter()]
        [string]$Title = 'Readiness'
    )
    Write-DemoScreen -InputObject ('== {0} ==' -f $Title) -Raw
    if ($Check.Count -gt 0) {
        $Check | Format-Table -Property Section, Check, Status, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-DemoScreen
    }
    $red = @($Check | Where-Object { $_.Status -eq 'RED' }).Count
    $green = @($Check | Where-Object { $_.Status -eq 'GREEN' }).Count
    $skip = @($Check | Where-Object { $_.Status -eq 'SKIP' }).Count
    Write-DemoScreen -InputObject ('Result: {0} green, {1} red, {2} skipped -> {3}' -f $green, $red, $skip, ($(if ($red -eq 0) { 'GREEN' } else { 'RED' }))) -Raw
}

function Get-DemoCheckExitCode {
    <#
    .SYNOPSIS
        0 when no check is RED, otherwise 1.
    .PARAMETER Check
        Rows from New-DemoCheck.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]]$Check
    )
    if (@($Check | Where-Object { $_.Status -eq 'RED' }).Count -gt 0) { return 1 }
    return 0
}

#endregion

#region Fault locks -----------------------------------------------------------------------------------------------------

function Get-DemoStateRoot {
    <#
    .SYNOPSIS
        Folder on the jump server holding demo state (fault locks). $env:NIC26_DEMO_STATE_DIR overrides.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = $env:NIC26_DEMO_STATE_DIR
    if (-not $root) {
        $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }
        $root = Join-Path $base 'nic26-demo'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $root -Force
    }
    return $root
}

function Get-DemoFaultLock {
    <#
    .SYNOPSIS
        Returns the active fault locks (none = no fault in progress).
    .PARAMETER Scope
        azure-local | avd | all
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter()]
        [ValidateSet('azure-local', 'avd', 'all')]
        [string]$Scope = 'all'
    )
    $root = Get-DemoStateRoot
    $files = @(Get-ChildItem -LiteralPath $root -Filter 'fault-*.json' -File -ErrorAction SilentlyContinue)
    $locks = foreach ($f in $files) {
        $lock = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ($Scope -ne 'all' -and $lock.Scope -ne $Scope) { continue }
        $lock
    }
    return @($locks)
}

function New-DemoFaultLock {
    <#
    .SYNOPSIS
        Records that a fault is active so other fault helpers refuse to stack. Names only; no secrets.
    .PARAMETER Fault
        Drive | IntentDrift | NodePowerOff | SessionHost
    .PARAMETER Target
        Node, adapter or host name.
    .PARAMETER Scope
        azure-local | avd
    .PARAMETER Detail
        Hashtable of values needed by the Undo script (adapter name, original value, disk instance id, ...).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Drive', 'IntentDrift', 'NodePowerOff', 'SessionHost')]
        [string]$Fault,

        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [ValidateSet('azure-local', 'avd')]
        [string]$Scope,

        [Parameter()]
        [hashtable]$Detail = @{}
    )
    $lock = [pscustomobject]@{
        Fault     = $Fault
        Target    = $Target
        Scope     = $Scope
        StartedAt = [DateTime]::UtcNow.ToString('o')
        Detail    = $Detail
    }
    $path = Join-Path (Get-DemoStateRoot) ("fault-{0}.json" -f $Fault.ToLowerInvariant())
    if ($PSCmdlet.ShouldProcess($path, "Record fault lock $Fault on $Target")) {
        $lock | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
    }
    return $lock
}

function Remove-DemoFaultLock {
    <#
    .SYNOPSIS
        Clears a fault lock after the Undo completed.
    .PARAMETER Fault
        Drive | IntentDrift | NodePowerOff | SessionHost
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Drive', 'IntentDrift', 'NodePowerOff', 'SessionHost')]
        [string]$Fault
    )
    $path = Join-Path (Get-DemoStateRoot) ("fault-{0}.json" -f $Fault.ToLowerInvariant())
    if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, 'Remove fault lock')) {
        Remove-Item -LiteralPath $path -Force
    }
}

#endregion

#region Remote / device wrappers ----------------------------------------------------------------------------------------

function Invoke-DemoRemote {
    <#
    .SYNOPSIS
        PowerShell remoting wrapper (Invoke-Command over WinRM). The only way demo scripts reach a node (no RDP automation).
    .PARAMETER ComputerName
        Node or cluster name.
    .PARAMETER ScriptBlock
        Remote script.
    .PARAMETER ArgumentList
        Arguments.
    .PARAMETER Credential
        Optional credential (default: the operator's session).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList = @(),

        [Parameter()]
        [pscredential]$Credential
    )
    $params = @{ ComputerName = $ComputerName; ScriptBlock = $ScriptBlock; ErrorAction = 'Stop' }
    if ($ArgumentList.Count -gt 0) { $params['ArgumentList'] = $ArgumentList }
    if ($Credential) { $params['Credential'] = $Credential }
    return Invoke-Command @params
}

function Get-DemoClusterHealth {
    <#
    .SYNOPSIS
        Collects a normalised health snapshot of the cluster over PowerShell remoting (read-only).
    .DESCRIPTION
        Returns: ClusterName, Nodes[{Name,State}], Pool{FriendlyName,HealthStatus,OperationalStatus},
        VirtualDisks[{FriendlyName,HealthStatus,OperationalStatus,ResiliencySettingName}],
        PhysicalDisks[{FriendlyName,SerialNumber,UniqueId,HealthStatus,OperationalStatus,Usage,MediaType,Node}],
        StorageJobs[{Name,JobState,PercentComplete}], Intents[{IntentName,Host,ConfigurationStatus,ProvisioningStatus}],
        Quorum{WitnessName,WitnessState}, RdmaAdapters[{Name,Enabled,Node}], Faults[{FaultType,Severity,FaultingObjectDescription}].
    .PARAMETER ComputerName
        A node or the cluster name to run against.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )
    $remote = {
        $nodes = @(Get-ClusterNode | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = [string]$_.State } })
        $pool = Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue | Select-Object -First 1
        $vdisks = @(Get-VirtualDisk -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ FriendlyName = $_.FriendlyName; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus; ResiliencySettingName = $_.ResiliencySettingName }
            })
        $pdisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.Usage -ne 'Unknown' } | ForEach-Object {
                $owner = ($_ | Get-StorageNode -PhysicallyConnected -ErrorAction SilentlyContinue | Select-Object -First 1).Name
                [pscustomobject]@{ FriendlyName = $_.FriendlyName; SerialNumber = $_.SerialNumber; UniqueId = $_.UniqueId; HealthStatus = [string]$_.HealthStatus; OperationalStatus = [string]$_.OperationalStatus; Usage = [string]$_.Usage; MediaType = [string]$_.MediaType; Node = $owner }
            })
        $jobs = @(Get-StorageJob -ErrorAction SilentlyContinue | Where-Object { $_.JobState -ne 'Completed' } | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; JobState = [string]$_.JobState; PercentComplete = $_.PercentComplete }
            })
        $intents = @(Get-NetIntentStatus -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ IntentName = $_.IntentName; Host = $_.Host; ConfigurationStatus = [string]$_.ConfigurationStatus; ProvisioningStatus = [string]$_.ProvisioningStatus }
            })
        $quorum = Get-ClusterQuorum -ErrorAction SilentlyContinue
        $witness = if ($quorum -and $quorum.QuorumResource) { [pscustomobject]@{ WitnessName = $quorum.QuorumResource.Name; WitnessState = [string]$quorum.QuorumResource.State } } else { [pscustomobject]@{ WitnessName = ''; WitnessState = 'Unknown' } }
        $rdma = @(Get-NetAdapterRdma -ErrorAction SilentlyContinue | Where-Object Enabled | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Enabled = $_.Enabled; Node = $env:COMPUTERNAME } })
        $faults = @(Get-StorageSubSystem -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like 'Clustered*' } | Debug-StorageSubSystem -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ FaultType = $_.FaultType; Severity = [string]$_.PerceivedSeverity; FaultingObjectDescription = $_.FaultingObjectDescription }
            })
        [pscustomobject]@{
            ClusterName   = (Get-Cluster).Name
            Nodes         = $nodes
            Pool          = $(if ($pool) { [pscustomobject]@{ FriendlyName = $pool.FriendlyName; HealthStatus = [string]$pool.HealthStatus; OperationalStatus = [string]$pool.OperationalStatus } } else { $null })
            VirtualDisks  = $vdisks
            PhysicalDisks = $pdisks
            StorageJobs   = $jobs
            Intents       = $intents
            Quorum        = $witness
            RdmaAdapters  = $rdma
            Faults        = $faults
            CollectedAt   = [DateTime]::UtcNow.ToString('o')
        }
    }
    return Invoke-DemoRemote -ComputerName $ComputerName -ScriptBlock $remote
}

function Get-DemoIntentStatus {
    <#
    .SYNOPSIS
        Get-NetIntentStatus on the cluster (read-only), normalised.
    .PARAMETER ComputerName
        Node or cluster name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )
    return @(Invoke-DemoRemote -ComputerName $ComputerName -ScriptBlock {
            Get-NetIntentStatus | ForEach-Object {
                [pscustomobject]@{ IntentName = $_.IntentName; Host = $_.Host; ConfigurationStatus = [string]$_.ConfigurationStatus; ProvisioningStatus = [string]$_.ProvisioningStatus; LastUpdated = $_.LastUpdated }
            }
        })
}

function Get-DemoUpdateState {
    <#
    .SYNOPSIS
        Lifecycle Manager state (read-only): update environment, available/installed updates and recent runs.
    .PARAMETER ComputerName
        Node or cluster name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName
    )
    return Invoke-DemoRemote -ComputerName $ComputerName -ScriptBlock {
        $envState = Get-SolutionUpdateEnvironment -ErrorAction SilentlyContinue
        $updates = @(Get-SolutionUpdate -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Version = $_.Version; DisplayName = $_.DisplayName; State = [string]$_.State; HealthState = [string]$_.HealthState; InstalledDate = $_.InstalledDate }
            })
        $runs = @(Get-SolutionUpdate -ErrorAction SilentlyContinue | Get-SolutionUpdateRun -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ ResourceId = $_.ResourceId; State = [string]$_.State; TimeStarted = $_.TimeStarted; LastUpdatedTime = $_.LastUpdatedTime; Duration = $_.Duration }
            })
        [pscustomobject]@{
            CurrentVersion = $(if ($envState) { $envState.CurrentVersion } else { '' })
            State          = $(if ($envState) { [string]$envState.State } else { 'Unknown' })
            HealthState    = $(if ($envState) { [string]$envState.HealthState } else { 'Unknown' })
            LastChecked    = $(if ($envState) { $envState.LastChecked } else { $null })
            Updates        = $updates
            Runs           = $runs
        }
    }
}

function Test-DemoTcpPort {
    <#
    .SYNOPSIS
        TCP reachability with a short timeout (no ICMP dependency).
    .PARAMETER ComputerName
        Host or IP.
    .PARAMETER Port
        TCP port.
    .PARAMETER TimeoutMs
        Timeout (default 3000).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter()]
        [int]$TimeoutMs = 3000
    )
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($ComputerName, $Port)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Resolve-DemoDnsName {
    <#
    .SYNOPSIS
        Resolves a name to IPv4 addresses (strings); empty array when it does not resolve.
    .PARAMETER Name
        DNS name.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    try {
        return @([System.Net.Dns]::GetHostAddresses($Name) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
    }
    catch {
        return @()
    }
}

function Test-DemoIcmp {
    <#
    .SYNOPSIS
        ICMP echo with a short timeout (System.Net.NetworkInformation.Ping); mockable.
    .PARAMETER ComputerName
        Host or IP.
    .PARAMETER TimeoutMs
        Timeout (default 2000).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter()]
        [int]$TimeoutMs = 2000
    )
    $ping = [System.Net.NetworkInformation.Ping]::new()
    try {
        $reply = $ping.Send($ComputerName, $TimeoutMs)
        return ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    }
    catch {
        return $false
    }
    finally {
        $ping.Dispose()
    }
}

function Test-DemoPrivateAddress {
    <#
    .SYNOPSIS
        $true when the IPv4 address is RFC 1918 (private endpoint reached privately).
    .PARAMETER Address
        IPv4 string.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string]$Address
    )
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Address, [ref]$ip)) { return $false }
    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -ne 4) { return $false }
    if ($bytes[0] -eq 10) { return $true }
    if ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) { return $true }
    if ($bytes[0] -eq 192 -and $bytes[1] -eq 168) { return $true }
    return $false
}

#endregion

#region Azure wrappers --------------------------------------------------------------------------------------------------

function Test-DemoAzContext {
    <#
    .SYNOPSIS
        $true when an Az context exists (Get-AzContext); never prints the account.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) { return $false }
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    return ($null -ne $ctx -and $null -ne $ctx.Account)
}

function Get-DemoAzResourceList {
    <#
    .SYNOPSIS
        Get-AzResource wrapper (mockable) returning Name, ResourceType, ResourceGroupName, Location, Properties.
    .PARAMETER ResourceGroupName
        Resource group.
    .PARAMETER ResourceType
        Optional type filter.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter()]
        [string]$ResourceType
    )
    $params = @{ ResourceGroupName = $ResourceGroupName; ExpandProperties = $true; ErrorAction = 'Stop' }
    if ($ResourceType) { $params['ResourceType'] = $ResourceType }
    return @(Get-AzResource @params)
}

function Get-DemoArbState {
    <#
    .SYNOPSIS
        Arc Resource Bridge appliance and custom location state in the cluster resource group.
    .PARAMETER ResourceGroupName
        Cluster resource group.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )
    $appliance = @(Get-DemoAzResourceList -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ResourceConnector/appliances') | Select-Object -First 1
    $customLocation = @(Get-DemoAzResourceList -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ExtendedLocation/customLocations') | Select-Object -First 1
    $applianceStatus = if ($appliance -and $appliance.Properties) { [string](Get-DemoConfigValue -Config $appliance.Properties -Key 'status') } else { 'NotFound' }
    $clState = if ($customLocation -and $customLocation.Properties) { [string](Get-DemoConfigValue -Config $customLocation.Properties -Key 'provisioningState') } else { 'NotFound' }
    return [pscustomobject]@{
        ApplianceName       = $(if ($appliance) { $appliance.Name } else { '' })
        ApplianceStatus     = $applianceStatus
        CustomLocationName  = $(if ($customLocation) { $customLocation.Name } else { '' })
        CustomLocationState = $clState
    }
}

function Invoke-DemoLogQuery {
    <#
    .SYNOPSIS
        Runs a KQL query against the lab workspace (Invoke-AzOperationalInsightsQuery) and returns the rows.
    .PARAMETER WorkspaceId
        Workspace customer ID (GUID) or resource ID; a resource ID is resolved to the customer ID.
    .PARAMETER Query
        KQL.
    .PARAMETER TimespanHours
        Lookback (default 1).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$WorkspaceId,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter()]
        [double]$TimespanHours = 1
    )
    $customerId = $WorkspaceId
    if ($WorkspaceId -like '/subscriptions/*') {
        $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName ($WorkspaceId -split '/')[4] -Name ($WorkspaceId -split '/')[-1] -ErrorAction Stop
        $customerId = $ws.CustomerId.ToString()
    }
    $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $customerId -Query $Query -Timespan ([TimeSpan]::FromHours($TimespanHours)) -ErrorAction Stop
    return @($result.Results)
}

# --- Key Vault (names and SecureStrings only) ---

function Get-DemoVaultSecretNameList {
    <#
    .SYNOPSIS
        Lists secret NAMES in a vault (discovery step of Copy-DemoSecrets; never reads values).
    .PARAMETER VaultName
        Vault.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName
    )
    return @(Get-AzKeyVaultSecret -VaultName $VaultName -ErrorAction Stop | Select-Object -ExpandProperty Name)
}

function Get-DemoVaultSecret {
    <#
    .SYNOPSIS
        Reads one secret (SecureString + version). Returns $null when the secret does not exist.
    .PARAMETER VaultName
        Vault.
    .PARAMETER Name
        Secret name.
    .PARAMETER Version
        Optional exact version to read (verification must read the version it just wrote, not the latest).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$Name,

        [string]$Version
    )
    $secret = if ($Version) { Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -Version $Version -ErrorAction Stop } else { Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop }
    if ($null -eq $secret) { return $null }
    return [pscustomobject]@{
        Name        = $secret.Name
        Version     = $secret.Version
        SecretValue = $secret.SecretValue
        Expires     = $secret.Expires
        Tags        = $secret.Tags
    }
}

function Set-DemoVaultSecret {
    <#
    .SYNOPSIS
        Writes a secret (SecureString) with expiry and tags; returns name + version only.
    .PARAMETER VaultName
        Vault.
    .PARAMETER Name
        Secret name.
    .PARAMETER SecretValue
        SecureString value (in memory only).
    .PARAMETER Expires
        Expiry (UTC).
    .PARAMETER Tag
        Tags hashtable (the five required tags).
    .PARAMETER ContentType
        Optional content type label.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [securestring]$SecretValue,

        [Parameter(Mandatory)]
        [datetime]$Expires,

        [Parameter(Mandatory)]
        [hashtable]$Tag,

        [Parameter()]
        [string]$ContentType = 'text/plain'
    )
    if ($PSCmdlet.ShouldProcess("$VaultName/$Name", 'Set-AzKeyVaultSecret')) {
        $written = Set-AzKeyVaultSecret -VaultName $VaultName -Name $Name -SecretValue $SecretValue -Expires $Expires -Tag $Tag -ContentType $ContentType -ErrorAction Stop
        return [pscustomobject]@{ Name = $written.Name; Version = $written.Version }
    }
    return [pscustomobject]@{ Name = $Name; Version = '(whatif)' }
}

function Compare-DemoSecureString {
    <#
    .SYNOPSIS
        Compares two SecureStrings in memory and returns match ($true) / mismatch ($false). No hash or value leaves the function.
    .PARAMETER Reference
        First value.
    .PARAMETER Difference
        Second value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [securestring]$Reference,

        [Parameter(Mandatory)]
        [securestring]$Difference
    )
    $refBytes = $null
    $difBytes = $null
    $refHash = $null
    $difHash = $null
    $bstrA = [IntPtr]::Zero
    $bstrB = [IntPtr]::Zero
    try {
        $bstrA = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Reference)
        $bstrB = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Difference)
        $lenA = [System.Runtime.InteropServices.Marshal]::ReadInt32($bstrA, -4)
        $lenB = [System.Runtime.InteropServices.Marshal]::ReadInt32($bstrB, -4)
        $refBytes = [byte[]]::new($lenA)
        $difBytes = [byte[]]::new($lenB)
        [System.Runtime.InteropServices.Marshal]::Copy($bstrA, $refBytes, 0, $lenA)
        [System.Runtime.InteropServices.Marshal]::Copy($bstrB, $difBytes, 0, $lenB)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $refHash = $sha.ComputeHash($refBytes)
            $difHash = $sha.ComputeHash($difBytes)
        }
        finally {
            $sha.Dispose()
        }
        if ($lenA -ne $lenB) { return $false }
        $equal = $true
        for ($i = 0; $i -lt $refHash.Length; $i++) {
            if ($refHash[$i] -ne $difHash[$i]) { $equal = $false }
        }
        return $equal
    }
    finally {
        if ($bstrA -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrA) }
        if ($bstrB -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrB) }
        foreach ($buffer in @($refBytes, $difBytes, $refHash, $difHash)) {
            if ($null -ne $buffer) { [Array]::Clear($buffer, 0, $buffer.Length) }
        }
    }
}

function New-DemoRandomSecureString {
    <#
    .SYNOPSIS
        Generates a random value straight into a SecureString (never a managed string). Default 24 chars, all four classes.
    .PARAMETER Length
        Length (14..128).
    .PARAMETER Alphanumeric
        Letters and digits only (for usernames or systems that reject symbols).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure generator; writes nothing.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [Parameter()]
        [ValidateRange(14, 128)]
        [int]$Length = 24,

        [Parameter()]
        [switch]$Alphanumeric
    )
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!#%+-=?@_'
    $classes = if ($Alphanumeric) { @($upper, $lower, $digit) } else { @($upper, $lower, $digit, $symbol) }
    $all = -join $classes
    $chars = [char[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $byte = [byte[]]::new(4)
        $pick = {
            param([string]$Set)
            $rng.GetBytes($byte)
            $n = [BitConverter]::ToUInt32($byte, 0)
            $Set[[int]($n % $Set.Length)]
        }
        # one of each class first, then fill, then shuffle
        for ($i = 0; $i -lt $classes.Count; $i++) { $chars[$i] = & $pick $classes[$i] }
        for ($i = $classes.Count; $i -lt $Length; $i++) { $chars[$i] = & $pick $all }
        for ($i = $Length - 1; $i -gt 0; $i--) {
            $rng.GetBytes($byte)
            $j = [int]([BitConverter]::ToUInt32($byte, 0) % ($i + 1))
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
        $secure = [securestring]::new()
        foreach ($c in $chars) { $secure.AppendChar($c) }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        [Array]::Clear($chars, 0, $chars.Length)
        $rng.Dispose()
    }
}

function Get-DemoVaultCredential {
    <#
    .SYNOPSIS
        Builds a PSCredential from a <name>-username / <name>-password secret pair in the ops vault (values in memory only).
    .PARAMETER VaultName
        Ops vault.
    .PARAMETER BaseName
        Secret base name (e.g. iic-nic26-bmc-admin).
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$BaseName
    )
    Assert-DemoSecretSafeHost
    $user = Get-DemoVaultSecret -VaultName $VaultName -Name "$BaseName-username"
    $pass = Get-DemoVaultSecret -VaultName $VaultName -Name "$BaseName-password"
    if ($null -eq $user -or $null -eq $pass) { throw "Credential pair '$BaseName-username/-password' not found in vault '$VaultName'." }
    $userName = [System.Net.NetworkCredential]::new('', $user.SecretValue).Password
    return [pscredential]::new($userName, $pass.SecretValue)
}

# --- AVD / compute / Arc ---

function Get-DemoHostPool {
    <#
    .SYNOPSIS
        Get-AzWvdHostPool wrapper -> Name, Type, LoadBalancerType, MaxSessionLimit, FriendlyName.
    .PARAMETER ResourceGroupName
        Control-plane resource group.
    .PARAMETER Name
        Host pool.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $hp = Get-AzWvdHostPool -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    return [pscustomobject]@{ Name = $hp.Name; Type = [string]$hp.HostPoolType; LoadBalancerType = [string]$hp.LoadBalancerType; MaxSessionLimit = $hp.MaxSessionLimit; FriendlyName = $hp.FriendlyName }
}

function Get-DemoWorkspace {
    <#
    .SYNOPSIS
        Get-AzWvdWorkspace wrapper -> Name, FriendlyName, ApplicationGroupReference count.
    .PARAMETER ResourceGroupName
        Control-plane resource group.
    .PARAMETER Name
        Workspace.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $ws = Get-AzWvdWorkspace -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    return [pscustomobject]@{ Name = $ws.Name; FriendlyName = $ws.FriendlyName; AppGroupCount = @($ws.ApplicationGroupReference).Count }
}

function Get-DemoSessionHostList {
    <#
    .SYNOPSIS
        Get-AzWvdSessionHost wrapper -> Name (short), Status, Sessions, AllowNewSession, LastHeartBeat, ResourceId, AgentVersion.
    .PARAMETER ResourceGroupName
        Control-plane resource group.
    .PARAMETER HostPoolName
        Host pool.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName
    )
    return @(Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name            = (($_.Name -split '/')[-1] -split '\.')[0]
                FullName        = ($_.Name -split '/')[-1]
                Status          = [string]$_.Status
                Sessions        = $_.Session
                AllowNewSession = $_.AllowNewSession
                LastHeartBeat   = $_.LastHeartBeat
                ResourceId      = $_.ResourceId
                AgentVersion    = $_.AgentVersion
            }
        })
}

function Get-DemoUserSessionList {
    <#
    .SYNOPSIS
        Get-AzWvdUserSession wrapper -> UserPrincipalName, SessionHost, SessionState, HostPool.
    .PARAMETER ResourceGroupName
        Control-plane resource group.
    .PARAMETER HostPoolName
        Host pool.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$HostPoolName
    )
    return @(Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                UserPrincipalName = $_.UserPrincipalName
                SessionHost       = (($_.Name -split '/')[1] -split '\.')[0]
                SessionState      = [string]$_.SessionState
                HostPool          = $HostPoolName
            }
        })
}

function Get-DemoAzureVMPowerState {
    <#
    .SYNOPSIS
        Power state of an Azure VM (e.g. 'VM running', 'VM deallocated').
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status -ErrorAction Stop
    return [string](($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus)
}

function Stop-DemoAzureVM {
    <#
    .SYNOPSIS
        Deallocates an Azure VM (Stop-AzVM -Force).
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$Name", 'Stop-AzVM (deallocate)')) {
        $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Force -ErrorAction Stop
    }
}

function Start-DemoAzureVM {
    <#
    .SYNOPSIS
        Starts an Azure VM.
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$Name", 'Start-AzVM')) {
        $null = Start-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Stop
    }
}

function Invoke-DemoAzCli {
    <#
    .SYNOPSIS
        Azure CLI wrapper (mockable) returning parsed JSON.
    .PARAMETER Arguments
        az arguments.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )
    $output = & az @Arguments --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0]) $($Arguments[1]) failed with exit code $LASTEXITCODE." }
    if (-not $output) { return $null }
    return ($output | Out-String | ConvertFrom-Json)
}

function Get-DemoArcVMPowerState {
    <#
    .SYNOPSIS
        Power state of an Azure Local VM (az stack-hci-vm show -> properties.status.powerState).
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    $vm = Invoke-DemoAzCli -Arguments @('stack-hci-vm', 'show', '--name', $Name, '--resource-group', $ResourceGroupName)
    return [string](Get-DemoConfigValue -Config $vm -Key 'properties.status.powerState')
}

function Stop-DemoArcVM {
    <#
    .SYNOPSIS
        Stops an Azure Local VM through Arc (az stack-hci-vm stop).
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$Name", 'az stack-hci-vm stop')) {
        $null = Invoke-DemoAzCli -Arguments @('stack-hci-vm', 'stop', '--name', $Name, '--resource-group', $ResourceGroupName)
    }
}

function Start-DemoArcVM {
    <#
    .SYNOPSIS
        Starts an Azure Local VM through Arc (az stack-hci-vm start).
    .PARAMETER ResourceGroupName
        RG.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ResourceGroupName/$Name", 'az stack-hci-vm start')) {
        $null = Invoke-DemoAzCli -Arguments @('stack-hci-vm', 'start', '--name', $Name, '--resource-group', $ResourceGroupName)
    }
}

function Get-DemoClusterGroupState {
    <#
    .SYNOPSIS
        State and owner node of a clustered VM role (Get-ClusterGroup over remoting).
    .PARAMETER ComputerName
        Cluster or node.
    .PARAMETER Name
        Cluster group (VM) name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    return Invoke-DemoRemote -ComputerName $ComputerName -ArgumentList @($Name) -ScriptBlock {
        param($GroupName)
        $g = Get-ClusterGroup -Name $GroupName -ErrorAction Stop
        $vm = Get-VM -Name $GroupName -ComputerName $g.OwnerNode.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{ Name = $g.Name; State = [string]$g.State; OwnerNode = $g.OwnerNode.Name; VMState = $(if ($vm) { [string]$vm.State } else { 'Unknown' }) }
    }
}

function Stop-DemoHyperVVM {
    <#
    .SYNOPSIS
        Hard power-off of a Hyper-V VM on its owner node (Stop-VM -TurnOff -Force) - the Hybrid-realm host failure.
    .PARAMETER ComputerName
        Owner node.
    .PARAMETER Name
        VM.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ComputerName/$Name", 'Stop-VM -TurnOff')) {
        Invoke-DemoRemote -ComputerName $ComputerName -ArgumentList @($Name) -ScriptBlock {
            param($VMName)
            Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop
        }
    }
}

function Start-DemoClusterGroup {
    <#
    .SYNOPSIS
        Brings a clustered VM role online (Start-ClusterGroup) - the operator/cluster restart, not AVD.
    .PARAMETER ComputerName
        Cluster or node.
    .PARAMETER Name
        Cluster group (VM) name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$Name
    )
    if ($PSCmdlet.ShouldProcess("$ComputerName/$Name", 'Start-ClusterGroup')) {
        Invoke-DemoRemote -ComputerName $ComputerName -ArgumentList @($Name) -ScriptBlock {
            param($GroupName)
            $null = Start-ClusterGroup -Name $GroupName -ErrorAction Stop
        }
    }
}

# --- Microsoft Graph (groups) ---

function Get-DemoGroupId {
    <#
    .SYNOPSIS
        Resolves an Entra group display name to its object ID (Get-MgGroup).
    .PARAMETER DisplayName
        Group display name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )
    $group = Get-MgGroup -Filter "displayName eq '$DisplayName'" -ErrorAction Stop | Select-Object -First 1
    if (-not $group) { throw "Entra group '$DisplayName' not found." }
    return [string]$group.Id
}

function Get-DemoUserId {
    <#
    .SYNOPSIS
        Resolves a UPN to the user object ID (Get-MgUser).
    .PARAMETER UserPrincipalName
        UPN.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )
    $user = Get-MgUser -UserId $UserPrincipalName -ErrorAction Stop
    return [string]$user.Id
}

function Get-DemoGroupMemberIdList {
    <#
    .SYNOPSIS
        Member object IDs of a group (Get-MgGroupMember).
    .PARAMETER GroupId
        Group object ID.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId
    )
    return @(Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop | Select-Object -ExpandProperty Id)
}

function Add-DemoGroupMember {
    <#
    .SYNOPSIS
        Adds a user to a group (New-MgGroupMember).
    .PARAMETER GroupId
        Group object ID.
    .PARAMETER UserId
        User object ID.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,

        [Parameter(Mandatory)]
        [string]$UserId
    )
    if ($PSCmdlet.ShouldProcess($GroupId, "Add member $UserId")) {
        New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $UserId -ErrorAction Stop
    }
}

function Remove-DemoGroupMember {
    <#
    .SYNOPSIS
        Removes a user from a group (Remove-MgGroupMemberByRef).
    .PARAMETER GroupId
        Group object ID.
    .PARAMETER UserId
        User object ID.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,

        [Parameter(Mandatory)]
        [string]$UserId
    )
    if ($PSCmdlet.ShouldProcess($GroupId, "Remove member $UserId")) {
        Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $UserId -ErrorAction Stop
    }
}

function Get-DemoAppGroupAssignmentList {
    <#
    .SYNOPSIS
        UPNs holding 'Desktop Virtualization User' directly on an application group (Get-AzRoleAssignment).
    .PARAMETER ResourceGroupName
        Control-plane RG.
    .PARAMETER AppGroupName
        Application group.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$AppGroupName
    )
    return @(Get-AzRoleAssignment -ResourceGroupName $ResourceGroupName -ResourceName $AppGroupName -ResourceType 'Microsoft.DesktopVirtualization/applicationGroups' -RoleDefinitionName 'Desktop Virtualization User' -ErrorAction Stop |
            Where-Object { $_.ObjectType -eq 'User' } | Select-Object -ExpandProperty SignInName)
}

function Add-DemoAppGroupAssignment {
    <#
    .SYNOPSIS
        Grants 'Desktop Virtualization User' on an application group to a user (New-AzRoleAssignment).
    .PARAMETER ResourceGroupName
        Control-plane RG.
    .PARAMETER AppGroupName
        Application group.
    .PARAMETER UserPrincipalName
        UPN.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$AppGroupName,

        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )
    if ($PSCmdlet.ShouldProcess($AppGroupName, "Assign Desktop Virtualization User to $UserPrincipalName")) {
        $null = New-AzRoleAssignment -SignInName $UserPrincipalName -RoleDefinitionName 'Desktop Virtualization User' -ResourceGroupName $ResourceGroupName -ResourceName $AppGroupName -ResourceType 'Microsoft.DesktopVirtualization/applicationGroups' -ErrorAction Stop
    }
}

function Remove-DemoAppGroupAssignment {
    <#
    .SYNOPSIS
        Removes a user's 'Desktop Virtualization User' assignment from an application group (Remove-AzRoleAssignment).
    .PARAMETER ResourceGroupName
        Control-plane RG.
    .PARAMETER AppGroupName
        Application group.
    .PARAMETER UserPrincipalName
        UPN.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$AppGroupName,

        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )
    if ($PSCmdlet.ShouldProcess($AppGroupName, "Remove Desktop Virtualization User from $UserPrincipalName")) {
        $null = Remove-AzRoleAssignment -SignInName $UserPrincipalName -RoleDefinitionName 'Desktop Virtualization User' -ResourceGroupName $ResourceGroupName -ResourceName $AppGroupName -ResourceType 'Microsoft.DesktopVirtualization/applicationGroups' -ErrorAction Stop
    }
}

# --- Azure Files (FSLogix share, metadata only) ---

function Get-DemoFileShareItemList {
    <#
    .SYNOPSIS
        Lists files/folders under a path in an Azure Files share (metadata only; identity-based context, never a key).
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ShareName
        Share.
    .PARAMETER Path
        Folder path inside the share ('' = root).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$ShareName,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Path = ''
    )
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -EnableFileBackupRequestIntent -ErrorAction Stop
    $params = @{ ShareName = $ShareName; Context = $ctx; ErrorAction = 'Stop' }
    if ($Path) { $params['Path'] = $Path }
    $items = if ($Path) { Get-AzStorageFile @params | Get-AzStorageFile } else { Get-AzStorageFile @params }
    return @($items | ForEach-Object {
            $isDir = $_.GetType().Name -like '*Directory*'
            [pscustomobject]@{
                Name          = $_.Name
                IsDirectory   = $isDir
                Length        = $(if ($isDir) { $null } else { $_.Length })
                LastModified  = $(if ($_.PSObject.Properties['LastModified']) { $_.LastModified } else { $null })
            }
        })
}

function Get-DemoFileHandleList {
    <#
    .SYNOPSIS
        Open SMB handles under a path in the share (Get-AzStorageFileHandle) - shows a stale lock after a hard power-off.
    .PARAMETER StorageAccountName
        Storage account.
    .PARAMETER ShareName
        Share.
    .PARAMETER Path
        Folder path.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$ShareName,

        [Parameter(Mandatory)]
        [string]$Path
    )
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -EnableFileBackupRequestIntent -ErrorAction Stop
    return @(Get-AzStorageFileHandle -ShareName $ShareName -Path $Path -Recursive -Context $ctx -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Path = $_.Path; HandleId = $_.HandleId; ClientIp = $_.ClientIp; OpenTime = $_.OpenTime }
        })
}

# --- Site Recovery ---

function Get-DemoAsrState {
    <#
    .SYNOPSIS
        Replication state from the Recovery Services vault: protected items, recovery plans, recent jobs.
    .PARAMETER ResourceGroupName
        Vault RG.
    .PARAMETER VaultName
        Vault.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VaultName
    )
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction Stop
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop
    $items = foreach ($fabric in @(Get-AzRecoveryServicesAsrFabric -ErrorAction Stop)) {
        foreach ($container in @(Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabric -ErrorAction Stop)) {
            foreach ($item in @(Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $container -ErrorAction Stop)) {
                [pscustomobject]@{
                    Name               = $item.FriendlyName
                    ProtectionState    = [string]$item.ProtectionStateDescription
                    ReplicationHealth  = [string]$item.ReplicationHealth
                    ActiveLocation     = [string]$item.ActiveLocation
                    AllowedOperations  = @($item.AllowedOperations)
                    Fabric             = $fabric.FriendlyName
                    Id                 = $item.ID
                }
            }
        }
    }
    $plans = @(Get-AzRecoveryServicesAsrRecoveryPlan -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.FriendlyName; Direction = [string]$_.FailoverDeploymentModel; Id = $_.ID } })
    $jobs = @(Get-AzRecoveryServicesAsrJob -ErrorAction Stop | Sort-Object -Property StartTime -Descending | Select-Object -First 10 | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; State = [string]$_.State; StateDescription = $_.StateDescription; StartTime = $_.StartTime; EndTime = $_.EndTime; TargetObjectName = $_.TargetObjectName }
        })
    return [pscustomobject]@{ VaultName = $VaultName; ProtectedItems = @($items); RecoveryPlans = $plans; Jobs = $jobs }
}

function Start-DemoAsrPlannedFailover {
    <#
    .SYNOPSIS
        Starts a planned failover of a recovery plan (PrimaryToRecovery) and returns the job name/ID only.
    .PARAMETER ResourceGroupName
        Vault RG.
    .PARAMETER VaultName
        Vault.
    .PARAMETER RecoveryPlanName
        Recovery plan.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$RecoveryPlanName
    )
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction Stop
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop
    $plan = Get-AzRecoveryServicesAsrRecoveryPlan -FriendlyName $RecoveryPlanName -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess($RecoveryPlanName, 'Start-AzRecoveryServicesAsrPlannedFailoverJob PrimaryToRecovery')) {
        $job = Start-AzRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery -ErrorAction Stop
        return [pscustomobject]@{ JobName = $job.Name; JobId = $job.ID; State = [string]$job.State }
    }
    return [pscustomobject]@{ JobName = '(whatif)'; JobId = ''; State = 'NotStarted' }
}

function Get-DemoAsrJob {
    <#
    .SYNOPSIS
        One ASR job by name, or the most recent failover job.
    .PARAMETER ResourceGroupName
        Vault RG.
    .PARAMETER VaultName
        Vault.
    .PARAMETER JobName
        Job name (optional).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter()]
        [string]$JobName
    )
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $ResourceGroupName -Name $VaultName -ErrorAction Stop
    $null = Set-AzRecoveryServicesAsrVaultContext -Vault $vault -ErrorAction Stop
    $job = if ($JobName) {
        Get-AzRecoveryServicesAsrJob -Name $JobName -ErrorAction Stop
    }
    else {
        Get-AzRecoveryServicesAsrJob -ErrorAction Stop | Where-Object { $_.DisplayName -like '*Failover*' } | Sort-Object -Property StartTime -Descending | Select-Object -First 1
    }
    if (-not $job) { return $null }
    return [pscustomobject]@{
        Name             = $job.Name
        DisplayName      = $job.DisplayName
        State            = [string]$job.State
        StateDescription = $job.StateDescription
        StartTime        = $job.StartTime
        EndTime          = $job.EndTime
        TargetObjectName = $job.TargetObjectName
        Tasks            = @($job.Tasks | ForEach-Object { [pscustomobject]@{ Name = $_.Name; State = [string]$_.State } })
        Errors           = @($job.Errors | ForEach-Object { $_.ServiceErrorDetails.Message })
    }
}

# --- Day-2 control steps ---

function Invoke-DemoControlStep {
    <#
    .SYNOPSIS
        Runs a control's remove/apply script (another solution's script) with -Execute when requested. Mockable.
    .PARAMETER ScriptPath
        Full path of the script.
    .PARAMETER Arguments
        Hashtable of parameters to splat.
    .PARAMETER Execute
        Pass -Execute through (otherwise the target script runs in its own WhatIf default).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter()]
        [hashtable]$Arguments = @{},

        [Parameter()]
        [switch]$Execute
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "Control step script not found: $ScriptPath" }
    $splat = @{} + $Arguments
    if ($Execute) { $splat['Execute'] = $true }
    if ($PSCmdlet.ShouldProcess($ScriptPath, $(if ($Execute) { 'Run with -Execute' } else { 'Run (WhatIf)' }))) {
        return & $ScriptPath @splat
    }
}

function Wait-DemoCondition {
    <#
    .SYNOPSIS
        Polls a condition script block until it returns $true or the timeout expires (Start-DemoSleep is mockable).
    .PARAMETER Condition
        Script block returning $true when satisfied.
    .PARAMETER TimeoutMinutes
        Maximum wait.
    .PARAMETER IntervalSeconds
        Poll interval.
    .PARAMETER Activity
        Label for progress lines.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Condition,

        [Parameter()]
        [double]$TimeoutMinutes = 20,

        [Parameter()]
        [double]$IntervalSeconds = 15,

        [Parameter()]
        [string]$Activity = 'condition'
    )
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $attempt = 0
    while ($true) {
        $attempt++
        if (& $Condition) { return $true }
        if ([DateTime]::UtcNow -ge $deadline) {
            Write-Warning "Timed out after $TimeoutMinutes minute(s) waiting for $Activity."
            return $false
        }
        Write-Verbose "Waiting for $Activity (attempt $attempt)..."
        Start-DemoSleep -Seconds $IntervalSeconds
    }
}

function Start-DemoSleep {
    <#
    .SYNOPSIS
        Sleep wrapper so tests can mock waits.
    .PARAMETER Seconds
        Seconds.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Waiting changes no state; wrapper exists so Pester can mock it.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 3600)]
        [double]$Seconds
    )
    if ($Seconds -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($Seconds * 1000)) }
}

#endregion

Export-ModuleMember -Function @(
    'Add-DemoHiddenTerm', 'Add-DemoHiddenPattern', 'Get-DemoHiddenTermList', 'Clear-DemoHiddenTerm', 'Initialize-DemoScreenHygiene',
    'Hide-DemoSensitiveText', 'Write-DemoScreen', 'Write-DemoUndo', 'Write-DemoPlan',
    'Test-DemoTranscriptActive', 'Test-DemoWindowsHost', 'Assert-DemoSecretSafeHost', 'Confirm-DemoTypedPhrase',
    'Read-DemoHostLine', 'Read-DemoHostSecureLine',
    'Get-DemoConfig', 'Clear-DemoConfigCache', 'ConvertTo-DemoHashtable', 'Get-DemoConfigValue', 'Get-DemoNodeList', 'Get-DemoAvdNameSet',
    'Get-DemoAzlNameSet', 'ConvertFrom-DemoSecretRef', 'Test-DemoIcmp',
    'Get-DemoAppGroupAssignmentList', 'Add-DemoAppGroupAssignment', 'Remove-DemoAppGroupAssignment',
    'New-DemoCheck', 'Write-DemoCheckTable', 'Get-DemoCheckExitCode',
    'Get-DemoStateRoot', 'Get-DemoFaultLock', 'New-DemoFaultLock', 'Remove-DemoFaultLock',
    'Invoke-DemoRemote', 
    'Get-DemoClusterHealth', 'Get-DemoIntentStatus', 'Get-DemoUpdateState',
    'Test-DemoTcpPort', 'Resolve-DemoDnsName', 'Test-DemoPrivateAddress',
    'Test-DemoAzContext', 'Get-DemoAzResourceList', 'Get-DemoArbState', 'Invoke-DemoLogQuery',
    'Get-DemoVaultSecretNameList', 'Get-DemoVaultSecret', 'Set-DemoVaultSecret', 'Compare-DemoSecureString',
    'New-DemoRandomSecureString', 'Get-DemoVaultCredential',
    'Get-DemoHostPool', 'Get-DemoWorkspace', 'Get-DemoSessionHostList', 'Get-DemoUserSessionList',
    'Get-DemoAzureVMPowerState', 'Stop-DemoAzureVM', 'Start-DemoAzureVM',
    'Invoke-DemoAzCli', 'Get-DemoArcVMPowerState', 'Stop-DemoArcVM', 'Start-DemoArcVM',
    'Get-DemoClusterGroupState', 'Stop-DemoHyperVVM', 'Start-DemoClusterGroup',
    'Get-DemoGroupId', 'Get-DemoUserId', 'Get-DemoGroupMemberIdList', 'Add-DemoGroupMember', 'Remove-DemoGroupMember',
    'Get-DemoFileShareItemList', 'Get-DemoFileHandleList',
    'Get-DemoAsrState', 'Start-DemoAsrPlannedFailover', 'Get-DemoAsrJob',
    'Invoke-DemoControlStep', 'Wait-DemoCondition', 'Start-DemoSleep'
)
