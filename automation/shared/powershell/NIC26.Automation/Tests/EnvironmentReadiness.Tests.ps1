#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for Test-EnvironmentReadiness.ps1 (placeholders that schema validation cannot see).
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-EnvTree is a test helper that writes into TestDrive.')]
param()

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..\..\Test-EnvironmentReadiness.ps1'
    $script:Zero = '00000000-0000-0000-0000-000000000000'
    function New-EnvTree {
        param([string]$Name, [string]$Shared, [string]$AzureLocal = $null)
        $root = Join-Path $TestDrive $Name
        foreach ($pair in @(@('shared', $Shared), @('azure-local', $AzureLocal))) {
            if ($null -ne $pair[1]) {
                $dir = Join-Path $root $pair[0]
                $null = New-Item -ItemType Directory -Path $dir -Force
                Set-Content -LiteralPath (Join-Path $dir 'environment.yml') -Value $pair[1]
            }
        }
        $root
    }
}

Describe 'Test-EnvironmentReadiness.ps1' {
    It 'reports an all-zero GUID, a TODO and a VERIFY with their key and task, and a clean file reports nothing' {
        $shared = "tenant_id: example-tenant-id`nsubscription_id: $($script:Zero)"
        $azl = "azl_rp_app_object_id: $($script:Zero)   # TODO(T-3.1.2): needs a lookup`nnodes:`n  - name: n1`n    lom1_mac: AA-BB-CC-DD-EE-FF   # TODO(T-5.1.2): VERIFY from the hardware`n    other: x   # VERIFY the model"
        $root = New-EnvTree -Name 'mixed' -Shared $shared -AzureLocal $azl
        $r = @(& $script:Script -Scope shared, azure-local -EnvironmentRoot $root 6>$null)
        ($r | Where-Object Kind -eq 'ZeroGuid').Key | Should -Contain 'subscription_id'
        ($r | Where-Object Kind -eq 'ZeroGuid').Key | Should -Contain 'azl_rp_app_object_id'
        (($r | Where-Object Kind -eq 'ZeroGuid' | Where-Object Key -eq 'azl_rp_app_object_id').Task) | Should -Be 'T-3.1.2'
        ($r | Where-Object Kind -eq 'Todo').Task | Should -Contain 'T-5.1.2'
        @($r | Where-Object Kind -eq 'Verify').Count | Should -Be 1
        @($r | Where-Object Scope -eq 'shared' | Where-Object Kind -ne 'ZeroGuid').Count | Should -Be 0
    }

    It 'returns nothing for a file without placeholders' {
        $root = New-EnvTree -Name 'clean' -Shared "tenant_id: example-tenant-id`nlocation: eastus"
        @(& $script:Script -Scope shared -EnvironmentRoot $root 6>$null).Count | Should -Be 0
    }

    It 'skips secret-map.yml (it has its own shape)' {
        $root = New-EnvTree -Name 'secretmap' -Shared 'tenant_id: example-tenant-id'
        Set-Content -LiteralPath (Join-Path $root 'shared\secret-map.yml') -Value "secrets:`n  - target: x # $($script:Zero) TODO(T-1.1.1)"
        @(& $script:Script -Scope shared -EnvironmentRoot $root 6>$null).Count | Should -Be 0
    }

    It 'exits 1 with -FailOnPlaceholder when a placeholder or a scope is missing, and 0 when clean' {
        $dirty = New-EnvTree -Name 'dirty' -Shared "subscription_id: $($script:Zero)"
        $clean = New-EnvTree -Name 'clean2' -Shared 'tenant_id: example-tenant-id'
        pwsh -NoProfile -File $script:Script -Scope shared -EnvironmentRoot $dirty -FailOnPlaceholder *> $null
        $LASTEXITCODE | Should -Be 1
        pwsh -NoProfile -File $script:Script -Scope shared -EnvironmentRoot $clean -FailOnPlaceholder *> $null
        $LASTEXITCODE | Should -Be 0
        pwsh -NoProfile -File $script:Script -Scope shared, avd -EnvironmentRoot $clean -FailOnPlaceholder *> $null
        $LASTEXITCODE | Should -Be 1
    }

    It 'does not fail on a VERIFY alone' {
        $root = New-EnvTree -Name 'verifyonly' -Shared "lom1_mac: AA-BB-CC-DD-EE-FF   # VERIFY from the hardware"
        pwsh -NoProfile -File $script:Script -Scope shared -EnvironmentRoot $root -FailOnPlaceholder *> $null
        $LASTEXITCODE | Should -Be 0
    }
}
