BeforeAll {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Test-JumpTools.ps1'), [ref]$tokens, [ref]$errors)
    foreach ($name in @('ConvertFrom-JumpGitLfsVersion', 'Get-JumpGitLfsRuntimeVersion', 'Test-JumpGitLfsInventory')) {
        $function=$ast.Find({ param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $manifest=Import-PowerShellDataFile (Join-Path $PSScriptRoot '../scripts/jump-tools.versions.psd1')
    $script:gitSpec=$manifest.Tools.git
}
Describe 'Exact bundled Git LFS runtime verification' {
    It 'rejects a GIT_EXEC_PATH dispatch override before reading or running a binary' {
        $prior=$env:GIT_EXEC_PATH
        try { $env:GIT_EXEC_PATH=Join-Path $TestDrive 'foreign'; Mock Get-Item { throw 'Must not read binary' }; Get-JumpGitLfsRuntimeVersion (Join-Path $TestDrive 'git.exe') | Should -BeNullOrEmpty; Should -Invoke Get-Item -Times 0 }
        finally { $env:GIT_EXEC_PATH=$prior }
    }
    It 'rejects an actual reparse ancestor before Git dispatch' {
        $prior=$env:GIT_EXEC_PATH
        try {
            $env:GIT_EXEC_PATH=$null
            $target=New-Item -ItemType Directory (Join-Path $TestDrive 'actual')
            Set-Content (Join-Path $target.FullName 'git.exe') 'not executable'
            Set-Content (Join-Path $target.FullName 'git-lfs.exe') 'not executable'
            $junction=New-Item -ItemType Junction -Path (Join-Path $TestDrive 'foreign-link') -Target $target.FullName
            Get-JumpGitLfsRuntimeVersion (Join-Path $junction.FullName 'git.exe') | Should -BeNullOrEmpty
        }
        finally { $env:GIT_EXEC_PATH=$prior }
    }
    It 'parses official Windows runtime metadata' { ConvertFrom-JumpGitLfsVersion 'git-lfs/3.7.1 (GitHub; windows amd64; go 1.25; git b84b3384)' | Should -Be '3.7.1' }
    It 'rejects a malformed version suffix' { ConvertFrom-JumpGitLfsVersion 'git-lfs/3.7.1-extra (windows amd64)' | Should -BeNullOrEmpty }
    It 'does not dispatch LFS from an unproven Git install' {
        Mock Get-JumpGitLfsRuntimeVersion { throw 'Must not run' }
        (Test-JumpGitLfsInventory $script:gitSpec $false).Result | Should -Be 'Failed'
        Should -Invoke Get-JumpGitLfsRuntimeVersion -Times 0
    }
    It 'rejects a close but different LFS version' {
        Mock Get-JumpGitLfsRuntimeVersion { '3.7.10' }
        (Test-JumpGitLfsInventory $script:gitSpec $true).Result | Should -Be 'Failed'
    }
    It 'accepts the exact pin only after machine Git proof' {
        Mock Get-JumpGitLfsRuntimeVersion { '3.7.1' }
        (Test-JumpGitLfsInventory $script:gitSpec $true).Result | Should -Be 'Passed'
    }
    It 'fails closed when the LFS pin is absent' {
        $copy=$script:gitSpec.Clone(); $copy.Remove('LfsVersion')
        Mock Get-JumpGitLfsRuntimeVersion { throw 'Must not run' }
        (Test-JumpGitLfsInventory $copy $true).Result | Should -Be 'Failed'
        Should -Invoke Get-JumpGitLfsRuntimeVersion -Times 0
    }
}


