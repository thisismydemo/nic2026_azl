#Requires -Version 7.0
# Pester 5 - cluster-configure/gpu static gates (no cluster, no Azure).
BeforeAll {
    $script:root = Join-Path $PSScriptRoot '..'
    $script:scripts = Get-ChildItem -Path (Join-Path $root 'scripts') -Filter *.ps1
    $script:text = @{}
    foreach ($s in $scripts) { $text[$s.Name] = Get-Content -LiteralPath $s.FullName -Raw }
}

Describe 'cluster-configure/gpu scripts' {
    It 'every script parses' {
        foreach ($s in $scripts) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because $s.Name
        }
    }
    It 'every script uses StrictMode and stop-on-error' {
        foreach ($s in $scripts) {
            $text[$s.Name] | Should -Match 'Set-StrictMode -Version Latest' -Because $s.Name
            $text[$s.Name] | Should -Match "\`$ErrorActionPreference = 'Stop'" -Because $s.Name
        }
    }
    It 'holds no lab values (G5): no IPs, GUIDs, vault names or lab resource names' {
        foreach ($s in $scripts) {
            $t = $text[$s.Name]
            $t | Should -Not -Match '\b(?:\d{1,3}\.){3}\d{1,3}\b' -Because $s.Name
            $t | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' -Because $s.Name
            $t | Should -Not -Match 'kv-iic|nic26-01-n0|rg-iic|cl-iic' -Because $s.Name
        }
    }
    It 'host prep and attach default to a plan and change only with -Execute' {
        foreach ($n in 'Initialize-GpuHost.ps1', 'Set-VmGpuAssignment.ps1') {
            $text[$n] | Should -Match '\[switch\]\$Execute' -Because $n
            $text[$n] | Should -Match 'if \(-not \$Execute\)' -Because $n
            $text[$n] | Should -Match 'SupportsShouldProcess' -Because $n
        }
    }
    It 'host prep gates on cluster, storage and VM state, drains one node at a time and waits for storage repair' {
        $t = $text['Initialize-GpuHost.ps1']
        $t | Should -Match 'Get-StorageJob'
        $t | Should -Match 'HealthStatus'
        $t | Should -Match 'Suspend-ClusterNode -Name \$n -Drain -Wait'
        $t | Should -Match 'Resume-ClusterNode'
        $t | Should -Match 'Storage not healthy'
        $t | Should -Match 'provisioningState'
        $t | Should -Match 'Dismount-VMHostAssignableDevice'
        $t | Should -Match 'pnputil /add-driver'
        $t | Should -Match 'mitigation_driver\.sha256'
        $t | Should -Not -Match 'Clear-Disk|Initialize-Disk|Add-Computer|Format-Volume'
    }
    It 'attach uses the CLI (Azure PowerShell for Azure Local VMs is out of scope) with one DDA GPU' {
        $t = $text['Set-VmGpuAssignment.ps1']
        $t | Should -Match "'stack-hci-vm', 'gpu', 'attach'"
        $t | Should -Match "'--gpu-dda-count', '1'"
        $t | Should -Match 'GpuDDA'
    }
    It 'guest script verifies the installer signature and sets the three AVD GPU policies' {
        $t = $text['Install-GuestGpuDriver.ps1']
        $t | Should -Match 'Get-AuthenticodeSignature'
        foreach ($v in 'bEnumerateHWBeforeSW', 'AVC444ModePreferred', 'AVCHardwareEncodePreferred') { $t | Should -Match $v }
    }
}

Describe 'gpu environment block' {
    It 'validates against the azure-local schema when present' {
        $repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\..')).Path
        $schemaFile = Join-Path $repo 'automation\shared\schemas\azure-local.environment.schema.json'
        $schema = Get-Content -LiteralPath $schemaFile -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.Keys | Should -Contain 'gpu'
        $schema.properties.gpu.required | Should -Contain 'mitigation_driver'
    }
}
