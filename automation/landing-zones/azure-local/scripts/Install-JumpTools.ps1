#Requires -Version 7.0
<#
.SYNOPSIS
    Plans or installs the machine-wide tools of the jump server, from one versions file.
.DESCRIPTION
    Reads every pinned version from jump-tools.versions.psd1. Without -Execute it changes nothing and prints the plan (what is
    installed, what is wanted, what it would do). With -Execute (elevated session) it installs what is missing or at the wrong
    version and skips what is already correct, so a re-run is safe.

    Every install is machine-wide: winget --scope machine, Install-PSResource -Scope AllUsers, Windows features, the Office
    Deployment Tool. Nothing auto-updates. -Execute is refused while a version in the file is still 'TODO-PIN' for a selected tool.
    Not installed by design: Azure VPN Client, Windows Admin Center, RVTools.

    Dot-sourcing the file defines the functions without running anything (the tests do this).
.PARAMETER Execute
    Perform the changes. Without it the script only prints the plan.
.PARAMETER Only
    Limit the run to these tool keys (see the Tools section of the versions file).
.PARAMETER SkipOffice
    Leave out Microsoft 365 Apps.
.PARAMETER PassThru
    Return the per-tool result objects on the pipeline.
.PARAMETER VersionsPath
    Path to the versions file. Default: jump-tools.versions.psd1 next to this script.
.PARAMETER AdditionalVersionsPath
    Optional second versions file merged over the first: its Tools entries are added or replace the same keys, and its
    AnsibleCollections are added to the list. A site layer uses it for tools that are specific to one environment, so the
    shared file stays generic.
.EXAMPLE
    ./Install-JumpTools.ps1
.EXAMPLE
    ./Install-JumpTools.ps1 -Execute -Only git, terraform -PassThru
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch] $Execute,
    [string[]] $Only,
    [switch] $SkipOffice,
    [switch] $PassThru,
    [string] $VersionsPath = (Join-Path $PSScriptRoot 'jump-tools.versions.psd1'),
    [string] $AdditionalVersionsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)
    Write-Information ('[{0}] {1}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Message) -InformationAction Continue
}

function Test-JumpElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JumpConfiguration {
    param([string] $Path)
    return Import-PowerShellDataFile -Path $Path
}

# Returns the locations (path inside the data) of every 'TODO-PIN' value.
function Get-PendingPins {
    param([System.Collections.IDictionary] $Configuration)
    $pending = [System.Collections.Generic.List[string]]::new()
    function Find-Pin {
        param($Value, [string] $Location)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.Keys) { Find-Pin -Value $Value[$key] -Location "$Location.$key" }
        }
        elseif ($Value -is [array]) {
            for ($i = 0; $i -lt $Value.Count; $i++) {
                $label = if ($Value[$i] -is [System.Collections.IDictionary] -and $Value[$i].Contains('Id')) { $Value[$i].Id } else { $i }
                Find-Pin -Value $Value[$i] -Location "$Location.$label"
            }
        }
        elseif ($Value -is [string] -and $Value -ceq 'TODO-PIN') { $pending.Add($Location) }
    }
    Find-Pin -Value $Configuration -Location 'Configuration'
    return $pending.ToArray()
}

# ---- read wrappers (no changes) ------------------------------------------------------------------------------------------
function Get-InstalledWingetVersion {
    param([string] $Id, [string] $Source)
    $arguments = @('list', '--id', $Id, '--exact', '--disable-interactivity')
    if ($Source) { $arguments += @('--source', $Source) }
    $output = & winget @arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $output) {
        if ($line -match ('\s{2,}' + [regex]::Escape($Id) + '\s{2,}(?<Version>\S+)')) { return $Matches.Version }
    }
    return $null
}

function Get-InstalledPSResourceVersion {
    param([string] $Name)
    $resource = Get-InstalledPSResource -Name $Name -Scope AllUsers -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $resource) { return $null }
    return [string] $resource.Version
}

function Get-InstalledAzExtensionVersion {
    param([string] $Name)
    $json = & az extension list --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $extension = @($json | ConvertFrom-Json) | Where-Object name -eq $Name | Select-Object -First 1
    if ($null -eq $extension) { return $null }
    return [string] $extension.version
}

function Get-InstalledAzBicepVersion {
    $text = & az bicep version 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if (($text -join ' ') -match '\b(?<Version>\d+\.\d+\.\d+)\b') { return $Matches.Version }
    return $null
}

function Get-WslState {
    param([string] $Distribution)
    $names = & wsl --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return (@($names | ForEach-Object { ([string]$_).Replace([string][char]0, '').Trim() }) -contains $Distribution)
}

function Get-AnsibleState {
    param([string] $Distribution, [string] $Component)
    $command = if ($Component -eq 'ansible-core') { 'ansible --version' } else { 'ansible-galaxy collection list --format json' }
    $output = & wsl -d $Distribution -u root -- sh -lc $command 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    if ($Component -eq 'ansible-core') {
        if (($output -join ' ') -match 'ansible \[core (?<Version>[^\]\s]+)') { return $Matches.Version }
        return $null
    }
    try {
        $paths = ($output -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($path in $paths.Keys) {
            if ($paths[$path].Contains($Component)) { return [string] $paths[$path][$Component].version }
        }
    }
    catch { return $null }
    return $null
}

function Get-WindowsFeatureState {
    param([string] $Name)
    return [string] (Get-WindowsFeature -Name $Name).InstallState
}

function Get-VSCodeExtensionVersion {
    param([string] $Id, [string] $Directory)
    $lines = & code --list-extensions --show-versions --extensions-dir $Directory 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $lines) {
        if ($line -match ('^' + [regex]::Escape($Id) + '@(?<Version>\S+)$')) { return $Matches.Version }
    }
    return $null
}

function Get-OfficeBuild {
    $entries = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($null -eq $entries) { return $null }
    $reported = [string] $entries.VersionToReport
    # VersionToReport is 16.0.<build>.<revision>, the same shape as the pin.
    return $reported
}

# ---- mutating wrappers (every change goes through one of these) ------------------------------------------------------
function Invoke-Winget {
    param([string[]] $Arguments)
    & winget @Arguments
    if ($LASTEXITCODE -ne 0) { throw "winget failed (exit $LASTEXITCODE)." }
}

function Install-PSResourcePinned {
    param([string] $Name, [string] $Version)
    $repository = Get-PSResourceRepository -Name PSGallery
    if (-not $repository.Trusted) { Set-PSResourceRepository -Name PSGallery -Trusted }
    Install-PSResource -Name $Name -Version $Version -Repository PSGallery -Scope AllUsers -TrustRepository -AcceptLicense -ErrorAction Stop
}

function Invoke-AzCli {
    param([string[]] $Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "az failed (exit $LASTEXITCODE)." }
}

function Invoke-Wsl {
    param([string[]] $Arguments)
    & wsl @Arguments
    if ($LASTEXITCODE -ne 0) { throw "wsl failed (exit $LASTEXITCODE)." }
}

function Install-WindowsFeaturePinned {
    param([string] $Name)
    $result = Install-WindowsFeature -Name $Name -IncludeAllSubFeature
    if (-not $result.Success) { throw "Windows feature $Name failed to install." }
    return $result
}

function Set-MachineExtensionsDirectory {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param([string] $Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    # A machine-scoped VSCODE_EXTENSIONS makes this the extensions directory of every VS Code process started after the next
    # sign-in (verify on the first build: sign out and in, then run `code --list-extensions`).
    [Environment]::SetEnvironmentVariable('VSCODE_EXTENSIONS', $Directory, 'Machine')
}

function Invoke-Code {
    param([string] $Id, [string] $Version, [string] $Directory)
    & code --install-extension "$Id@$Version" --extensions-dir $Directory --force
    if ($LASTEXITCODE -ne 0) { throw "VS Code extension $Id failed." }
}

function Set-WingetAutoUpdate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param()
    # winget has no package auto-upgrade by itself; if this installation's settings file carries an auto-update flag, turn it off.
    $settings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json'
    if (-not (Test-Path $settings)) { return }
    $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json -AsHashtable
    $changed = $false
    if ($json.Contains('autoUpdate')) { $json.autoUpdate = $false; $changed = $true }
    if ($json.Contains('source') -and $json.source -is [System.Collections.IDictionary] -and $json.source.Contains('autoUpdateIntervalInMinutes')) {
        $json.source.autoUpdateIntervalInMinutes = 0; $changed = $true
    }
    if ($changed) { $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settings -Encoding utf8 }
}

function New-OfficeConfigurationXml {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Reached only through Invoke-JumpTools, which turns on WhatIf unless -Execute is given and skips the changing calls then.')]
    param([string] $Build)
    if ($Build -notmatch '^\d+(?:\.\d+){3}$') { throw 'The Office version must be a four-part build number such as 16.0.20430.20146.' }
    [xml] $xml = '<Configuration/>'
    $add = $xml.CreateElement('Add')
    $add.SetAttribute('OfficeClientEdition', '64')
    $add.SetAttribute('Channel', 'Current')
    $add.SetAttribute('Version', $Build)
    [void] $xml.DocumentElement.AppendChild($add)
    $product = $xml.CreateElement('Product')
    $product.SetAttribute('ID', 'O365ProPlusRetail')
    [void] $add.AppendChild($product)
    $language = $xml.CreateElement('Language')
    $language.SetAttribute('ID', 'MatchOS')
    [void] $product.AppendChild($language)
    # Word, Excel, PowerPoint, Outlook and OneNote stay; the rest of the suite is excluded.
    foreach ($app in @('Access', 'Publisher', 'Groove', 'Lync', 'Teams', 'OneDrive', 'Bing')) {
        $exclude = $xml.CreateElement('ExcludeApp')
        $exclude.SetAttribute('ID', $app)
        [void] $product.AppendChild($exclude)
    }
    $property = $xml.CreateElement('Property')
    $property.SetAttribute('Name', 'SharedComputerLicensing')
    $property.SetAttribute('Value', '1')
    [void] $xml.DocumentElement.AppendChild($property)
    $updates = $xml.CreateElement('Updates')
    $updates.SetAttribute('Enabled', 'FALSE')
    [void] $xml.DocumentElement.AppendChild($updates)
    $display = $xml.CreateElement('Display')
    $display.SetAttribute('Level', 'None')
    $display.SetAttribute('AcceptEULA', 'TRUE')
    [void] $xml.DocumentElement.AppendChild($display)
    return $xml
}

function Invoke-OfficeSetup {
    param([string] $Build, [string] $DownloadUrl, [string] $Sha256)
    if (-not $DownloadUrl -or -not $DownloadUrl.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Office.DownloadUrl must be an https URL of the Office Deployment Tool.'
    }
    if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'Office.DownloadSha256 must be the SHA-256 of the Office Deployment Tool.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory | Out-Null
    try {
        $bootstrap = Join-Path $directory 'odt.exe'
        $config = Join-Path $directory 'configuration.xml'
        $setup = Join-Path $directory 'setup.exe'
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $bootstrap
        if ((Get-FileHash -LiteralPath $bootstrap -Algorithm SHA256).Hash -ne $Sha256.ToUpperInvariant()) { throw 'The downloaded Office Deployment Tool does not match the pinned SHA-256.' }
        $signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'The Office Deployment Tool is not signed by Microsoft.' }
        $extract = Start-Process -FilePath $bootstrap -ArgumentList @("/extract:$directory", '/quiet') -Wait -PassThru
        if ($extract.ExitCode -ne 0 -or -not (Test-Path $setup)) { throw 'Office Deployment Tool extraction failed.' }
        (New-OfficeConfigurationXml -Build $Build).Save($config)
        $install = Start-Process -FilePath $setup -ArgumentList @('/configure', "`"$config`"") -Wait -PassThru
        if ($install.ExitCode -ne 0) { throw "Office setup failed (exit $($install.ExitCode))." }
    }
    finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
}

# The installed version of one component, read through the (mockable) read wrappers. Used before an install (what is there) and after it (did it land).
function Get-JumpComponentVersion {
    param($Component, $Spec, [string] $ExtensionDirectory)
    switch ($Component.Kind) {
        'winget' { Get-InstalledWingetVersion -Id $Component.Name -Source $Component.Data.Source }
        'psresource' { Get-InstalledPSResourceVersion -Name $Component.Name }
        'az-extension' { Get-InstalledAzExtensionVersion -Name $Component.Name }
        'az-bicep' { Get-InstalledAzBicepVersion }
        'code' { Get-VSCodeExtensionVersion -Id $Component.Name -Directory $ExtensionDirectory }
        'feature' { Get-WindowsFeatureState -Name $Component.Name }
        'wsl' { if (Get-WslState -Distribution $Component.Name) { $Component.Version } else { $null } }
        'ansible' { if (Get-WslState -Distribution $Spec.Distribution) { Get-AnsibleState -Distribution $Spec.Distribution -Component $Component.Name } else { $null } }
        'office' { Get-OfficeBuild }
    }
}

# 'N/A' means the component is not version-pinned (a Store package): presence is enough. A feature waiting for a restart counts as installed.
function Test-JumpComponentCorrect {
    param($Component, $Installed)
    if (-not $Installed) { return $false }
    if ($Component.Kind -eq 'feature') { return ([string]$Installed -in @('Installed', 'InstallPending')) }
    return ($Component.Version -ceq 'N/A' -or [string]$Installed -ceq [string]$Component.Version)
}

function Invoke-JumpTools {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch] $Execute,
        [string[]] $Only,
        [switch] $SkipOffice,
        [switch] $PassThru,
        [string] $VersionsPath = (Join-Path $PSScriptRoot 'jump-tools.versions.psd1'),
        [string] $AdditionalVersionsPath
    )

    $script:JumpToolsFailed = $false
    if (-not $Execute) { $WhatIfPreference = $true }
    $configuration = Get-JumpConfiguration -Path $VersionsPath
    if ($AdditionalVersionsPath) {
        $extra = Get-JumpConfiguration -Path $AdditionalVersionsPath
        if ($extra.Contains('Tools')) { foreach ($k in $extra.Tools.Keys) { $configuration.Tools[$k] = $extra.Tools[$k] } }
        if ($extra.Contains('AnsibleCollections')) {
            if (-not $configuration.Contains('AnsibleCollections')) { $configuration.AnsibleCollections = @{} }
            foreach ($k in $extra.AnsibleCollections.Keys) { $configuration.AnsibleCollections[$k] = $extra.AnsibleCollections[$k] }
        }
    }
    $tools = $configuration.Tools
    if ($null -eq $tools -or $tools -isnot [System.Collections.IDictionary]) { throw 'The versions file must contain a Tools dictionary.' }
    $requested = @($Only | Where-Object { $_ })
    foreach ($key in $requested) { if (-not $tools.Contains($key)) { throw "Unknown tool key: $key" } }

    $keys = @(if ($requested.Count -gt 0) { $requested } else { $tools.Keys })
    if ($SkipOffice) { $keys = @($keys | Where-Object { $_ -ne 'office' }) }

    # Pins are checked for the selected tools only, so one unresolved pin blocks its own tool and nothing else.
    $selected = @{ Tools = @{} }
    foreach ($key in $keys) { $selected.Tools[$key] = $tools[$key] }
    if ($keys -contains 'ansible-wsl') { $selected.AnsibleCollections = $configuration.AnsibleCollections }
    $pins = @(Get-PendingPins -Configuration $selected)
    if ($Execute) {
        if (-not (Test-JumpElevated)) { throw 'Execution requires an elevated session.' }
        if ($pins.Count -gt 0) { throw "Resolve TODO-PIN before execution: $($pins -join ', ')" }
    }
    elseif ($pins.Count -gt 0) { Write-Warning "Unresolved pins (execution is refused until they are set): $($pins -join ', ')" }

    $results = [System.Collections.Generic.List[object]]::new()
    $extensionDirectory = Join-Path $env:ProgramData 'JumpTools\VSCodeExtensions'

    foreach ($key in $keys) {
        $spec = $tools[$key]
        $wanted = [string] $spec.Version
        $found = [System.Collections.Generic.List[string]]::new()
        $missing = [System.Collections.Generic.List[object]]::new()
        $reboot = $false

        # A tool can have several components (a package plus extensions, several modules). Each is checked before it is
        # scheduled; a correct component is never installed again.
        $components = [System.Collections.Generic.List[object]]::new()
        if ($spec.Contains('Packages')) {
            foreach ($package in $spec.Packages) {
                $components.Add([pscustomobject]@{ Kind = 'winget'; Name = $package.Id; Version = $package.Version; Data = $package })
            }
        }
        if ($spec.Contains('Modules')) {
            foreach ($name in $spec.Modules.Keys) { $components.Add([pscustomobject]@{ Kind = 'psresource'; Name = $name; Version = $spec.Modules[$name]; Data = $null }) }
        }
        if ($spec.Contains('Features')) {
            foreach ($name in $spec.Features) { $components.Add([pscustomobject]@{ Kind = 'feature'; Name = $name; Version = 'Installed'; Data = $null }) }
        }
        if ($key -eq 'azure-cli') {
            foreach ($name in $spec.Extensions.Keys) { $components.Add([pscustomobject]@{ Kind = 'az-extension'; Name = $name; Version = $spec.Extensions[$name]; Data = $null }) }
        }
        if ($key -eq 'bicep') { $components.Add([pscustomobject]@{ Kind = 'az-bicep'; Name = 'az bicep'; Version = $spec.Version; Data = $null }) }
        if ($key -eq 'vscode') {
            foreach ($name in $spec.Extensions.Keys) { $components.Add([pscustomobject]@{ Kind = 'code'; Name = $name; Version = $spec.Extensions[$name]; Data = $null }) }
        }
        if ($key -eq 'ansible-wsl') {
            $components.Add([pscustomobject]@{ Kind = 'wsl'; Name = $spec.Distribution; Version = $spec.Version; Data = $null })
            $components.Add([pscustomobject]@{ Kind = 'ansible'; Name = 'ansible-core'; Version = $spec.AnsibleCoreVersion; Data = $null })
            foreach ($name in $configuration.AnsibleCollections.Keys) { $components.Add([pscustomobject]@{ Kind = 'ansible'; Name = $name; Version = $configuration.AnsibleCollections[$name]; Data = $null }) }
        }
        if ($key -eq 'office') { $components.Add([pscustomobject]@{ Kind = 'office'; Name = 'Microsoft 365 Apps'; Version = $spec.Version; Data = $null }) }
        if ($components.Count -eq 0) { throw "The versions file defines nothing to install for '$key'." }

        foreach ($component in $components) {
            $installed = Get-JumpComponentVersion -Component $component -Spec $spec -ExtensionDirectory $extensionDirectory
            if ($installed) { $found.Add("$($component.Name)=$installed") }
            if (-not (Test-JumpComponentCorrect -Component $component -Installed $installed)) { $missing.Add($component) }
        }

        $action = if ($missing.Count) { 'Install' } else { 'Skip' }
        $result = if ($missing.Count) { 'Planned' } else { 'AlreadyCorrect' }

        if ($Execute -and $missing.Count -gt 0) {
            $result = 'Installed'
            foreach ($component in $missing) {
                Write-Log "$key`: installing $($component.Name) $($component.Version)"
                $verify = $true
                try {
                    if (-not $PSCmdlet.ShouldProcess($component.Name, "Install $($component.Version)")) { if ($result -ne 'Failed') { $result = 'Planned' }; continue }
                    switch ($component.Kind) {
                        'winget' {
                            $arguments = @('install', '--id', $component.Name, '--exact', '--scope', 'machine', '--silent',
                                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                            if ($component.Data.Source) { $arguments += @('--source', $component.Data.Source) }
                            if ($component.Version -cne 'N/A') { $arguments += @('--version', $component.Version) }
                            if ($component.Data.Contains('Override') -and $component.Data.Override) { $arguments += @('--override', $component.Data.Override) }
                            Invoke-Winget -Arguments $arguments
                            Set-WingetAutoUpdate
                        }
                        'psresource' { Install-PSResourcePinned -Name $component.Name -Version $component.Version }
                        'az-extension' { Invoke-AzCli -Arguments @('extension', 'add', '--name', $component.Name, '--version', $component.Version) }
                        'az-bicep' { Invoke-AzCli -Arguments @('bicep', 'install', '--version', $component.Version) }
                        'code' {
                            Set-MachineExtensionsDirectory -Directory $extensionDirectory
                            Invoke-Code -Id $component.Name -Version $component.Version -Directory $extensionDirectory
                        }
                        'feature' {
                            $featureResult = Install-WindowsFeaturePinned -Name $component.Name
                            if ($featureResult.RestartNeeded -eq 'Yes') { $reboot = $true }
                        }
                        'wsl' {
                            try { Invoke-Wsl -Arguments @('--install', '-d', $component.Name, '--no-launch') }
                            catch { if (-not (Get-WslState -Distribution $component.Name)) { throw } }
                            # A new WSL component or distribution is usable after the next boot; the Ansible steps run on the next pass.
                            $reboot = $true
                            $verify = $false
                        }
                        'ansible' {
                            if ($reboot) { $verify = $false; break }
                            if ($component.Name -eq 'ansible-core') {
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'sh', '-c', 'apt-get update && apt-get install -y pipx python3-venv')
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'pipx', 'install', '--global', "ansible-core==$($component.Version)")
                            }
                            else {
                                Invoke-Wsl -Arguments @('-d', $spec.Distribution, '-u', 'root', '--', 'ansible-galaxy', 'collection', 'install', '-p', '/usr/share/ansible/collections', "$($component.Name):$($component.Version)")
                            }
                        }
                        'office' { Invoke-OfficeSetup -Build $component.Version -DownloadUrl $spec.DownloadUrl -Sha256 $spec.DownloadSha256 }
                    }
                    # Install-then-verify: an exit code of 0 does not prove the pinned version landed (winget can pick another one).
                    if ($verify) {
                        $after = Get-JumpComponentVersion -Component $component -Spec $spec -ExtensionDirectory $extensionDirectory
                        if (-not (Test-JumpComponentCorrect -Component $component -Installed $after)) {
                            throw "installed, but found '$after' where '$($component.Version)' is pinned"
                        }
                    }
                }
                catch {
                    $result = 'Failed'
                    Write-Log "$key`: $($component.Name) failed: $($_.Exception.Message)"
                }
            }
            if ($reboot -and $result -ne 'Failed') { $result = 'RebootRequired' }
        }

        Write-Log "$key`: $action, $result"
        $results.Add([pscustomobject]@{
                Tool   = $key
                Wanted = $wanted
                Found  = if ($found.Count) { $found -join '; ' } else { 'Not found' }
                Action = $action
                Result = $result
                Reboot = $reboot
            })
    }

    $results | Format-Table Tool, Wanted, Found, Action, Result, Reboot -AutoSize | Out-String | Write-Information -InformationAction Continue
    $script:JumpToolsFailed = @($results | Where-Object Result -eq 'Failed').Count -gt 0
    if ($PassThru) { return $results.ToArray() }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-JumpTools -Execute:$Execute -Only $Only -SkipOffice:$SkipOffice -PassThru:$PassThru -VersionsPath $VersionsPath -AdditionalVersionsPath $AdditionalVersionsPath
    if ($script:JumpToolsFailed) { exit 1 }
}
