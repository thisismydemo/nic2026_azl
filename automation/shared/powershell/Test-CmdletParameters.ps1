<#
.SYNOPSIS
Lists named parameters used in repo scripts that the installed cmdlet does not have.
.DESCRIPTION
Stubbed Pester tests cannot catch a wrong parameter name (for example Remove-AzVMRunCommand -Force, which does not
exist). This parses every non-test script, resolves each command against the modules installed on this machine and
reports parameters the real command lacks. Commands from modules that are not installed are skipped, so a clean
result covers only what is installed here.
.PARAMETER Root
Folder to scan recursively (tests and .terraform folders are skipped).
#>
param([string]$Root)
$cache = @{}
$repoModule = Join-Path $PSScriptRoot "NIC26.Automation/NIC26.Automation.psd1"
if (Test-Path -LiteralPath $repoModule) { Import-Module $repoModule -Force -DisableNameChecking }
$sep = [IO.Path]::DirectorySeparatorChar
$files = Get-ChildItem -Path $Root -Recurse -Include *.ps1, *.psm1 -File | Where-Object {
    $parts = $_.FullName.Split($sep)
    -not ($parts -contains '.terraform') -and -not ($parts -contains 'tests')
}
foreach ($f in $files) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if (-not $cache.ContainsKey($name)) { $cache[$name] = Get-Command $name -ErrorAction SilentlyContinue }
        $info = $cache[$name]
        if (-not $info -or $info.CommandType -notin 'Cmdlet', 'Function' -or [string]::IsNullOrEmpty($info.Source)) { continue }
        $params = @($info.Parameters.Keys)
        $aliases = @($info.Parameters.Values | ForEach-Object { $_.Aliases })
        foreach ($el in $c.CommandElements) {
            if ($el -is [System.Management.Automation.Language.CommandParameterAst]) {
                $p = $el.ParameterName
                $m = $params | Where-Object { $_ -like "$p*" }
                $a = $aliases | Where-Object { $_ -like "$p*" }
                if (-not $m -and -not $a) { '{0}:{1}  {2} -{3}' -f $f.Name, $el.Extent.StartLineNumber, $name, $p }
            }
        }
    }
}
