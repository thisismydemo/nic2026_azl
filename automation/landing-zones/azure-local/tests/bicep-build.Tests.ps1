#Requires -Version 7.0
# Gate (contract §8): az bicep build on every .bicep with 0 errors; warnings reported; the example bicepparam compiles.
BeforeDiscovery {
    $script:BicepRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'bicep'
    $script:BicepFiles = @(Get-ChildItem -Path $script:BicepRoot -Recurse -Filter '*.bicep' | Select-Object -ExpandProperty FullName)
}

Describe 'Bicep build' -Tag 'Gate', 'Bicep' {
    BeforeAll {
        $az = Get-Command az -ErrorAction SilentlyContinue
        if (-not $az) { throw 'az CLI is not installed; the Bicep gate cannot run.' }
    }

    It 'builds <_> with 0 errors' -ForEach $script:BicepFiles {
        $out = & az bicep build --file $_ --stdout 2>&1
        $errors = @($out | Where-Object { "$_" -match ': Error [A-Z0-9]+:' })
        $errors -join "`n" | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'builds <_> with 0 warnings' -ForEach $script:BicepFiles {
        $out = & az bicep build --file $_ --stdout 2>&1
        $warnings = @($out | Where-Object { "$_" -match ': Warning [a-zA-Z0-9-]+:' })
        $warnings -join "`n" | Should -BeNullOrEmpty
    }

    It 'compiles main.example.bicepparam' {
        $out = & az bicep build-params --file (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'bicep') 'main.example.bicepparam') --stdout 2>&1
        $LASTEXITCODE | Should -Be 0
        @($out | Where-Object { "$_" -match ': Error ' }) | Should -BeNullOrEmpty
    }

    It 'main.bicep contains no literal GUID, IP address or region' {
        $main = Get-Content (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'bicep') 'main.bicep') -Raw
        $main | Should -Not -Match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
        $main | Should -Not -Match '\b\d{1,3}(\.\d{1,3}){3}\b'
        $main | Should -Not -Match "'(eastus|westeurope|norwayeast)'"
    }

    It 'no Bicep file reads a secret (getSecret / listKeys / listSecrets)' {
        foreach ($f in $script:BicepFiles) {
            (Get-Content $f -Raw) | Should -Not -Match '\.getSecret\(|listKeys\(|listSecrets\(' -Because "$f must not read secrets (contract §3)"
        }
    }
}
