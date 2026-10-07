#Requires -Version 7.0
# Pester 5 — cluster-configure/defender gates via the shared kit.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-defender' `
    -RequiredInputs 'defender_servers_plan', 'enable_defender_keyvault', 'enable_defender_storage' `
    -EntryScripts 'Set-DefenderServersPlan.ps1'

Describe 'defender specifics' {
    It 'Remove with Bicep redeploys the plan as off instead of pretending to delete' {
        (Get-Content (Join-Path $PSScriptRoot '..\scripts\Set-DefenderServersPlan.ps1') -Raw) | Should -Match "defender_servers_plan = 'off'"
    }
    It 'uses the same pricings api-version as the landing zone' {
        (Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw) | Should -Match 'Microsoft.Security/pricings@2024-01-01'
    }
}
