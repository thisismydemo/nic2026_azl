#Requires -Version 7.0
# Parity (contract §6): manifest outputs == Bicep outputs == Terraform outputs; manifest inputs == Bicep params == Terraform
# variables; every names.<key> referenced by either track exists in the manifest catalog; both example files cover every input.
BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $manifestText = Get-Content (Join-Path $script:Root 'solution.yml') -Raw

    # Minimal YAML readers for the three sections this test needs (no powershell-yaml dependency).
    function Get-YamlSectionLines([string] $Text, [string] $Section) {
        $lines = $Text -split "`r?`n"
        $start = ($lines | Select-String -Pattern "^$Section\s*:" | Select-Object -First 1).LineNumber
        if (-not $start) { return @() }
        $out = @()
        for ($i = $start; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^[A-Za-z_]+\s*:' ) { break }
            $out += $lines[$i]
        }
        return $out
    }
    $script:ManifestInputs = @(Get-YamlSectionLines $manifestText 'inputs' | ForEach-Object { if ($_ -match '^\s*-\s*\{\s*name:\s*([a-z0-9_]+)') { $Matches[1] } })
    $script:ManifestOutputs = @(Get-YamlSectionLines $manifestText 'outputs' | ForEach-Object { if ($_ -match '^\s*-\s*\{\s*name:\s*([a-z0-9_]+)') { $Matches[1] } })
    $script:ManifestNames = @(Get-YamlSectionLines $manifestText 'names' | ForEach-Object { if ($_ -match '^\s{2}([a-z0-9_]+)\s*:') { $Matches[1] } })

    $bicepJson = (& az bicep build --file (Join-Path $script:Root 'bicep\main.bicep') --stdout 2>$null) -join "`n" | ConvertFrom-Json -AsHashtable
    $script:BicepOutputs = @($bicepJson.outputs.Keys)
    $script:BicepParams = @($bicepJson.parameters.Keys)

    $tfOutputsText = Get-Content (Join-Path $script:Root 'terraform\outputs.tf') -Raw
    $script:TfOutputs = @([regex]::Matches($tfOutputsText, 'output\s+"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })
    $tfVarsText = Get-Content (Join-Path $script:Root 'terraform\variables.tf') -Raw
    $script:TfVars = @([regex]::Matches($tfVarsText, 'variable\s+"([a-z0-9_]+)"') | ForEach-Object { $_.Groups[1].Value })

    $bicepAll = (Get-ChildItem (Join-Path $script:Root 'bicep') -Recurse -Filter '*.bicep' | Get-Content -Raw) -join "`n"
    $tfAll = (Get-ChildItem (Join-Path $script:Root 'terraform') -Filter '*.tf' | Get-Content -Raw) -join "`n"
    $script:BicepNameRefs = @([regex]::Matches($bicepAll, '\bnames\.([a-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $script:TfNameRefs = @([regex]::Matches($tfAll, 'var\.names\.([a-z0-9_]+)|var\.names\["([a-z0-9_]+)"\]') | ForEach-Object { if ($_.Groups[1].Value) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Sort-Object -Unique)

    $script:ExampleBicep = Get-Content (Join-Path $script:Root 'bicep\main.example.bicepparam') -Raw
    $script:ExampleTf = Get-Content (Join-Path $script:Root 'terraform\terraform.example.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
}

Describe 'Outputs parity (manifest == Bicep == Terraform)' -Tag 'Parity' {
    It 'manifest declares outputs' { $script:ManifestOutputs.Count | Should -BeGreaterThan 10 }
    It 'Bicep outputs equal the manifest outputs' {
        Compare-Object ($script:ManifestOutputs | Sort-Object) ($script:BicepOutputs | Sort-Object) | Should -BeNullOrEmpty
    }
    It 'Terraform outputs equal the manifest outputs' {
        Compare-Object ($script:ManifestOutputs | Sort-Object) ($script:TfOutputs | Sort-Object) | Should -BeNullOrEmpty
    }
}

Describe 'Inputs parity (manifest == Bicep params == Terraform variables)' -Tag 'Parity' {
    It 'Bicep parameters equal the manifest inputs' {
        Compare-Object ($script:ManifestInputs | Sort-Object) ($script:BicepParams | Sort-Object) | Should -BeNullOrEmpty
    }
    It 'Terraform variables equal the manifest inputs' {
        Compare-Object ($script:ManifestInputs | Sort-Object) ($script:TfVars | Sort-Object) | Should -BeNullOrEmpty
    }
    It 'main.example.bicepparam sets every non-secret input' {
        $secure = @('jump_admin_username', 'jump_admin_password')
        foreach ($i in ($script:ManifestInputs | Where-Object { $_ -notin $secure })) { $script:ExampleBicep | Should -Match "(?m)^param $i\s*=" -Because "$i must be in the example" }
    }
    It 'main.example.bicepparam does NOT set the run-time secure parameters' {
        $script:ExampleBicep | Should -Not -Match '(?m)^param jump_admin_(username|password)\s*='
    }
    It 'terraform.example.tfvars.json sets every non-secret input and no secure one' {
        $secure = @('jump_admin_username', 'jump_admin_password')
        foreach ($i in ($script:ManifestInputs | Where-Object { $_ -notin $secure })) { $script:ExampleTf.ContainsKey($i) | Should -BeTrue -Because "$i must be in the example" }
        foreach ($s in $secure) { $script:ExampleTf.ContainsKey($s) | Should -BeFalse }
    }
}

Describe 'Name catalog parity (contract §10)' -Tag 'Parity' {
    It 'every names.<key> used by Bicep exists in the manifest catalog' {
        @($script:BicepNameRefs | Where-Object { $_ -notin $script:ManifestNames }) | Should -BeNullOrEmpty
    }
    It 'every var.names.<key> used by Terraform exists in the manifest catalog' {
        @($script:TfNameRefs | Where-Object { $_ -notin $script:ManifestNames }) | Should -BeNullOrEmpty
    }
    It 'both example files resolve every catalog key' {
        foreach ($k in $script:ManifestNames) {
            $script:ExampleBicep | Should -Match "(?m)^\s+$k\s*:" -Because "bicep example lacks names.$k"
            $script:ExampleTf.names.ContainsKey($k) | Should -BeTrue -Because "tfvars example lacks names.$k"
        }
    }
    It 'every non-exempt example name contains nic26 (D-005)' {
        $exempt = @('pdns_vaultcore', 'pdns_monitor', 'pdns_oms', 'pdns_ods', 'pdns_agentsvc', 'tfstate_key', 'tfstate_container')
        foreach ($k in $script:ExampleTf.names.Keys) {
            if ($k -in $exempt) { continue }
            $script:ExampleTf.names[$k] | Should -Match 'nic26' -Because "names.$k"
        }
    }
    It 'Key Vault and storage example names respect the length rules (naming standard §3)' {
        foreach ($k in 'kv_ops', 'kv_azl') { $script:ExampleTf.names[$k].Length | Should -BeLessOrEqual 24; $script:ExampleTf.names[$k] | Should -Not -Match '--' }
        foreach ($k in ($script:ExampleTf.names.Keys | Where-Object { $_ -like 'st_*' })) { $script:ExampleTf.names[$k] | Should -Match '^[a-z0-9]{3,24}$' }
        $script:ExampleTf.names.vm_jump_computer_name.Length | Should -BeLessOrEqual 15
    }
}
