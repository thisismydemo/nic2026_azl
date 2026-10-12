#Requires -Version 7.0
# Pester 5 - static gates for automation/shared/security (no Azure calls).
BeforeAll {
    $script:root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:repo = (Resolve-Path (Join-Path $root '..\..\..')).Path
    $script:allowedGuids = @(
        # built-in policy definitions
        'e56962a6-4747-49cd-b67b-bf8b01975c4c', 'e765b5de-1225-4ba3-bd56-1ac6695af988', '96670d01-0a4d-4649-9c89-2d3abc0a5025',
        'ea3f2387-9b95-492a-a190-fcdc54f7b070', '2465583e-4e78-4c15-b6be-a36cbc7c8b0f', 'eab1f514-22e3-42e3-9a1f-e1dc9199355c',
        '94f686d6-9a24-4e19-91f1-de937dc171a4', 'ca817e41-e85a-4783-bc7f-dc532d36235e',
        # built-in role definitions
        'b24988ac-6180-42a0-ab88-20f7382dd24c', '749f88d5-cbae-40b8-bcfc-e573ddc772fa', '92aaf0da-9dab-42b6-94a3-d43ce8d16293',
        'cd570a14-e51a-42ad-bac8-bafd67325302', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
    )
}

Describe 'automation/shared/security' {
    It 'builds both Bicep entry points' -ForEach @('workspace.bicep', 'subscription.bicep') {
        $out = & az bicep build --file (Join-Path $root "bicep\$_") --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
    }
    It 'contains no GUID except built-in policy and role definitions (G5/G6)' {
        $files = Get-ChildItem -Path $root -Recurse -File -Include *.bicep, *.ps1, *.md | Where-Object { $_.FullName -notmatch '\\tests\\' }
        foreach ($f in $files) {
            $guids = [regex]::Matches((Get-Content $f.FullName -Raw), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object Value
            foreach ($g in $guids) { $allowedGuids | Should -Contain $g.ToLowerInvariant() -Because "$($f.Name) holds $g" }
        }
    }
    It 'never assigns the Microsoft cloud security benchmark again (Defender assigns it as SecurityCenterBuiltIn)' {
        (Get-Content (Join-Path $root 'bicep\subscription.bicep') -Raw) | Should -Not -Match '1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
    }
    It 'keeps guardrails non-blocking (Audit / DoNotEnforce) by default' {
        $b = Get-Content (Join-Path $root 'bicep\subscription.bicep') -Raw
        $b | Should -Match "param allowedLocationsEffect string = 'Audit'"
        $b | Should -Match "enforcementMode: 'DoNotEnforce'"
    }
    It 'exempts Azure Local machines from the per-machine AMA policy' {
        (Get-Content (Join-Path $root 'bicep\subscription.bicep') -Raw) | Should -Match "modules/policy-exemption\.bicep"
    }
    It 'collects the Learn Common event set into SecurityEvent' {
        $w = Get-Content (Join-Path $root 'bicep\workspace.bicep') -Raw
        $w | Should -Match 'Microsoft-SecurityEvent'
        foreach ($id in 4624, 4625, 4634, 4688, 4720, 4728, 1102) { $w | Should -Match "\b$id\b" }
    }
    It 'example environment validates against the schema and carries only zero GUIDs' {
        Import-Module powershell-yaml -ErrorAction Stop
        $ex = Get-Content (Join-Path $repo 'automation\shared\examples\environment.security.example.yml') -Raw
        ($ex | ConvertFrom-Yaml | ConvertTo-Json -Depth 20) | Test-Json -SchemaFile (Join-Path $repo 'automation\shared\schemas\security.environment.schema.json') | Should -BeTrue
        [regex]::Matches($ex, '/subscriptions/([0-9a-fA-F-]{36})') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique | Should -Be '00000000-0000-0000-0000-000000000000'
    }
    It 'runner is what-if by default and StrictMode' {
        $s = Get-Content (Join-Path $root 'scripts\Invoke-SecurityBaseline.ps1') -Raw
        $s | Should -Match '\[switch\]\$Execute'
        $s | Should -Match 'Set-StrictMode -Version Latest'
    }
}
