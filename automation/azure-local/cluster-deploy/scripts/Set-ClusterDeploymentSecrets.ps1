#Requires -Version 7.0
<#
.SYNOPSIS
    Writes the two platform-mandated deployment secrets into the CLUSTER vault for the Local Identity ARM/Bicep path:
    LocalAdminCredential = base64("<user>:<password>") and WitnessStorageKey = base64("<storage key>").
.DESCRIPTION
    Design: landing-zone §5.5 / §9.1 (O3), keyvault-and-secrets.md §3 ("written by the deploy solution's script, never by
    IaC state, never printed"). The secret NAMES follow the Microsoft quickstart (create-adless-cluster-external-dns-
    public-preview): <cluster_name>-LocalAdminCredential and <cluster_name>-WitnessStorageKey, unless the inputs
    local_admin_secret_name / witness_key_secret_name override them. The IaC receives only the vault name.

    Values are resolved in memory under the OPERATOR'S OWN SIGN-IN on the Windows jump server (K-8):
      - local admin username/password: keyvault:// references in identity.local_admin_*_secret (OPS vault);
      - witness key: Get-AzStorageAccountKey on the witness account (needs Storage Account Contributor / key list right).
    Nothing is printed, logged, written to disk or returned. Start-Transcript is refused by Resolve-NIC26KeyVaultRef.
    Default is -WhatIf (prints the plan as names only); -Execute writes. Existing secrets are kept unless -Overwrite.
.PARAMETER InputFile
    terraform.generated.tfvars.json (or the example for a dry run) produced by ConvertTo-NIC26TfVars.
.PARAMETER Overwrite
    Write a new version even when the secret already exists (for example after a witness key rotation).
.PARAMETER Execute
    Perform the writes. Without it the script only reports the plan.
.EXAMPLE
    .\Set-ClusterDeploymentSecrets.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json
    .\Set-ClusterDeploymentSecrets.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -Execute
.NOTES
    Must run on the Windows jump server (SecureString is not a protection elsewhere). Requires Az.Accounts, Az.KeyVault,
    Az.Storage. The cluster vault must be reachable from here (public access Enabled during the deployment window, §5.3).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [switch]$Overwrite,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')

if (-not $Execute) { $WhatIfPreference = $true }
if (-not $IsWindows) { throw 'Refusing: this script handles secret material and must run on the Windows jump server (contract §7, K-8).' }

[void](Import-ClusterDeployAutomationModule)
$inputs = Get-ClusterDeployInputs -InputFile $InputFile
foreach ($cmd in 'Get-AzKeyVaultSecret', 'Set-AzKeyVaultSecret', 'Get-AzStorageAccountKey') {
    if (-not (Test-ClusterDeployCommand -Name $cmd)) { throw "Az cmdlet '$cmd' not available (Az.KeyVault, Az.Storage)." }
}
Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id

$clusterName = [string]$inputs.cluster_name
$vaultName = [string]$inputs.kv_azl_name
$witnessAccount = [string]$inputs.witness.storage_account_name
$witnessRg = [string]$inputs.names.rg_azl
$localAdminSecretName = if ($inputs.PSObject.Properties.Name -contains 'local_admin_secret_name' -and $inputs.local_admin_secret_name) { [string]$inputs.local_admin_secret_name } else { "$clusterName-LocalAdminCredential" }
$witnessKeySecretName = if ($inputs.PSObject.Properties.Name -contains 'witness_key_secret_name' -and $inputs.witness_key_secret_name) { [string]$inputs.witness_key_secret_name } else { "$clusterName-WitnessStorageKey" }
$usernameRef = [string]$inputs.identity.local_admin_username_secret
$passwordRef = [string]$inputs.identity.local_admin_password_secret
# org five-tag rule (owner, project, rotation-days, managed-by, lifecycle); owner and project come from the shared tags input, never invented here
$sharedTags = if ($inputs.PSObject.Properties.Name -contains 'tags' -and $inputs.tags) { $inputs.tags } else { $null }
foreach ($required in 'owner', 'project') {
    if ($null -eq $sharedTags -or -not ($sharedTags.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace([string]$sharedTags.$required)) { throw "Input tag '$required' is missing; it is required on every Key Vault secret." }
}
$tags = @{ owner = [string]$sharedTags.owner; project = [string]$sharedTags.project; 'rotation-days' = '90'; 'managed-by' = 'script'; lifecycle = 'temporary'; purpose = 'azure-local-deployment'; source = 'Set-ClusterDeploymentSecrets' }
$expires = (Get-Date).ToUniversalTime().AddDays(90)   # lab lifetime (keyvault-and-secrets.md §6)

function Get-ClusterDeploySecretOrNull {
    # Fail closed: only a confirmed not-found counts as absent. Throttling, 403, firewall or transport errors stop the run instead of authorising a write.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VaultName, [Parameter(Mandatory)][string]$Name)
    try { return (Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop) }
    catch {
        $text = (@($_.Exception.Message, $_.FullyQualifiedErrorId) -join ' ')
        if ($text -notmatch '(?i)forbidden|\b403\b|unauthori[sz]ed|\b401\b' -and $text -match '(?i)SecretNotFound|was not found|\bNotFound\b|\b404\b') { return $null }
        throw "Cannot read secret '$Name' in vault '$VaultName' (not a not-found): $(($_.Exception.Message -replace '\s+', ' ').Substring(0, [Math]::Min(160, ($_.Exception.Message -replace '\s+', ' ').Length)))"
    }
}

$plan = foreach ($item in @(
        @{ Name = $localAdminSecretName; Ece = 'LocalAdminCredential'; Source = "ops vault refs $usernameRef + <password ref>" }
        @{ Name = $witnessKeySecretName; Ece = 'WitnessStorageKey'; Source = "storage key of $witnessAccount (rg $witnessRg)" }
    )) {
    $existing = Get-ClusterDeploySecretOrNull -VaultName $vaultName -Name $item.Name
    [pscustomobject]@{
        Vault      = $vaultName
        SecretName = $item.Name
        EceName    = $item.Ece
        Source     = $item.Source
        Exists     = [bool]$existing
        Action     = if ($existing -and -not $Overwrite) { 'keep' } else { 'write' }
    }
}
$plan | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

$pending = @($plan | Where-Object { $_.Action -eq 'write' })
if ($pending.Count -eq 0) { Write-ClusterDeployLog -Message 'Both deployment secrets exist; nothing to do (use -Overwrite to rotate).'; return $plan | Select-Object Vault, SecretName, EceName, Exists, Action }
if (-not $Execute) {
    Write-Warning "WhatIf (default): $($pending.Count) secret(s) would be written to '$vaultName' (names above). Re-run with -Execute on the jump server."
    return $plan | Select-Object Vault, SecretName, EceName, Exists, Action
}

function ConvertTo-ClusterDeploySecureString {
    # Internal: builds a SecureString character by character from an in-memory string (no plaintext cmdlet parameter).
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)][string]$Text)
    $ss = [securestring]::new()
    foreach ($ch in $Text.ToCharArray()) { $ss.AppendChar($ch) }
    $ss.MakeReadOnly()
    return $ss
}

function Set-ClusterDeploySecretValue {
    # Internal: writes one secret; the plaintext lives in local variables only and is cleared on exit.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][securestring]$Value,
        [Parameter(Mandatory)][hashtable]$Tag,
        [Parameter(Mandatory)][datetime]$Expires
    )
    if ($PSCmdlet.ShouldProcess("$VaultName/$Name", 'Set-AzKeyVaultSecret (value never displayed)')) {
        $result = Invoke-NIC26WithRetry -Activity "write secret '$Name'" -MaxMinutes 5 -ScriptBlock {
            Set-AzKeyVaultSecret -VaultName $VaultName -Name $Name -SecretValue $Value -ContentType 'base64' -Tag $Tag -Expires $Expires
        }
        Write-ClusterDeployLog -Message "Wrote '$Name' to '$VaultName' (version $($result.Version); value not logged)."
    }
}

try {
    foreach ($p in $pending) {
        $secure = $null
        try {
            if ($p.EceName -eq 'LocalAdminCredential') {
                $user = Resolve-NIC26KeyVaultRef -Ref $usernameRef -AsPlainText
                $pass = Resolve-NIC26KeyVaultRef -Ref $passwordRef -AsPlainText
                if ([string]::IsNullOrEmpty($user) -or [string]::IsNullOrEmpty($pass)) { throw 'The local administrator username or password reference resolved to nothing; fix the ops-vault secrets first.' }
                if ($user.Contains(':')) { throw 'The local administrator username contains a colon, which is ambiguous in the base64(user:password) format; choose another username.' }
                if ($pass.Length -lt 14) { throw 'The local administrator password is shorter than 14 characters (Local Identity prerequisite). Fix the ops-vault secret first.' }
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:${pass}"))
                $secure = ConvertTo-ClusterDeploySecureString -Text $encoded
                $pass = $null; $encoded = $null
            }
            else {
                $keys = Invoke-NIC26WithRetry -Activity "list keys of '$witnessAccount'" -MaxMinutes 5 -ScriptBlock { Get-AzStorageAccountKey -ResourceGroupName $witnessRg -Name $witnessAccount }
                $key1 = @($keys | Where-Object { $_.KeyName -eq 'key1' } | Select-Object -First 1)
                if ($key1.Count -eq 0) { throw "Storage account '$witnessAccount' returned no key1." }
                $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$key1[0].Value))
                $secure = ConvertTo-ClusterDeploySecureString -Text $encoded
                $keys = $null; $key1 = $null; $encoded = $null
            }
            Set-ClusterDeploySecretValue -VaultName $vaultName -Name $p.SecretName -Value $secure -Tag $tags -Expires $expires
        }
        finally {
            if ($secure) { $secure.Dispose() }
            [GC]::Collect()
        }
    }
}
finally {
    Remove-Variable -Name user, pass, encoded, keys, key1, secure -ErrorAction SilentlyContinue
}

# Verify by existence and version only (never by value).
$verified = foreach ($p in $plan) {
    $s = Get-ClusterDeploySecretOrNull -VaultName $vaultName -Name $p.SecretName
    [pscustomobject]@{ Vault = $vaultName; SecretName = $p.SecretName; EceName = $p.EceName; Exists = [bool]$s; Version = if ($s) { $s.Version } else { $null }; Expires = if ($s) { $s.Expires } else { $null } }
}
if (@($verified | Where-Object { -not $_.Exists }).Count -gt 0) { throw "Verification failed: not present after the write: $((@($verified | Where-Object { -not $_.Exists }).SecretName) -join ', ')." }
$verified | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
return $verified
