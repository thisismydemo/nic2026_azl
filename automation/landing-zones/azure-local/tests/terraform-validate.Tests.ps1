#Requires -Version 7.0
# Gate (contract §8): terraform fmt -check, terraform init -backend=false, terraform validate.
Describe 'Terraform validate' -Tag 'Gate', 'Terraform' {
    BeforeAll {
        $script:TfDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform'
        if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { throw 'terraform is not installed; the Terraform gate cannot run.' }
        Push-Location $script:TfDir
    }
    AfterAll { Pop-Location }

    It 'terraform fmt -check passes' {
        & terraform fmt -check -recursive -no-color | Out-String | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'terraform init -backend=false succeeds (downloads the pinned AVM modules and providers)' {
        $out = & terraform init -backend=false -input=false -no-color 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It 'terraform validate succeeds' {
        $out = & terraform validate -no-color 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It 'contains no data "azurerm_key_vault_secret" (contract §3)' {
        $hits = Get-ChildItem $script:TfDir -Filter '*.tf' | Select-String -Pattern 'data\s+"azurerm_key_vault_secret"'
        @($hits) | Should -BeNullOrEmpty
    }

    It 'commits no backend values (backend "azurerm" block is empty)' {
        $versions = Get-Content (Join-Path $script:TfDir 'versions.tf') -Raw
        $versions | Should -Match 'backend\s+"azurerm"\s+\{\s*\}'
    }

    It 'pins every module and provider version' {
        $all = Get-ChildItem $script:TfDir -Filter '*.tf' | Get-Content -Raw
        $moduleBlocks = [regex]::Matches(($all -join "`n"), '(?s)module\s+"[^"]+"\s*\{.*?\n\}')
        foreach ($m in $moduleBlocks) { if ($m.Value -match 'source\s*=\s*"Azure/') { $m.Value | Should -Match 'version\s*=\s*"\d+\.\d+\.\d+"' } }
        (Get-Content (Join-Path $script:TfDir 'versions.tf') -Raw) | Should -Match 'azurerm[\s\S]*version\s*=\s*">= 4\.81\.0, < 5\.0\.0"'
    }
}
