#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Pester 5 tests for the NIC26.Automation module.
.DESCRIPTION
    Run from the repo root:
        Invoke-Pester -Path automation\shared\powershell\NIC26.Automation\Tests -Output Detailed
    Covers: every registry type (length / characters / nic26 rule), the example environment files validate against the
    schemas through Get-NIC26Config, converters emit only declared inputs and fail on missing required inputs,
    secret-ref handling, the retry helper, and the Key Vault resolver (transcript refusal, never prints; Az mocked).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll/BeforeDiscovery variables are consumed inside It blocks, which the analyzer cannot see.')]
param()

BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1'
    Import-Module $modulePath -Force
    $registry = & (Get-Module NIC26.Automation) { Get-NIC26NameRegistry }
    $script:generatedTypeCases = @()
    $script:allTypeCases = @()
    foreach ($entry in $registry.Values) {
        $script:allTypeCases += @{ Type = $entry.Type; Example = $entry.Example; Entry = $entry }
        if ($entry.Generated) {
            $purpose = ''
            if ($entry.PurposeValidSet) { $purpose = $entry.PurposeValidSet[0] }
            elseif ($entry.PurposeRegex -eq '^\d{2}$') { $purpose = '01' }
            elseif ($entry.PurposeIsParentName) { $purpose = 'vm-iic-nic26-demo-eus-01' }
            elseif ($entry.PurposeAllowed) { $purpose = 'demo' }
            $suffix = ''
            if ($entry.Template -like '*{suffix}*') { $suffix = 'hub' }
            $script:generatedTypeCases += @{ Type = $entry.Type; Purpose = $purpose; Suffix = $suffix; Entry = $entry }
        }
    }
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1'
    Import-Module $modulePath -Force
    $script:ModuleName = 'NIC26.Automation'
    $script:SharedRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
    $script:ExamplesRoot = Join-Path $script:SharedRoot 'examples'
    $script:SchemaRoot = Join-Path $script:SharedRoot 'schemas'
    $script:FixtureSolution = Join-Path $PSScriptRoot 'fixtures' 'solutions' 'lz-example'

    # Stage the example files as a private environment tree: <TestDrive>\env\<scope>\environment.yml
    $script:EnvRoot = Join-Path $TestDrive 'env'
    foreach ($scope in @('shared', 'azure-local', 'avd')) {
        $folder = Join-Path $script:EnvRoot $scope
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot "environment.$scope.example.yml") -Destination (Join-Path $folder 'environment.yml')
    }
    $script:AvdConfig = Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')

    function ConvertTo-TestSecureString {
        param([string]$Text)
        $secure = [securestring]::new()
        foreach ($char in $Text.ToCharArray()) { $secure.AppendChar($char) }
        $secure.MakeReadOnly()
        return $secure
    }

    function Copy-FixtureSolution {
        param([string]$Name = 'lz-example', [string]$Under = 'landing-zones')
        $target = Join-Path $TestDrive 'automation' $Under $Name
        $null = New-Item -ItemType Directory -Path $target -Force
        Copy-Item -LiteralPath (Join-Path $script:FixtureSolution 'solution.yml') -Destination (Join-Path $target 'solution.yml') -Force
        return $target
    }
}

Describe 'Module surface' {
    It 'exports exactly the eleven contract functions' {
        $expected = @(
            'ConvertTo-NIC26AnsibleVars', 'ConvertTo-NIC26BicepParam', 'ConvertTo-NIC26TfVars', 'Get-NIC26Config',
            'Get-NIC26SolutionManifest', 'Invoke-NIC26ArmDeployment', 'Invoke-NIC26WithRetry', 'New-NIC26ResourceName', 'Resolve-NIC26KeyVaultRef',
            'Test-NIC26ResourceName', 'Write-NIC26Log'
        )
        $actual = @(Get-Command -Module $script:ModuleName | Select-Object -ExpandProperty Name | Sort-Object)
        $actual | Should -Be ($expected | Sort-Object)
    }

    It 'has comment-based help with a synopsis on every exported function' {
        foreach ($command in Get-Command -Module $script:ModuleName) {
            (Get-Help $command.Name).Synopsis | Should -Not -BeNullOrEmpty -Because "$($command.Name) needs help"
        }
    }
}

Describe 'Naming standard - registry types' {
    It 'generates a valid name for type <Type>' -ForEach $generatedTypeCases {
        $arguments = @{ Type = $Type }
        if ($Purpose) { $arguments.Purpose = $Purpose }
        if ($Suffix) { $arguments.Suffix = $Suffix }
        $name = New-NIC26ResourceName @arguments
        $name | Should -Not -BeNullOrEmpty
        $name.Length | Should -BeLessOrEqual $Entry.MaxLength
        $name.Length | Should -BeGreaterOrEqual $Entry.MinLength
        $name | Should -Match $Entry.Regex
        if ($Entry.RequireToken) { $name | Should -BeLike '*nic26*' }
        if ($Entry.NoConsecutiveHyphens) { $name | Should -Not -Match '--' }
        Test-NIC26ResourceName -Name $name -Type $Type | Should -BeTrue
    }

    It 'accepts the naming-standard example for type <Type> (<Example>)' -ForEach $allTypeCases {
        $result = Test-NIC26ResourceName -Name $Example -Type $Type -Detailed
        $result.IsValid | Should -BeTrue -Because ($result.Reasons -join '; ')
    }

    It 'pads the instance to two digits and lowercases the purpose' {
        New-NIC26ResourceName -Type rg -Purpose 'AVD-Hosts' -Instance 3 | Should -Be 'rg-iic-nic26-avd-hosts-eus-03'
    }

    It 'builds the documented names from the design' {
        New-NIC26ResourceName -Type kv -Purpose ops | Should -Be 'kv-iic-nic26-ops-eus-01'
        New-NIC26ResourceName -Type kv -Purpose azl | Should -Be 'kv-iic-nic26-azl-eus-01'
        New-NIC26ResourceName -Type st -Purpose fslogix | Should -Be 'stiicnic26fslogixeus01'
        New-NIC26ResourceName -Type st -Purpose wit | Should -Be 'stiicnic26witeus01'
        New-NIC26ResourceName -Type st -Purpose tfstate | Should -Be 'stiicnic26tfstateeus01'
        New-NIC26ResourceName -Type gal | Should -Be 'galiicnic26eus01'
        New-NIC26ResourceName -Type law | Should -Be 'law-iic-nic26-eus-01'
        New-NIC26ResourceName -Type vdws | Should -Be 'vdws-iic-nic26-eus-01'
        New-NIC26ResourceName -Type vdpool -Purpose hybrid | Should -Be 'vdpool-iic-nic26-hybrid-eus-01'
        New-NIC26ResourceName -Type pep -Purpose kvops | Should -Be 'pep-iic-nic26-kvops-eus-01'
        New-NIC26ResourceName -Type dcr -Purpose azl-insights | Should -Be 'dcr-iic-nic26-azl-insights-eus-01'
        New-NIC26ResourceName -Type init -Purpose hybrid-baseline | Should -Be 'init-iic-nic26-hybrid-baseline'
        New-NIC26ResourceName -Type imgdef -Purpose win11-avd | Should -Be 'imgdef-iic-nic26-win11-avd'
        New-NIC26ResourceName -Type img -Purpose win11-avd-25h2 | Should -Be 'img-iic-nic26-win11-avd-25h2'
        New-NIC26ResourceName -Type lnet -Purpose compute | Should -Be 'lnet-iic-nic26-compute-eus'
        New-NIC26ResourceName -Type sp -Purpose m2-vmstore | Should -Be 'sp-nic26-m2-vmstore-01'
        New-NIC26ResourceName -Type csv -Purpose m2-vmstore | Should -Be 'csv-nic26-m2-vmstore-01'
        New-NIC26ResourceName -Type clus | Should -Be 'nic26-clus01'
        New-NIC26ResourceName -Type node -Instance 2 | Should -Be 'nic26-01-n02'
        New-NIC26ResourceName -Type bmc -Purpose nic26-01-n01 | Should -Be 'nic26-01-n01-i'
        New-NIC26ResourceName -Type jmp | Should -Be 'nic26-jmp-01'
        New-NIC26ResourceName -Type sessionhost -Purpose az | Should -Be 'nic26-avd-az01'
        New-NIC26ResourceName -Type sessionhost -Purpose hv -Instance 2 | Should -Be 'nic26-avd-hv02'
        New-NIC26ResourceName -Type share -Purpose fslogix-profiles | Should -Be 'nic26-fslogix-profiles'
        New-NIC26ResourceName -Type vlan -Purpose mgmt -Suffix 100 | Should -Be 'nic26-mgmt-100'
        New-NIC26ResourceName -Type peer -Purpose vnet-iic-nic26-avd-eus-01 -Suffix hub | Should -Be 'peer-vnet-iic-nic26-avd-eus-01-to-hub'
        New-NIC26ResourceName -Type nic -Purpose vm-iic-nic26-jump-eus-01 | Should -Be 'nic-vm-iic-nic26-jump-eus-01-01'
        New-NIC26ResourceName -Type budget -Purpose avd | Should -Be 'budget-iic-nic26-avd-01'
        New-NIC26ResourceName -Type spn -Purpose arc-onboard | Should -Be 'spn-iic-nic26-arc-onboard'
        New-NIC26ResourceName -Type grp -Purpose avd-azure | Should -Be 'grp-iic-nic26-avd-azure'
        New-NIC26ResourceName -Type dnspr -Purpose avd | Should -Be 'dnspr-iic-nic26-avd-eus-01'
        New-NIC26ResourceName -Type rp -Purpose tier1 | Should -Be 'rp-iic-nic26-tier1-01'
        New-NIC26ResourceName -Type dcra -Purpose azl | Should -Be 'dcra-iic-nic26-azl-01'
        New-NIC26ResourceName -Type vmazl -Purpose avd | Should -Be 'vm-iic-nic26-avd-azl-01'
    }

    It 'honours -Org, -Token and -Region' {
        New-NIC26ResourceName -Type vnet -Purpose hub -Org acme -Token lab7 -Region weu | Should -Be 'vnet-acme-lab7-hub-weu-01'
    }

    It 'throws with the computed length when a Key Vault name is too long' {
        { New-NIC26ResourceName -Type kv -Purpose operations-vault } | Should -Throw -ExpectedMessage '*length 36*3-24*'
    }

    It 'throws with the computed length when a storage account name is too long' {
        { New-NIC26ResourceName -Type st -Purpose fslogixprofilesbig } | Should -Throw -ExpectedMessage '*length 33*3-24*'
    }

    It 'strips hyphens from compact (storage / gallery) purposes' {
        New-NIC26ResourceName -Type st -Purpose asr-cache | Should -Be 'stiicnic26asrcacheeus01'
    }

    It 'rejects an unknown type with the list of known types' {
        { New-NIC26ResourceName -Type bogus -Purpose x } | Should -Throw -ExpectedMessage '*Unknown resource-name type*rg*'
    }

    It 'refuses to generate fixed / exempt names' {
        { New-NIC26ResourceName -Type pdnszone -Purpose x } | Should -Throw -ExpectedMessage '*never generated*'
        { New-NIC26ResourceName -Type fixedsubnet } | Should -Throw
        { New-NIC26ResourceName -Type imgver } | Should -Throw
    }

    It 'rejects a purpose where none is allowed, and requires one where it is' {
        { New-NIC26ResourceName -Type clus -Purpose x } | Should -Throw -ExpectedMessage '*does not take a -Purpose*'
        { New-NIC26ResourceName -Type rg } | Should -Throw -ExpectedMessage '*requires -Purpose*'
        { New-NIC26ResourceName -Type vlan -Purpose mgmt } | Should -Throw -ExpectedMessage '*requires -Suffix*'
        { New-NIC26ResourceName -Type rg -Purpose x -Suffix y } | Should -Throw -ExpectedMessage '*does not take a -Suffix*'
    }

    It 'restricts session-host purposes to az | al | hv and node purposes to two digits' {
        { New-NIC26ResourceName -Type sessionhost -Purpose xx } | Should -Throw -ExpectedMessage '*Allowed: az, al, hv*'
        { New-NIC26ResourceName -Type node -Purpose abc } | Should -Throw
    }

    It 'rejects invalid purpose characters' {
        { New-NIC26ResourceName -Type rg -Purpose 'bad_purpose' } | Should -Throw -ExpectedMessage '*must match*'
        { New-NIC26ResourceName -Type rg -Purpose 'double--hyphen' } | Should -Throw
    }
}

Describe 'Test-NIC26ResourceName' {
    It 'returns false with reasons when nic26 is missing' {
        $result = Test-NIC26ResourceName -Name 'rg-iic-demo-eus-01' -Type rg -Detailed
        $result.IsValid | Should -BeFalse
        $result.Reasons | Should -Contain "does not contain the lab token 'nic26' (naming standard section 1)"
        Test-NIC26ResourceName -Name 'rg-iic-demo-eus-01' -Type rg | Should -BeFalse
    }

    It 'allows exempt types without nic26' {
        Test-NIC26ResourceName -Name 'privatelink.vaultcore.azure.net' -Type pdnszone | Should -BeTrue
        Test-NIC26ResourceName -Name 'GatewaySubnet' -Type fixedsubnet | Should -BeTrue
        Test-NIC26ResourceName -Name 'AzureBastionSubnet' -Type fixedsubnet | Should -BeTrue
        Test-NIC26ResourceName -Name 'MySubnet' -Type fixedsubnet | Should -BeFalse
        Test-NIC26ResourceName -Name '1.0.0' -Type imgver | Should -BeTrue
        Test-NIC26ResourceName -Name 'v1' -Type imgver | Should -BeFalse
    }

    It 'enforces Key Vault rules (length, consecutive hyphens)' {
        Test-NIC26ResourceName -Name 'kv-iic-nic26--ops-eus-01' -Type kv | Should -BeFalse
        Test-NIC26ResourceName -Name 'kv-iic-nic26-operations-eus-01' -Type kv | Should -BeFalse
        Test-NIC26ResourceName -Name 'kv-iic-nic26-ops-eus-01' -Type kv | Should -BeTrue
    }

    It 'enforces storage account characters and NetBIOS length' {
        Test-NIC26ResourceName -Name 'st-iic-nic26-x-eus-01' -Type st | Should -BeFalse
        Test-NIC26ResourceName -Name 'nic26-avd-azure01' -Type sessionhost | Should -BeFalse
        Test-NIC26ResourceName -Name 'nic26-avd-az01' -Type sessionhost | Should -BeTrue
    }

    It 'reports an unknown type instead of throwing' {
        $result = Test-NIC26ResourceName -Name 'x' -Type nope -Detailed
        $result.IsValid | Should -BeFalse
        $result.Reasons[0] | Should -BeLike "unknown type 'nope'*"
    }

    It 'rejects structurally wrong names of the right length' {
        Test-NIC26ResourceName -Name 'nic26-iic-rg-avd-eus-01' -Type rg | Should -BeFalse
        Test-NIC26ResourceName -Name 'rg-iic-nic26-avd-eus-1' -Type rg | Should -BeFalse
    }
}

Describe 'Get-NIC26Config and the example environment files' {
    It 'loads and validates the <_> example against its schema' -ForEach @('shared', 'azure-local', 'avd') {
        $config = Get-NIC26Config -Scope $_ -Path (Join-Path $script:EnvRoot $_)
        $config.scope | Should -Be $_
        $config.values.Count | Should -BeGreaterThan 10
        $config.values.tenant_id | Should -Be '00000000-0000-0000-0000-000000000000'
    }

    It 'validates every example file directly with Test-Json against its schema' -ForEach @('shared', 'azure-local', 'avd') {
        $yaml = Get-Content -LiteralPath (Join-Path $script:ExamplesRoot "environment.$_.example.yml") -Raw
        $json = ConvertFrom-Yaml -Yaml $yaml -Ordered | ConvertTo-Json -Depth 100
        Test-Json -Json $json -SchemaFile (Join-Path $script:SchemaRoot "$_.environment.schema.json") | Should -BeTrue
    }

    It 'merges shared first, then the scope (scope wins), and exposes both sections' {
        $script:AvdConfig.shared.org | Should -Be 'iic'
        $script:AvdConfig.avd.subscription_id_avd | Should -Be '00000000-0000-0000-0000-000000000000'
        $script:AvdConfig.values.org | Should -Be 'iic'
        $script:AvdConfig.values.avd_vnet_prefix | Should -Be '10.100.8.0/22'
        $script:AvdConfig.sources.shared.Count | Should -Be 1
        $script:AvdConfig.sources.avd.Count | Should -Be 1
    }

    It 'merges several files in one folder in name order with later files winning' {
        $folder = Join-Path $TestDrive 'merge' 'shared'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot 'environment.shared.example.yml') -Destination (Join-Path $folder '10-base.yml')
        Set-Content -LiteralPath (Join-Path $folder '20-override.yml') -Value "cost_center: override-cc`ntags:`n  cost-center: override-cc`n"
        $config = Get-NIC26Config -Scope shared -Path $folder
        $config.values.cost_center | Should -Be 'override-cc'
        $config.values.tags.'cost-center' | Should -Be 'override-cc'
        $config.values.tags.project | Should -Be 'nic26'
        $config.sources.shared.Count | Should -Be 2
    }

    It 'skips secret-map.yml in the shared folder (it has its own shape and is read through secret_map_path)' {
        $folder = Join-Path $TestDrive 'secretmap' 'shared'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot 'environment.shared.example.yml') -Destination (Join-Path $folder 'environment.yml')
        Set-Content -LiteralPath (Join-Path $folder 'secret-map.yml') -Value "version: 1`nsource_vaults:`n  - kv-example`ntarget_vault: kv-target`nsecrets: []"
        $config = Get-NIC26Config -Scope shared -Path $folder
        $config.sources.shared.Count | Should -Be 1
        $config.values.tenant_id | Should -Be '00000000-0000-0000-0000-000000000000'
    }

    It 'rejects unknown keys' {
        $folder = Join-Path $TestDrive 'unknown' 'shared'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot 'environment.shared.example.yml') -Destination (Join-Path $folder 'environment.yml')
        Add-Content -LiteralPath (Join-Path $folder 'environment.yml') -Value "rogue_key: 1"
        { Get-NIC26Config -Scope shared -Path $folder } | Should -Throw -ExpectedMessage '*failed schema validation*'
    }

    It 'rejects a malformed GUID and a plaintext value in a secret field' {
        $folder = Join-Path $TestDrive 'badguid' 'shared'
        $null = New-Item -ItemType Directory -Path $folder -Force
        (Get-Content -LiteralPath (Join-Path $script:ExamplesRoot 'environment.shared.example.yml') -Raw) -replace 'tenant_id: 00000000-0000-0000-0000-000000000000', 'tenant_id: not-a-guid' |
            Set-Content -LiteralPath (Join-Path $folder 'environment.yml')
        { Get-NIC26Config -Scope shared -Path $folder } | Should -Throw -ExpectedMessage '*tenant_id*'

        $azlFolder = Join-Path $TestDrive 'badsecret' 'azure-local'
        $null = New-Item -ItemType Directory -Path $azlFolder -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'badsecret' 'shared') -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot 'environment.shared.example.yml') -Destination (Join-Path $TestDrive 'badsecret' 'shared' 'environment.yml')
        (Get-Content -LiteralPath (Join-Path $script:ExamplesRoot 'environment.azure-local.example.yml') -Raw) -replace 'jump_admin_password_secret: keyvault://[^\r\n]+', 'jump_admin_password_secret: Hunter2-Plaintext' |
            Set-Content -LiteralPath (Join-Path $azlFolder 'environment.yml')
        { Get-NIC26Config -Scope azure-local -Path $azlFolder } | Should -Throw -ExpectedMessage '*jump_admin_password_secret*'
    }

    It 'explains how to create the folder when it is missing' {
        { Get-NIC26Config -Scope avd -Path (Join-Path $TestDrive 'does-not-exist' 'avd') } | Should -Throw -ExpectedMessage '*not found*example*'
    }
}

Describe 'Get-NIC26SolutionManifest' {
    It 'parses the fixture and fills optional sections' {
        $manifest = Get-NIC26SolutionManifest -Path $script:FixtureSolution
        $manifest.name | Should -Be 'lz-example'
        $manifest.inputs.Count | Should -Be 12
        $manifest.names.Count | Should -Be 15
        $manifest.depends_on | Should -Be @('lz-azure-local')
        $manifest.solution_root | Should -Be (Resolve-Path $script:FixtureSolution).Path
    }

    It 'accepts the solution.yml file path as well as the folder' {
        (Get-NIC26SolutionManifest -Path (Join-Path $script:FixtureSolution 'solution.yml')).name | Should -Be 'lz-example'
    }

    It 'rejects a manifest with a missing required key' {
        $folder = Copy-FixtureSolution -Name 'lz-broken-key'
        (Get-Content -LiteralPath (Join-Path $folder 'solution.yml') -Raw) -replace 'destroy: supported', '' | Set-Content -LiteralPath (Join-Path $folder 'solution.yml')
        { Get-NIC26SolutionManifest -Path $folder } | Should -Throw -ExpectedMessage '*failed schema validation*'
    }

    It 'rejects a secret-ref input whose source is not keyvault' {
        $folder = Copy-FixtureSolution -Name 'lz-broken-secret'
        (Get-Content -LiteralPath (Join-Path $folder 'solution.yml') -Raw) -replace "source: keyvault", 'source: environment' | Set-Content -LiteralPath (Join-Path $folder 'solution.yml')
        { Get-NIC26SolutionManifest -Path $folder } | Should -Throw -ExpectedMessage '*must have source: keyvault*'
    }

    It 'rejects an unknown type in the names catalog' {
        $folder = Copy-FixtureSolution -Name 'lz-broken-names'
        Add-Content -LiteralPath (Join-Path $folder 'solution.yml') -Value "  weird: { type: zzz, purpose: x }"
        { Get-NIC26SolutionManifest -Path $folder } | Should -Throw -ExpectedMessage "*unknown type 'zzz'*"
    }
}

Describe 'Converters' {
    BeforeAll {
        $script:DeclaredInputs = @((Get-NIC26SolutionManifest -Path $script:FixtureSolution).inputs | ForEach-Object { $_.name })
        # Expected emitted set: all declared inputs except the generated one and the optional one without a default.
        $script:ExpectedEmitted = @($script:DeclaredInputs | Where-Object { $_ -notin @('registration_token', 'optional_without_default') })
    }

    Context 'Bicep' {
        It 'emits only declared inputs plus names, with the using line and a header, and writes nothing without -Execute' {
            $text = ConvertTo-NIC26BicepParam -Solution $script:FixtureSolution -Config $script:AvdConfig
            $text | Should -BeOfType [string]
            $text | Should -Match "(?m)^using './main.bicep'$"
            $text | Should -Match '(?m)^// GENERATED by NIC26.Automation'
            $params = @([regex]::Matches($text, '(?m)^param ([a-z0-9_]+) = ') | ForEach-Object { $_.Groups[1].Value })
            ($params | Where-Object { $_ -ne 'names' } | Sort-Object) | Should -Be ($script:ExpectedEmitted | Sort-Object)
            $text | Should -Not -Match 'registration_token'
            $text | Should -Not -Match 'optional_without_default'
            $text | Should -Match "(?m)^param enable_example_feature = false$"
            $text | Should -Match "(?m)^param shortpath_managed_port = 3390$"
            $text | Should -Match "  'cost-center': 'iic-nic26-lab'"
            $text | Should -Match "  fslogix_sa: 'stiicnic26fslogixeus01'"
            $text | Should -Match "  gateway_subnet: 'GatewaySubnet'"
            $text | Should -Match "  sh_azure_01: 'nic26-avd-az01'"
            Test-Path (Join-Path $script:FixtureSolution 'bicep' 'main.generated.bicepparam') | Should -BeFalse
        }

        It 'emits a list input as a flat array' {
            $text = ConvertTo-NIC26BicepParam -Solution $script:FixtureSolution -Config $script:AvdConfig
            $text | Should -Match "(?m)^param onprem_compute_prefixes = \[\n  '192\.168\.110\.0/24'\n  '192\.168\.120\.0/24'\n\]"
        }

        It 'writes <solution>\bicep\main.generated.bicepparam with -Execute and honours -WhatIf' {
            $folder = Copy-FixtureSolution -Name 'lz-bicep'
            $expected = Join-Path $folder 'bicep' 'main.generated.bicepparam'
            ConvertTo-NIC26BicepParam -Solution $folder -Config $script:AvdConfig -Execute -WhatIf
            Test-Path $expected | Should -BeFalse
            $file = ConvertTo-NIC26BicepParam -Solution $folder -Config $script:AvdConfig -Execute
            $file.FullName | Should -Be $expected
            (Get-Content $expected -Raw) | Should -Match "using './main.bicep'"
            [System.IO.File]::ReadAllBytes($expected)[0..2] | Should -Not -Be @(0xEF, 0xBB, 0xBF)
        }

        It 'refuses when the solution does not declare bicep' {
            $folder = Copy-FixtureSolution -Name 'lz-notbicep'
            (Get-Content -LiteralPath (Join-Path $folder 'solution.yml') -Raw) -replace 'tools: \[bicep, terraform, ansible\]', 'tools: [terraform]' | Set-Content -LiteralPath (Join-Path $folder 'solution.yml')
            { ConvertTo-NIC26BicepParam -Solution $folder -Config $script:AvdConfig } | Should -Throw -ExpectedMessage "*does not declare 'bicep'*"
        }
    }

    Context 'Terraform' {
        It 'emits only declared inputs plus names and a _generated marker' {
            $json = ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $script:AvdConfig | ConvertFrom-Json -AsHashtable
            $keys = @($json.Keys | Where-Object { $_ -notin @('_generated', 'names') } | Sort-Object)
            $keys | Should -Be ($script:ExpectedEmitted | Sort-Object)
            $json._generated.solution | Should -Be 'lz-example'
            $json.names.spoke_vnet | Should -Be 'vnet-iic-nic26-avd-eus-01'
            $json.names.kv_ops | Should -Be 'kv-iic-nic26-ops-eus-01'
            $json.onprem_compute_prefixes | Should -Be @('192.168.110.0/24', '192.168.120.0/24')
            $json.shortpath_managed_port | Should -Be 3390
            $json.enable_example_feature | Should -BeFalse
        }

        It 'writes terraform\terraform.generated.tfvars.json with -Execute' {
            $folder = Copy-FixtureSolution -Name 'lz-tf'
            $file = ConvertTo-NIC26TfVars -Solution $folder -Config $script:AvdConfig -Execute
            $file.FullName | Should -Be (Join-Path $folder 'terraform' 'terraform.generated.tfvars.json')
            (Get-Content $file.FullName -Raw | ConvertFrom-Json)._generated.tool | Should -BeLike '*ConvertTo-NIC26TfVars'
        }

        It 'honours -OutFile' {
            $out = Join-Path $TestDrive 'custom' 'x.generated.tfvars.json'
            (ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $script:AvdConfig -OutFile $out -Execute).FullName | Should -Be $out
        }
    }

    Context 'Ansible' {
        It 'emits only declared inputs plus names as YAML with a header' {
            $text = ConvertTo-NIC26AnsibleVars -Solution $script:FixtureSolution -Config $script:AvdConfig
            $text | Should -Match '(?m)^# GENERATED by NIC26.Automation'
            $data = ConvertFrom-Yaml -Yaml ($text -replace '(?m)^#.*$', '') -Ordered
            $keys = @($data.Keys | Where-Object { $_ -ne 'names' } | Sort-Object)
            $keys | Should -Be ($script:ExpectedEmitted | Sort-Object)
            $data.names.rg_net | Should -Be 'rg-iic-nic26-avd-net-eus-01'
            @($data.onprem_compute_prefixes).Count | Should -Be 2
        }

        It 'writes ansible\group_vars\generated.yml with -Execute' {
            $folder = Copy-FixtureSolution -Name 'lz-ansible'
            (ConvertTo-NIC26AnsibleVars -Solution $folder -Config $script:AvdConfig -Execute).FullName | Should -Be (Join-Path $folder 'ansible' 'group_vars' 'generated.yml')
        }
    }

    Context 'Failure modes shared by all converters' {
        It 'fails when a required input is missing and names every missing input' {
            $values = (Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')).values
            $values.Remove('avd_vnet_prefix')
            $values.Remove('shortpath_managed_port')
            { ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*required input(s) missing*avd_vnet_prefix*shortpath_managed_port*'
            { ConvertTo-NIC26BicepParam -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*required input(s) missing*'
            { ConvertTo-NIC26AnsibleVars -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*required input(s) missing*'
        }

        It 'emits a secret-ref only as the keyvault:// reference string' {
            $text = ConvertTo-NIC26BicepParam -Solution $script:FixtureSolution -Config $script:AvdConfig
            $text | Should -Match "(?m)^param hybrid_local_admin_password = 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-hyperv-hybrid-local-admin-password'$"
        }

        It 'refuses to emit a secret-ref input whose value is not a keyvault:// reference' {
            $values = (Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')).values
            $values.secret_refs.hybrid_local_admin_password = 'Hunter2-Plaintext'
            { ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*secret-ref*refusing*'
            { ConvertTo-NIC26AnsibleVars -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*secret-ref*refusing*'
        }

        It 'never contains the plaintext even when a converter throws' {
            $values = (Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')).values
            $values.secret_refs.hybrid_local_admin_password = 'Hunter2-Plaintext'
            $message = ''
            try { ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $values } catch { $message = $_.Exception.Message }
            $message | Should -Not -Match 'Hunter2'
        }

        It 'fails on a type mismatch' {
            $values = (Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')).values
            $values.shortpath_managed_port = 'not-a-number'
            { ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $values } | Should -Throw -ExpectedMessage '*shortpath_managed_port*type int*'
        }

        It 'fails the conversion when a catalog name violates the standard' {
            $folder = Copy-FixtureSolution -Name 'lz-badname'
            Add-Content -LiteralPath (Join-Path $folder 'solution.yml') -Value "  too_long_kv: { type: kv, purpose: operations-vault-name }"
            { ConvertTo-NIC26TfVars -Solution $folder -Config $script:AvdConfig } | Should -Throw -ExpectedMessage '*Name catalog resolution failed*too_long_kv*'
        }

        It 'resolves a solution by name under the automation root' {
            $byNameRoot = Join-Path $TestDrive 'byname' 'automation'
            $target = Join-Path $byNameRoot 'landing-zones' 'lz-example'
            $null = New-Item -ItemType Directory -Path $target -Force
            Copy-Item -LiteralPath (Join-Path $script:FixtureSolution 'solution.yml') -Destination (Join-Path $target 'solution.yml') -Force
            $previous = $env:NIC26_AUTOMATION_ROOT
            try {
                $env:NIC26_AUTOMATION_ROOT = $byNameRoot
                (ConvertTo-NIC26TfVars -Solution 'lz-example' -Config $script:AvdConfig | ConvertFrom-Json)._generated.solution | Should -Be 'lz-example'
                { ConvertTo-NIC26TfVars -Solution 'lz-nowhere' -Config $script:AvdConfig } | Should -Throw -ExpectedMessage '*not found*'
            }
            finally {
                $env:NIC26_AUTOMATION_ROOT = $previous
            }
        }

        It 'accepts a PSCustomObject config as well as the Get-NIC26Config object' {
            $custom = $script:AvdConfig.values | ConvertTo-Json -Depth 50 | ConvertFrom-Json
            $json = ConvertTo-NIC26TfVars -Solution $script:FixtureSolution -Config $custom | ConvertFrom-Json
            $json.tenant_id | Should -Be '00000000-0000-0000-0000-000000000000'
        }
    }
}

Describe 'Invoke-NIC26WithRetry' {
    BeforeAll {
        Mock -ModuleName $script:ModuleName Start-NIC26Sleep { }
    }

    It 'retries retryable errors with doubling delays and returns the result' {
        $script:attempts = 0
        $result = Invoke-NIC26WithRetry -InitialSeconds 2 -ScriptBlock {
            $script:attempts++
            if ($script:attempts -lt 4) { throw "The client does not have authorization to perform action (403 Forbidden)" }
            return "ok-$script:attempts"
        } -WarningAction SilentlyContinue
        $result | Should -Be 'ok-4'
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 3 -Exactly
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 8 }
    }

    It 'rethrows a non-retryable error immediately without sleeping' {
        { Invoke-NIC26WithRetry -ScriptBlock { throw 'Resource not found: kv-x' } } | Should -Throw -ExpectedMessage 'Resource not found: kv-x'
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 0 -Exactly
    }

    It 'gives up when the budget is exhausted and rethrows the last error' {
        { Invoke-NIC26WithRetry -MaxMinutes 0 -ScriptBlock { throw '429 Too Many Requests' } -WarningAction SilentlyContinue } | Should -Throw -ExpectedMessage '429 Too Many Requests'
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 0 -Exactly
    }

    It 'caps a single delay at -MaxDelaySeconds' {
        $script:n = 0
        $null = Invoke-NIC26WithRetry -InitialSeconds 50 -MaxDelaySeconds 60 -ScriptBlock { $script:n++; if ($script:n -lt 4) { throw 'RBAC propagation: Forbidden' }; 'done' } -WarningAction SilentlyContinue
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 60 }
    }

    It 'honours a custom -RetryOn pattern and passes -ArgumentList' {
        $script:k = 0
        $result = Invoke-NIC26WithRetry -RetryOn 'flaky' -ScriptBlock { param($x) $script:k++; if ($script:k -eq 1) { throw 'flaky backend' }; "got $x" } -ArgumentList 'arg1' -WarningAction SilentlyContinue
        $result | Should -Be 'got arg1'
    }
}

Describe 'Resolve-NIC26KeyVaultRef' {
    BeforeAll {
        $script:PlainValue = 'Pl4in-Text-Secret-Value!'
        Mock -ModuleName $script:ModuleName Assert-NIC26AzContext { }
        Mock -ModuleName $script:ModuleName Start-NIC26Sleep { }
        Mock -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret {
            [pscustomobject]@{ Name = $Name; VaultName = $VaultName; SecretValue = (ConvertTo-TestSecureString -Text $script:PlainValue) }
        }
    }

    It 'rejects a malformed reference before touching Azure' {
        { Resolve-NIC26KeyVaultRef -Ref 'https://kv.vault.azure.net/secrets/x' } | Should -Throw
        { Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv/with space/x' } | Should -Throw
        Should -Invoke -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret -Times 0 -Exactly
    }

    It 'returns a SecureString by default and the plain string only with -AsPlainText' {
        $secure = Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password'
        $secure | Should -BeOfType [securestring]
        (ConvertFrom-SecureString -SecureString $secure -AsPlainText) | Should -Be $script:PlainValue
        Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password' -AsPlainText | Should -Be $script:PlainValue
        Should -Invoke -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret -ParameterFilter { $VaultName -eq 'kv-iic-nic26-ops-eus-01' -and $Name -eq 'iic-nic26-jump-local-admin-password' }
    }

    It 'never prints the value on any stream, even with -Verbose' {
        $streams = Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password' -Verbose -InformationAction Continue *>&1 |
            Where-Object { $_ -isnot [securestring] } | Out-String
        $streams | Should -Not -Match ([regex]::Escape($script:PlainValue))
        $streams | Should -Match 'value is never logged'
    }

    It 'refuses to run while a transcript is active' {
        $transcript = Join-Path $TestDrive 'transcript.txt'
        Start-Transcript -Path $transcript -Force | Out-Null
        try {
            { Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password' } | Should -Throw -ExpectedMessage '*transcript*'
        }
        finally {
            Stop-Transcript | Out-Null
        }
        (Get-Content $transcript -Raw) | Should -Not -Match ([regex]::Escape($script:PlainValue))
        Should -Invoke -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret -Times 0 -Exactly
    }

    It 'retries a 403 (RBAC propagation) and then succeeds' {
        $script:kvCalls = 0
        Mock -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret {
            $script:kvCalls++
            if ($script:kvCalls -lt 3) { throw 'Operation returned an invalid status code ''Forbidden'' (403)' }
            [pscustomobject]@{ SecretValue = (ConvertTo-TestSecureString -Text $script:PlainValue) }
        }
        $secure = Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/iic-nic26-jump-local-admin-password' -WarningAction SilentlyContinue
        $secure | Should -BeOfType [securestring]
        $script:kvCalls | Should -Be 3
        Should -Invoke -ModuleName $script:ModuleName Start-NIC26Sleep -Times 2 -Exactly
    }

    It 'throws when the secret does not exist' {
        Mock -ModuleName $script:ModuleName Get-NIC26AzKeyVaultSecret { $null }
        { Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/missing' } | Should -Throw -ExpectedMessage '*not found*'
    }

    It 'requires an Az context' {
        Mock -ModuleName $script:ModuleName Assert-NIC26AzContext { throw 'No Azure context. Sign in first with Connect-AzAccount' }
        { Resolve-NIC26KeyVaultRef -Ref 'keyvault://kv-iic-nic26-ops-eus-01/x' } | Should -Throw -ExpectedMessage '*Connect-AzAccount*'
    }
}

Describe 'Write-NIC26Log' {
    It 'writes Info to the information stream with a timestamp and level' {
        $line = Write-NIC26Log -Message 'Resolved 3 inputs' -Source 'tests' 6>&1 | Out-String
        $line | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \[INFO\] NIC26 \[tests\] Resolved 3 inputs'
    }

    It 'refuses to log anything marked -Sensitive' {
        $line = Write-NIC26Log -Message 'Hunter2-Plaintext' -Sensitive 6>&1 | Out-String
        $line | Should -Not -Match 'Hunter2'
        $line | Should -Match 'redacted'
    }

    It 'appends to a log file without the sensitive value' {
        $log = Join-Path $TestDrive 'nic26.log'
        Write-NIC26Log -Message 'first line' -LogFile $log 6>$null
        Write-NIC26Log -Message 'Hunter2-Plaintext' -Sensitive -LogFile $log 6>$null
        $content = Get-Content $log -Raw
        $content | Should -Match 'first line'
        $content | Should -Not -Match 'Hunter2'
    }

    It 'maps Warning and Verbose to their streams and Error stays non-terminating' {
        (Write-NIC26Log -Message 'careful' -Level Warning 3>&1 | Out-String) | Should -Match '\[WARNING\] NIC26 careful'
        (Write-NIC26Log -Message 'chatty' -Level Verbose -Verbose 4>&1 | Out-String) | Should -Match '\[VERBOSE\] NIC26 chatty'
        { Write-NIC26Log -Message 'broken' -Level Error -ErrorAction SilentlyContinue } | Should -Not -Throw
    }
}

Describe 'Publishing hygiene (CONTRACT.md section 7)' {
    It 'keeps real GUIDs out of the shared tree' {
        $files = Get-ChildItem -LiteralPath $script:SharedRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.yml', '*.json', '*.md' |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Name -ne 'NIC26.Automation.Tests.ps1' }
        $guidHits = $files | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -AllMatches |
            ForEach-Object { $_.Matches.Value } | Where-Object { $_ -ne '00000000-0000-0000-0000-000000000000' -and $_ -ne '3f1c8b7e-6a2d-4c5e-9b1a-0d2e4f6a8c10' }
        @($guidHits) | Should -BeNullOrEmpty
    }

    It 'has every secret-looking field in the examples as a keyvault:// reference' {
        $lines = Get-ChildItem -LiteralPath $script:ExamplesRoot -Filter '*.yml' | Select-String -Pattern '(?i)(password|secret|token)\s*:\s*(.+)$' |
            Where-Object { $_.Line -notmatch '^\s*#' -and $_.Line -notmatch 'keyvault://' -and $_.Line -notmatch '^\s*(token|registration_token_ttl_hours|secret_map_path|secret_refs):' }
        @($lines | ForEach-Object { $_.Line.Trim() }) | Should -BeNullOrEmpty
    }
}

Describe 'Naming defaults (no organisation, token or region in code)' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1') -Force
        $script:saved = @{ O = $env:NIC26_ORG; T = $env:NIC26_TOKEN; R = $env:NIC26_REGION }
    }
    AfterEach {
        $env:NIC26_ORG = $script:saved.O; $env:NIC26_TOKEN = $script:saved.T; $env:NIC26_REGION = $script:saved.R
    }
    It 'takes the example defaults from NamingDefaults.psd1 when nothing else is set' {
        $env:NIC26_ORG = $null; $env:NIC26_TOKEN = $null; $env:NIC26_REGION = $null
        New-NIC26ResourceName -Type rg -Purpose demo | Should -Be 'rg-iic-nic26-demo-eus-01'
    }
    It 'lets environment variables replace organisation, token and region, read on every call' {
        $env:NIC26_ORG = 'acme'; $env:NIC26_TOKEN = 'lab9'; $env:NIC26_REGION = 'weu'
        New-NIC26ResourceName -Type rg -Purpose demo | Should -Be 'rg-acme-lab9-demo-weu-01'
        $env:NIC26_REGION = 'neu'
        New-NIC26ResourceName -Type rg -Purpose demo | Should -Be 'rg-acme-lab9-demo-neu-01'
    }
    It 'prefers an explicit parameter over every default' {
        $env:NIC26_ORG = 'acme'
        New-NIC26ResourceName -Type rg -Purpose demo -Org zeta | Should -Be 'rg-zeta-nic26-demo-eus-01'
    }
    It 'rejects an invalid default instead of silently skipping parameter validation' {
        $env:NIC26_ORG = 'Not Valid!'
        { New-NIC26ResourceName -Type rg -Purpose demo } | Should -Throw '*must match*'
    }
    It 'the name catalog takes org, token and location_short from the config values, whatever the defaults say' {
        $env:NIC26_ORG = $null
        $catalog = [ordered]@{ rg_demo = [ordered]@{ type = 'rg'; purpose = 'demo' } }
        $values = [ordered]@{ org = 'acme'; token = 'lab9'; location_short = 'weu' }
        $names = & (Get-Module NIC26.Automation) { param($c, $v) Resolve-NIC26NameCatalog -Catalog $c -Values $v } $catalog $values
        $names['rg_demo'] | Should -Be 'rg-acme-lab9-demo-weu-01'
    }
}
