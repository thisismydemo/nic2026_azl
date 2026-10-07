#Requires -Version 7.0
# Pester 5 - Get-Day2ControlState.ps1: every control's Applied / Partial / Removed / Unknown logic with the ARM reads mocked.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks')]
param()

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\scripts\Get-Day2ControlState.ps1'
    . $script:scriptPath
    $script:sub = '11111111-1111-1111-1111-111111111111'
    $script:names = [pscustomobject]@{
        rg_azl = 'rg-azl'; rg_mon = 'rg-mon'; rg_bcdr = 'rg-bcdr'; rsv_azl = 'rsv'; bkp_tier1 = 'bkp'; asrpol_tier1 = 'asrpol'
        dcr_insights = 'dcr-ins'; dcr_vminsights = 'dcr-vm'
        alert_node_down = 'a1'; alert_storage_health = 'a2'; alert_intent_drift = 'a3'; alert_capacity = 'a4'; alert_kv_backup = 'a5'
        mc_azl = 'mc'; mc_azl_dynscope = 'mcdyn'
        asg_hybrid_baseline = 'asg1'; asg_akv_backup_ext = 'asg2'; asg_insights_ama = 'asg3'; asg_insights_dcra = 'asg4'
        img_win11_avd = 'img-win'; img_ws2025 = 'img-ws'
    }
    $script:present = [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'Succeeded' } }
}

Describe 'insights' {
    BeforeAll {
        $script:insightsInputs = [pscustomobject]@{ names = $script:names; cluster_name = 'clus'; nodes = @([pscustomobject]@{ name = 'n1' }, [pscustomobject]@{ name = 'n2' }) }
    }
    It 'is Applied when the agent succeeded and every node is associated (node objects)' {
        Mock Get-Day2Resource {
            if ($Path -like '*AzureMonitorWindowsAgent*') { return $script:present }
            [pscustomobject]@{ value = @([pscustomobject]@{ properties = [pscustomobject]@{ dataCollectionRuleId = '/subscriptions/x/resourceGroups/rg-mon/providers/Microsoft.Insights/dataCollectionRules/DCR-INS' } }) }
        }
        $row = Test-Day2InsightsState -Inputs $script:insightsInputs -SubscriptionId $script:sub
        $row.Status | Should -Be 'Applied'
        $row.Control | Should -Be 'insights'
    }
    It 'is Partial and names the node without the association' {
        Mock Get-Day2Resource {
            if ($Path -like '*AzureMonitorWindowsAgent*') { return $script:present }
            if ($Path -like '*machines/n2/*') { return [pscustomobject]@{ value = @() } }
            [pscustomobject]@{ value = @([pscustomobject]@{ properties = [pscustomobject]@{ dataCollectionRuleId = '/x/dataCollectionRules/dcr-ins' } }) }
        }
        $row = Test-Day2InsightsState -Inputs $script:insightsInputs -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'n2'
    }
    It 'is Removed when nothing exists' {
        Mock Get-Day2Resource { $null }
        (Test-Day2InsightsState -Inputs $script:insightsInputs -SubscriptionId $script:sub).Status | Should -Be 'Removed'
    }
}

Describe 'monitoring-config' {
    It 'is Applied when the VM DCR, four rules and the routing rule exist; Partial names the missing rule' {
        $in = [pscustomobject]@{ names = $script:names; enable_vm_insights_dcr = $true }
        Mock Get-Day2Resource { [pscustomobject]@{ name = 'x' } }
        (Test-Day2MonitoringConfigState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        Mock Get-Day2Resource { if ($Path -like '*scheduledQueryRules/a3?*') { $null } else { [pscustomobject]@{ name = 'x' } } }
        $row = Test-Day2MonitoringConfigState -Inputs $in -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'a3'
    }
    It 'does not expect the VM DCR when it is disabled' {
        $in = [pscustomobject]@{ names = $script:names; enable_vm_insights_dcr = $false }
        Mock Get-Day2Resource { if ($Path -like '*dataCollectionRules*') { $null } else { [pscustomobject]@{ name = 'x' } } }
        (Test-Day2MonitoringConfigState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Applied'
    }
}

Describe 'update-manager' {
    It 'needs the assignment to point at the configuration' {
        $in = [pscustomobject]@{ names = $script:names }
        Mock Get-Day2Resource {
            if ($Path -like '*configurationAssignments*') { return [pscustomobject]@{ properties = [pscustomobject]@{ maintenanceConfigurationId = '/subscriptions/x/resourceGroups/rg-mon/providers/Microsoft.Maintenance/maintenanceConfigurations/MC' } } }
            [pscustomobject]@{ name = 'mc' }
        }
        (Test-Day2UpdateManagerState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        Mock Get-Day2Resource {
            if ($Path -like '*configurationAssignments*') { return [pscustomobject]@{ properties = [pscustomobject]@{ maintenanceConfigurationId = '/x/maintenanceConfigurations/other' } } }
            [pscustomobject]@{ name = 'mc' }
        }
        $row = Test-Day2UpdateManagerState -Inputs $in -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'mcdyn'
    }
}

Describe 'backup and site-recovery' {
    It 'read the policies in the recovery vault resource group' {
        $in = [pscustomobject]@{ names = $script:names }
        Mock Get-Day2Resource { [pscustomobject]@{ name = 'p' } }
        (Test-Day2BackupState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        (Test-Day2SiteRecoveryState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        Should -Invoke Get-Day2Resource -ParameterFilter { $Path -like '/subscriptions/*/resourceGroups/rg-bcdr/providers/Microsoft.RecoveryServices/vaults/rsv/backupPolicies/bkp?api-version=2023-02-01' } -Times 1
        Should -Invoke Get-Day2Resource -ParameterFilter { $Path -like '*/replicationPolicies/asrpol?api-version=2023-02-01' } -Times 1
        Mock Get-Day2Resource { $null }
        (Test-Day2BackupState -Inputs $in -SubscriptionId $script:sub).Status | Should -Be 'Removed'
    }
}

Describe 'pim-access' {
    BeforeAll {
        $script:pimInputs = [pscustomobject]@{
            group_object_ids = [pscustomobject]@{ azl_admins = '22222222-2222-2222-2222-222222222222'; azl_operators = '33333333-3333-3333-3333-333333333333' }
            pim_assignments  = @([pscustomobject]@{ group = 'azl_admins'; role = 'RoleA' }, [pscustomobject]@{ group = 'azl_operators'; role = 'RoleB' })
        }
        $script:roleDefinitionId = "/subscriptions/$($script:sub)/providers/Microsoft.Authorization/roleDefinitions/44444444-4444-4444-4444-444444444444"
    }
    It 'is Applied when every row has an eligibility at the subscription' {
        Mock Get-AzRoleDefinition { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' } }
        Mock Get-AzRoleEligibilitySchedule { [pscustomobject]@{ RoleDefinitionId = $script:roleDefinitionId; Scope = "/subscriptions/$($script:sub)" } }
        (Test-Day2PimAccessState -Inputs $script:pimInputs -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        Should -Invoke Get-AzRoleEligibilitySchedule -ParameterFilter { $Filter -eq "principalId eq '22222222-2222-2222-2222-222222222222'" -and $Scope -eq "/subscriptions/$($script:sub)" } -Times 1
    }
    It 'is Partial and names the missing group:role' {
        Mock Get-AzRoleDefinition { [pscustomobject]@{ Id = '44444444-4444-4444-4444-444444444444' } }
        Mock Get-AzRoleEligibilitySchedule {
            if ($Filter -like '*3333*') { return @() }
            [pscustomobject]@{ RoleDefinitionId = $script:roleDefinitionId; Scope = "/subscriptions/$($script:sub)" }
        }
        $row = Test-Day2PimAccessState -Inputs $script:pimInputs -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'azl_operators:RoleB'
    }
    It 'refuses a placeholder group id (the caller reports Unknown)' {
        $in = [pscustomobject]@{ group_object_ids = [pscustomobject]@{ azl_admins = '00000000-0000-0000-0000-000000000000' }; pim_assignments = @([pscustomobject]@{ group = 'azl_admins'; role = 'RoleA' }) }
        { Test-Day2PimAccessState -Inputs $in -SubscriptionId $script:sub } | Should -Throw '*Placeholder*'
    }
}

Describe 'defender' {
    It 'matches the plan: <Plan> / <Tier> / <Sub> is <Expected>' -ForEach @(
        @{ Plan = 'P2'; Tier = 'Standard'; Sub = 'P2'; Expected = 'Applied' }
        @{ Plan = 'P2'; Tier = 'Free'; Sub = ''; Expected = 'Removed' }
        @{ Plan = 'P2'; Tier = 'Standard'; Sub = 'P1'; Expected = 'Partial' }
        @{ Plan = 'off'; Tier = 'Free'; Sub = ''; Expected = 'Applied' }
    ) {
        $tier = $Tier
        $sub = $Sub
        Mock Get-Day2Resource { [pscustomobject]@{ properties = [pscustomobject]@{ pricingTier = $tier; subPlan = $sub } } }.GetNewClosure()
        (Test-Day2DefenderState -Inputs ([pscustomobject]@{ defender_servers_plan = $Plan }) -SubscriptionId $script:sub).Status | Should -Be $Expected
    }
}

Describe 'policy-baseline' {
    It 'expects the Insights assignments only when they are enabled' {
        Mock Get-Day2Resource { if ($Path -like '*policyAssignments/asg3*' -or $Path -like '*policyAssignments/asg4*') { $null } else { [pscustomobject]@{ name = 'x' } } }
        (Test-Day2PolicyBaselineState -Inputs ([pscustomobject]@{ names = $script:names; assign_insights_policies = $false }) -SubscriptionId $script:sub).Status | Should -Be 'Applied'
        $row = Test-Day2PolicyBaselineState -Inputs ([pscustomobject]@{ names = $script:names; assign_insights_policies = $true }) -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'asg3, asg4'
    }
}

Describe 'policy-baseline enforcement mode' {
    It 'counts an assignment whose enforcement mode differs from the configured one as not present' {
        Mock Get-Day2Resource { [pscustomobject]@{ properties = [pscustomobject]@{ enforcementMode = 'DoNotEnforce' } } }
        $row = Test-Day2PolicyBaselineState -Inputs ([pscustomobject]@{ names = $script:names; assign_insights_policies = $false }) -SubscriptionId $script:sub
        $row.Status | Should -Be 'Removed'
        $row = Test-Day2PolicyBaselineState -Inputs ([pscustomobject]@{ names = $script:names; assign_insights_policies = $false; enforcement_mode = 'DoNotEnforce' }) -SubscriptionId $script:sub
        $row.Status | Should -Be 'Applied'
    }
}

Describe 'workload-platform' {
    BeforeAll {
        $script:platformInputs = [pscustomobject]@{
            names            = $script:names
            logical_networks = @([pscustomobject]@{ name = 'lnet-a' })
            storage          = [pscustomobject]@{ storage_paths = @([pscustomobject]@{ name = 'sp-a' }) }
        }
    }
    It 'is Applied when networks, images and storage paths exist and the images succeeded' {
        Mock Get-Day2Resource { $script:present }
        (Test-Day2WorkloadPlatformState -Inputs $script:platformInputs -SubscriptionId $script:sub).Status | Should -Be 'Applied'
    }
    It 'is Partial while an image is still downloading' {
        Mock Get-Day2Resource { if ($Path -like '*marketplaceGalleryImages/img-win*') { [pscustomobject]@{ properties = [pscustomobject]@{ provisioningState = 'InProgress' } } } else { $script:present } }
        $row = Test-Day2WorkloadPlatformState -Inputs $script:platformInputs -SubscriptionId $script:sub
        $row.Status | Should -Be 'Partial'
        $row.Detail | Should -Be 'image img-win InProgress'
    }
    It 'is Removed when nothing exists' {
        Mock Get-Day2Resource { $null }
        (Test-Day2WorkloadPlatformState -Inputs $script:platformInputs -SubscriptionId $script:sub).Status | Should -Be 'Removed'
    }
}

Describe 'the script itself' {
    It 'reports Unknown (never throws) for every control when no inputs exist, and honours -Control' {
        $empty = Join-Path $TestDrive 'nothing'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $rows = @(& $script:scriptPath -InputRoot $empty)
        $rows.Count | Should -Be 9
        @($rows | Where-Object Status -NE 'Unknown').Count | Should -Be 0
        $one = @(& $script:scriptPath -InputRoot $empty -Control backup)
        $one.Count | Should -Be 1
        $one[0].Control | Should -Be 'backup'
        $one[0].PSObject.Properties.Name | Should -Be @('Control', 'Status', 'Detail', 'Section')
    }
    It 'emits exactly the control keys of the demo registry' {
        Import-Module powershell-yaml -ErrorAction Stop
        $registry = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\..\demo\azure-local\day2-controls.yml') -Raw)
        $empty = Join-Path $TestDrive 'nothing2'
        New-Item -ItemType Directory -Path $empty | Out-Null
        $emitted = @((& $script:scriptPath -InputRoot $empty).Control | Sort-Object)
        $expected = @(@($registry.controls).key | Sort-Object)
        $emitted | Should -Be $expected
    }
    It 'is read-only: it calls no Set, New, Remove or write REST method' {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $text | Should -Not -Match '(?m)^\s*(Set|New|Remove|Update|Start|Stop)-Az\w+'
        $text | Should -Not -Match 'Invoke-AzRestMethod'
        $text | Should -Not -Match '(?i)-Method\s+(PUT|PATCH|POST|DELETE)'
        $text | Should -Not -Match 'Write-Host|Start-Transcript'
    }
}
