@{
    RootModule           = 'NIC26.Automation.psm1'
    ModuleVersion        = '0.1.0'
    CompatiblePSEditions = @('Core')
    GUID                 = '3f1c8b7e-6a2d-4c5e-9b1a-0d2e4f6a8c10'
    Author               = 'NIC 2026 lab'
    CompanyName          = 'Infinite Improbability Corp (IIC)'
    Copyright            = '(c) 2026 NIC 2026 lab. MIT.'
    Description          = 'Shared automation for the NIC 2026 lab: environment config loader with JSON Schema validation, naming-standard generator, Bicep/Terraform/Ansible input converters, Key Vault reference resolver, bounded retry and logging.'
    PowerShellVersion    = '7.4'
    FunctionsToExport    = @(
        'ConvertTo-NIC26AnsibleVars'
        'ConvertTo-NIC26BicepParam'
        'ConvertTo-NIC26TfVars'
        'Get-NIC26Config'
        'Get-NIC26SolutionManifest'
        'Invoke-NIC26ArmDeployment'
        'Invoke-NIC26WithRetry'
        'New-NIC26ResourceName'
        'Resolve-NIC26KeyVaultRef'
        'Test-NIC26ResourceName'
        'Write-NIC26Log'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('NIC26', 'AzureLocal', 'AVD', 'Bicep', 'Terraform', 'Naming')
            ProjectUri   = 'https://github.com/thisismydemo'
            ReleaseNotes = 'Initial shared foundation. Requires the powershell-yaml module (Install-PSResource powershell-yaml -Scope CurrentUser). Az.KeyVault is needed only by Resolve-NIC26KeyVaultRef.'
        }
    }
}
