#Requires -Version 7.0
# Pester 5 — cluster-configure/policy gates via the shared kit. Allowed GUIDs = built-in role definition IDs only.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-policy' `
    -RequiredInputs 'management_group_id', 'log_analytics_workspace_id', 'enforcement_mode' `
    -EntryScripts 'Invoke-PolicyBaseline.ps1' `
    -AllowedGuids 'b24988ac-6180-42a0-ab88-20f7382dd24c', '92aaf0da-9dab-42b6-94a3-d43ce8d16293', '749f88d5-cbae-40b8-bcfc-e573ddc772fa', '088ab73d-1256-47ae-bea9-9de8e7131f31', 'fb1c8493-542b-48eb-b624-b4c8fea62acd'

Describe 'policy specifics' {
    It 'assigns through the subscription-scope gap-fill module (AVM ptn is management-group only) and never redefines the initiative' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $b | Should -Match "module \w+ 'modules/policy-assignment\.bicep'"
        $b | Should -Not -Match 'br/public:avm/ptn/authorization/policy-assignment'
        $b | Should -Not -Match 'policySetDefinitions@'
    }
    It 'carries the Learn Insights policy rules (AMA on clusters, DCR association on machines)' {
        foreach ($f in 'bicep\main.bicep', 'terraform\main.tf') {
            $t = Get-Content (Join-Path $PSScriptRoot "..\$f") -Raw
            $t | Should -Match 'arcSettings/extensions'
            $t | Should -Match 'dataCollectionRuleAssociations'
            $t | Should -Match 'AKVBackupForWindows'
        }
    }
    It 'offers -Remove as the reversible path' {
        (Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-PolicyBaseline.ps1') -Raw) | Should -Match '\[switch\]\$Remove'
    }
}
