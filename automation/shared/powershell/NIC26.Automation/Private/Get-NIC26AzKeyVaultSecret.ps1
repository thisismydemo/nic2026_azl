function Get-NIC26AzKeyVaultSecret {
    <#
    .SYNOPSIS
        Thin wrapper over Get-AzKeyVaultSecret so tests can mock Az.KeyVault without importing it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return Get-AzKeyVaultSecret -VaultName $VaultName -Name $Name -ErrorAction Stop
}
