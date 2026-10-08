#Requires -Version 7.0
<#
.SYNOPSIS
    Orchestrates the Azure Local landing zone stages S-1..S9 (design §10.2) for the Bicep or the Terraform track.
.DESCRIPTION
    DEFAULT IS WHAT-IF. Every stage prints what it would do (Bicep what-if / terraform plan / script plan) and changes
    nothing. -Execute is required to change anything; S-1 additionally requires -ConfirmDeleteList (owner-approved).
    Stages:
      S-1 Decommission previous deployment  -> Remove-PreviousAzureLocalDeployment.ps1 (never in the default stage set)
      S0  Bootstrap                          -> Register-LzProviders.ps1, New-LzEntraGroups.ps1, bicep/bootstrap.bicep (both tools)
      S1..S7 IaC                             -> one subscription deployment (Bicep) or one root module (Terraform) with
                                                enabled_stages filtered to the requested stages; S1 also runs bicep/initiative.bicep
                                                at management-group scope (Bicep tool) when management_group_id is set
      S8  Secret seeding and lock-down       -> prints the Copy-DemoSecrets.ps1 instruction (runs on the jump server under the
                                                operator's sign-in), then re-applies S3 with kv_public_network_access.ops = Disabled
                                                once Test-LandingZone -Checks dns-vault -ExpectDnsPrivate passes
      S9  Validation                         -> Test-LandingZone.ps1 (read-only)
    Configuration flow (contract §3): Get-NIC26Config -Scope azure-local -> ConvertTo-NIC26BicepParam / ConvertTo-NIC26TfVars.
    SECRETS: the jump-server local-admin credential (S7) is resolved from the ops vault by Resolve-NIC26KeyVaultRef or, on the
    first run, generated in memory and written to the ops vault by THIS script (never by IaC), then handed to the deployment
    as a secure parameter (Bicep: SecureString dynamic parameter; Terraform: TF_VAR_* in the child process environment).
    No value is printed, logged or written to disk; Start-Transcript is refused. S7 with -Execute runs on Windows only
    (SecureString/DPAPI; K-8) - in practice on the jump server for every stage after S7.
.PARAMETER Tool
    Bicep (demo path) or Terraform (parity path).
.PARAMETER Stage
    Stages to run, in order. Default: S0..S9. S-1 must be requested explicitly.
.PARAMETER Execute
    Change Azure. Without it every stage is what-if/plan only.
.PARAMETER ConfirmDeleteList
    Owner-approved JSON list for S-1 (passed through to Remove-PreviousAzureLocalDeployment.ps1).
.PARAMETER Config
    Canonical config object; defaults to Get-NIC26Config -Scope azure-local.
.PARAMETER ParameterFile
    Override the generated parameter file (main.generated.bicepparam / terraform.generated.tfvars.json). Used by tests.
.PARAMETER BackendConfig
    Terraform: path to the backend config file from environment/ (never committed). Required for Terraform with -Execute.
.EXAMPLE
    ./Invoke-LzAzureLocalDeploy.ps1                                   # what-if of S0..S9 with Bicep
    ./Invoke-LzAzureLocalDeploy.ps1 -Tool Terraform -Stage S1,S2 -BackendConfig ../../environment/azure-local/tf-backend.hcl
    ./Invoke-LzAzureLocalDeploy.ps1 -Stage S1,S2,S3,S4 -Execute
    ./Invoke-LzAzureLocalDeploy.ps1 -Stage S-1 -Execute -ConfirmDeleteList ./approved.json
.NOTES
    Requires: Az.Accounts, Az.Resources, Az.KeyVault, NIC26.Automation (shared module), az CLI with Bicep, terraform >= 1.11.
    Owner approval is required before any -Execute run (contract §7).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Bicep', 'Terraform')] [string] $Tool = 'Bicep',
    [ValidateSet('S-1', 'S0', 'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'S9')] [string[]] $Stage = @('S0', 'S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7', 'S8', 'S9'),
    [switch] $Execute,
    [string] $ConfirmDeleteList,
    [object] $Config,
    [string] $ParameterFile,
    [string] $BackendConfig,
    [string] $JumpAdminUsername = 'jumpadmin'   # local-admin user created on the jump server; not Administrator (management-plane 1.5)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ((Get-Command Get-Variable).Module -and (Get-Variable -Name Transcript -ErrorAction SilentlyContinue)) { throw 'Start-Transcript is forbidden around secret handling (contract §3).' }

$solutionRoot = Split-Path -Parent $PSScriptRoot
$bicepDir = Join-Path $solutionRoot 'bicep'
$tfDir = Join-Path $solutionRoot 'terraform'
$iacStages = @('S1', 'S2', 'S3', 'S4', 'S5', 'S6', 'S7')
$mode = $Execute ? 'EXECUTE' : 'WHAT-IF'
Write-Information "Azure Local landing zone - tool=$Tool mode=$mode stages=$($Stage -join ',')" -InformationAction Continue

if (-not $Config) { $Config = Get-NIC26Config -Scope 'azure-local' }
# Get-NIC26Config returns { scope, sources, shared, azure_local, values }; the stages read the flat values. Tests pass a flat config.
$fullConfig = $Config
if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('values')) { $Config = $Config['values'] }
$externalJump = @{}
foreach ($key in @('external_jump_vm_id', 'external_jump_subnet_id')) {
    $present = ($Config -is [System.Collections.IDictionary]) ? $Config.Contains($key) : ($null -ne $Config.PSObject.Properties[$key])
    if ($present) { $externalJump[$key] = [string]$Config.$key }
}
if ($externalJump.Count -gt 0) {
    if ($externalJump.Count -ne 2 -or
        $externalJump.external_jump_vm_id -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/virtualMachines/[^/]+$' -or
        $externalJump.external_jump_subnet_id -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+/subnets/[^/]+$') {
        throw 'External jump requires a valid VM/subnet resource-ID pair.'
    }
    $terraformApply = $Tool -eq 'Terraform' -and (@($Stage | Where-Object { $_ -in $iacStages -or $_ -eq 'S8' }).Count -gt 0)
    if ($Execute -and ('S7' -in $Stage -or 'S-1' -in $Stage -or $terraformApply)) {
        throw 'External jump configured: source S7, S-1 and Terraform apply are unavailable until deployment ownership is reconciled; preserve rollback VM/disks.'
    }
    if ($Tool -eq 'Terraform') { Write-Warning 'External jump configured: this Terraform plan is diagnostic only; deployment ownership is unresolved and apply is refused by this orchestrator.' }
}
# The flat values carry no resolved names; the converters resolve them from the solution's manifest. Tests pass a config that already has them.
$hasNames = ($Config -is [System.Collections.IDictionary]) ? $Config.Contains('names') : ($null -ne $Config.PSObject.Properties['names'])
$names = if ($hasNames) { $Config.names } else {
    & (Get-Module NIC26.Automation) { param($root, $cfg) (Resolve-NIC26SolutionInputs -Manifest (Get-NIC26SolutionManifest -Path $root) -Config $cfg).names } $solutionRoot $fullConfig
}
if (-not $hasNames -and $Config -is [System.Collections.IDictionary]) { $Config['names'] = $names }   # child scripts (Initialize-LzPim.ps1) read Config.names
$sub = [string] $Config.subscription_id

function Assert-LzContext {
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
    if ($ctx.Subscription.Id -ne $sub) { $null = Set-AzContext -WhatIf:$false -Tenant ([string]$Config.tenant_id) -SubscriptionId $sub }
    if ($ctx.Tenant.Id -ne [string]$Config.tenant_id) { throw 'Az context tenant does not match Config.tenant_id.' }
}

function Get-LzParameterFile {
    if ($ParameterFile) { return $ParameterFile }
    if ($Tool -eq 'Bicep') { return (ConvertTo-NIC26BicepParam -Solution $solutionRoot -Config $Config -Execute).FullName }
    return (ConvertTo-NIC26TfVars -Solution $solutionRoot -Config $Config -Execute).FullName
}

function Get-LzJumpCredential {
    <# Returns @{ Username = SecureString; Password = SecureString } without ever materialising the values in logs.
       Reads the ops vault secrets by reference; generates and stores the password on first -Execute of S7. #>
    if (-not $IsWindows) { throw 'S7 handles the jump-server credential and must run on Windows (the jump server or a Windows operator host), K-8.' }
    $userRef = [string] $Config.jump_admin_username_secret
    $pwdRef = [string] $Config.jump_admin_password_secret
    $user = try { Resolve-NIC26KeyVaultRef -Ref $userRef } catch { $null }
    $pwd = try { Resolve-NIC26KeyVaultRef -Ref $pwdRef } catch { $null }
    if (-not $user -or -not $pwd) {
        if (-not $Execute) { Write-Information 'S7: jump credential not yet in the ops vault; it would be generated and stored on -Execute.' -InformationAction Continue; return $null }
        $vaultName = ($pwdRef -replace '^keyvault://', '') -split '/' | Select-Object -First 1
        $secretName = ($pwdRef -replace '^keyvault://', '') -split '/' | Select-Object -Last 1
        $userSecretName = ($userRef -replace '^keyvault://', '') -split '/' | Select-Object -Last 1
        # 24 characters from a CSPRNG, four character classes guaranteed; appended straight into a SecureString so no
        # plaintext string object is ever created (PSAvoidUsingConvertToSecureStringWithPlainText).
        $alphabet = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+-=?'
        $pwd = [securestring]::new()
        foreach ($seed in [char[]]'aZ7!') { $pwd.AppendChar($seed) }
        for ($i = 0; $i -lt 20; $i++) { $pwd.AppendChar($alphabet[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]) }
        $pwd.MakeReadOnly()
        $user = [securestring]::new()   # deliberately not 'Administrator' (management-plane §1.5); a username, not a secret
        $jumpUser = $JumpAdminUsername
        foreach ($c in [char[]]$jumpUser) { $user.AppendChar($c) }
        $user.MakeReadOnly()
        $expires = (Get-Date).ToUniversalTime().AddDays(90)
        $tags = @{ owner = [string]$Config.tags.owner; project = [string]$Config.tags.project; 'rotation-days' = '90'; 'managed-by' = 'script'; lifecycle = 'temporary' }
        if ($PSCmdlet.ShouldProcess("$vaultName/$secretName", 'Generate and store jump local-admin credential (values never shown)')) {
            Invoke-NIC26WithRetry -ScriptBlock {
                $null = Set-AzKeyVaultSecret -VaultName $vaultName -Name $userSecretName -SecretValue $user -Expires $expires -Tag $tags -ContentType 'username'
                $null = Set-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -SecretValue $pwd -Expires $expires -Tag $tags -ContentType 'password'
            } -MaxMinutes 5 -Activity 'write jump credential to the ops vault'
        }
    }
    return @{ Username = $user; Password = $pwd }
}

function Invoke-LzBicep {
    param([string[]] $EnabledStages, [hashtable] $Overrides = @{})
    $paramFile = Get-LzParameterFile
    $jsonParams = Join-Path ([System.IO.Path]::GetTempPath()) "lz-azl-$([guid]::NewGuid()).parameters.json"
    try {
        $null = az bicep build-params --file $paramFile --outfile $jsonParams
        if ($LASTEXITCODE -ne 0) { throw 'az bicep build-params failed' }
        # The compiled template is about 2 MB compact (inlined AVM modules); New-AzSubscriptionDeployment refuses it with RequestContentTooLarge, so the shared REST helper sends it.
        $armParameters = @{ enabled_stages = $EnabledStages }
        foreach ($k in $Overrides.Keys) { $armParameters[$k] = $Overrides[$k] }
        if ('S7' -in $EnabledStages -and [bool]$Config.enable_jump_server) {
            $cred = Get-LzJumpCredential
            if ($cred) { $armParameters['jump_admin_username'] = $cred.Username; $armParameters['jump_admin_password'] = $cred.Password }
        }
        $deployArgs = @{
            SubscriptionId     = $sub
            Name               = [string] $names.deployment_name
            Location           = [string] $Config.location
            TemplateFile       = Join-Path $bicepDir 'main.bicep'
            ParameterFile      = $jsonParams
            ParameterOverrides = $armParameters
        }
        if (-not $Execute) {
            Write-Information "Bicep what-if: stages $($EnabledStages -join ',')" -InformationAction Continue
            return (Invoke-NIC26ArmDeployment @deployArgs -Preview)
        }
        if ($PSCmdlet.ShouldProcess("subscription $sub", "Deploy $($names.deployment_name) [$($EnabledStages -join ',')]")) {
            return (Invoke-NIC26ArmDeployment @deployArgs)
        }
    }
    finally {
        if (Test-Path $jsonParams) { Remove-Item $jsonParams -Force }
        if (Get-Variable -Name cred -ErrorAction SilentlyContinue) { $cred = $null }
    }
}

function Invoke-LzBicepInitiative {
    if (-not [string]$Config.management_group_id) { Write-Warning 'S1: management_group_id is empty, so the hybrid-baseline initiative is NOT created and the Day-2 policy beat (outline 3.5) has nothing to assign. Set management_group_id to the management group that holds the landing zones.'; return }
    $splat = @{
        Name              = "$($names.deployment_name)-init"
        ManagementGroupId = [string] $Config.management_group_id
        Location          = [string] $Config.location
        TemplateFile      = Join-Path $bicepDir 'initiative.bicep'
        names                = $names
        locationFromTemplate = [string] $Config.location   # Az suffixes template params that collide with cmdlet params
        subscription_id      = $sub
    }
    if (-not $Execute) { return (New-AzManagementGroupDeployment @splat -WhatIf) }
    if ($PSCmdlet.ShouldProcess("management group $($Config.management_group_id)", 'New-AzManagementGroupDeployment initiative.bicep')) { return (New-AzManagementGroupDeployment @splat) }
}

function Invoke-LzBootstrap {
    $splat = @{
        Name         = "$($names.deployment_name)-bootstrap"
        Location     = [string] $Config.location
        TemplateFile = Join-Path $bicepDir 'bootstrap.bicep'
        names                = $names
        locationFromTemplate = [string] $Config.location
        tags                 = $Config.tags
    }
    if (-not $Execute) { return (New-AzSubscriptionDeployment @splat -WhatIf) }
    if ($PSCmdlet.ShouldProcess("subscription $sub", 'New-AzSubscriptionDeployment bootstrap.bicep (rg_sec + tfstate storage)')) { return (New-AzSubscriptionDeployment @splat) }
}

function Invoke-LzTerraform {
    param([string[]] $EnabledStages, [hashtable] $Overrides = @{})
    $varFile = Get-LzParameterFile
    $initArgs = @('init', '-input=false', '-no-color')
    $initArgs += $BackendConfig ? @("-backend-config=$BackendConfig") : @('-backend=false')
    if (-not $BackendConfig -and $Execute) { throw 'Terraform -Execute needs -BackendConfig (remote state in st_tfstate; contract §3).' }
    Push-Location $tfDir
    $envSet = @()
    try {
        & terraform @initArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'terraform init failed' }
        $varArgs = @("-var-file=$varFile", "-var=enabled_stages=$($EnabledStages | ConvertTo-Json -Compress)")
        foreach ($k in $Overrides.Keys) { $varArgs += "-var=$k=$($Overrides[$k] | ConvertTo-Json -Compress)" }
        if ('S7' -in $EnabledStages -and [bool]$Config.enable_jump_server) {
            $cred = Get-LzJumpCredential
            if ($cred) {
                # Process-environment only; ephemeral variables -> azapi sensitive_body (write-only). Cleared in finally.
                $env:TF_VAR_jump_admin_username = [System.Net.NetworkCredential]::new('', $cred.Username).Password
                $env:TF_VAR_jump_admin_password = [System.Net.NetworkCredential]::new('', $cred.Password).Password
                $envSet = @('TF_VAR_jump_admin_username', 'TF_VAR_jump_admin_password')
            }
        }
        if (-not $Execute) {
            Write-Information "terraform plan: stages $($EnabledStages -join ',')" -InformationAction Continue
            & terraform plan -input=false -no-color -lock=false @varArgs
            if ($LASTEXITCODE -ne 0) { throw 'terraform plan failed' }
            return
        }
        if ($PSCmdlet.ShouldProcess("subscription $sub", "terraform apply [$($EnabledStages -join ',')]")) {
            & terraform apply -input=false -no-color -auto-approve @varArgs
            if ($LASTEXITCODE -ne 0) { throw 'terraform apply failed' }
        }
    }
    finally {
        foreach ($e in $envSet) { Remove-Item "Env:$e" -ErrorAction SilentlyContinue }
        Pop-Location
    }
}

function Invoke-LzIaC {
    param([string[]] $EnabledStages, [hashtable] $Overrides = @{})
    if ($Tool -eq 'Bicep') { return (Invoke-LzBicep -EnabledStages $EnabledStages -Overrides $Overrides) }
    return (Invoke-LzTerraform -EnabledStages $EnabledStages -Overrides $Overrides)
}

# ------------------------------------------------------------------ run
Assert-LzContext
$requestedIaC = @($Stage | Where-Object { $_ -in $iacStages })
$results = [ordered]@{}

foreach ($s in $Stage) {
    switch ($s) {
        'S-1' {
            $splat = @{ SubscriptionId = $sub }
            if ($Execute) {
                if (-not $ConfirmDeleteList) { throw 'S-1 with -Execute requires -ConfirmDeleteList (owner-approved list).' }
                $splat.Execute = $true; $splat.ConfirmDeleteList = $ConfirmDeleteList
            }
            $results['S-1'] = & (Join-Path $PSScriptRoot 'Remove-PreviousAzureLocalDeployment.ps1') @splat
        }
        'S0' {
            $results['S0.providers'] = & (Join-Path $PSScriptRoot 'Register-LzProviders.ps1') -SubscriptionId $sub -Execute:$Execute
            $results['S0.groups'] = & (Join-Path $PSScriptRoot 'New-LzEntraGroups.ps1') -SolutionPath $solutionRoot -Execute:$Execute
            $results['S0.bootstrap'] = Invoke-LzBootstrap
            Write-Information 'S0 manual: PIM role settings (8 h, MFA, justification) in the portal; then Initialize-LzPim.ps1 after S3.' -InformationAction Continue
        }
        { $_ -in $iacStages } {
            # One IaC run for all requested IaC stages (dependency order is inside the template/root module).
            if (-not $results.Contains('IaC')) {
                # defender_servers_plan is shared with the Day-2 defender control, which applies it live in the demo (outline 3.5) and
                # whose Remove forces it off. A landing-zone build with a plan other than off applies it now and the beat is lost.
                if ('S1' -in $requestedIaC -and [string]$Config.defender_servers_plan -notin @('', 'off')) {
                    Write-Warning "S1 will set Defender for Servers to '$($Config.defender_servers_plan)' now. For the demo build run S1 with defender_servers_plan = off and let the Day-2 defender control apply the plan live."
                }
                $results['IaC'] = Invoke-LzIaC -EnabledStages $requestedIaC
                # The baseline initiative is a management-group item: the owner of the management group assigns it once (design/azure-local/landing-zone-placement.md).
                if ('S1' -in $requestedIaC -and $Tool -eq 'Bicep' -and [bool]$Config.deploy_platform_scope_items) { $results['S1.initiative'] = Invoke-LzBicepInitiative }
                if ('S3' -in $requestedIaC -and -not [bool]$Config.manage_pim_in_iac) {
                    $results['S3.pim'] = & (Join-Path $PSScriptRoot 'Initialize-LzPim.ps1') -Config $Config -Execute:$Execute
                }
            }
        }
        'S8' {
            if (-not [bool]$Config.enable_private_endpoints) { Write-Information 'S8 lock-down not applicable: private endpoints are not used (D-029); the vaults stay on their public endpoints (RBAC only).' -InformationAction Continue; $results['S8'] = 'skipped (D-029)'; break }
            $dns = & (Join-Path $PSScriptRoot 'Test-LandingZone.ps1') -Config $Config -Checks 'dns-vault' -ExpectDnsPrivate
            if ($LASTEXITCODE -ne 0) { Write-Warning 'S8 lock-down skipped: the vault names do not resolve to the private endpoints from here yet (design §10.2 S8 precondition).'; $results['S8'] = $dns; break }
            $pna = @{ ops = 'Disabled'; azl = [string]$Config.kv_public_network_access.azl }
            Write-Information 'S8: re-applying S3 with kv_public_network_access.ops = Disabled (cluster vault unchanged until the deploy solution post-step).' -InformationAction Continue
            $results['S8'] = Invoke-LzIaC -EnabledStages @('S3') -Overrides @{ kv_public_network_access = $pna }
        }
        'S9' {
            $results['S9'] = & (Join-Path $PSScriptRoot 'Test-LandingZone.ps1') -Config $Config
            $results['S9.exitcode'] = $LASTEXITCODE
        }
    }
}

if (-not $Execute) { Write-Warning 'WHAT-IF run complete: nothing was changed. Re-run with -Execute (owner approval required) to apply.' }
return [pscustomobject]$results
