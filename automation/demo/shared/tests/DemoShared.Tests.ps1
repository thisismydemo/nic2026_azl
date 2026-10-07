#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0'; MaximumVersion = '5.99.99' }
<#
.SYNOPSIS
    Pester 5 tests for automation/demo/shared: screen hygiene, guards, fault locks,
    Test-DemoPrerequisites. No Azure, no device: every wrapper is mocked.
.DESCRIPTION
    Run from the repo root:
        Import-Module Pester -RequiredVersion 5.9.1
        Invoke-Pester -Path automation\demo\shared\tests -Output Detailed
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Test fixtures build SecureStrings from literal test values.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = 'Mock bodies invoked from another script file resolve $script: to that file (dynamic scoping); one global hashtable carries the mock state and is removed in AfterAll.')]
param()

BeforeAll {
    $global:NIC26Test = @{}
    $script:ScriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' 'scripts')).Path
    Import-Module (Join-Path $script:ScriptsRoot 'DemoCommon.psd1') -Force
    $env:NIC26_DEMO_STATE_DIR = Join-Path $TestDrive 'state'
    $env:NIC26_ASSUME_PLATFORM = 'Windows'
    $env:NIC26_ASSUME_TRANSCRIPT = $null
    $env:NIC26_LOG_FILE = Join-Path $TestDrive 'run.log'

    function ConvertTo-TestSecure {
        param([string]$Text)
        return (ConvertTo-SecureString -String $Text -AsPlainText -Force)
    }
    function ConvertFrom-TestSecure {
        param([securestring]$Secure)
        return [System.Net.NetworkCredential]::new('', $Secure).Password
    }
    function Invoke-CaptureAll {
        param([scriptblock]$Script)
        $lines = & $Script *>&1 | ForEach-Object { if ($_ -is [string]) { $_ } else { $_ | Out-String } }
        return ($lines -join "`n")
    }
}

AfterAll {
    Remove-Variable -Name NIC26Test -Scope Global -ErrorAction SilentlyContinue
    $env:NIC26_DEMO_STATE_DIR = $null
    $env:NIC26_ASSUME_PLATFORM = $null
    $env:NIC26_ASSUME_TRANSCRIPT = $null
    $env:NIC26_LOG_FILE = $null
}

Describe 'Screen-hygiene filter (Hide-DemoSensitiveText / Write-DemoScreen)' {
    BeforeEach { Clear-DemoHiddenTerm -Confirm:$false }

    It 'masks a registered term wherever it appears' {
        Add-DemoHiddenTerm -Term 'acmecorp'
        $out = Hide-DemoSensitiveText -InputObject 'vault kv-acmecorp-mgmt-01 on acmecorp.example'
        $out | Should -Not -Match 'acmecorp'
        $out | Should -Match '[hidden]'
    }
    It 'masks a registered pattern, from Add-DemoHiddenPattern and from the configuration' {
        Add-DemoHiddenPattern -Pattern '(?i)\bacme-[a-z0-9-]*'
        $out = Hide-DemoSensitiveText -InputObject 'node acme-n01 up'
        $out | Should -Not -Match 'acme'
        Clear-DemoHiddenTerm -Confirm:$false
        Initialize-DemoScreenHygiene -Config @{ screen_hidden_patterns = @('(?i)\bzeta-[a-z0-9-]*') }
        $out = Hide-DemoSensitiveText -InputObject 'node zeta-n02 up'
        $out | Should -Not -Match 'zeta'
        { Add-DemoHiddenPattern -Pattern '(unclosed' } | Should -Throw '*Invalid*'
    }
    It 'masks GUIDs by default and keeps them with -KeepGuid' {
        $g = '12345678-abcd-4ef0-9876-0123456789ab'
        (Hide-DemoSensitiveText -InputObject "/subscriptions/$g/x") | Should -Not -Match $g
        (Hide-DemoSensitiveText -InputObject "/subscriptions/$g/x" -KeepGuid) | Should -Match $g
    }
    It 'masks the tenant domain, tenant id, subscription ids and owner e-mail loaded from the config' {
        $cfg = @{
            tenant_domain = 'contoso-real.onmicrosoft.com'
            tenant_id     = 'aaaaaaaa-1111-2222-3333-444444444444'
            owner_email   = 'owner@contoso-real.com'
            subscriptions = @{ avd = 'bbbbbbbb-1111-2222-3333-444444444444' }
            tags          = @{ owner = 'owner@contoso-real.com' }
            screen_hidden_terms = @('secretcorp')
        }
        Initialize-DemoScreenHygiene -Config $cfg
        (Get-DemoHiddenTermList) | Should -Contain 'contoso-real.onmicrosoft.com'
        (Get-DemoHiddenTermList) | Should -Contain 'secretcorp'
        $out = Hide-DemoSensitiveText -InputObject 'user thor@contoso-real.onmicrosoft.com at secretcorp, owner owner@contoso-real.com' -KeepGuid
        $out | Should -Not -Match 'contoso-real'
        $out | Should -Not -Match 'secretcorp'
    }
    It 'leaves IIC lab names untouched' {
        $text = 'rg-iic-nic26-azl-eus-01 nic26-clus01 vdpool-iic-nic26-hybrid-eus-01 thor@contoso.com'
        (Hide-DemoSensitiveText -InputObject $text) | Should -Be $text
    }
    It 'Write-DemoScreen filters the Information stream and never uses Write-Host' {
        Add-DemoHiddenTerm -Term 'acmecorp'
        $captured = Write-DemoScreen -InputObject 'node acmecorp-node-01 ready' 6>&1
        ($captured | Out-String) | Should -Not -Match 'acmecorp'
        ($captured | Out-String) | Should -Match 'ready'
        (Get-Content -LiteralPath (Join-Path $script:ScriptsRoot 'DemoCommon.psm1') -Raw) | Should -Not -Match '(?m)(^\s*|\|\s*|;\s*|\{\s*)Write-Host\b'
    }
    It 'filters objects piped as tables' {
        Add-DemoHiddenTerm -Term 'acmecorp'
        $rows = @([pscustomobject]@{ Name = 'acmecorp-thing'; State = 'Up' })
        $out = ($rows | Format-Table | Out-String | Hide-DemoSensitiveText) -join "`n"
        $out | Should -Not -Match 'acmecorp'
        $out | Should -Match 'Up'
    }
}

Describe 'Guards' {
    It 'Assert-DemoSecretSafeHost refuses a non-Windows host' {
        $env:NIC26_ASSUME_PLATFORM = 'Linux'
        try { { Assert-DemoSecretSafeHost } | Should -Throw '*Windows jump server*' }
        finally { $env:NIC26_ASSUME_PLATFORM = 'Windows' }
    }
    It 'Assert-DemoSecretSafeHost refuses while a transcript is active' {
        $env:NIC26_ASSUME_TRANSCRIPT = '1'
        try { { Assert-DemoSecretSafeHost } | Should -Throw '*transcript*' }
        finally { $env:NIC26_ASSUME_TRANSCRIPT = $null }
    }
    It 'Confirm-DemoTypedPhrase requires the exact phrase (case-sensitive) and asks when none is provided' {
        Confirm-DemoTypedPhrase -Phrase 'POWER OFF n01' -Provided 'POWER OFF n01' | Should -BeTrue
        Confirm-DemoTypedPhrase -Phrase 'POWER OFF n01' -Provided 'power off n01' | Should -BeFalse
        Mock Read-DemoHostLine { 'POWER OFF n01' } -ModuleName DemoCommon
        Confirm-DemoTypedPhrase -Phrase 'POWER OFF n01' | Should -BeTrue
        Should -Invoke Read-DemoHostLine -Times 1 -ModuleName DemoCommon
    }
    It 'Compare-DemoSecureString reports match/mismatch only' {
        Compare-DemoSecureString -Reference (ConvertTo-TestSecure 'Same-Value-1') -Difference (ConvertTo-TestSecure 'Same-Value-1') | Should -BeTrue
        Compare-DemoSecureString -Reference (ConvertTo-TestSecure 'Same-Value-1') -Difference (ConvertTo-TestSecure 'Same-Value-2') | Should -BeFalse
        Compare-DemoSecureString -Reference (ConvertTo-TestSecure 'short') -Difference (ConvertTo-TestSecure 'short-and-longer') | Should -BeFalse
    }
    It 'New-DemoRandomSecureString honours the length and uses all four classes' {
        $s = New-DemoRandomSecureString -Length 32
        $s.Length | Should -Be 32
        $plain = ConvertFrom-TestSecure $s
        $plain | Should -Match '[A-Z]'
        $plain | Should -Match '[a-z]'
        $plain | Should -Match '[0-9]'
        $plain | Should -Match '[!#%+\-=?@_]'
        (ConvertFrom-TestSecure (New-DemoRandomSecureString -Length 14 -Alphanumeric)) | Should -Match '^[A-Za-z0-9]{14}$'
    }
}

Describe 'Fault locks' {
    BeforeEach { Get-ChildItem -LiteralPath (Get-DemoStateRoot) -Filter 'fault-*.json' -File | Remove-Item -Force }
    It 'records, lists and removes a lock without secrets' {
        $null = New-DemoFaultLock -Fault Drive -Target 'nic26-01-n01' -Scope 'azure-local' -Detail @{ Method = 'PnpDisable'; SerialNumber = 'S1' } -Confirm:$false
        $locks = @(Get-DemoFaultLock -Scope 'azure-local')
        $locks.Count | Should -Be 1
        $locks[0].Fault | Should -Be 'Drive'
        $locks[0].Detail.SerialNumber | Should -Be 'S1'
        @(Get-DemoFaultLock -Scope 'avd').Count | Should -Be 0
        Remove-DemoFaultLock -Fault Drive -Confirm:$false
        @(Get-DemoFaultLock -Scope 'all').Count | Should -Be 0
    }
    It 'New-DemoFaultLock honours -WhatIf' {
        $null = New-DemoFaultLock -Fault IntentDrift -Target 'n02' -Scope 'azure-local' -WhatIf
        @(Get-DemoFaultLock).Count | Should -Be 0
    }
}

Describe 'Test-DemoPrerequisites.ps1' {
    It 'returns rows and no RED for the state checks when the config loads' {
        Mock Get-DemoConfig { @{ org = 'iic' } }
        $rows = @(& (Join-Path $script:ScriptsRoot 'Test-DemoPrerequisites.ps1') -Scope avd -SkipAzure -PassThru 6>$null)
        $rows.Count | Should -BeGreaterThan 10
        @($rows | Where-Object { $_.Section -eq 'state' -and $_.Status -eq 'RED' }).Count | Should -Be 0
        @($rows | Where-Object { $_.Check -like 'environment files load*' }).Status | Should -Be 'GREEN'
    }
}
