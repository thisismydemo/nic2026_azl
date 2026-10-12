#Requires -Version 7.0
#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Deploys and reads back the security baseline for the landing-zone subscriptions: Microsoft Sentinel workspace and
    security DCR (bicep/workspace.bicep), Defender for Cloud plans and the Azure Policy set (bicep/subscription.bicep, once
    per subscription), the Microsoft Entra ID diagnostic setting, the content hub solutions and starter analytics rules,
    and the policy remediation tasks. Default is what-if / plan only; -Execute changes Azure. Rerunnable (every step is
    an idempotent PUT or a deployment of the same template).
.DESCRIPTION
    Design: design/shared/security-operations.md. Inputs: environment/shared/environment.yml (subscriptions, location,
    tags) and environment/shared/security/security.yml (schema automation/shared/schemas/security.environment.schema.json).
    Stages run in order: Workspace, Subscriptions, Entra, Content, Remediate, ReadBack. -Stage picks a subset.
    Never prints a secret (there are none in these inputs).
.PARAMETER EnvironmentPath
    Folder that holds environment.yml and security\security.yml (default: <repo>/environment/shared).
.PARAMETER Stage
    One or more of Workspace, Subscriptions, Entra, Content, Remediate, ReadBack. Default: all.
.PARAMETER StartComplianceScan
    Start an on-demand compliance evaluation per subscription after the Subscriptions stage (runs in the background).
.EXAMPLE
    ./Invoke-SecurityBaseline.ps1                                     # what-if for every stage that supports it
    ./Invoke-SecurityBaseline.ps1 -Execute -StartComplianceScan       # deploy everything
    ./Invoke-SecurityBaseline.ps1 -Stage ReadBack                     # read-only state report (JSON + table)
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$EnvironmentPath,
    [ValidateSet('Workspace', 'Subscriptions', 'Entra', 'Content', 'Remediate', 'ReadBack')][string[]]$Stage = @('Workspace', 'Subscriptions', 'Entra', 'Content', 'Remediate', 'ReadBack'),
    [switch]$StartComplianceScan,
    [string]$ReadBackPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo = (Resolve-Path (Join-Path $root '..\..\..')).Path
if (-not $EnvironmentPath) { $EnvironmentPath = Join-Path $repo 'environment\shared' }
$sentinelApi = '2024-09-01'

function Write-Step([string]$Message) { Write-Information -MessageData "[security] $Message" -InformationAction Continue }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    $out = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az $($Arguments[0..2] -join ' ') failed: $($out | Out-String)" }
    if ($Json) { return (($out | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json -Depth 50) }
    return $out
}

function Invoke-Arm {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('GET', 'PUT', 'DELETE', 'POST')][string]$Method = 'GET', [object]$Body, [switch]$AllowNotFound)
    $p = @{ Path = $Path; Method = $Method }
    if ($null -ne $Body) { $p.Payload = ($Body | ConvertTo-Json -Depth 50 -Compress) }
    $r = Invoke-AzRestMethod @p
    if ($r.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($r.StatusCode -ge 400) { throw "$Method $Path -> HTTP $($r.StatusCode): $($r.Content)" }
    if ([string]::IsNullOrWhiteSpace($r.Content)) { return $null }
    return ($r.Content | ConvertFrom-Json -Depth 50)
}

function Select-LiteralValue([object]$Node) {
    # Content-hub templates write some rule properties as ARM expressions (e.g. "[variables('TemplateEmptyArray')]").
    # A direct REST PUT cannot evaluate them, so such keys are dropped (the service then applies its defaults).
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in @($Node.Keys)) {
            $v = $Node[$key]
            if ($v -is [string] -and $v -match '^\[.*\]$') { $Node.Remove($key) } else { $Node[$key] = Select-LiteralValue $v }
        }
        return $Node
    }
    if ($Node -is [System.Collections.IList] -and $Node -isnot [string]) { return , @($Node | ForEach-Object { Select-LiteralValue $_ }) }
    return $Node
}

function Write-ParameterFile([hashtable]$Values, [string]$Name) {
    $doc = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = [ordered]@{} }
    foreach ($k in $Values.Keys) { $doc.parameters[$k] = @{ value = $Values[$k] } }
    $file = Join-Path ([IO.Path]::GetTempPath()) "nic26-security-$Name.parameters.json"
    $doc | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding utf8NoBOM
    return $file
}

# ------------------------------------------------------------------ inputs
$sharedFile = Join-Path $EnvironmentPath 'environment.yml'
$secFile = Join-Path $EnvironmentPath 'security\security.yml'   # own folder: Get-NIC26Config merges every *.yml directly in environment/shared
foreach ($f in $sharedFile, $secFile) { if (-not (Test-Path -LiteralPath $f)) { throw "Missing input file $f (copy the example from automation/shared/examples)." } }
$shared = Get-Content -LiteralPath $sharedFile -Raw | ConvertFrom-Yaml
$sec = Get-Content -LiteralPath $secFile -Raw | ConvertFrom-Yaml
$schema = Join-Path $repo 'automation\shared\schemas\security.environment.schema.json'
if (-not (($sec | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
    ($sec | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile $schema | Out-Null   # rethrows the validation detail
    throw "security.yml does not match $schema"
}

$location = [string]$shared.location
$subs = [ordered]@{}
foreach ($k in $sec.subscription_keys) {
    if (-not $shared.subscriptions.ContainsKey($k)) { throw "subscription key '$k' is not in environment.yml subscriptions." }
    $subs[$k] = [string]$shared.subscriptions[$k]
}
$wsSub = [string]$shared.subscriptions[$sec.workspace.subscription_key]
$wsRg = [string]$sec.workspace.resource_group_name
$wsName = [string]$sec.workspace.name
$workspaceId = "/subscriptions/$wsSub/resourceGroups/$wsRg/providers/Microsoft.OperationalInsights/workspaces/$wsName"
$dcrId = "/subscriptions/$wsSub/resourceGroups/$wsRg/providers/Microsoft.Insights/dataCollectionRules/$($sec.dcr.name)"
$tags = @{}
foreach ($t in $shared.tags.Keys) { $tags[$t] = [string]$shared.tags[$t] }
foreach ($t in $sec.tags.Keys) { $tags[$t] = [string]$sec.tags[$t] }
$policy = $sec.policy
$excludedRgs = @(if ($policy.ContainsKey('remediation_excluded_resource_groups')) { $policy.remediation_excluded_resource_groups } else { @() })
$holdVmIds = @(if ($policy.ContainsKey('ama_remediation_hold_vm_ids')) { $policy.ama_remediation_hold_vm_ids } else { @() })
$exemptIds = @(if ($policy.ContainsKey('ama_exempt_machine_ids')) { $policy.ama_exempt_machine_ids } else { @() })
$mode = if ($Execute) { 'create' } else { 'what-if' }
if (-not $Execute) { Write-Warning 'What-if (default): nothing is changed. Re-run with -Execute to deploy.' }

# ------------------------------------------------------------------ Workspace (Sentinel + DCR + associations)
if ($Stage -contains 'Workspace') {
    Write-Step "Workspace: $wsName in $wsRg ($mode)"
    $pf = Write-ParameterFile -Name 'workspace' -Values @{
        location                     = $location
        workspaceName                = $wsName
        retentionInDays              = [int]$sec.workspace.retention_days
        dailyQuotaGb                 = [int]$sec.workspace.daily_cap_gb
        dcrName                      = [string]$sec.dcr.name
        dcrAssociationName           = [string]$sec.dcr.association_name
        machineResourceIds           = @($sec.dcr.machine_resource_ids)
        defenderAlertSubscriptionIds = @($subs.Values)
        actionGroupId                = [string]($sec.workspace.action_group_id ?? '')
        alertNamePrefix              = [string]$sec.workspace.alert_name_prefix
        tags                         = $tags
    }
    if ($mode -eq 'create' -and -not $PSCmdlet.ShouldProcess("$wsRg/$wsName", 'deploy workspace.bicep')) { return }
    $wsArgs = @('deployment', 'group', $mode, '--subscription', $wsSub, '--resource-group', $wsRg, '--name', 'dep-nic26-sec-workspace',
        '--template-file', (Join-Path $root 'bicep\workspace.bicep'), '--parameters', "@$pf", '--only-show-errors')
    # First run on a new workspace: Sentinel creates the SecurityEvent table asynchronously after onboarding, so the DCR
    # can fail with InvalidOutputTable once; the deployment is idempotent and is retried.
    for ($attempt = 1; ; $attempt++) {
        try { $o = Invoke-Az -Arguments $wsArgs; if ($mode -eq 'what-if') { $o | Write-Output }; Write-Step "Workspace stage $mode succeeded (attempt $attempt)"; break }
        catch {
            if ($attempt -ge 4 -or $_.Exception.Message -notmatch 'InvalidOutputTable') { throw }
            Write-Step 'SecurityEvent table not ready yet (Sentinel onboarding is asynchronous); retrying in 60 s'
            Start-Sleep -Seconds 60
        }
    }
}

# ------------------------------------------------------------------ Subscriptions (Defender + Policy + exemptions)
if ($Stage -contains 'Subscriptions') {
    foreach ($k in $subs.Keys) {
        $sid = $subs[$k]
        Write-Step "Subscription $k ($mode): Defender plans, policy assignments, exemptions"
        $pf = Write-ParameterFile -Name "sub-$k" -Values @{
            location                      = $location
            assignmentPrefix              = [string]$policy.assignment_prefix
            exemptionPrefix               = [string]$policy.exemption_prefix
            enableDefenderCspm            = [bool]$sec.defender.cspm
            defenderServersPlan           = [string]$sec.defender.servers_plan
            enableDefenderStorage         = [bool]$sec.defender.storage
            storageMalwareScanCapGb       = [int]($sec.defender.storage_malware_scan_cap_gb ?? 100)
            enableDefenderKeyVault        = [bool]$sec.defender.keyvault
            enableDefenderArm             = [bool]$sec.defender.arm
            enableAgentlessVmScanning     = [bool]($sec.defender.agentless_vm_scanning ?? $true)
            enableFileIntegrityMonitoring = [bool]($sec.defender.file_integrity_monitoring ?? $true)
            allowedLocations              = @($policy.allowed_locations)
            allowedLocationsEffect        = [string]$policy.allowed_locations_effect
            requiredResourceGroupTag      = [string]$policy.required_resource_group_tag
            inheritTags                   = @($policy.inherit_tags)
            workspaceId                   = $workspaceId
            dcrId                         = $dcrId
            amaExemptMachineIds           = @($exemptIds | Where-Object { $_ -like "/subscriptions/$sid/*" })
        }
        if ($mode -eq 'create' -and -not $PSCmdlet.ShouldProcess("subscription $k", 'deploy subscription.bicep')) { continue }
        Invoke-Az -Arguments @('deployment', 'sub', $mode, '--subscription', $sid, '--location', $location, '--name', 'dep-nic26-sec-baseline',
            '--template-file', (Join-Path $root 'bicep\subscription.bicep'), '--parameters', "@$pf", '--only-show-errors') | Write-Output
        if ($Execute -and $StartComplianceScan) {
            $null = Set-AzContext -Subscription $sid -WhatIf:$false
            Start-AzPolicyComplianceScan -AsJob | Out-Null
            Write-Step "Compliance scan started for $k (background; evaluation is not instant)."
        }
    }
}

# ------------------------------------------------------------------ Entra ID diagnostic setting (tenant scope)
if ($Stage -contains 'Entra') {
    $name = [string]$sec.sentinel.entra_diagnostic_setting_name
    $path = "/providers/microsoft.aadiam/diagnosticSettings/$($name)?api-version=2017-04-01-preview"
    $body = @{ properties = @{ workspaceId = $workspaceId; logs = @($sec.sentinel.entra_log_categories | ForEach-Object { @{ category = $_; enabled = $true } }) } }
    if ($Execute) {
        if ($PSCmdlet.ShouldProcess("Entra ID diagnostic setting $name", 'PUT')) { $null = Invoke-Arm -Path $path -Method PUT -Body $body; Write-Step "Entra ID diagnostic setting $name -> $wsName" }
    }
    else { Write-Step "What-if: PUT Entra ID diagnostic setting $name with $(@($sec.sentinel.entra_log_categories).Count) categories -> $wsName" }
}

# ------------------------------------------------------------------ Content hub solutions + starter analytics rules
if ($Stage -contains 'Content') {
    $si = "/subscriptions/$wsSub/resourceGroups/$wsRg/providers/Microsoft.OperationalInsights/workspaces/$wsName/providers/Microsoft.SecurityInsights"
    $catalog = @((Invoke-Arm -Path "$si/contentProductPackages?api-version=$sentinelApi").value)
    $installed = @((Invoke-Arm -Path "$si/contentPackages?api-version=$sentinelApi").value)
    foreach ($sol in $sec.sentinel.content_hub_solutions) {
        $pkg = $catalog | Where-Object { $_.properties.displayName -eq $sol -and $_.properties.contentKind -eq 'Solution' } | Select-Object -First 1
        if (-not $pkg) { Write-Warning "Content hub solution not found: $sol"; continue }
        $have = $installed | Where-Object { $_.properties.contentId -eq $pkg.properties.contentId -and $_.properties.version -eq $pkg.properties.version }
        if ($have) { Write-Step "Solution present: $sol $($pkg.properties.version)"; continue }
        if (-not $Execute) { Write-Step "What-if: install solution $sol $($pkg.properties.version)"; continue }
        if (-not $PSCmdlet.ShouldProcess($sol, 'install content hub solution')) { continue }
        # Learn (Sentinel REST): the package's packagedContent is an ARM template; deploying it installs the solution.
        $full = Invoke-Arm -Path "$si/contentProductPackages/$($pkg.name)?api-version=$sentinelApi&`$expand=properties/packagedContent"
        $tf = Join-Path ([IO.Path]::GetTempPath()) "nic26-sec-solution-$($pkg.name).json"
        $full.properties.packagedContent | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $tf -Encoding utf8NoBOM
        $tplParams = @($full.properties.packagedContent.parameters.PSObject.Properties.Name)
        $args2 = @('deployment', 'group', 'create', '--subscription', $wsSub, '--resource-group', $wsRg, '--name', ("dep-nic26-sec-sol-" + ($pkg.name -replace '[^A-Za-z0-9-]', '').Substring(0, [Math]::Min(40, ($pkg.name -replace '[^A-Za-z0-9-]', '').Length))), '--template-file', $tf, '--only-show-errors')
        if ($tplParams -contains 'workspace') { $args2 += @('--parameters', "workspace=$wsName") }
        if ($tplParams -contains 'workspace-location') { $args2 += @('--parameters', "workspace-location=$location") }
        Invoke-Az -Arguments $args2 | Out-Null
        Write-Step "Installed solution $sol $($pkg.properties.version)"
    }
    # Analytics rules: create each wanted rule once from its template (idempotent: rule name = guid of the template id).
    $templates = @((Invoke-Arm -Path "$si/contentTemplates?api-version=$sentinelApi&`$filter=(properties/contentKind eq 'AnalyticsRule')").value)
    $existing = @((Invoke-Arm -Path "$si/alertRules?api-version=$sentinelApi").value)
    foreach ($ruleName in $sec.sentinel.analytics_rules) {
        $tpl = $templates | Where-Object { $_.properties.displayName -eq $ruleName } | Sort-Object { [version]($_.properties.version -replace '[^0-9.]', '') } -Descending | Select-Object -First 1
        if (-not $tpl) { Write-Warning "Analytics rule template not found in installed solutions: $ruleName"; continue }
        $already = $existing | Where-Object { ($_.properties.PSObject.Properties.Name -contains 'alertRuleTemplateName') -and $_.properties.alertRuleTemplateName -eq $tpl.properties.contentId }
        if ($already) { Write-Step "Rule present: $ruleName"; continue }
        if (-not $Execute) { Write-Step "What-if: create analytics rule $ruleName"; continue }
        $tfull = Invoke-Arm -Path "$si/contentTemplates/$($tpl.name)?api-version=$sentinelApi&`$expand=properties/mainTemplate"
        $res = @($tfull.properties.mainTemplate.resources) | Where-Object { $_.type -match '(alertRules|AlertRuleTemplates)$' } | Select-Object -First 1
        if (-not $res) { Write-Warning "Template $ruleName has no alertRules resource"; continue }
        $props = Select-LiteralValue ($res.properties | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable)
        foreach ($drop in 'requiredDataConnectors', 'version', 'status', 'lastUpdatedDateUTC', 'createdDateUTC', 'alertRulesCreatedByTemplateCount') { $props.Remove($drop) }
        if ($res.kind -eq 'Scheduled') {
            if (-not $props.ContainsKey('suppressionDuration')) { $props.suppressionDuration = 'PT5H' }
            if (-not $props.ContainsKey('suppressionEnabled')) { $props.suppressionEnabled = $false }
        }
        $props.enabled = $true
        $props.alertRuleTemplateName = $tpl.properties.contentId
        $props.templateVersion = $tpl.properties.version
        $ruleId = [guid]::new(([Security.Cryptography.MD5]::HashData([Text.Encoding]::UTF8.GetBytes("$workspaceId|$($tpl.properties.contentId)")))).ToString()
        if ($PSCmdlet.ShouldProcess($ruleName, 'create analytics rule')) {
            try { $null = Invoke-Arm -Path "$si/alertRules/$($ruleId)?api-version=2025-09-01" -Method PUT -Body @{ kind = $res.kind; properties = $props }; Write-Step "Created rule: $ruleName" }
            catch { Write-Warning "Rule $ruleName not created: $((($_.Exception.Message -replace '\s+',' ') -replace '^.*?HTTP','HTTP'))" }
        }
    }
}

# ------------------------------------------------------------------ Remediation tasks (Modify / DeployIfNotExists)
if ($Stage -contains 'Remediate') {
    foreach ($k in $subs.Keys) {
        $sid = $subs[$k]
        $null = Set-AzContext -Subscription $sid -WhatIf:$false
        $asgs = @(Get-AzPolicyAssignment -Scope "/subscriptions/$sid" | Where-Object { $_.Name -like "$($policy.assignment_prefix)-*" -and $_.IdentityType -eq 'SystemAssigned' })
        foreach ($a in $asgs) {
            # Remediate only where the assignment reports non-compliant resources (no empty tasks); excluded resource
            # groups and held VMs are skipped. Run again after the compliance scan when nothing is evaluated yet.
            $nc = @(Get-AzPolicyState -SubscriptionId $sid -Filter "PolicyAssignmentName eq '$($a.Name)' and ComplianceState eq 'NonCompliant'" -ErrorAction SilentlyContinue)
            if ($a.Name -like '*-ama-vm') { $nc = @($nc | Where-Object { $holdVmIds -notcontains $_.ResourceId }) }
            $isSubLevel = $a.Name -like '*-activity-log'
            $targets = @(if ($isSubLevel) { if ($nc.Count -gt 0) { '' } } else { $nc | ForEach-Object { $_.ResourceGroup } | Where-Object { $_ -and $excludedRgs -notcontains $_ } | Sort-Object -Unique })
            if ($targets.Count -eq 0) { Write-Step "Nothing to remediate (or not evaluated yet): $($a.Name) in $k"; continue }
            foreach ($rg in $targets) {
                $scopeLabel = if ($rg) { $rg } else { "subscription $k" }
                $remName = "rem-$($a.Name)-$(Get-Date -Format 'yyyyMMddHHmm')"
                if ($remName.Length -gt 64) { $remName = $remName.Substring(0, 64) }
                if (-not $Execute) { Write-Step "What-if: remediation $($a.Name) at $scopeLabel"; continue }
                if (-not $PSCmdlet.ShouldProcess("$($a.Name) at $scopeLabel", 'Start-AzPolicyRemediation')) { continue }
                $p = @{ Name = $remName; PolicyAssignmentId = $a.Id; AsJob = $true }
                if ($rg) { $p.ResourceGroupName = $rg; $p.ResourceDiscoveryMode = 'ReEvaluateCompliance' } else { $p.Scope = "/subscriptions/$sid" }
                Start-AzPolicyRemediation @p | Out-Null
                Write-Step "Remediation started: $($a.Name) at $scopeLabel"
            }
        }
    }
}

# ------------------------------------------------------------------ Read back
if ($Stage -contains 'ReadBack') {
    $report = [ordered]@{ checkedAt = (Get-Date).ToUniversalTime().ToString('o'); subscriptions = [ordered]@{}; workspace = [ordered]@{} }
    foreach ($k in $subs.Keys) {
        $sid = $subs[$k]
        $pr = @((Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Security/pricings?api-version=2024-01-01").value | Where-Object { $_.properties.pricingTier -eq 'Standard' } |
                ForEach-Object { [ordered]@{ plan = $_.name; subPlan = ($_.properties.PSObject.Properties.Name -contains 'subPlan') ? $_.properties.subPlan : ''; extensions = @(if ($_.properties.PSObject.Properties.Name -contains 'extensions') { $_.properties.extensions | Where-Object { $_.isEnabled -eq 'True' } | ForEach-Object name }) } })
        $asg = @((Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Authorization/policyAssignments?api-version=2025-01-01&`$filter=atScope()").value |
                ForEach-Object { [ordered]@{ name = $_.name; enforcement = $_.properties.enforcementMode; identity = if ($_.PSObject.Properties.Name -contains 'identity' -and $_.identity) { $_.identity.type } else { 'None' } } })
        $null = Set-AzContext -Subscription $sid -WhatIf:$false
        $summary = Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01" -Method POST
        $compliance = @(if ($summary -and $summary.value) { $summary.value[0].policyAssignments | Where-Object { $_.policyAssignmentId -match "/$([regex]::Escape($policy.assignment_prefix))-|securitycenterbuiltin" } | ForEach-Object { [ordered]@{ assignment = ($_.policyAssignmentId -split '/')[-1]; nonCompliantResources = $_.results.nonCompliantResources } } })
        $exm = @((Invoke-Arm -Path "/subscriptions/$sid/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview&`$filter=atScope()" -AllowNotFound)?.value | ForEach-Object { $_.name })
        $exmBelow = @(Get-AzPolicyExemption -IncludeDescendent -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$($policy.exemption_prefix)-*" } | ForEach-Object Name)
        $report.subscriptions[$k] = [ordered]@{ defenderPlans = $pr; policyAssignments = $asg; compliance = $compliance; exemptions = @($exm + $exmBelow | Select-Object -Unique) }
    }
    $null = Set-AzContext -Subscription $wsSub -WhatIf:$false
    $ws = Invoke-Arm -Path "$($workspaceId)?api-version=2023-09-01" -AllowNotFound
    if ($ws) {
        $si = "$workspaceId/providers/Microsoft.SecurityInsights"
        $report.workspace = [ordered]@{
            name           = $ws.name
            retentionDays  = $ws.properties.retentionInDays
            dailyCapGb     = $ws.properties.workspaceCapping.dailyQuotaGb
            tags           = $ws.tags
            sentinel       = [bool](Invoke-Arm -Path "$si/onboardingStates/default?api-version=$sentinelApi" -AllowNotFound)
            dataConnectors = @((Invoke-Arm -Path "$si/dataConnectors?api-version=$sentinelApi").value | ForEach-Object { "$($_.kind)" })
            solutions      = @((Invoke-Arm -Path "$si/contentPackages?api-version=$sentinelApi").value | ForEach-Object { "$($_.properties.displayName) $($_.properties.version)" })
            analyticsRules = @((Invoke-Arm -Path "$si/alertRules?api-version=$sentinelApi").value | ForEach-Object { "$($_.kind): $($_.properties.displayName) (enabled=$($_.properties.enabled))" })
            dcr            = [bool](Invoke-Arm -Path "$($dcrId)?api-version=2023-03-11" -AllowNotFound)
            dcrAssociations = @((Invoke-Arm -Path "$dcrId/associations?api-version=2023-03-11" -AllowNotFound)?.value | ForEach-Object { ($_.id -split '/providers/Microsoft.Insights/')[0] -split '/' | Select-Object -Last 1 })
            entraDiagnostic = [bool](Invoke-Arm -Path "/providers/microsoft.aadiam/diagnosticSettings/$($sec.sentinel.entra_diagnostic_setting_name)?api-version=2017-04-01-preview" -AllowNotFound)
        }
    }
    $json = $report | ConvertTo-Json -Depth 20
    if ($ReadBackPath) { $json | Set-Content -LiteralPath $ReadBackPath -Encoding utf8NoBOM; Write-Step "Read-back written to $ReadBackPath" }
    $json
}
