# Shared Pester 5 test kit for the cluster-configure solutions. Dot-source at the TOP of a *.Tests.ps1 (discovery time)
# and call Invoke-Day2SolutionTests. Data reaches the run phase through Describe -ForEach (Pester 5 scoping rules).
# Covers contract §8: manifest + converters, outputs parity (manifest = Bicep = Terraform), script hygiene (Apply/Remove,
# -Execute guard, WhatIf default, no Write-Host / Start-Transcript / secret data sources), bicep build + terraform validate
# (skipped — never claimed — when the tool is missing) and the identifier sweep.
#Requires -Version 7.0
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks')]
param()

function Invoke-Day2SolutionTests {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionRoot,
        [Parameter(Mandatory)][string]$ExpectedName,
        [string[]]$AllowedGuids = @(),
        [string[]]$RequiredInputs = @(),
        [string[]]$EntryScripts = @()
    )
    $data = @{
        SolutionRoot   = (Resolve-Path $SolutionRoot).Path
        ExpectedName   = $ExpectedName
        AllowedGuids   = @('00000000-0000-0000-0000-000000000000') + @($AllowedGuids | ForEach-Object { $_.ToLowerInvariant() })
        RequiredInputs = $RequiredInputs
        EntryScripts   = $EntryScripts
        RepoRoot       = (Resolve-Path (Join-Path $SolutionRoot '..\..\..\..')).Path
        HasAz          = [bool](Get-Command az -ErrorAction SilentlyContinue)
        HasTerraform   = [bool](Get-Command terraform -ErrorAction SilentlyContinue)
    }

    Describe '<ExpectedName>: manifest and converters' -ForEach @($data) {
        BeforeAll {
            Import-Module (Join-Path $RepoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
            $envRoot = Join-Path $TestDrive 'env'
            New-Item -ItemType Directory -Force -Path (Join-Path $envRoot 'shared'), (Join-Path $envRoot 'azure-local') | Out-Null
            Copy-Item (Join-Path $RepoRoot 'automation\shared\examples\environment.shared.example.yml') (Join-Path $envRoot 'shared\environment.yml')
            Copy-Item (Join-Path $RepoRoot 'automation\shared\examples\environment.azure-local.example.yml') (Join-Path $envRoot 'azure-local\environment.yml')
            $config = Get-NIC26Config -Scope azure-local -Path (Join-Path $envRoot 'azure-local') -SharedPath (Join-Path $envRoot 'shared')
            $manifest = Get-NIC26SolutionManifest -Path $SolutionRoot
        }
        It 'solution.yml validates and names the solution' { $manifest.name | Should -Be $ExpectedName }
        It 'depends on cluster-deploy (Day-2 runs on a deployed cluster)' { $manifest.depends_on | Should -Contain 'cluster-deploy' }
        It 'declares the inputs the design requires' {
            $names = @($manifest.inputs | ForEach-Object { $_.name })
            foreach ($r in $RequiredInputs) { $names | Should -Contain $r }
            $names | Should -Contain 'names'
        }
        It 'ConvertTo-NIC26BicepParam and ConvertTo-NIC26TfVars render from the example environment' {
            (ConvertTo-NIC26BicepParam -Solution $SolutionRoot -Config $config) | Should -Match 'param names ='
            $json = ConvertTo-NIC26TfVars -Solution $SolutionRoot -Config $config | ConvertFrom-Json -Depth 50
            foreach ($p in $json.names.PSObject.Properties) { $p.Value | Should -Match 'nic26' }
        }
    }

    Describe '<ExpectedName>: outputs parity and IaC rules' -ForEach @($data) {
        BeforeAll {
            Import-Module (Join-Path $RepoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
            $manifest = Get-NIC26SolutionManifest -Path $SolutionRoot
            $bicepOutputs = @(Select-String -Path (Join-Path $SolutionRoot 'bicep\main.bicep') -Pattern '^output\s+(\w+)\s' | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $tfOutputs = @(Select-String -Path (Join-Path $SolutionRoot 'terraform\outputs.tf') -Pattern '^output\s+"(\w+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value })
            $manifestOutputs = @($manifest.outputs | ForEach-Object { $_.name })
            $iac = Get-ChildItem $SolutionRoot -Recurse -File -Include '*.bicep', '*.tf' | Where-Object { $_.FullName -notmatch '\\\.terraform\\' }
        }
        It 'Bicep outputs equal the manifest outputs' { Compare-Object $manifestOutputs $bicepOutputs | Should -BeNullOrEmpty }
        It 'Terraform outputs equal the manifest outputs' { Compare-Object $manifestOutputs $tfOutputs | Should -BeNullOrEmpty }
        It 'IaC never reads secret values and never hardcodes a nic26 resource name' {
            foreach ($f in $iac) {
                $t = (Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*(//|#)' }) -join "`n"
                $t | Should -Not -Match 'getSecret\('
                $t | Should -Not -Match 'data\s+"azurerm_key_vault_secret"'
                $t | Should -Not -Match '[''"][a-z]+-iic-nic26-[a-z0-9-]+[''"]'
            }
        }
    }

    Describe '<ExpectedName>: script hygiene (contract §7)' -ForEach @($data) {
        BeforeAll {
            $scripts = @(Get-ChildItem (Join-Path $SolutionRoot 'scripts') -Filter '*.ps1' -ErrorAction SilentlyContinue)
        }
        It 'every script declares PowerShell 7 and strict mode, no Write-Host, no Start-Transcript' {
            $scripts.Count | Should -BeGreaterThan 0
            foreach ($s in $scripts) {
                $t = Get-Content $s.FullName -Raw
                $code = (Get-Content $s.FullName | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
                $t | Should -Match '#Requires -Version 7\.0'
                $t | Should -Match 'Set-StrictMode -Version Latest'
                $code | Should -Not -Match '(?m)^\s*Write-Host\b'
                $code | Should -Not -Match '(?m)(^|[;{(|]\s*)Start-Transcript\b'
            }
        }
        It 'entry scripts support ShouldProcess, default to WhatIf, require -Execute and offer Apply and Remove' {
            foreach ($name in $EntryScripts) {
                $t = Get-Content (Join-Path $SolutionRoot "scripts\$name") -Raw
                $t | Should -Match 'SupportsShouldProcess'
                $t | Should -Match '\[switch\]\$Execute'
                $t | Should -Match "ValidateSet\('Apply', 'Remove'\)"
            }
        }
        It 'entry scripts refuse Terraform without -BackendConfig before reading any config or touching Azure' {
            foreach ($name in $EntryScripts) {
                { & (Join-Path $SolutionRoot "scripts\$name") -Action Apply -Tool Terraform -WarningAction SilentlyContinue 6>$null } | Should -Throw '*BackendConfig*'
            }
        }
    }

    Describe '<ExpectedName>: IaC gates' -Tag Gate -ForEach @($data) {
        It 'az bicep build main.bicep succeeds' {
            if (-not $HasAz) { Set-ItResult -Skipped -Because 'az not installed'; return }
            & az bicep build --file (Join-Path $SolutionRoot 'bicep\main.bicep') --stdout 2>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        It 'terraform fmt -check, init -backend=false, validate succeed' {
            if (-not $HasTerraform) { Set-ItResult -Skipped -Because 'terraform not installed'; return }
            Push-Location (Join-Path $SolutionRoot 'terraform')
            try {
                & terraform fmt -check -recursive | Out-Null; $LASTEXITCODE | Should -Be 0
                & terraform init -backend=false -input=false 2>&1 | Out-Null; $LASTEXITCODE | Should -Be 0
                & terraform validate 2>&1 | Out-Null; $LASTEXITCODE | Should -Be 0
            }
            finally { Pop-Location }
        }
    }

    Describe '<ExpectedName>: identifier sweep (contract §8)' -ForEach @($data) {
        BeforeAll {
            $files = Get-ChildItem $SolutionRoot -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.terraform\\' -and $_.Name -notlike '*.Tests.ps1' -and $_.Name -notlike '*.generated.*' -and $_.Extension -in '.bicep', '.bicepparam', '.tf', '.json', '.ps1', '.yml', '.md' }
        }
        It 'contains no GUID outside the allow-list (built-in roles / policy definitions only)' {
            $hits = $files | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -AllMatches |
                ForEach-Object { foreach ($m in $_.Matches) { if ($AllowedGuids -notcontains $m.Value.ToLowerInvariant()) { "$($_.Path):$($_.LineNumber) $($m.Value)" } } }
            $hits | Should -BeNullOrEmpty
        }
        It 'contains no literal passwords' {
            $forbidden = 'password\s*=\s*[''"][^''"]+[''"]'
            ($files | Select-String -Pattern $forbidden) | Should -BeNullOrEmpty
        }
        It 'contains only private IP addresses' {
            $hits = $files | Select-String -Pattern '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b' -AllMatches |
                Where-Object { $_.Line -notmatch '^\s*"?contentVersion"?\s*[:=]\s*"?''?1\.0\.0\.0''?"?\s*,?\s*$' } |
                ForEach-Object { foreach ($m in $_.Matches) { if ($m.Value -notmatch '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|169\.254\.|0\.0\.0\.0|168\.63\.129\.16|12\.2609\.|10\.0\.0\.0|4\.1\.2609)') { "$($_.Path):$($_.LineNumber) $($m.Value)" } } }
            $hits | Should -BeNullOrEmpty
        }
    }
}
