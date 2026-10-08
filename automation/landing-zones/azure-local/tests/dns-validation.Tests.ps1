#Requires -Version 7.0
# Unit tests extract only the read-only DNS probe; no tenant or network calls.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester fixture variables are read by extracted production scriptblocks.')]
param()

BeforeAll {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../scripts/Test-LandingZone.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Validator parse errors' }
    $probe = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-LzDcDns' }, $true)
    . ([scriptblock]::Create($probe.Extent.Text))
    $keyHelper = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-LzConfigKey' }, $true)
    . ([scriptblock]::Create($keyHelper.Extent.Text))
    $lawCheck = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-LzCheck' -and $node.CommandElements[1].Value -eq 'law' }, $true)
    $script:LawProbe = $lawCheck.CommandElements[2].ScriptBlock.GetScriptBlock()
    # Own the dependency signatures: earlier suites may leave narrower non-advanced Az stubs.
    function Get-AzResource {
        [CmdletBinding()]
        param([string]$ResourceId)
        throw 'Unit test must mock Get-AzResource'
    }
    function Get-AzOperationalInsightsWorkspace {
        [CmdletBinding()]
        param([string]$Name, [string]$ResourceGroupName)
        throw 'Unit test must mock Get-AzOperationalInsightsWorkspace'
    }
    function Add-LzResult {
        param($Name, $Status, $Detail)
        [pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail }
    }
}
Describe 'DNS response acceptance from each configured server' {
    BeforeEach {
        Mock Test-NetConnection { $true }
        Mock Resolve-DnsName { [pscustomobject]@{ Type = 'A'; IPAddress = '192.0.2.10' } }
    }
    It 'does not pass on TCP success when DNS times out' {
        Mock Resolve-DnsName { throw 'Synthetic DNS timeout' }
        $result = Test-LzDcDns -Servers @('192.0.2.1') -QueryName 'example.vault.azure.net'
        $result.Tcp53 | Should -BeTrue
        $result.DnsAnswered | Should -BeFalse
    }
    It 'rejects empty and non-A answers' {
        Mock Resolve-DnsName { [pscustomobject]@{ Type = 'CNAME'; IPAddress = '' } }
        (Test-LzDcDns -Servers @('192.0.2.1') -QueryName 'example.vault.azure.net').DnsAnswered | Should -BeFalse
        Mock Resolve-DnsName { }
        (Test-LzDcDns -Servers @('192.0.2.1') -QueryName 'example.vault.azure.net').DnsAnswered | Should -BeFalse
    }
    It 'queries every server and preserves one failing response' {
        Mock Resolve-DnsName { throw 'Synthetic DNS timeout' } -ParameterFilter { $Server -eq '192.0.2.2' }
        $results = @(Test-LzDcDns -Servers @('192.0.2.1', '192.0.2.2') -QueryName 'example.vault.azure.net')
        $results.Count | Should -Be 2
        $results[0].DnsAnswered | Should -BeTrue
        $results[1].DnsAnswered | Should -BeFalse
        Should -Invoke Resolve-DnsName -Times 2 -Exactly -ParameterFilter { -not $TcpOnly -and $DnsOnly -and $NoHostsFile -and $Type -eq 'A' }
    }
    It 'records actual host vantage and answers from all servers' {
        $results = @(Test-LzDcDns -Servers @('192.0.2.1', '192.0.2.2') -QueryName 'example.vault.azure.net')
        @($results | Where-Object { -not $_.DnsAnswered }).Count | Should -Be 0
        $results[0].HostVantage | Should -Be $env:COMPUTERNAME
        $results[0].QueryName | Should -Be 'example.vault.azure.net'
    }
    It 'continues normal DNS queries after a TCP diagnostic throws' {
        Mock Test-NetConnection { throw 'Synthetic TCP failure' }
        $results = @(Test-LzDcDns -Servers @('192.0.2.1', '192.0.2.2') -QueryName 'example.vault.azure.net')
        $results.Count | Should -Be 2
        @($results | Where-Object { -not $_.DnsAnswered }).Count | Should -Be 0
        Should -Invoke Resolve-DnsName -Times 2 -Exactly
    }
}
Describe 'Central workspace respects platform ownership' {
    It 'checks the configured central workspace rather than requiring a workload workspace' {
        $Config = @{ central_log_analytics_workspace_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.OperationalInsights/workspaces/law-example' }
        Mock Get-AzResource { [pscustomobject]@{ Name = 'law-example' } }
        Mock Get-AzOperationalInsightsWorkspace { throw 'Must not query workload workspace' }
        (& $script:LawProbe).Status | Should -Be 'Pass'
        Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter { $ResourceId -eq $Config.central_log_analytics_workspace_id -and $ErrorAction -eq 'Stop' }
        Should -Invoke Get-AzOperationalInsightsWorkspace -Times 0
    }
    It 'does not turn denied central workspace access into a pass' {
        $Config = @{ central_log_analytics_workspace_id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-example/providers/Microsoft.OperationalInsights/workspaces/law-example' }
        Mock Get-AzResource { throw 'Synthetic denied read' }
        { & $script:LawProbe } | Should -Throw '*denied read*'
    }
}
