@{
    RootModule        = 'DemoCommon.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7f3b2c1e-5a4d-4e8f-9c0b-1d2e3f4a5b6c'
    Author            = 'NIC 2026 lab'
    CompanyName       = 'IIC'
    Copyright         = '(c) 2026 NIC 2026 lab. MIT.'
    Description       = 'NIC 2026 demo support: screen-hygiene filter, safety guards, fault locks and mockable wrappers for the demo scripts (automation/demo).'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
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
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('NIC2026', 'demo', 'AzureLocal', 'AVD')
            ProjectUri = 'https://github.com/thisismydemo'
        }
    }
}
