#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Switching the Az context only changes the local session, so it must never be skipped by -WhatIf: a dry run that stays on
# the previous subscription reports the wrong subscription's state (found 7 Oct 2026 on Register-AvdProviders.ps1).

BeforeDiscovery {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path
    $script:ScriptFiles = Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File |
        Where-Object { $_.FullName -notmatch '[\/](tests?|\.terraform|node_modules)[\/]|\.Tests\.ps1$' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '(?m)^\s*(\$null = |\[void\]\()?Set-AzContext\s+-' } |
        ForEach-Object { @{ Path = $_.FullName; Name = [IO.Path]::GetRelativePath($root, $_.FullName) } }
}

Describe 'Set-AzContext in scripts' {
    It 'is called with -WhatIf:$false in <Name>' -ForEach $script:ScriptFiles {
        $calls = Select-String -LiteralPath $Path -Pattern '(?<![\w''"-])Set-AzContext\s+-' | Where-Object { $_.Line -notmatch '^\s*#' }
        $calls | Should -Not -BeNullOrEmpty
        foreach ($c in $calls) { $c.Line | Should -Match 'Set-AzContext\s+-WhatIf:\$false' }
    }
}
