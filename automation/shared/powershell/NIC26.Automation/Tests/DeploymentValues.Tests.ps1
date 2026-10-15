#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
.SYNOPSIS
    Deployment values come from the environment files: the helpers that read them (naming context, AVD host context, Packer
    variables, Terraform backend) and a guard that no published script, parameter default or template carries a literal.
.DESCRIPTION
    Run against the example environment files in automation\shared\examples, so it needs nothing private and works in the
    public repositories. The literal guard skips a file that is not part of the published tree being tested.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester BeforeAll/BeforeDiscovery variables are consumed inside It blocks, which the analyzer cannot see.')]
param()

BeforeDiscovery {
    # One case per script that used to carry a deployment value. Pattern = what must not appear in the file any more.
    $script:literalCases = @(
        @{ File = 'azure-local/cluster-configure/sdn-network/scripts/Invoke-SdnNetworkDeploy.ps1'; Pattern = "dep-iic-nic26|'nic26'|'iic'"; Because = 'defect 1: deployment name from New-NIC26ResourceName, parameter files generated' }
        @{ File = 'azure-local/cluster-configure/sdn-network/bicep/main.bicep'; Pattern = "'eastus'|ComputeSwitch|ConvergedSwitch"; Because = 'defect 1: no deployment-bound Bicep default' }
        @{ File = 'avd/session-hosts-azure-local/scripts/Invoke-AzlSessionHostBuild.ps1'; Pattern = "'nic26'|'iic'|value = 'n/a'|environment = 'demo'"; Because = 'defect 2: org, token, region and tags from the config' }
        @{ File = 'landing-zones/avd/scripts/Deploy-AvdWorkbook.ps1'; Pattern = "'nic26'|dep-iic-nic26"; Because = 'defect 3' }
        @{ File = 'landing-zones/avd/scripts/Set-AvdMonitoring.ps1'; Pattern = 'dep-iic-nic26'; Because = 'defect 4' }
        @{ File = 'azure-local/cluster-configure/sdn-network/scripts/Invoke-SdnNetworkCli.ps1'; Pattern = "project=nic26|environment=demo"; Because = 'defect 5: tag set from the shared tags' }
        @{ File = 'azure-local/cluster-configure/platform/scripts/New-StoragePathCli.ps1'; Pattern = "project=nic26|environment=demo"; Because = 'defect 5' }
        @{ File = 'landing-zones/azure-local/scripts/New-EntraConnectServer.ps1'; Pattern = "project = 'nic26'|environment = 'demo'|'nic26-entra"; Because = 'defect 5' }
        @{ File = 'landing-zones/azure-local/scripts/Set-HybridIdentityAd.ps1'; Pattern = "project = 'nic26'|'nic26-hybrid"; Because = 'defect 5' }
        @{ File = 'landing-zones/azure-local/scripts/Set-HybridIdentitySync.ps1'; Pattern = "project = 'nic26'|'nic26-cs"; Because = 'defect 5' }
        @{ File = 'azure-local/cluster-configure/backup-asr/scripts/Invoke-AsrFromEnvironment.ps1'; Pattern = "workload = 'iic'"; Because = 'defect 5' }
        @{ File = 'avd/session-hosts-hybrid/scripts/Invoke-HybridHostBuild.ps1'; Pattern = "project = 'nic26'|environment = 'demo'"; Because = 'defect 6' }
        @{ File = 'demo/azure-local/scripts/New-WorkloadVm.ps1'; Pattern = "iicadmin|workload=iic|workload = 'iic'"; Because = 'defect 7' }
        @{ File = 'landing-zones/azure-local/scripts/Invoke-LzAzureLocalDeploy.ps1'; Pattern = "JumpAdminUsername = 'jumpadmin'"; Because = 'defect 8' }
        @{ File = 'avd/images/packer-nutanix/packer/variables.pkr.hcl'; Pattern = 'IIC|build-admin|avd-w11-ent'; Because = 'defect 9' }
        @{ File = 'avd/images/packer-vsphere/packer/variables.pkr.hcl'; Pattern = 'IIC|build-admin|avd-w11-ent'; Because = 'defect 9' }
        @{ File = 'avd/images/packer-nutanix/packer/windows11-nutanix.pkr.hcl'; Pattern = 'IICANSWER'; Because = 'defect 9' }
        @{ File = 'avd/images/packer-vsphere/packer/windows11-vsphere.pkr.hcl'; Pattern = 'IICANSWER'; Because = 'defect 9' }
        @{ File = 'landing-zones/avd/scripts/New-AvdDemoUsers.ps1'; Pattern = "UsageLocation = 'US'"; Because = 'defect 11' }
        @{ File = 'azure-local/cluster-configure/access-pim/scripts/Request-PimActivation.ps1'; Pattern = 'NIC 2026'; Because = 'defect 12' }
    )
    # Scripts whose deployment values are optional parameters that default from the environment file (defects 11 and 13).
    $script:configDefaultCases = @(
        @{ File = 'landing-zones/avd/scripts/New-AvdDemoUsers.ps1'; Params = @('TenantId', 'Domain', 'KeyVaultName', 'SecretNamePrefix', 'Users', 'UsageLocation', 'NamingToken'); Loader = 'Get-LzAvdEntraDefault' }
        @{ File = 'landing-zones/avd/scripts/New-AvdEntraGroups.ps1'; Params = @('TenantId', 'Org', 'NamingToken'); Loader = 'Get-LzAvdEntraDefault' }
        @{ File = 'landing-zones/avd/scripts/New-AvdConditionalAccess.ps1'; Params = @('TenantId', 'UsersGroupName', 'NamePrefix'); Loader = 'Get-LzAvdEntraDefault' }
        @{ File = 'landing-zones/avd/scripts/Set-AvdEntraSso.ps1'; Params = @('TenantId'); Loader = 'Get-LzAvdEntraDefault' }
        @{ File = 'landing-zones/avd/scripts/Set-AvdStorageEntraKerberos.ps1'; Params = @('TenantId', 'SubscriptionId', 'ResourceGroupName', 'StorageAccountName'); Loader = 'Get-LzAvdEntraDefault' }
        @{ File = 'avd/session-hosts-azure/scripts/Register-AvdSessionHosts.ps1'; Params = @('SubscriptionId', 'ResourceGroupName', 'HostPoolResourceGroup', 'HostPoolName', 'VmName', 'TokenScriptPath'); Loader = 'Get-NIC26AvdHostContext' }
        @{ File = 'avd/session-hosts-azure-local/scripts/Register-AvdSessionHostsAzureLocal.ps1'; Params = @('SubscriptionId', 'ResourceGroupName', 'HostPoolResourceGroup', 'HostPoolName', 'MachineName', 'TokenScriptPath'); Loader = 'Get-NIC26AvdHostContext' }
        @{ File = 'avd/session-hosts-hybrid/scripts/Register-HybridHosts.ps1'; Params = @('SubscriptionId', 'ArcResourceGroup', 'HostPoolResourceGroup', 'HostPoolName', 'MachineName', 'TokenScriptPath'); Loader = 'Get-NIC26AvdHostContext' }
        @{ File = 'avd/session-hosts-hybrid/scripts/Test-HybridHost.ps1'; Params = @('ExpectedHostName', 'SubscriptionId', 'ArcResourceGroup', 'HostPoolResourceGroup', 'HostPoolName'); Loader = 'Get-NIC26AvdHostContext' }
        @{ File = 'avd/images/azure/scripts/Start-ImageBuild.ps1'; Params = @('SubscriptionId', 'ResourceGroupName', 'TemplateName'); Loader = 'Get-NIC26AvdHostContext' }
    )
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'NIC26.Automation.psd1') -Force
    $script:AutomationRoot = & (Get-Module NIC26.Automation) { Get-NIC26AutomationRoot }
    $script:ExamplesRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' 'examples')).Path
    $script:EnvRoot = Join-Path $TestDrive 'env'
    foreach ($scope in @('shared', 'azure-local', 'avd')) {
        $folder = Join-Path $script:EnvRoot $scope
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:ExamplesRoot "environment.$scope.example.yml") -Destination (Join-Path $folder 'environment.yml')
    }
    $script:AvdConfig = Get-NIC26Config -Scope avd -Path (Join-Path $script:EnvRoot 'avd')
    $script:AzlConfig = Get-NIC26Config -Scope azure-local -Path (Join-Path $script:EnvRoot 'azure-local')
    $script:SolutionFolder = {
        param([string]$Relative)
        $path = Join-Path $script:AutomationRoot $Relative
        if (Test-Path -LiteralPath (Join-Path $path 'solution.yml')) { return $path }
        return $null
    }
}

Describe 'Get-NIC26NamingContext' {
    It 'returns org, token, region, tags and the secret prefix from the config' {
        $context = Get-NIC26NamingContext -Config $script:AvdConfig
        $context.Org | Should -Be $script:AvdConfig.values.org
        $context.Token | Should -Be $script:AvdConfig.values.token
        $context.Region | Should -Be $script:AvdConfig.values.location_short
        $context.Project | Should -Be $script:AvdConfig.values.tags.project
        $context.SecretNamePrefix | Should -Be $script:AvdConfig.values.secret_name_prefix
        $context.TagPairs | Should -Contain "project=$($script:AvdConfig.values.tags.project)"
    }
    It 'falls back to the module defaults for a config that carries no org, token or region' {
        $context = Get-NIC26NamingContext -Config ([ordered]@{ tags = [ordered]@{ project = 'p1' } })
        $context.Org | Should -Match '^[a-z0-9]{2,8}$'
        $context.Token | Should -Match '^[a-z0-9]{3,8}$'
        $context.Project | Should -Be 'p1'
    }
    It 'returns a copy of the tags that callers may change' {
        $context = Get-NIC26NamingContext -Config $script:AvdConfig
        $context.Tags['added'] = 'x'
        $script:AvdConfig.values.tags.Contains('added') | Should -BeFalse
    }
}

Describe 'deployment names follow the config' {
    It 'New-NIC26ResourceName -Type dep takes org and token from the context' {
        $context = Get-NIC26NamingContext -Config ([ordered]@{ org = 'zz'; token = 'tok9'; location_short = 'wus' })
        (New-NIC26ResourceName -Type dep -Purpose 'avd-workbook' -Org $context.Org -Token $context.Token) | Should -Be 'dep-zz-tok9-avd-workbook-01'
    }
}

Describe 'sdn-network solution (defect 1)' {
    BeforeAll { $script:Sdn = & $script:SolutionFolder 'azure-local/cluster-configure/sdn-network' }
    It 'emits sdn, logical networks, NSGs and the management target, and never the pass switch' {
        if (-not $script:Sdn) { Set-ItResult -Skipped -Because 'sdn-network is not part of this published tree'; return }
        $text = ConvertTo-NIC26BicepParam -Solution $script:Sdn -Config $script:AzlConfig
        $text | Should -Match '(?m)^param sdn = '
        $text | Should -Match '(?m)^param logical_networks = '
        $text | Should -Match '(?m)^param network_security_groups = '
        $text | Should -Match '(?m)^param vm_management = '
        $text | Should -Match "(?m)^param names = \{\s*\n\s*deployment_name: 'dep-"
        $text | Should -Not -Match 'deploy_network_security_groups'
    }
    It 'main.bicep has no deployment-bound default and the deploy script names deployments with New-NIC26ResourceName' {
        if (-not $script:Sdn) { Set-ItResult -Skipped -Because 'sdn-network is not part of this published tree'; return }
        $bicep = Get-Content -LiteralPath (Join-Path $script:Sdn 'bicep/main.bicep') -Raw
        $bicep | Should -Not -Match "(?m)^param (location|vmSwitchName|vm_switch_name)\b[^\n]*="
        $script = Get-Content -LiteralPath (Join-Path $script:Sdn 'scripts/Invoke-SdnNetworkDeploy.ps1') -Raw
        $script | Should -Match 'ConvertTo-NIC26BicepParam'
        $script | Should -Match 'New-NIC26ResourceName -Type dep'
    }
}

Describe 'ConvertTo-NIC26PackerVars (defect 10)' {
    BeforeAll { $script:Hyperv = & $script:SolutionFolder 'avd/images/packer-hyperv' }
    It 'writes the Packer variables from the environment file and never a secret' {
        if (-not $script:Hyperv) { Set-ItResult -Skipped -Because 'the Packer solutions are not part of this published tree'; return }
        $vars = ConvertTo-NIC26PackerVars -Solution $script:Hyperv -Config $script:AvdConfig | ConvertFrom-Json -AsHashtable
        $vars.iso_path | Should -Be $script:AvdConfig.values.images.packer_iso_path
        $vars.switch_name | Should -Be $script:AvdConfig.values.hybrid.compute_switch_name
        $vars.output_directory | Should -Be $script:AvdConfig.values.images.packer_output_path
        $vars.cpus | Should -Be 4
        $vars.winrm_timeout | Should -Be '2h'
        $vars.customizer_tokens.install_teams_app | Should -Be 'false'
        $vars.vm_name | Should -Match '^vm-'
        $vars.Keys | Should -Not -Contain 'build_password'
        $vars.Keys | Should -Not -Contain 'build_username'
        ($vars | ConvertTo-Json -Depth 5) | Should -Not -Match 'keyvault://'
    }
    It 'honours an optional key set in the environment file' {
        if (-not $script:Hyperv) { Set-ItResult -Skipped -Because 'the Packer solutions are not part of this published tree'; return }
        $values = [ordered]@{}
        foreach ($key in $script:AvdConfig.values.Keys) { $values[$key] = $script:AvdConfig.values[$key] }
        $images = [ordered]@{}
        foreach ($key in $values['images'].Keys) { $images[$key] = $values['images'][$key] }
        $images['packer_cpus'] = 8
        $images['install_teams_app'] = $true
        $values['images'] = $images
        $values['install_teams_app'] = $true
        $vars = ConvertTo-NIC26PackerVars -Solution $script:Hyperv -Config $values | ConvertFrom-Json -AsHashtable
        $vars.cpus | Should -Be 8
        $vars.customizer_tokens.install_teams_app | Should -Be 'true'
    }
    It 'refuses a solution that does not declare packer' {
        { ConvertTo-NIC26PackerVars -Solution (Join-Path $script:AutomationRoot 'demo/shared') -Config $script:AvdConfig } | Should -Throw '*packer*'
    }
    It 'vsphere and nutanix fill their targets from images.vsphere and images.nutanix' {
        foreach ($case in @(@{ Folder = 'avd/images/packer-vsphere'; Key = 'vcenter_server' }, @{ Folder = 'avd/images/packer-nutanix'; Key = 'nutanix_endpoint' })) {
            $folder = & $script:SolutionFolder $case.Folder
            if (-not $folder) { Set-ItResult -Skipped -Because 'the Packer solutions are not part of this published tree'; return }
            $vars = ConvertTo-NIC26PackerVars -Solution $folder -Config $script:AvdConfig | ConvertFrom-Json -AsHashtable
            $vars.Keys | Should -Contain $case.Key
            $vars.Keys | Should -Not -Contain 'build_password'
        }
    }
}

Describe 'New-NIC26TerraformBackendConfig (defect 16)' {
    It 'renders the backend file from terraform_backend and the solution name' {
        $solution = & $script:SolutionFolder 'landing-zones/avd'
        if (-not $solution) { Set-ItResult -Skipped -Because 'lz-avd is not part of this published tree'; return }
        $text = New-NIC26TerraformBackendConfig -Solution $solution -Config $script:AvdConfig
        $backend = $script:AvdConfig.values.terraform_backend
        $text | Should -Match "storage_account_name = `"$($backend.storage_account_name)`""
        $text | Should -Match "container_name\s+= `"$($backend.container_name)`""
        $text | Should -Match 'key\s+= "lz-avd\.tfstate"'
        $text | Should -Not -Match '(?i)access_key|sas_token|client_secret'
    }
    It 'puts key_prefix in front of the state key' {
        $solution = & $script:SolutionFolder 'landing-zones/avd'
        if (-not $solution) { Set-ItResult -Skipped -Because 'lz-avd is not part of this published tree'; return }
        $values = [ordered]@{ terraform_backend = [ordered]@{ subscription_id = '00000000-0000-0000-0000-000000000000'; resource_group_name = 'rg-x'; storage_account_name = 'stx01'; container_name = 'tfstate'; key_prefix = 'team/a' } }
        (New-NIC26TerraformBackendConfig -Solution $solution -Config $values) | Should -Match 'key\s+= "team/a/lz-avd\.tfstate"'
    }
    It 'fails clearly without a terraform_backend block' {
        $solution = & $script:SolutionFolder 'landing-zones/avd'
        if (-not $solution) { Set-ItResult -Skipped -Because 'lz-avd is not part of this published tree'; return }
        { New-NIC26TerraformBackendConfig -Solution $solution -Config ([ordered]@{ org = 'iic' }) } | Should -Throw '*terraform_backend*'
    }
    It 'writes a *.generated.hcl next to the Terraform root with -Execute' {
        $solution = & $script:SolutionFolder 'landing-zones/avd'
        if (-not $solution) { Set-ItResult -Skipped -Because 'lz-avd is not part of this published tree'; return }
        $out = Join-Path $TestDrive 'backend.generated.hcl'
        $file = New-NIC26TerraformBackendConfig -Solution $solution -Config $script:AvdConfig -OutFile $out -Execute
        $file.FullName | Should -Exist
        (Get-Content -LiteralPath $out -Raw) | Should -Match 'use_azuread_auth\s+= true'
    }
}

Describe 'Get-NIC26AvdHostContext (defect 13)' {
    It 'derives the Azure realm from the environment and the name catalogs' {
        if (-not (& $script:SolutionFolder 'avd/session-hosts-azure')) { Set-ItResult -Skipped -Because 'the AVD solutions are not part of this published tree'; return }
        $context = Get-NIC26AvdHostContext -Realm azure -Config $script:AvdConfig
        $context.SubscriptionId | Should -Be $script:AvdConfig.values.subscription_id_avd
        $context.HostPoolName | Should -Match '^vdpool-.*-azure-'
        $context.HostPoolResourceGroup | Should -Match '^rg-'
        $context.ResourceGroupName | Should -Match '^rg-.*-hosts-'
        @($context.VmName).Count | Should -Be $script:AvdConfig.values.host_pools.azure.session_host_count
    }
    It 'uses the Azure Local subscription for the Azure Local realm and the Arc group for the Hybrid realm' {
        if (-not (& $script:SolutionFolder 'avd/session-hosts-azure-local')) { Set-ItResult -Skipped -Because 'the AVD solutions are not part of this published tree'; return }
        (Get-NIC26AvdHostContext -Realm azl -Config $script:AvdConfig).SubscriptionId | Should -Be $script:AvdConfig.values.subscription_id_azl
        $hybrid = Get-NIC26AvdHostContext -Realm hybrid -Config $script:AvdConfig
        $hybrid.ArcResourceGroup | Should -Match '^rg-.*-arc-'
        @($hybrid.VmName).Count | Should -BeGreaterThan 0
    }
    It 'lists the image templates and their resource group' {
        if (-not (& $script:SolutionFolder 'avd/images/azure')) { Set-ItResult -Skipped -Because 'the AVD solutions are not part of this published tree'; return }
        $image = Get-NIC26AvdHostContext -Realm image -Config $script:AvdConfig
        @($image.TemplateName).Count | Should -Be 2
        $image.ResourceGroupName | Should -Match '^rg-.*-img-'
    }
}

Describe 'string inputs from YAML booleans' {
    It 'emits true/false in lower case for a string input' {
        $solution = & $script:SolutionFolder 'avd/images/azure'
        if (-not $solution) { Set-ItResult -Skipped -Because 'the AVD solutions are not part of this published tree'; return }
        $values = [ordered]@{}
        foreach ($key in $script:AvdConfig.values.Keys) { $values[$key] = $script:AvdConfig.values[$key] }
        $values['install_teams_app'] = $true
        (ConvertTo-NIC26BicepParam -Solution $solution -Config $values) | Should -Match "(?m)^param install_teams_app = 'true'"
    }
}

Describe 'optional tuning keys are schema keys with examples (defect 15, 17)' {
    It 'azure-local: the cluster-deploy secret names and the tuning keys validate; a wrong value is rejected' {
        $folder = Join-Path $TestDrive 'tuned-azl'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:EnvRoot 'azure-local/environment.yml') -Destination (Join-Path $folder 'environment.yml')
        Add-Content -LiteralPath (Join-Path $folder 'environment.yml') -Value "local_admin_secret_name: my-local-admin`nwitness_key_secret_name: my-witness-key`nenforcement_mode: DoNotEnforce`nnode_heartbeat_minutes: 15`nbackup_policy:`n  retention_days: 45`nasr_policy:`n  replication_frequency_seconds: 900"
        $config = Get-NIC26Config -Scope azure-local -Path $folder -SharedPath (Join-Path $script:EnvRoot 'shared')
        $config.values.local_admin_secret_name | Should -Be 'my-local-admin'
        Add-Content -LiteralPath (Join-Path $folder 'environment.yml') -Value "enforcement_mode: Sometimes"
        { Get-NIC26Config -Scope azure-local -Path $folder -SharedPath (Join-Path $script:EnvRoot 'shared') } | Should -Throw
    }
    It 'avd: the image and session-host tuning keys validate; a wrong value is rejected' {
        $folder = Join-Path $TestDrive 'tuned-avd'
        $null = New-Item -ItemType Directory -Path $folder -Force
        Copy-Item -LiteralPath (Join-Path $script:EnvRoot 'avd/environment.yml') -Destination (Join-Path $folder 'environment.yml')
        Add-Content -LiteralPath (Join-Path $folder 'environment.yml') -Value "enable_scaling_plan: false`nbuild_timeout_minutes: 90`ninstall_teams_app: true`nos_disk_sku: StandardSSD_LRS`nvcpu: 8"
        $config = Get-NIC26Config -Scope avd -Path $folder -SharedPath (Join-Path $script:EnvRoot 'shared')
        $config.values.build_timeout_minutes | Should -Be 90
        Add-Content -LiteralPath (Join-Path $folder 'environment.yml') -Value "os_disk_sku: Floppy_LRS"
        { Get-NIC26Config -Scope avd -Path $folder -SharedPath (Join-Path $script:EnvRoot 'shared') } | Should -Throw
    }
    It 'every optional key a solution.yml reads from the environment is a schema key of its scope' {
        Import-Module powershell-yaml -ErrorAction Stop
        $alias = & (Get-Module NIC26.Automation) { Get-NIC26InputAliasMap }
        $schemas = @{}
        foreach ($scope in 'azure-local', 'avd', 'shared') {
            $schemas[$scope] = (Get-Content -LiteralPath (Join-Path $script:AutomationRoot "shared/schemas/$scope.environment.schema.json") -Raw | ConvertFrom-Json -AsHashtable)
        }
        $missing = foreach ($manifestFile in (Get-ChildItem -Path $script:AutomationRoot -Recurse -Depth 4 -Filter 'solution.yml' -File | Where-Object { $_.FullName -match '[\\/]automation[\\/](landing-zones|azure-local|avd|demo)[\\/]' -and $_.FullName -notmatch '[\\/](Tests|fixtures|os-provisioning|network-devices|hardware-baseline)[\\/]' })) {
            $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Yaml
            if ($manifest.scope -notin 'azure-local', 'avd') { continue }
            foreach ($input in @($manifest.inputs | Where-Object { $_.source -eq 'environment' })) {
                $key = if ($input.ContainsKey('path') -and $input.path) { $input.path } elseif ($alias.ContainsKey($input.name)) { $alias[$input.name] } else { $input.name }
                $root = ($key -split '\.')[0]
                $known = ($schemas[$manifest.scope].properties.ContainsKey($root) -or $schemas['shared'].properties.ContainsKey($root) -or $schemas[$manifest.scope].properties.ContainsKey($input.name))
                if (-not $known) { "$($manifest.name): $($input.name) -> $root" }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }
    It 'the example files show every optional key the published entry points read (commented where optional)' {
        $azl = Get-Content -LiteralPath (Join-Path $script:ExamplesRoot 'environment.azure-local.example.yml') -Raw
        foreach ($key in 'pim_assignments', 'asr_policy', 'backup_policy', 'alert_evaluation_frequency', 'alert_window_size', 'node_heartbeat_minutes', 'enable_vm_insights_dcr', 'vm_switch_name', 'marketplace_images',
            'enable_network_security_group', 'enforcement_mode', 'assign_insights_policies', 'networking_type', 'rdma_protocol', 'security_settings', 'observability', 'storage_configuration_mode', 'logs_retention_days',
            'assign_hci_rp_role', 'local_admin_secret_name', 'witness_key_secret_name', 'tags', 'secret_name_prefix', 'create_workspace', 'sdn', 'network_security_groups', 'vm_management', 'vm_images', 'workload_vms',
            'demo_vm_lifecycle', 'sofs_cluster', 'solution_update', 'gpu', 'hybrid_identity', 'asr', 'backup_azure_vms', 'maintenance_window', 'dynamic_scope_tags', 'screen_hidden_terms') {
            $azl | Should -Match "(?m)^\s*#?\s*${key}:" -Because "environment.azure-local.example.yml shows $key"
        }
        $avd = Get-Content -LiteralPath (Join-Path $script:ExamplesRoot 'environment.avd.example.yml') -Raw
        foreach ($key in 'deploy_platform_scope_items', 'secret_name_prefix', 'fslogix_realms', 'azl_session_hosts', 'gpu_demo_workload', 'tenant_id', 'workspace_friendly_name', 'live_host_pool', 'remote_apps', 'enable_scaling_plan',
            'storage_path_id', 'sas_duration_seconds', 'build_timeout_minutes', 'defender_paths', 'defender_processes', 'vdot_archive_uri', 'vdot_archive_sha256', 'install_teams_app', 'disable_teams_autoupdate', 'vcpu', 'memory_mb',
            'enable_monitoring', 'os_disk_sku', 'os_disk_size_gb', 'encryption_at_host', 'dcr_avd_insights_id', 'hostpool_identity_principal_id', 'enable_arc_extensions', 'manage_arc_rg_rbac', 'assign_vm_login_roles',
            'demo_user_domain', 'demo_user_usage_location', 'packer_cpus', 'vsphere', 'nutanix') {
            $avd | Should -Match "(?m)^\s*#?\s*${key}:" -Because "environment.avd.example.yml shows $key"
        }
    }
}

Describe 'no deployment value in a published script, default or template' {
    It '<File>: <Because>' -ForEach $literalCases {
        $path = Join-Path $script:AutomationRoot $File
        if (-not (Test-Path -LiteralPath $path)) { Set-ItResult -Skipped -Because 'the file is not part of this published tree'; return }
        # comment-based help and comments may show the fictional example names; code, defaults and here-strings may not
        $code = (Get-Content -LiteralPath $path) | Where-Object { $_ -notmatch '^\s*(#|//)' }
        ($code -join "`n") | Should -Not -Match $Pattern
    }
    It '<File> reads <Params> from the environment when they are not passed' -ForEach $configDefaultCases {
        $path = Join-Path $script:AutomationRoot $File
        if (-not (Test-Path -LiteralPath $path)) { Set-ItResult -Skipped -Because 'the file is not part of this published tree'; return }
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        foreach ($name in $Params) {
            $parameter = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $name }
            $parameter | Should -Not -BeNullOrEmpty -Because "-$name exists"
            ($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' -and ($_.NamedArguments | Where-Object { $_.ArgumentName -eq 'Mandatory' }) }) | Should -BeNullOrEmpty -Because "-$name is no longer mandatory: it defaults from the environment"
        }
        (Get-Content -LiteralPath $path -Raw) | Should -Match $Loader
    }
}
