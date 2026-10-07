#Requires -Version 7.0
<#
.SYNOPSIS
    Post-deployment step of design §5.3 (phase flag): disables public network access on the CLUSTER vault once the
    private path (private endpoint over the S2S VPN + DNS on the domain controllers) is proven; -Mode Enable is the
    documented break-glass that re-opens it.
.DESCRIPTION
    Checks first, changes second (default -WhatIf):
      1. The vault FQDN resolves from THIS host (the jump server) to the private endpoint IP (RFC 1918).
      2. Optionally the same resolution from a node (WinRM, credential resolved in memory) — the nodes are the consumer
         that matters (Key Vault backup extension; alert KeyVaultAccess).
      3. With -Execute: Update-AzKeyVault -PublicNetworkAccess Disabled|Enabled, then waits (bounded) for the
         AzureEdgeAKVBackupForWindows extension on every node to report Succeeded.
    Nothing is printed except names, IPs and states. Idempotent: no change when the vault is already in the target state.
.PARAMETER InputFile
    terraform.generated.tfvars.json (or the example file for a dry run).
.PARAMETER Mode
    Disable (default, the post-deployment target) or Enable (break-glass; also the state required during Validate/Deploy).
.PARAMETER CheckFromNode
    Also resolve the vault name from the first node over WinRM.
.PARAMETER Execute
    Apply the change. Without it only the checks and the plan run.
.EXAMPLE
    .\Set-ClusterVaultPublicAccess.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -CheckFromNode
    .\Set-ClusterVaultPublicAccess.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -CheckFromNode -Execute
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [ValidateSet('Disable', 'Enable')][string]$Mode = 'Disable',
    [switch]$CheckFromNode,
    [int]$ExtensionWaitMinutes = 10,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')
if (-not $Execute) { $WhatIfPreference = $true }

[void](Import-ClusterDeployAutomationModule)
$inputs = Get-ClusterDeployInputs -InputFile $InputFile
Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
$vaultName = [string]$inputs.kv_azl_name
$vaultFqdn = "$vaultName.vault.azure.net"
$target = if ($Mode -eq 'Disable') { 'Disabled' } else { 'Enabled' }

# Owner decision D-029: no private endpoints, so the cluster vault must stay on its public endpoint.
$privateEndpoints = $false
if ($inputs -is [System.Collections.IDictionary]) { if ($inputs.Contains('enable_private_endpoints')) { $privateEndpoints = [bool]$inputs['enable_private_endpoints'] } }
elseif ($inputs.PSObject.Properties['enable_private_endpoints']) { $privateEndpoints = [bool]$inputs.enable_private_endpoints }
if ($Mode -eq 'Disable' -and -not $privateEndpoints) {
    throw 'Refusing to disable public access on the cluster vault: private endpoints are not used (D-029), so the nodes and the Key Vault backup extension need the public endpoint.'
}

function Test-PrivateIPv4 {
    param([Parameter(Mandatory)][string]$Ip)
    return ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or $Ip -match '^172\.(1[6-9]|2\d|3[01])\.')
}

$vault = Get-AzKeyVault -VaultName $vaultName
if (-not $vault) { throw "Vault '$vaultName' not found in subscription $($inputs.subscription_id)." }
$current = $vault.PublicNetworkAccess
Write-ClusterDeployLog -Message "Vault '$vaultName' public network access: current=$current target=$target"

# 1. DNS from this host
$localIps = @()
try { $localIps = @(Resolve-DnsName -Name $vaultFqdn -Type A -ErrorAction Stop | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress) } catch { Write-Warning "Resolve-DnsName $vaultFqdn failed here: $($_.Exception.Message)" }
$localPrivate = ($localIps.Count -gt 0) -and -not @($localIps | Where-Object { -not (Test-PrivateIPv4 -Ip $_) }).Count
Write-ClusterDeployLog -Message "DNS from this host: $vaultFqdn -> $($localIps -join ',') (private=$localPrivate)"

# 2. DNS from a node (the consumer that matters)
$nodePrivate = $null
if ($CheckFromNode) {
    try {
        if (-not $IsWindows) { throw 'node check needs the Windows jump server' }
        $user = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_username_secret -AsPlainText
        $pass = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_password_secret
        $cred = [pscredential]::new($user, $pass)
        $nodeIps = @(Invoke-Command -ComputerName ([string]$inputs.nodes[0].management_ip) -Credential $cred -Authentication Negotiate -ArgumentList $vaultFqdn -ScriptBlock { param($f) (Resolve-DnsName -Name $f -Type A | Where-Object { $_.Type -eq 'A' }).IPAddress })
        Remove-Variable -Name user, pass, cred -ErrorAction SilentlyContinue
        $nodePrivate = ($nodeIps.Count -gt 0) -and -not @($nodeIps | Where-Object { -not (Test-PrivateIPv4 -Ip $_) }).Count
        Write-ClusterDeployLog -Message "DNS from node $($inputs.nodes[0].name): $vaultFqdn -> $($nodeIps -join ',') (private=$nodePrivate)"
    }
    catch { Write-Warning "Node DNS check failed: $($_.Exception.Message)"; $nodePrivate = $false }
}

$plan = [pscustomobject]@{
    Vault             = $vaultName
    CurrentAccess     = $current
    TargetAccess      = $target
    LocalDnsPrivate   = $localPrivate
    NodeDnsPrivate    = $nodePrivate
    ChangeNeeded      = ($current -ne $target)
    SafeToDisable     = ($Mode -eq 'Enable') -or ($localPrivate -and ($nodePrivate -ne $false))
}
$plan | Format-List | Out-String | Write-Information -InformationAction Continue

if (-not $plan.ChangeNeeded) { Write-ClusterDeployLog -Message "Vault already '$target'; nothing to do."; return $plan }
if ($Mode -eq 'Disable' -and -not $plan.SafeToDisable) {
    throw "Refusing to disable public access: the vault name does not resolve privately from every checked location (design §4.5: conditional forwarder for vault.azure.net -> 168.63.129.16 on every DNS server the rack uses; acceptance test A4). Fix DNS first."
}
if (-not $Execute) { Write-Warning "WhatIf (default): would set PublicNetworkAccess=$target on '$vaultName'. Re-run with -Execute."; return $plan }

if ($PSCmdlet.ShouldProcess("Key Vault $vaultName", "Set PublicNetworkAccess = $target")) {
    $null = Invoke-NIC26WithRetry -Activity 'Update-AzKeyVault' -MaxMinutes 5 -ScriptBlock { Update-AzKeyVault -VaultName $vaultName -ResourceGroupName $vault.ResourceGroupName -PublicNetworkAccess $target }
    Write-ClusterDeployLog -Message "Vault '$vaultName' PublicNetworkAccess set to $target."

    # 3. Watch the Key Vault backup extension on every node (alert KeyVaultAccess is the platform signal; this is the fast check).
    $deadline = (Get-Date).AddMinutes($ExtensionWaitMinutes)
    do {
        $states = foreach ($n in $inputs.nodes) {
            $r = Invoke-AzRestMethod -Path "/subscriptions/$($inputs.subscription_id)/resourceGroups/$($inputs.names.rg_azl)/providers/Microsoft.HybridCompute/machines/$($n.name)/extensions/AzureEdgeAKVBackupForWindows?api-version=2024-07-10" -Method GET
            $st = if ($r.StatusCode -eq 200) { ($r.Content | ConvertFrom-Json).properties.provisioningState } else { "HTTP $($r.StatusCode)" }
            [pscustomobject]@{ Node = $n.name; Extension = 'AzureEdgeAKVBackupForWindows'; State = $st }
        }
        $pending = @($states | Where-Object { $_.State -ne 'Succeeded' })
        if ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 60 }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    $states | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
    if ($pending.Count -gt 0) { Write-Warning "Key Vault backup extension not Succeeded on: $(($pending | ForEach-Object Node) -join ', '). Break-glass: re-run with -Mode Enable -Execute." }
}
return $plan
