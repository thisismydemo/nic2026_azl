#Requires -Version 7.0
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../NIC26.Automation.psd1') -Force
    $sharedRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $script:ScopeRoot = Join-Path $TestDrive 'environment'
    foreach ($scope in 'shared','azure-local','avd') {
        $folder = Join-Path $script:ScopeRoot $scope
        $null = New-Item -ItemType Directory -Path $folder
        Copy-Item -LiteralPath (Join-Path $sharedRoot "examples/environment.$scope.example.yml") -Destination (Join-Path $folder 'environment.yml')
    }
}
Describe 'Azure Local scope tag overrides' {
    It 'merges workload into shared tags without changing AVD or shared configuration' {
        $before = Get-NIC26Config -Scope shared -Path (Join-Path $script:ScopeRoot 'shared')
        Add-Content -LiteralPath (Join-Path $script:ScopeRoot 'azure-local/environment.yml') -Value "`ntags:`n  workload: azure-local"
        $local = Get-NIC26Config -Scope azure-local -Path (Join-Path $script:ScopeRoot 'azure-local')
        $local.values.tags.workload | Should -Be 'azure-local'
        foreach ($key in $before.values.tags.Keys) { $local.values.tags[$key] | Should -Be $before.values.tags[$key] }
        $avd = Get-NIC26Config -Scope avd -Path (Join-Path $script:ScopeRoot 'avd')
        $avd.values.tags.Contains('workload') | Should -BeFalse
    }
    It 'rejects non-string tag values' {
        Set-Content -LiteralPath (Join-Path $script:ScopeRoot 'azure-local/z-invalid.yml') -Value "tags:`n  invalid: 123"
        { Get-NIC26Config -Scope azure-local -Path (Join-Path $script:ScopeRoot 'azure-local') } | Should -Throw '*schema validation*'
    }
}
