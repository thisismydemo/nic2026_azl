function Resolve-NIC26KeyVaultRef {
    <#
    .SYNOPSIS
        Resolves a keyvault://<vault>/<secret> reference to its value under the current Az context.
    .DESCRIPTION
        Reads the secret with Az.KeyVault (Get-AzKeyVaultSecret) using the operator's own sign-in. Returns a
        SecureString by default (-AsPlainText returns the string for APIs that need it). The value is never logged
        and never written to disk. The function refuses to run while a transcript (Start-Transcript) is active, and
        retries RBAC-propagation / throttling errors with Invoke-NIC26WithRetry (bounded, 5 minutes by default).
        SecureString is not a protection on non-Windows hosts: run on the Windows jump server (CONTRACT.md section 7).
    .PARAMETER Ref
        Reference in the form keyvault://<vault-name>/<secret-name>.
    .PARAMETER AsPlainText
        Return the plain string instead of a SecureString. Keep it in memory only.
    .PARAMETER MaxMinutes
        Retry budget for RBAC propagation (default 5).
    .EXAMPLE
        $secure = Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password'
    .OUTPUTS
        System.Security.SecureString or System.String (with -AsPlainText)
    #>
    [CmdletBinding()]
    [OutputType([securestring], [string])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidatePattern('^keyvault://[a-z0-9-]{3,24}/[A-Za-z0-9-]+$')]
        [string]$Ref,

        [Parameter()]
        [switch]$AsPlainText,

        [Parameter()]
        [ValidateRange(0, 60)]
        [double]$MaxMinutes = 5
    )

    process {
        if (Test-NIC26TranscriptActive) {
            throw 'Refusing to resolve a Key Vault reference while a PowerShell transcript is active (Start-Transcript). Run Stop-Transcript and retry; secret values must never reach a transcript.'
        }
        if (-not $IsWindows) {
            Write-Warning 'SecureString offers no memory protection on this platform. Resolve secrets on the Windows jump server (design/shared/keyvault-and-secrets.md K-8).'
        }

        $null = $Ref -match '^keyvault://(?<vault>[a-z0-9-]{3,24})/(?<secret>[A-Za-z0-9-]+)$'
        $vaultName = $Matches['vault']
        $secretName = $Matches['secret']

        Assert-NIC26AzContext

        Write-NIC26Log -Message "Resolving Key Vault reference vault='$vaultName' secret='$secretName' (value is never logged)" -Level Verbose
        $secret = Invoke-NIC26WithRetry -Activity "read secret '$secretName' from '$vaultName'" -MaxMinutes $MaxMinutes -ScriptBlock {
            Get-NIC26AzKeyVaultSecret -VaultName $vaultName -Name $secretName
        }

        if ($null -eq $secret -or $null -eq $secret.SecretValue) {
            throw "Secret '$secretName' was not found in vault '$vaultName' (or the caller has no read access)."
        }

        if ($AsPlainText) {
            return (ConvertFrom-SecureString -SecureString $secret.SecretValue -AsPlainText)
        }
        return $secret.SecretValue
    }
}
