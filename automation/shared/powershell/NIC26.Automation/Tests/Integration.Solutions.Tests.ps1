#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Integration tests: every solution.yml under automation\{landing-zones,azure-local,avd,demo} against the shared module.
.DESCRIPTION
    For each manifest found: validates it against solution.schema.json, runs ConvertTo-NIC26BicepParam and
    ConvertTo-NIC26TfVars in preview mode against the scope's EXAMPLE environment files, checks that only declared,
    non-generated inputs are emitted, and asserts every catalog name passes Test-NIC26ResourceName and contains nic26
    unless exempt. Solutions whose folder exists in the contract layout but has no solution.yml yet are listed as
    skipped, never failed.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll/BeforeDiscovery variables are consumed inside It blocks, which the analyzer cannot see.')]
param()

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1') -Force
    $automationRoot = & (Get-Module NIC26.Automation) { Get-NIC26AutomationRoot }
    $searchRoots = @('landing-zones', 'azure-local', 'avd', 'demo') | ForEach-Object { Join-Path $automationRoot $_ } | Where-Object { Test-Path $_ }
    $script:solutionCases = @()
    foreach ($manifest in (Get-ChildItem -Path $searchRoots -Recurse -Depth 3 -Filter 'solution.yml' -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $scopeLine = Select-String -LiteralPath $manifest.FullName -Pattern '^\s*scope:\s*([a-z-]+)' | Select-Object -First 1
        $toolsLine = Select-String -LiteralPath $manifest.FullName -Pattern '^\s*tools:\s*\[([^\]]*)\]' | Select-Object -First 1
        $tools = @()
        if ($toolsLine) { $tools = @($toolsLine.Matches[0].Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $script:solutionCases += @{
            Name     = $manifest.DirectoryName.Substring($automationRoot.Length).TrimStart('\', '/')
            Path     = $manifest.DirectoryName
            Scope    = if ($scopeLine) { $scopeLine.Matches[0].Groups[1].Value } else { 'unknown' }
            HasBicep = ($tools -contains 'bicep')
            HasTf    = ($tools -contains 'terraform')
        }
    }
    # Contract layout (CONTRACT.md section 1): folders expected to hold a solution.yml eventually.
    $expected = @(
        'landing-zones\azure-local', 'landing-zones\avd',
        'azure-local\network-devices', 'azure-local\hardware-baseline', 'azure-local\os-provisioning', 'azure-local\cluster-deploy',
        'avd\control-plane', 'avd\fslogix', 'avd\session-hosts-azure', 'avd\session-hosts-azure-local', 'avd\session-hosts-hybrid',
        'demo\azure-local', 'demo\avd', 'demo\shared'
    )
    foreach ($wildcardParent in @('azure-local\cluster-configure', 'avd\images')) {
        $parent = Join-Path $automationRoot $wildcardParent
        if (Test-Path $parent) {
            $children = @(Get-ChildItem -LiteralPath $parent -Directory | Where-Object { $_.Name -notin @('scripts', 'tests', 'bicep', 'terraform', 'ansible', 'modules') } | ForEach-Object { Join-Path $wildcardParent $_.Name })
            if ($children.Count -eq 0) { $expected += $wildcardParent } else { $expected += $children }
        }
        else {
            $expected += $wildcardParent
        }
    }
    $script:missingCases = @($expected | Where-Object { -not (Test-Path (Join-Path $automationRoot $_ 'solution.yml')) } | ForEach-Object { @{ Folder = $_ } })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1') -Force
    $script:ExamplesRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'examples')).Path
    $script:EnvRoot = Join-Path $TestDrive 'env'
    foreach ($scope in @('shared', 'azure-local', 'avd')) {
        $folder = Join-Path $script:EnvRoot $scope
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot "environment.$scope.example.yml") -Destination (Join-Path $folder 'environment.yml')
    }
    $script:Configs = @{}
    foreach ($scope in @('shared', 'azure-local', 'avd')) {
        $script:Configs[$scope] = Get-NIC26Config -Scope $scope -Path (Join-Path $script:EnvRoot $scope)
    }
    $script:Registry = & (Get-Module NIC26.Automation) { Get-NIC26NameRegistry }

    function Get-DeclaredInputSet {
        param([System.Collections.IDictionary]$Manifest)
        $emittable = @($Manifest.inputs | Where-Object { $_.source -ne 'generated' } | ForEach-Object { $_.name })
        $generated = @($Manifest.inputs | Where-Object { $_.source -eq 'generated' } | ForEach-Object { $_.name })
        return @{ Emittable = $emittable; Generated = $generated }
    }
}

Describe 'Solution manifest integration: <Name> (scope <Scope>)' -ForEach $solutionCases {
    BeforeAll {
        $script:Manifest = $null
        $script:ManifestError = $null
        try { $script:Manifest = Get-NIC26SolutionManifest -Path $Path } catch { $script:ManifestError = $_.Exception.Message }
    }

    It 'validates against solution.schema.json and the manifest rules' {
        $script:ManifestError | Should -BeNullOrEmpty
        $script:Manifest.name | Should -Not -BeNullOrEmpty
        $script:Manifest.scope | Should -Be $Scope
    }

    It 'generates Bicep parameters from the example config with only declared, non-generated inputs' -Skip:(-not $HasBicep) {
        $script:ManifestError | Should -BeNullOrEmpty
        # A generated file may already exist on a machine that has deployed (it is git-ignored); the preview must leave it, or its absence, as it was.
        $generatedFile = Join-Path $Path 'bicep' 'main.generated.bicepparam'
        $existedBefore = Test-Path $generatedFile
        $stampBefore = if ($existedBefore) { (Get-Item $generatedFile).LastWriteTimeUtc } else { $null }
        $text = ConvertTo-NIC26BicepParam -Solution $Path -Config $script:Configs[$Scope]
        $text | Should -Match "(?m)^using './main.bicep'$"
        $params = @([regex]::Matches($text, '(?m)^param ([a-z0-9_]+) = ') | ForEach-Object { $_.Groups[1].Value })
        $declared = Get-DeclaredInputSet -Manifest $script:Manifest
        foreach ($param in $params) {
            if ($param -eq 'names') { continue }
            $declared.Emittable | Should -Contain $param -Because 'only declared inputs may be emitted'
        }
        foreach ($generated in $declared.Generated) {
            if ($generated -eq 'names') { continue }
            $params | Should -Not -Contain $generated -Because 'source: generated inputs are run-time values'
        }
        ($params | Where-Object { $_ -eq 'names' }).Count | Should -Be 1
        Test-Path $generatedFile | Should -Be $existedBefore -Because 'preview must not write'
        if ($existedBefore) { (Get-Item $generatedFile).LastWriteTimeUtc | Should -Be $stampBefore -Because 'preview must not rewrite an existing file' }
    }

    It 'generates Terraform variables from the example config with only declared, non-generated inputs' -Skip:(-not $HasTf) {
        $script:ManifestError | Should -BeNullOrEmpty
        $json = ConvertTo-NIC26TfVars -Solution $Path -Config $script:Configs[$Scope] | ConvertFrom-Json -AsHashtable
        $declared = Get-DeclaredInputSet -Manifest $script:Manifest
        foreach ($key in $json.Keys) {
            if ($key -in @('_generated', 'names')) { continue }
            $declared.Emittable | Should -Contain $key
        }
        foreach ($generated in $declared.Generated) {
            if ($generated -eq 'names') { continue }
            $json.Keys | Should -Not -Contain $generated
        }
        $json._generated.solution | Should -Be $script:Manifest.name
    }

    It 'resolves every catalog name to a valid name that contains nic26 unless exempt' {
        $script:ManifestError | Should -BeNullOrEmpty
        $names = & (Get-Module NIC26.Automation) { param($catalog, $values) Resolve-NIC26NameCatalog -Catalog $catalog -Values $values } $script:Manifest.names $script:Configs[$Scope].values
        $names.Count | Should -Be $script:Manifest.names.Count
        foreach ($key in $script:Manifest.names.Keys) {
            $spec = $script:Manifest.names[$key]
            $name = [string]$names[$key]
            $name | Should -Not -BeNullOrEmpty -Because "names.$key must resolve"
            $typeKey = & (Get-Module NIC26.Automation) { param($t) Resolve-NIC26NameType -Type $t } ([string]$spec.type)
            $exempt = ($spec.Contains('exempt') -and [bool]$spec.exempt)
            if ($typeKey) {
                $result = Test-NIC26ResourceName -Name $name -Type $typeKey -Detailed
                $result.IsValid | Should -BeTrue -Because "names.$key = '$name': $($result.Reasons -join '; ')"
                if (-not $script:Registry[$typeKey].RequireToken) { $exempt = $true }
            }
            else {
                $exempt | Should -BeTrue -Because "names.$key uses an unknown type and must be declared exempt"
            }
            if (-not $exempt) {
                $name | Should -BeLike '*nic26*' -Because "names.$key = '$name' must carry the lab token (D-005)"
            }
        }
    }
}

Describe 'Solutions without a manifest yet' {
    It 'has no solution.yml yet: <Folder>' -ForEach $missingCases {
        Set-ItResult -Skipped -Because "automation\$Folder has no solution.yml yet (owner still writing it)"
    }
}
