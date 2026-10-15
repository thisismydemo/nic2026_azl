#Requires -Version 7.0
# Gate (contract §8): Select-String sweep of the solution for GUIDs, non-documentation IPs, 'password =', tokens.
# Documented allow-list: all-zero GUIDs (examples); built-in role/policy definition GUIDs in the two constants files
# (Azure platform constants, verified live by Test-LandingZone.ps1 role-map / policy-map), also where a script repeats one of
# them; in jump-tools.versions.psd1 the public download-path GUID, the verified publisher certificate subject and the
# installer identities of public installers (MSI ProductCode, Inno Setup UninstallKey, VS Code SystemAppId); documentation
# IP ranges (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24); the Azure DNS virtual IP 168.63.129.16 (a platform constant
# named in the design).
BeforeAll {
    function Test-SweepPublicInstallerGuid {
        param([string] $FileName, [string] $Line, [string] $Value)
        # Installer identities published by the vendors of the pinned public installers (MSI ProductCode, Inno Setup
        # UninstallKey, VS Code SystemAppId), not tenant/subscription identifiers. Allowed only in the pin file, only as the
        # value of one of those three keys: on its own line or inside a one-line MachineEvidence = @{ ... } table.
        if ($FileName -ne 'jump-tools.versions.psd1') { return $false }
        $key = "(ProductCode|UninstallKey|SystemAppId)\s*=\s*'\{\{?$([regex]::Escape($Value))\}[^']*'"
        return ($Line -match "^\s*$key\s*(#.*)?$") -or ($Line -match "MachineEvidence\s*=\s*@\{.*[;\s]$key")
    }
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Files = Get-ChildItem $script:Root -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/](\.terraform|\.git)[\\/]' -and $_.Extension -in '.bicep', '.bicepparam', '.tf', '.json', '.ps1', '.psd1', '.yml', '.yaml', '.md', '.hcl' -and $_.Name -notlike '*.generated.*' -and $_.Name -ne 'secrets-sweep.Tests.ps1' }   # the sweep itself necessarily contains the patterns
    $script:GuidAllowFiles = @('built-in-roles.bicep', 'policy-definitions.bicep')
    # The one GUID that is part of a public Microsoft download path (the Office Deployment Tool URL in jump-tools.versions.psd1), read from that file so it is not repeated here.
    $script:GuidAllowValues = @([regex]::Matches((Get-Content (Join-Path $script:Root 'scripts' 'jump-tools.versions.psd1') -Raw), 'download.microsoft.com/download/([0-9a-fA-F-]{36})/') | ForEach-Object { $_.Groups[1].Value })
    # The built-in role and policy definition GUIDs are allowed wherever a script repeats one of them (e.g. a role ID passed to a role assignment); read from the two constants files so they are not repeated here.
    $script:GuidAllowValues += @($script:GuidAllowFiles | ForEach-Object { [regex]::Matches((Get-Content (Join-Path $script:Root 'bicep' 'modules' $_) -Raw), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}') | ForEach-Object { $_.Value } })
    # Files that carry four-part tool versions, not addresses; the IP sweep still covers every other file.
    $script:IpAllowFiles = @('jump-tools.versions.psd1', 'Install-JumpTools.Tests.ps1', 'JumpMachineEvidence.Tests.ps1', 'JumpMsix.Tests.ps1')
}

Describe 'Secrets and tenant-data sweep' -Tag 'Gate', 'Secrets' {
    It 'contains no GUID other than all-zero examples and the documented built-in role/policy constants' {
        $hits = foreach ($f in $script:Files) {
            Select-String -Path $f.FullName -Pattern '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}' -AllMatches | ForEach-Object {
                foreach ($m in $_.Matches) {
                    if ($m.Value -eq '00000000-0000-0000-0000-000000000000') { continue }
                    if ($m.Value -match '^([0-9a-f])\1{7}-([0-9a-f])\2{3}-([0-9a-f])\3{3}-([0-9a-f])\4{3}-([0-9a-f])\5{11}$') { continue }   # synthetic single-digit test fixtures
                    if ($f.Name -in $script:GuidAllowFiles) { continue }
                    if ($m.Value -in $script:GuidAllowValues) { continue }
                    if (Test-SweepPublicInstallerGuid -FileName $f.Name -Line $_.Line -Value $m.Value) { continue }
                    "$($f.Name):$($_.LineNumber) $($m.Value)"
                }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }
    It 'allows public installer identities only as ProductCode/UninstallKey/SystemAppId values in the pin file' {
        $guid = [guid]::NewGuid().ToString().ToUpperInvariant()
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    ProductCode = '{$guid}'" -Value $guid | Should -BeTrue
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    UninstallKey = '{$guid}_is1'" -Value $guid | Should -BeTrue
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    MachineEvidence = @{ PackageId = 'Example.Tool'; Kind = 'msi-file-hash'; UninstallKey = '{$guid}'; Publisher = 'Example' }" -Value $guid | Should -BeTrue
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    MachineEvidence = @{ PackageId = 'Example.Tool'; Kind = 'signed-inno'; SystemAppId = '{{$guid}' }" -Value $guid | Should -BeTrue
        Test-SweepPublicInstallerGuid -FileName 'other.psd1' -Line "    ProductCode = '{$guid}'" -Value $guid | Should -BeFalse
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    TenantId = '$guid'" -Value $guid | Should -BeFalse
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    ProductCode = '$guid'" -Value $guid | Should -BeFalse
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    MachineEvidence = @{ PackageId = 'Example.Tool'; TenantId = '{$guid}' }" -Value $guid | Should -BeFalse
        Test-SweepPublicInstallerGuid -FileName 'jump-tools.versions.psd1' -Line "    Settings = @{ UninstallKey = '{$guid}' }" -Value $guid | Should -BeFalse
    }

    It 'contains no IP address outside the documentation ranges and the Azure DNS virtual IP' {
        $hits = foreach ($f in $script:Files) {
            if ($f.Name -in $script:IpAllowFiles) { continue }
            Select-String -Path $f.FullName -Pattern '\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b' -AllMatches | ForEach-Object {
                foreach ($m in $_.Matches) {
                    $ip = $m.Value
                    if ($ip -match '^(192\.0\.2|198\.51\.100|203\.0\.113)\.' -or $ip -eq '168.63.129.16') { continue }
                    if ($ip -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$' -and ([int]$Matches[1] -gt 255)) { continue } # version strings such as 2024.07.01.0
                    "$($f.Name):$($_.LineNumber) $ip"
                }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'contains no secret value assignment or token' {
        $hits = foreach ($f in $script:Files) {
            Select-String -Path $f.FullName -Pattern '(?i)(password|secret|token)\s*[:=]\s*["''][^"''$\{<]{8,}["'']|eyJ[a-zA-Z0-9_-]{20,}|AccountKey=|SharedAccessSignature=|sig=[a-zA-Z0-9%]{20,}' -AllMatches |
                Where-Object { $_.Line -notmatch 'keyvault://|ContentType|description|Description|_secret\s*=\s*' } |
                ForEach-Object { "$($f.Name):$($_.LineNumber) $($_.Line.Trim())" }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'no script uses Start-Transcript or prints a credential variable' {
        foreach ($f in ($script:Files | Where-Object Extension -EQ '.ps1')) {
            (Get-Content $f.FullName -Raw) | Should -Not -Match '(?m)^\s*Start-Transcript'
            (Get-Content $f.FullName -Raw) | Should -Not -Match 'Write-(Host|Output|Information)[^\n]*\$(plain|pwd|cred|password)\b'
        }
    }
}
