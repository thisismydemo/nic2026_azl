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

Describe 'periodic assessment script (T-5.4.2, 12 Oct)' {
    It 'never touches an Azure Local node, keeps hotpatch VMs on platform checks and only reads or sets assessment' {
        $s = Get-Content (Join-Path $PSScriptRoot '..\scripts\Set-PeriodicAssessment.ps1') -Raw
        $s | Should -Match "AzureEdgeLifecycleManager"
        $s | Should -Match 'enableHotpatching'
        $s | Should -Match "assessmentMode = 'AutomaticByPlatform'"
        $s | Should -Not -Match 'installPatches|Install-AzUpdate|Start-AzMaintenance'
        $s | Should -Match 'SupportsShouldProcess'
    }
    It 'the dynamic scope is a global subscription-level resource whose types come from the input' {
        $b = Get-Content (Join-Path $PSScriptRoot '..\bicep\main.bicep') -Raw
        $b | Should -Match "location: 'global'"
        $b | Should -Match 'resourceTypes: dynamic_scope_resource_types'
    }
}

Describe 'solution update with additional content (Invoke-SolutionUpdate.ps1, T-5.3.14)' {
    BeforeAll { $script:su = Get-Content (Join-Path $PSScriptRoot '..\scripts\Invoke-SolutionUpdate.ps1') -Raw }
    It 'parses, uses StrictMode and changes nothing without -Execute' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\Invoke-SolutionUpdate.ps1'), [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
        $su | Should -Match 'Set-StrictMode -Version Latest'
        $su | Should -Match '\[switch\]\$Execute'
        $su | Should -Match 'if \(-not \$Execute\)'
    }
    It 'holds no environment values (G5)' {
        $su | Should -Not -Match '\b(?:\d{1,3}\.){3}\d{1,3}\b'
        $su | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $su | Should -Not -Match 'kv-iic|nic26-01-n0|rg-iic|vdpool-iic|D:\D[e]ll'
    }
    It 'follows the Learn PowerShell procedure: signed package, import, prepare, start, monitor' {
        $su | Should -Match 'CheckSignature'
        $su | Should -Match 'Add-SolutionUpdate -SourceFolder'
        $su | Should -Match 'Start-SolutionUpdate -PrepareOnly'
        $su | Should -Match 'Get-SolutionUpdateRun'
        $su | Should -Match 'HealthCheckResult'
    }
    It 'gates on nodes, storage jobs and virtual disks and stops the DDA GPU VMs (no live migration) through the CLI' {
        $su | Should -Match 'Get-StorageJob'
        $su | Should -Match 'HealthStatus'
        $su | Should -Match 'allowNewSession'
        $su | Should -Match 'stack-hci-vm stop'
        $su | Should -Match 'stack-hci-vm start'
        $su | Should -Not -Match 'Stop-VM |Clear-Disk|Suspend-ClusterNode|Set-AzStackHciVM'
    }
}
