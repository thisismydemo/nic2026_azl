#Requires -Version 7.0
# Pester 5 - the Recovery Services vault sends Site Recovery logs in the right mode (Learn: Monitor Site Recovery with Azure Monitor Logs):
# only AzureSiteRecoveryJobs and ASRReplicatedItems are resource-specific; the legacy categories must stay in Azure Diagnostics mode.
BeforeAll {
    $script:bicep = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\bicep\modules\bcdr.bicep') -Raw
    $script:tf = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\terraform\s6-bcdr.tf') -Raw
}
Describe 'Recovery vault diagnostics' {
    It 'Bicep: legacy categories are in an AzureDiagnostics setting, the two resource-specific ones in a Dedicated setting' {
        $legacy = [regex]::Match($script:bicep, "(?s)logAnalyticsDestinationType: 'AzureDiagnostics'(.*?)\]\s*\}").Groups[1].Value
        $dedicated = [regex]::Match($script:bicep, "(?s)logAnalyticsDestinationType: 'Dedicated'(.*?)\]\s*\}").Groups[1].Value
        foreach ($c in 'AzureBackupReport', 'AzureSiteRecoveryEvents', 'AzureSiteRecoveryReplicatedItems', 'AzureSiteRecoveryReplicationStats', 'AzureSiteRecoveryRecoveryPoints') { $legacy | Should -Match $c }
        foreach ($c in 'AzureSiteRecoveryJobs', 'ASRReplicatedItems') { $dedicated | Should -Match $c }
        $dedicated | Should -Not -Match 'AzureSiteRecoveryEvents|ReplicationStats|RecoveryPoints|AzureBackupReport'
        $legacy | Should -Not -Match 'AzureSiteRecoveryJobs|ASRReplicatedItems'
    }
    It 'Terraform: the same split, with the destination type set explicitly (the module default is Dedicated)' {
        $script:tf | Should -Match 'log_analytics_destination_type = "AzureDiagnostics"'
        $script:tf | Should -Match 'log_analytics_destination_type = "Dedicated"'
        $script:tf | Should -Match 'log_categories\s+= \["AzureSiteRecoveryJobs", "ASRReplicatedItems"\]'
        $script:tf | Should -Not -Match '"AzureBackupReport", "AzureSiteRecoveryJobs"'
    }
}
