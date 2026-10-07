function Assert-NIC26AzContext {
    <#
    .SYNOPSIS
        Ensures Az.Accounts / Az.KeyVault are available and an Az context (Connect-AzAccount) exists; throws otherwise.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    foreach ($moduleName in @('Az.Accounts', 'Az.KeyVault')) {
        if (-not (Get-Module -Name $moduleName)) {
            $null = Import-Module -Name $moduleName -ErrorAction SilentlyContinue -PassThru
        }
    }
    if (-not (Get-Command -Name 'Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue)) {
        throw 'Az.KeyVault is required: Install-PSResource Az.KeyVault -Scope CurrentUser (Az.Accounts is installed with it).'
    }
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if ($null -eq $context -or $null -eq $context.Account) {
        throw 'No Azure context. Sign in first with Connect-AzAccount (your own account; the resolver uses the current context only).'
    }
}
