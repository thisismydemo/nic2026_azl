#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for Invoke-NIC26ArmDeployment: the compact REST path that avoids the 4 MB request limit of New-AzSubscriptionDeployment.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll variables are consumed inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Tests build a throwaway secure value to prove it never reaches an error message.')]
param()

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1') -Force
    $script:Dir = Join-Path $TestDrive 'arm'
    New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
    $script:Tpl = Join-Path $script:Dir 'main.json'
    Set-Content -LiteralPath $script:Tpl -Value '{"$schema":"https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#","contentVersion":"1.0.0.0","parameters":{"enabled_stages":{"type":"array"},"jump_admin_password":{"type":"securestring"}},"resources":[]}'
    $script:Prm = Join-Path $script:Dir 'p.json'
    Set-Content -LiteralPath $script:Prm -Value '{"parameters":{"location":{"value":"eastus"}}}'
}

Describe 'Invoke-NIC26ArmDeployment' {
    BeforeEach { $script:Sent = [System.Collections.Generic.List[object]]::new() }

    It 'posts a compact what-if body and returns the changes after polling' {
        Mock Invoke-AzRestMethod -ModuleName NIC26.Automation -MockWith {
            if ($Method -eq 'POST') { return [pscustomobject]@{ StatusCode = 202; Content = ''; Headers = @{ Location = 'https://example.invalid/op' } } }
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"status":"Succeeded","properties":{"changes":[{"changeType":"Create","resourceId":"/subscriptions/s/resourceGroups/rg"}]}}' }
        }
        Mock Start-Sleep -ModuleName NIC26.Automation -MockWith { }
        $r = Invoke-NIC26ArmDeployment -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name t -Location eastus -TemplateFile $script:Tpl -ParameterFile $script:Prm -ParameterOverrides @{ enabled_stages = @('S1') } -Preview -InformationAction SilentlyContinue
        $r.Mode | Should -Be 'WhatIf'
        $r.Changes.Count | Should -Be 1
        $r.Changes[0].ChangeType | Should -Be 'Create'
        Should -Invoke Invoke-AzRestMethod -ModuleName NIC26.Automation -ParameterFilter { $Method -eq 'POST' -and $Path -like '*/deployments/t/whatIf?api-version=*' -and $Payload -notmatch "`n" -and $Payload -match '"enabled_stages":\{"value":\["S1"\]\}' } -Times 1 -Exactly
    }
    It 'deploys with PUT and returns the outputs' {
        Mock Invoke-AzRestMethod -ModuleName NIC26.Automation -MockWith {
            if ($Method -eq 'PUT') { return [pscustomobject]@{ StatusCode = 201; Headers = @{}; Content = '{"properties":{"provisioningState":"Running"}}' } }
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"properties":{"provisioningState":"Succeeded","correlationId":"c-1","outputs":{"kvId":{"type":"String","value":"abc"}}}}' }
        }
        Mock Start-Sleep -ModuleName NIC26.Automation -MockWith { }
        $r = Invoke-NIC26ArmDeployment -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name t -Location eastus -TemplateFile $script:Tpl -ParameterFile $script:Prm -InformationAction SilentlyContinue
        $r.Mode | Should -Be 'Deploy'
        $r.Outputs.kvId | Should -Be 'abc'
        $r.CorrelationId | Should -Be 'c-1'
    }
    It 'throws the service error code and message, not the request body' {
        Mock Invoke-AzRestMethod -ModuleName NIC26.Automation -MockWith { [pscustomobject]@{ StatusCode = 400; Headers = @{}; Content = '{"error":{"code":"InvalidTemplate","message":"duplicate role assignment"}}' } }
        { Invoke-NIC26ArmDeployment -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name t -Location eastus -TemplateFile $script:Tpl -ParameterFile $script:Prm -ParameterOverrides @{ jump_admin_password = (ConvertTo-SecureString 'Sup3r-Secret-Value' -AsPlainText -Force) } -InformationAction SilentlyContinue } |
            Should -Throw '*InvalidTemplate - duplicate role assignment*'
    }
    It 'never puts a secure value into an error message' {
        Mock Invoke-AzRestMethod -ModuleName NIC26.Automation -MockWith { throw 'boom with payload' }
        $msg = try { Invoke-NIC26ArmDeployment -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name t -Location eastus -TemplateFile $script:Tpl -ParameterFile $script:Prm -ParameterOverrides @{ jump_admin_password = (ConvertTo-SecureString 'Sup3r-Secret-Value' -AsPlainText -Force) } -InformationAction SilentlyContinue } catch { $_.Exception.Message }
        $msg | Should -Be 'Deploy request could not be sent.'
        $msg | Should -Not -Match 'Sup3r'
    }
    It 'refuses a template that is neither .bicep nor .json' {
        { Invoke-NIC26ArmDeployment -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name t -Location eastus -TemplateFile (Join-Path $script:Dir 'x.txt') -ParameterFile $script:Prm } | Should -Throw '*.bicep or .json*'
    }
}

