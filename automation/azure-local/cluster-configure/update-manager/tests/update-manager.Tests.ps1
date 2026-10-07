#Requires -Version 7.0
# Pester 5 — cluster-configure/update-manager gates via the shared kit.
. (Join-Path $PSScriptRoot '..\..\tests\Day2TestKit.ps1')
Invoke-Day2SolutionTests -SolutionRoot (Join-Path $PSScriptRoot '..') -ExpectedName 'cluster-configure-update-manager' `
    -RequiredInputs 'maintenance_window', 'patch_classifications', 'dynamic_scope_tags' `
    -EntryScripts 'Invoke-UpdateManagerConfigure.ps1'

Describe 'update-manager specifics' {
    It 'uses the confirmed AVM maintenance-configuration module and a subscription-level dynamic scope' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $b | Should -Match 'br/public:avm/res/maintenance/maintenance-configuration:0\.4\.0'
        $b | Should -Match "targetScope = 'subscription'"
        $b | Should -Match 'configurationAssignments@2023-04-01'
        $b | Should -Match "maintenanceScope: 'InGuestPatch'"
    }
    It 'Terraform scopes the dynamic assignment by tag with the All operator' {
        (Get-Content (Join-Path $PSScriptRoot '..\terraform\main.tf') -Raw) | Should -Match 'tag_filter\s+=\s+"All"'
    }
}

Describe 'maintenance window start (review R-35)' {
    BeforeAll { . (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1') }
    It 'accepts today or later and refuses a start date that has passed, in the window''s own time zone' {
        $now = [datetime]::new(2026, 10, 15, 8, 0, 0, [DateTimeKind]::Utc)
        Test-Day2MaintenanceStart -StartDateTime '2026-10-15 02:00' -TimeZone 'UTC' -NowUtc $now | Should -BeTrue
        Test-Day2MaintenanceStart -StartDateTime '2026-10-16 02:00' -TimeZone 'UTC' -NowUtc $now | Should -BeTrue
        Test-Day2MaintenanceStart -StartDateTime '2026-10-05 02:00' -TimeZone 'UTC' -NowUtc $now | Should -BeFalse
        Test-Day2MaintenanceStart -StartDateTime '2026-10-05 02:00' -TimeZone 'No Such Zone' -NowUtc $now | Should -BeFalse
    }
    It 'the entry script refuses before any Azure call and the driver runs the check first' {
        $s = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-UpdateManagerConfigure.ps1') -Raw
        $s | Should -Match 'Test-Day2MaintenanceStart'
        $s | Should -Match '-PreApplyCheck \$preApply'
        $c = Get-Content (Join-Path $PSScriptRoot '..\..\scripts\Day2.Common.ps1') -Raw
        $c.IndexOf('& $PreApplyCheck $inputs') | Should -BeLessThan $c.IndexOf('Assert-Day2AzContext -SubscriptionId $inputs.subscription_id')
    }
}
