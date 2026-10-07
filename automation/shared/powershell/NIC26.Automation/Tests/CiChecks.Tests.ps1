#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for shared/scripts/Invoke-CiChecks.ps1: what it discovers, what it skips and what it fails on. Nothing here deploys anything.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $script:Script = Join-Path $PSScriptRoot '..' '..' '..' 'scripts' 'Invoke-CiChecks.ps1'
    . $script:Script
    $script:Root = Join-Path $TestDrive 'repo'
    $files = @(
        'automation/a/scripts/Do-Thing.ps1', 'automation/a/tests/Do-Thing.Tests.ps1', 'automation/a/tests/fixtures/Fixture.Tests.ps1',
        'automation/a/bicep/main.bicep', 'automation/a/bicep/modules/other.bicep',
        'automation/a/terraform/main.tf', 'automation/a/terraform/.terraform/skipped.tf',
        'automation/b/packer/x.pkr.hcl', 'automation/b/node_modules/pkg/i.ps1',
        'README.md', 'docs/guide.md', 'follow-along-site/README.md')
    foreach ($f in $files) {
        $p = Join-Path $script:Root $f
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        Set-Content -LiteralPath $p -Value '# x'
    }
}

Describe 'discovery' {
    It 'finds PowerShell files for the analyzer and skips node_modules' {
        $t = @(Get-CiAnalyzerTargets -Root $script:Root)
        $t | Should -Contain 'automation/a/scripts/Do-Thing.ps1'
        ($t -match 'node_modules') | Should -BeNullOrEmpty
    }
    It 'finds Pester suites and skips fixtures' {
        @(Get-CiPesterTargets -Root $script:Root) | Should -Be @('automation/a/tests/Do-Thing.Tests.ps1')
    }
    It 'finds only main.bicep entry templates' {
        @(Get-CiBicepTargets -Root $script:Root) | Should -Be @('automation/a/bicep/main.bicep')
    }
    It 'finds Terraform folders and skips .terraform' {
        @(Get-CiTerraformFolders -Root $script:Root) | Should -Be @('automation/a/terraform')
    }
    It 'finds Packer folders' {
        @(Get-CiPackerFolders -Root $script:Root) | Should -Be @('automation/b/packer')
    }
    It 'finds Markdown files outside the follow-along site source' {
        $m = @(Get-CiMarkdownFiles -Root $script:Root)
        $m | Should -Contain 'README.md'
        $m | Should -Contain 'docs/guide.md'
        ($m -match 'follow-along-site') | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-CiChecks.ps1' {
    It 'in plan mode lists targets and runs nothing' {
        $r = @(& $script:Script -Root $script:Root -Check Bicep, Terraform, Packer -Plan -PassThru 6>$null)
        $r.Count | Should -Be 3
        ($r.Status | Sort-Object -Unique) | Should -Be 'Skipped'
        ($r.Detail | Sort-Object -Unique) | Should -Be 'plan only'
    }
    It 'fails a Markdown file with a dead relative link and passes one with a live link or only external links' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/guide.md') -Value @('[ok](../README.md)', '[web](https://example.com/x)', '[anchor](#top)', '`[code](nope.md)`', '[dead](missing.md#part)')
        $r = @(& $script:Script -Root $script:Root -Check Links -PassThru 6>$null)
        @($r | Where-Object Status -eq 'Failed').Count | Should -Be 1
        ($r | Where-Object Status -eq 'Failed').Target | Should -Be 'docs/guide.md'
        ($r | Where-Object Status -eq 'Failed').Detail | Should -Match 'missing\.md'
        ($r | Where-Object Status -eq 'Failed').Detail | Should -Not -Match 'nope\.md'
    }
    It 'reports a summary pass when every link resolves' {
        Set-Content -LiteralPath (Join-Path $script:Root 'docs/guide.md') -Value '[ok](../README.md)'
        $r = @(& $script:Script -Root $script:Root -Check Links -PassThru 6>$null)
        @($r | Where-Object Status -eq 'Failed').Count | Should -Be 0
        @($r | Where-Object Status -eq 'Passed').Count | Should -Be 1
    }
    It 'writes the results as JSON when asked' {
        $out = Join-Path $TestDrive 'r.json'
        $null = & $script:Script -Root $script:Root -Check Packer -Plan -PassThru -ResultPath $out 6>$null
        (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).Check | Should -Be 'Packer'
    }
}
