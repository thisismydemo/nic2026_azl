#Requires -Version 7.0
# Pester 5 — cluster-configure/access-pim gates via the shared kit. Allowed GUIDs = built-in role definition IDs only.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-access-pim' `
    -RequiredInputs 'group_object_ids', 'pim_assignments' `
    -EntryScripts 'Invoke-PimEligibility.ps1' `
    -AllowedGuids 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'bda0d508-adf1-4af0-9c28-88919fc3ae06', '874d1c73-6003-4e60-a13a-cb31ea190a85', '4b3fe76c-f777-4d24-a2d7-b027b0f7b273'

Describe 'access-pim specifics' {
    It 'the Az path checks existing schedules before submitting (idempotent) and offers AdminRemove' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-PimEligibility.ps1') -Raw
        $t | Should -Match 'Get-AzRoleEligibilitySchedule'
        $t | Should -Match 'AdminRemove'
        $t | Should -Match 'TargetRoleEligibilityScheduleId'
    }
    It 'the activation helper self-activates with justification and bounded duration' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\scripts\Request-PimActivation.ps1') -Raw
        $t | Should -Match 'SelfActivate'
        $t | Should -Match 'ExpirationDuration'
        $t | Should -Match '\[switch\]\$Execute'
    }
}
