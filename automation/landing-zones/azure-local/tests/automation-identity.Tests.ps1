#Requires -Version 7.0
# Automation identity (README "Automation identity"): the role map is least privilege and consistent with built-in-roles.bicep,
# both tracks read it, the ABAC condition is constrained to roles, service principals and not-self, and the
# automation_identity environment block validates against the schema. Offline: compiles Bicep, reads files, no Azure call.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Repo = (Resolve-Path (Join-Path $script:Root '..' '..' '..')).Path
    $script:Map = Get-Content (Join-Path $script:Root 'automation-identity-roles.json') -Raw | ConvertFrom-Json -AsHashtable
    $builtIn = Get-Content (Join-Path $script:Root 'bicep' 'modules' 'built-in-roles.bicep') -Raw
    $block = [regex]::Match($builtIn, '(?s)var builtInRoles = \{(.*?)\n\}').Groups[1].Value
    $script:BuiltInKeys = @([regex]::Matches($block, '(?m)^\s+([A-Za-z]+):') | ForEach-Object { $_.Groups[1].Value })
    $script:Main = (& az bicep build --file (Join-Path $script:Root 'bicep' 'main.bicep') --stdout 2>$null) -join "`n" | ConvertFrom-Json -AsHashtable
    $script:Module = (& az bicep build --file (Join-Path $script:Root 'bicep' 'modules' 'automation-identity-rbac.bicep') --stdout 2>$null) -join "`n"
    $script:Tf = Get-Content (Join-Path $script:Root 'terraform' 's3-automation-identity.tf') -Raw
}

Describe 'Role map (automation-identity-roles.json)' -Tag 'AutomationIdentity' {
    It 'has unique keys and only the known scopes and features' {
        $keys = @($script:Map.assignments | ForEach-Object { $_.key })
        ($keys | Sort-Object -Unique).Count | Should -Be $keys.Count
        foreach ($a in $script:Map.assignments) {
            $a.scope | Should -BeIn @('rg_azl', 'rg_sec', 'kv_azl', 'kv_ops')
            $a.feature | Should -BeIn @('core', 'simplified_provisioning')
            $a.source | Should -Match '^https://learn\.microsoft\.com/'
            $a.purpose | Should -Not -BeNullOrEmpty
        }
    }
    It 'uses only roles defined in built-in-roles.bicep and named in role_display_names' {
        foreach ($a in $script:Map.assignments) {
            foreach ($r in @($a.role) + @($a['delegable_roles'] | Where-Object { $_ })) {
                $r | Should -BeIn $script:BuiltInKeys -Because "$($a.key) uses $r"
                $script:Map.role_display_names.ContainsKey($r) | Should -BeTrue -Because "$r needs a display name"
            }
        }
    }
    It 'never grants Owner or User Access Administrator, and grants nothing at subscription scope' {
        @($script:Map.assignments | Where-Object { $_.role -in 'Owner', 'UserAccessAdministrator' }) | Should -BeNullOrEmpty
        @($script:Map.assignments | Where-Object { $_.scope -like 'sub*' }) | Should -BeNullOrEmpty
    }
    It 'constrains every Role Based Access Control Administrator item with delegable roles that are not broad' {
        $rbac = @($script:Map.assignments | Where-Object role -EQ 'RoleBasedAccessControlAdministrator')
        $rbac.Count | Should -Be 2
        foreach ($a in $rbac) {
            @($a.delegable_roles).Count | Should -BeGreaterThan 0
            @($a.delegable_roles | Where-Object { $_ -in 'Owner', 'UserAccessAdministrator', 'Contributor' }) | Should -BeNullOrEmpty
            $a.feature | Should -Be 'simplified_provisioning'
        }
    }
    It 'keeps Contributor to the simplified-provisioning feature on the cluster resource group only' {
        $c = @($script:Map.assignments | Where-Object role -EQ 'Contributor')
        $c.Count | Should -Be 1
        $c[0].scope | Should -Be 'rg_azl'
        $c[0].feature | Should -Be 'simplified_provisioning'
    }
    It 'covers the Learn deployment set (Azure Local azloc-2609)' {
        $core = @($script:Map.assignments | Where-Object feature -EQ 'core' | ForEach-Object { $_.role })
        foreach ($r in 'AzureConnectedMachineOnboarding', 'AzureConnectedMachineResourceAdministrator', 'AzureStackHCIAdministrator', 'Reader',
            'KeyVaultDataAccessAdministrator', 'KeyVaultSecretsOfficer', 'KeyVaultContributor', 'StorageAccountContributor') { $r | Should -BeIn $core }
    }
}

Describe 'Bicep track' -Tag 'AutomationIdentity' {
    It 'declares the automation_identity parameter with an empty default (nothing granted)' {
        $script:Main.parameters.automation_identity.type | Should -Be 'object'
        $script:Main.parameters.automation_identity.defaultValue.Count | Should -Be 0
    }
    It 'deploys the three automation-identity modules only when grant_roles is set (variable aiGrant)' {
        foreach ($m in 'automationIdentityRgAzl', 'automationIdentityRgSec', 'automationIdentityKvOps') {
            $script:Main.resources.ContainsKey($m) | Should -BeTrue
            $script:Main.resources[$m].condition | Should -Match "variables\('aiGrant'\)"
        }
        $script:Main.variables.aiGrant | Should -Match "grant_roles"
    }
    It 'reads the role map with loadJsonContent (single source)' {
        (Get-Content (Join-Path $script:Root 'bicep' 'main.bicep') -Raw) | Should -Match "loadJsonContent\('\.\./automation-identity-roles\.json'\)"
    }
    It 'builds the ABAC condition with role, principal-type and not-self constraints for write, and role constraint for delete' {
        $script:Module | Should -Match 'roleAssignments:PrincipalType\] ForAnyOfAnyValues:StringEqualsIgnoreCase'
        $script:Module | Should -Match 'roleAssignments:PrincipalId\] ForAnyOfAllValues:GuidNotEquals'
        $script:Module | Should -Match "Microsoft\.Authorization/roleAssignments/delete''\}+\)\) OR \(@Resource\[Microsoft\.Authorization/roleAssignments:RoleDefinitionId\]"
        $script:Module | Should -Match "'2\.0'"
    }
}

Describe 'Terraform track' -Tag 'AutomationIdentity' {
    It 'reads the same role map and gates on grant_roles' {
        $script:Tf | Should -Match 'automation-identity-roles\.json'
        $script:Tf | Should -Match 'automation_identity\.grant_roles'
    }
    It 'uses the same ABAC condition shape as Bicep' {
        foreach ($p in 'PrincipalType\] ForAnyOfAnyValues:StringEqualsIgnoreCase', 'PrincipalId\] ForAnyOfAllValues:GuidNotEquals', 'condition_version\s*=') {
            $script:Tf | Should -Match $p
        }
    }
    It 'contains no literal GUID' {
        $script:Tf | Should -Not -Match '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'
    }
}

Describe 'automation_identity environment contract' -Tag 'AutomationIdentity' {
    BeforeAll {
        $script:Schema = Join-Path $script:Repo 'automation' 'shared' 'schemas' 'azure-local.environment.schema.json'
        $script:SkipYaml = -not (Get-Module -ListAvailable powershell-yaml)
        if (-not $script:SkipYaml) {
            Import-Module powershell-yaml
            $script:Example = Get-Content (Join-Path $script:Repo 'automation' 'shared' 'examples' 'environment.azure-local.example.yml') -Raw | ConvertFrom-Yaml
        }
        function Test-Block([hashtable]$Block) {
            $doc = $script:Example.Clone()
            $doc['automation_identity'] = $Block
            return (Test-Json -Json ($doc | ConvertTo-Json -Depth 30) -SchemaFile $script:Schema -ErrorAction SilentlyContinue)
        }
    }
    It 'the example file carries a managed-identity block that validates' -Skip:$script:SkipYaml {
        $script:Example.automation_identity.type | Should -Be 'managed-identity'
        Test-Block $script:Example.automation_identity | Should -BeTrue
    }
    It 'accepts a service principal with both Key Vault references' -Skip:$script:SkipYaml {
        Test-Block @{ type = 'service-principal'; service_principal_app_id_secret = 'keyvault://kv-iic-nic26-ops-eus-01/a'; service_principal_secret_secret = 'keyvault://kv-iic-nic26-ops-eus-01/b'; service_principal_object_id = '00000000-0000-0000-0000-000000000000' } | Should -BeTrue
    }
    It 'rejects a service principal without its secret reference' -Skip:$script:SkipYaml {
        Test-Block @{ type = 'service-principal'; service_principal_app_id_secret = 'keyvault://kv-iic-nic26-ops-eus-01/a' } | Should -BeFalse
    }
    It 'rejects an unknown type, an unknown key and a plain-text secret' -Skip:$script:SkipYaml {
        Test-Block @{ type = 'user' } | Should -BeFalse
        Test-Block @{ type = 'managed-identity'; extra = 1 } | Should -BeFalse
        Test-Block @{ type = 'managed-identity'; managed_identity_client_id_secret = 'plain-value' } | Should -BeFalse
    }
}
