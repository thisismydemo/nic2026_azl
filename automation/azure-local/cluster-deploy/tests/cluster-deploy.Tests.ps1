#Requires -Version 7.0
# Pester 5 — cluster-deploy quality gates (contract §8): manifest, converters, outputs parity (manifest = Bicep = Terraform),
# script hygiene (WhatIf default, -Execute guard, no secret printing, no transcript), bicep build / terraform validate
# (skipped when the tool is missing — reported as skipped, never claimed), and the secrets / identifier sweep.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks')]
param()

BeforeAll {
    $script:solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
    Import-Module (Join-Path $script:repoRoot 'automation\shared\powershell\NIC26.Automation\NIC26.Automation.psd1') -Force
    . (Join-Path $script:solutionRoot 'scripts\ClusterDeploy.Common.ps1')

    # Scratch environment built from the committed examples (IIC values, all-zero GUIDs) so converters run without real values.
    $script:envRoot = Join-Path $TestDrive 'env'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:envRoot 'shared'), (Join-Path $script:envRoot 'azure-local') | Out-Null
    Copy-Item (Join-Path $script:repoRoot 'automation\shared\examples\environment.shared.example.yml') (Join-Path $script:envRoot 'shared\environment.yml')
    Copy-Item (Join-Path $script:repoRoot 'automation\shared\examples\environment.azure-local.example.yml') (Join-Path $script:envRoot 'azure-local\environment.yml')
    $script:config = Get-NIC26Config -Scope azure-local -Path (Join-Path $script:envRoot 'azure-local') -SharedPath (Join-Path $script:envRoot 'shared')
    $script:manifest = Get-NIC26SolutionManifest -Path $script:solutionRoot

    $script:bicepOutputs = @(Select-String -Path (Join-Path $script:solutionRoot 'bicep\main.bicep') -Pattern '^output\s+(\w+)\s' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $script:tfOutputs = @(Select-String -Path (Join-Path $script:solutionRoot 'terraform\outputs.tf') -Pattern '^output\s+"(\w+)"' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    $script:manifestOutputs = @($script:manifest.outputs | ForEach-Object { $_.name })
    $script:hasAz = [bool](Get-Command az -ErrorAction SilentlyContinue)
    $script:hasTerraform = [bool](Get-Command terraform -ErrorAction SilentlyContinue)
}

Describe 'cluster-deploy manifest and converters' {
    It 'solution.yml validates against solution.schema.json' {
        $script:manifest.name | Should -Be 'cluster-deploy'
        $script:manifest.destroy | Should -Be 'none'
        $script:manifest.depends_on | Should -Contain 'lz-azure-local'
    }
    It 'declares the design inputs that drive the deployment' {
        $names = @($script:manifest.inputs | ForEach-Object { $_.name })
        foreach ($required in 'cluster_name', 'identity', 'kv_azl_name', 'witness', 'nodes', 'intents', 'ip_plan', 'vlans', 'qos', 'rdma_protocol', 'networking_pattern', 'azl_rp_app_object_id', 'names') { $names | Should -Contain $required }
    }
    It 'rdma_protocol is a string input, never a numeric keyword' {
        ($script:manifest.inputs | Where-Object { $_.name -eq 'rdma_protocol' }).type | Should -Be 'string'
        (Get-Content (Join-Path $script:solutionRoot 'bicep\main.bicep') -Raw) | Should -Not -Match 'networkDirectTechnology:\s*[''"]?4[''"]?'
    }
    It 'ConvertTo-NIC26BicepParam renders every declared input and the names catalog' {
        $text = ConvertTo-NIC26BicepParam -Solution $script:solutionRoot -Config $script:config
        $text | Should -Match "param names ="
        $text | Should -Match "st_diag: 'stiicnic26diageus01'"
        $text | Should -Match "cl_azl: 'cl-iic-nic26-azl-eus-01'"
        $text | Should -Not -Match 'deployment_mode'   # generated per run, never from files
    }
    It 'ConvertTo-NIC26TfVars renders JSON with the names map and no secret values' {
        $json = ConvertTo-NIC26TfVars -Solution $script:solutionRoot -Config $script:config | ConvertFrom-Json -Depth 50
        $json.names.kv_azl | Should -Be 'kv-iic-nic26-azl-eus-01'
        $json.identity.local_admin_password_secret | Should -Match '^keyvault://'
        $json.witness.storage_account_name | Should -Be $json.names.st_witness
    }
    It 'every generated name contains nic26 and passes Test-NIC26ResourceName' {
        $json = ConvertTo-NIC26TfVars -Solution $script:solutionRoot -Config $script:config | ConvertFrom-Json -Depth 50
        foreach ($p in $json.names.PSObject.Properties) { $p.Value | Should -Match 'nic26' }
    }
}

Describe 'outputs parity (manifest = Bicep = Terraform)' {
    It 'Bicep outputs equal the manifest outputs' { Compare-Object $script:manifestOutputs $script:bicepOutputs | Should -BeNullOrEmpty }
    It 'Terraform outputs equal the manifest outputs' { Compare-Object $script:manifestOutputs $script:tfOutputs | Should -BeNullOrEmpty }
    It 'both tracks use the same Azure Local api-version from the quickstart' {
        (Get-Content (Join-Path $script:solutionRoot 'bicep\main.bicep') -Raw) | Should -Match 'deploymentSettings@2025-09-15-preview'
        (Get-Content (Join-Path $script:solutionRoot 'terraform\main.tf') -Raw) | Should -Match 'deploymentSettings@2025-09-15-preview'
    }
    It 'both tracks declare identityProvider LocalIdentity and the two ECE secret names' {
        foreach ($f in 'bicep\main.bicep', 'terraform\main.tf') {
            # code lines only: comments explain why DefaultARBApplication is NOT part of this path
            $t = (Get-Content (Join-Path $script:solutionRoot $f) | Where-Object { $_ -notmatch '^\s*(//|#)' }) -join "`n"
            $t | Should -Match 'LocalIdentity'
            $t | Should -Match 'LocalAdminCredential'
            $t | Should -Match 'WitnessStorageKey'
            $t | Should -Not -Match 'DefaultARBApplication'
            $t | Should -Not -Match 'getSecret\('
            $t | Should -Not -Match 'data\s+"azurerm_key_vault_secret"'
        }
    }
}

Describe 'script hygiene (contract §7)' {
    # discovery-time list (Pester 5/6: -ForEach data must exist before run)
    $scripts = @(Get-ChildItem (Join-Path $PSScriptRoot '..\scripts') -Filter '*.ps1')
    It '<_.Name> declares PowerShell 7, strict mode and Stop' -ForEach $scripts {
        $t = Get-Content $_.FullName -Raw
        $t | Should -Match '#Requires -Version 7\.0'
        $t | Should -Match 'Set-StrictMode -Version Latest'
    }
    It '<_.Name> never calls Write-Host or Start-Transcript' -ForEach $scripts {
        $code = (Get-Content $_.FullName | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"   # code lines; help text may mention them
        $code | Should -Not -Match '(?m)^\s*Write-Host\b'
        $code | Should -Not -Match '(?m)(^|[;{(|]\s*)Start-Transcript\b'
    }
    It 'state-changing scripts support ShouldProcess, default to WhatIf and require -Execute' {
        foreach ($name in 'Invoke-ClusterDeploy.ps1', 'Set-ClusterDeploymentSecrets.ps1', 'Set-ClusterVaultPublicAccess.ps1') {
            $t = Get-Content (Join-Path $script:solutionRoot "scripts\$name") -Raw
            $t | Should -Match 'SupportsShouldProcess'
            $t | Should -Match '\[switch\]\$Execute'
            $t | Should -Match 'if \(-not \$Execute\) \{ \$WhatIfPreference = \$true \}'
        }
    }
    It 'the Generate stage writes the local generated files even in the default WhatIf run, so Preview finds its inputs' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Invoke-ClusterDeploy.ps1') -Raw
        $t | Should -Match 'ConvertTo-NIC26BicepParam[^\r\n]*-Execute -WhatIf:\$false'
        $t | Should -Match 'ConvertTo-NIC26TfVars[^\r\n]*-Execute -WhatIf:\$false'
    }
    It 'the secret writer never prints, returns or persists values' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Set-ClusterDeploymentSecrets.ps1') -Raw
        $t | Should -Not -Match 'Write-(Information|Output|Verbose|Warning)[^\n]*\$(pass|encoded|key1|user)\b'
        $t | Should -Not -Match 'Set-Content|Out-File|Export-Clixml'
        $t | Should -Match 'Refusing: this script handles secret material'
        $t | Should -Not -Match 'ConvertTo-SecureString'   # SecureString is built char-by-char from the in-memory value
        $t | Should -Match 'ConvertTo-ClusterDeploySecureString -Text \$encoded'
    }
    It 'the secret writer carries the five-tag rule, takes owner/project from the shared tags, and sets no NotBefore' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Set-ClusterDeploymentSecrets.ps1') -Raw
        foreach ($tag in "owner =", "project =", "'rotation-days' =", "'managed-by' =", "lifecycle =") { $t | Should -Match ([regex]::Escape($tag)) }
        $t | Should -Match '\$inputs\.tags'
        $t | Should -Not -Match '-NotBefore'
    }
    It 'the secret writer reads fail-closed: no SilentlyContinue on Get-AzKeyVaultSecret, and a not-found helper is used' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Set-ClusterDeploymentSecrets.ps1') -Raw
        $t | Should -Not -Match 'Get-AzKeyVaultSecret[^\r\n]*SilentlyContinue'
        $t | Should -Match 'Get-ClusterDeploySecretOrNull'
    }
    It 'Get-ClusterDeploySecretOrNull returns null only for a confirmed not-found and throws on any other read failure' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Set-ClusterDeploymentSecrets.ps1') -Raw
        $m = [regex]::Match($t, '(?s)function Get-ClusterDeploySecretOrNull \{.*?\r?\n\}\r?\n')
        $m.Success | Should -BeTrue
        function global:Get-AzKeyVaultSecret { [CmdletBinding()] param($VaultName, $Name) }
        try {
            . ([scriptblock]::Create($m.Value))
            Mock Get-AzKeyVaultSecret { throw 'Operation returned an invalid status code NotFound: SecretNotFound' } -ParameterFilter { $Name -eq 'absent' }
            Mock Get-AzKeyVaultSecret { throw 'Forbidden (403): caller is not authorized' } -ParameterFilter { $Name -eq 'denied' }
            Mock Get-AzKeyVaultSecret { [pscustomobject]@{ Name = $Name; Version = 'v1' } } -ParameterFilter { $Name -eq 'present' }
            Get-ClusterDeploySecretOrNull -VaultName 'kv' -Name 'absent' | Should -BeNullOrEmpty
            (Get-ClusterDeploySecretOrNull -VaultName 'kv' -Name 'present').Version | Should -Be 'v1'
            { Get-ClusterDeploySecretOrNull -VaultName 'kv' -Name 'denied' } | Should -Throw '*not a not-found*'
        }
        finally { Remove-Item -Path 'Function:\global:Get-AzKeyVaultSecret' -ErrorAction SilentlyContinue }
    }
    It 'Invoke-ClusterDeploy refuses a Deploy execute without -Execute before touching Azure' {
        { & (Join-Path $script:solutionRoot 'scripts\Invoke-ClusterDeploy.ps1') -Pass Deploy -Stage Execute } | Should -Throw '*-Execute*'
    }
    It 'Test-ClusterPostDeployment is read-only (no Set-/New-/Remove- Az calls)' {
        $t = Get-Content (Join-Path $script:solutionRoot 'scripts\Test-ClusterPostDeployment.ps1') -Raw
        $t | Should -Not -Match '\b(Set|New|Remove|Update)-Az(?!Context)\w+'
        $t | Should -Not -Match 'Invoke-AzRestMethod[^\n]*-Method (PUT|POST|PATCH|DELETE)'
    }
    It 'common helpers parse inputs from the example tfvars' {
        $i = Get-ClusterDeployInputs -InputFile (Join-Path $script:solutionRoot 'terraform\terraform.example.tfvars.json')
        $i.cluster_name | Should -Be 'nic26-clus01'
        (ConvertTo-ClusterDeployResult -Check 'x' -Result 'pass' -Evidence 'y').result | Should -Be 'pass'
    }
}

Describe 'IaC gates' -Tag Gate {
    It 'az bicep build main.bicep succeeds' -Skip:(-not $script:hasAz) {
        & az bicep build --file (Join-Path $script:solutionRoot 'bicep\main.bicep') --stdout 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'az bicep build-params main.example.bicepparam succeeds' -Skip:(-not $script:hasAz) {
        & az bicep build-params --file (Join-Path $script:solutionRoot 'bicep\main.example.bicepparam') --stdout 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'terraform fmt -check, init -backend=false and validate succeed' -Skip:(-not $script:hasTerraform) {
        Push-Location (Join-Path $script:solutionRoot 'terraform')
        try {
            & terraform fmt -check -recursive | Out-Null; $LASTEXITCODE | Should -Be 0
            & terraform init -backend=false -input=false 2>&1 | Out-Null; $LASTEXITCODE | Should -Be 0
            & terraform validate 2>&1 | Out-Null; $LASTEXITCODE | Should -Be 0
        }
        finally { Pop-Location }
    }
}

Describe 'secrets and identifier sweep (contract §8)' {
    BeforeAll {
        $script:files = Get-ChildItem $script:solutionRoot -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.terraform\\' -and $_.Name -notlike '*.Tests.ps1' -and $_.Name -notlike '*.generated.*' -and $_.Extension -in '.bicep', '.bicepparam', '.tf', '.json', '.ps1', '.yml', '.md' }
        # Platform constants allowed in this solution (built-in role definition IDs; the Azure Local RP app ID quoted in Learn).
        $script:allowedGuids = 'f5819b54-e033-4d82-ac66-4fec3cbf3f4c', '865ae368-6a45-4bd1-8fbf-0d5151f56fc1', 'c99c945f-8bd1-4fb1-a903-01460aae6068', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7', 'a4417e6f-fecd-4de8-b567-7b0420556985', '1412d89f-b8a8-4111-b4fd-e82905cbd85d', '00000000-0000-0000-0000-000000000000'
    }
    It 'contains no GUID outside the documented allow-list' {
        $hits = $script:files | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -AllMatches |
            ForEach-Object { foreach ($m in $_.Matches) { if ($script:allowedGuids -notcontains $m.Value.ToLowerInvariant()) { "$($_.Path):$($_.LineNumber) $($m.Value)" } } }
        $hits | Should -BeNullOrEmpty
    }
    It 'contains no literal password assignment' {
        $forbidden = 'password\s*=\s*[''"][^''"]+[''"]'
        $hits = $script:files | Select-String -Pattern $forbidden
        $hits | Should -BeNullOrEmpty
    }
    It 'contains only private / documentation IP addresses' {
        $hits = $script:files | Select-String -Pattern '\b(?!10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|169\.254\.|0\.0\.0\.0|255\.|168\.63\.129\.16)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b' -AllMatches |
            ForEach-Object { foreach ($m in $_.Matches) { if ($m.Value -notmatch '^\d+\.\d+\.\d+\.\d+$' -or $m.Value -match '^(\d{1,2}|1\d{2}|2[0-4]\d|25[0-5])\.') { "$($_.Path):$($_.LineNumber) $($m.Value)" } } } |
            Where-Object { $_ -notmatch '12\.2609\.1003\.7|10\.0\.0\.0|4\.1\.2609\.1' }
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'pass outcome and secret usability (review R-33)' {
    BeforeAll {
        $script:solutionRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        . (Join-Path $script:solutionRoot 'scripts\ClusterDeploy.Common.ps1')
    }
    It 'Bicep: a leftover status is never an outcome until this submission''s ARM deployment is Succeeded' -ForEach @(
        @{ Arm = 'Pending'; Val = 'Success'; Dep = 'Failed'; Pass = 'Validate'; Expected = $null }
        @{ Arm = 'Running'; Val = 'Success'; Dep = 'Success'; Pass = 'Deploy'; Expected = $null }
        @{ Arm = 'Succeeded'; Val = 'Success'; Dep = 'Success'; Pass = 'Validate'; Expected = 'Success' }
        @{ Arm = 'Succeeded'; Val = 'Success'; Dep = 'Success'; Pass = 'Deploy'; Expected = 'Success' }
        @{ Arm = 'Failed'; Val = 'Success'; Dep = 'Success'; Pass = 'Deploy'; Expected = 'Failed' }
        @{ Arm = 'Canceled'; Val = 'Success'; Dep = ''; Pass = 'Validate'; Expected = 'Failed' }
        @{ Arm = 'Succeeded'; Val = 'InProgress'; Dep = ''; Pass = 'Validate'; Expected = $null }
    ) {
        Resolve-ClusterDeployPassOutcome -Tool Bicep -Pass $Pass -ArmState $Arm -ValidationStatus $Val -DeploymentStatus $Dep | Should -Be $Expected
    }
    It 'Terraform: the finished apply makes the status the outcome' {
        Resolve-ClusterDeployPassOutcome -Tool Terraform -Pass Deploy -ArmState 'n/a' -ValidationStatus 'Success' -DeploymentStatus 'Failed' | Should -Be 'Failed'
        Resolve-ClusterDeployPassOutcome -Tool Terraform -Pass Deploy -ArmState 'n/a' -ValidationStatus 'Success' -DeploymentStatus 'InProgress' | Should -BeNullOrEmpty
    }
    It 'a secret must exist, be enabled and outlive the pass' {
        $until = [datetime]::UtcNow.AddHours(4)
        Test-ClusterDeploySecretUsable -Secret $null -ValidUntil $until | Should -Be 'missing'
        Test-ClusterDeploySecretUsable -Secret ([pscustomobject]@{ Enabled = $false; Expires = $null }) -ValidUntil $until | Should -Be 'disabled'
        Test-ClusterDeploySecretUsable -Secret ([pscustomobject]@{ Enabled = $true; Expires = [datetime]::UtcNow.AddHours(1) }) -ValidUntil $until | Should -BeLike 'expires before*'
        Test-ClusterDeploySecretUsable -Secret ([pscustomobject]@{ Enabled = $true; Expires = [datetime]::UtcNow.AddDays(30) }) -ValidUntil $until | Should -BeNullOrEmpty
        Test-ClusterDeploySecretUsable -Secret ([pscustomobject]@{ Enabled = $true; Expires = $null }) -ValidUntil $until | Should -BeNullOrEmpty
    }
    It 'the wrapper submits in Incremental mode, so a mode-dependent template can never delete the pass-1 resources' {
        $text = Get-Content -LiteralPath (Join-Path $script:solutionRoot 'scripts\Invoke-ClusterDeploy.ps1') -Raw
        $text | Should -Match "'--mode', 'Incremental'"
        $text | Should -Not -Match '(?i)--mode.{0,12}complete'
    }
    It 'the wrapper checks the secrets and the stamped ARM record before and while a pass runs' {
        $text = Get-Content -LiteralPath (Join-Path $script:solutionRoot 'scripts\Invoke-ClusterDeploy.ps1') -Raw
        $text | Should -Match 'Test-ClusterDeploySecretUsable'
        $text | Should -Match 'Resolve-ClusterDeployPassOutcome'
        $text | Should -Match 'armRecord\.Timestamp'
    }
}
