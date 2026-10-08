#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Install-JumpTools.ps1')
    $script:pins = Join-Path $TestDrive 'pins.psd1'
    Set-Content $script:pins "@{ Tools = @{ git = @{ Version = '1.2.3'; Packages = @(@{Id='Example.Git';Version='1.2.3';Source='winget'}) } } }"
}
Describe 'Read-only pinned tool verification' {
    BeforeEach { Mock Invoke-Winget { throw 'Verification must never install' } }
    It 'reports a matching pin as Passed without installation' {
        Mock Get-JumpComponentVersion { '1.2.3' }
        $r=Invoke-JumpTools -VerifyOnly -VersionsPath $script:pins -PassThru
        $r.Action | Should -Be 'Verify'
        $r.Result | Should -Be 'Passed'
        Should -Invoke Invoke-Winget -Times 0
    }
    It 'fails a mismatch without attempting repair' {
        Mock Get-JumpComponentVersion { '0.1.0' }
        (Invoke-JumpTools -VerifyOnly -VersionsPath $script:pins -PassThru).Result | Should -Be 'Failed'
        Should -Invoke Invoke-Winget -Times 0
    }
    It 'fails inventory errors without attempting repair' {
        Mock Get-JumpComponentVersion { throw 'Command unavailable' }
        (Invoke-JumpTools -VerifyOnly -VersionsPath $script:pins -PassThru).Result | Should -Be 'Failed'
        Should -Invoke Invoke-Winget -Times 0
    }
    It 'rejects conflicting execute mode' {
        { Invoke-JumpTools -VerifyOnly -Execute -VersionsPath $script:pins } | Should -Throw '*cannot be combined*'
    }
    It 'rejects unresolved selected pins' {
        $bad=Join-Path $TestDrive 'bad.psd1'
        Set-Content $bad "@{ Tools = @{ git = @{ Version = 'TODO-PIN'; Packages = @(@{Id='Example.Git';Version='TODO-PIN'}) } } }"
        { Invoke-JumpTools -VerifyOnly -VersionsPath $bad } | Should -Throw '*resolved pins*'
    }
    It 'fails a feature waiting for restart' {
        $features=Join-Path $TestDrive 'features.psd1'
        Set-Content $features "@{ Tools = @{ rsat = @{ Version = 'N/A'; Features = @('Example.Feature') } } }"
        Mock Get-JumpComponentVersion { 'InstallPending' }
        $r=Invoke-JumpTools -VerifyOnly -VersionsPath $features -PassThru
        $r.Result | Should -Be 'Failed'
        $r.Reboot | Should -BeTrue
    }
    It 'rejects an empty selection after exclusions' {
        $office=Join-Path $TestDrive 'office.psd1'
        Set-Content $office "@{ Tools = @{ office = @{ Version = '1.2.3' } } }"
        { Invoke-JumpTools -VerifyOnly -SkipOffice -VersionsPath $office } | Should -Throw '*at least one*'
    }
    It 'preserves custom wrapper arguments across dot-sourcing and propagates exit status' {
        $dir=Join-Path $TestDrive 'wrapper'
        $null=New-Item -ItemType Directory -Path $dir
        $wrapper=Join-Path $dir 'Test-JumpTools.ps1'
        Copy-Item (Join-Path $PSScriptRoot '../scripts/Test-JumpTools.ps1') $wrapper
        Set-Content (Join-Path $dir 'Install-JumpTools.ps1') @'
param([string[]] $Only, [string] $VersionsPath = 'overwritten')
function Invoke-JumpTools {
    param([switch] $VerifyOnly, [switch] $PassThru, [string[]] $Only, [switch] $SkipOffice, [string] $VersionsPath, [string] $AdditionalVersionsPath)
    if (-not $VerifyOnly -or -not $PassThru -or $Only -notcontains 'git') { throw 'Arguments lost' }
    if ($VersionsPath -eq 'passed') { [pscustomobject]@{Result='Passed'} }
    elseif ($VersionsPath -eq 'failed') { [pscustomobject]@{Result='Failed'} }
    elseif ($VersionsPath -eq 'error') { throw 'Inventory failed' }
}
'@
        foreach ($case in @(@('passed', 0), @('failed', 1), @('empty', 1), @('error', 1))) {
            & pwsh -NoProfile -File $wrapper -Only git -VersionsPath $case[0] *> $null
            $LASTEXITCODE | Should -Be $case[1]
        }
    }
}
