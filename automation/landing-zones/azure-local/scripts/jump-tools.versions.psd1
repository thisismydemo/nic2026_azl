# Pinned versions for Install-JumpTools.ps1. Every version is changed only by a commit, so a rebuild reproduces the same machine.
# Resolved 6 Oct 2026 from the authoritative source of each tool (winget manifests, PowerShell Gallery, the Azure CLI extension index,
# PyPI, Ansible Galaxy, the VS Code Marketplace, Microsoft's Current Channel history). 'TODO-PIN' is refused by -Execute for the
# selected tools; 'N/A' is reserved for built-in Windows features; package versions must match exactly.
@{
    Tools              = @{
        'node' = @{
            Version = '24.19.0'
            Node = @{
                NpmVersion = '11.17.0'
                DownloadUrl = 'https://nodejs.org/dist/v24.19.0/node-v24.19.0-x64.msi'
                Sha256 = 'F0F66C2A80C08A30A5AB5179EE9EA9E45F9B46289436A8CC87FF833B852DB351'
                Publisher = 'CN=OpenJS Foundation, O=OpenJS Foundation, L=San Francisco, S=California, C=US'
                ProductCode = '{89850E15-F7D6-476D-972E-F8F5215E4498}'
                RegistrationPublisher = 'Node.js Foundation'
                BinarySha256 = '3602F2BB1A10F2CBAB4C36886218A33C1AB3DB87290E73B033C46C77147D0237'
            }
        }
        'testing' = @{
            Version = '5.9.1'
            Modules = @{ 'Pester' = '5.9.1'; 'PSScriptAnalyzer' = '1.25.0'; 'powershell-yaml' = '0.4.12' }
        }
        'python' = @{
            Version = '3.14.8'
            Python = @{
                InstallDirectory = 'Python314'
                RendererDirectory = 'NIC26/PythonTools/3.14.8'
                DownloadUrl = 'https://www.python.org/ftp/python/3.14.8/python-3.14.8-amd64.exe'
                Sha256 = '759be887b96e736a3ca886daf8d575f18fcae1a09efab6902f42d59e8999f8ef'
                Publisher = 'CN=Python Software Foundation, O=Python Software Foundation, L=Beaverton, S=Oregon, C=US'
                Packages = @(
                    @{ Name = 'Jinja2'; Version = '3.1.6'; File = 'jinja2-3.1.6-py3-none-any.whl'; Sha256 = '85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67'; Url = 'https://files.pythonhosted.org/packages/62/a1/3d680cbfd5f4b8f15abc1d571870c5fc3e594bb582bc3b64ea099db13e56/jinja2-3.1.6-py3-none-any.whl' }
                    @{ Name = 'PyYAML'; Version = '6.0.3'; File = 'pyyaml-6.0.3-cp314-cp314-win_amd64.whl'; Sha256 = '4a2e8cebe2ff6ab7d1050ecd59c25d4c8bd7e6f400f5f82b96557ac0abafd0ac'; Url = 'https://files.pythonhosted.org/packages/23/20/bb6982b26a40bb43951265ba29d4c246ef0ff59c9fdcdf0ed04e0687de4d/pyyaml-6.0.3-cp314-cp314-win_amd64.whl' }
                    @{ Name = 'MarkupSafe'; Version = '3.0.4'; File = 'markupsafe-3.0.4-cp314-cp314-win_amd64.whl'; Sha256 = 'c1bc67752d5f21013cfe430df4062441714eab79f65a6a05e01505957e9c35fe'; Url = 'https://files.pythonhosted.org/packages/80/f0/5792ff768a410f93ee3f84fc19345295ffc352d2c936b424cb37e514714c/markupsafe-3.0.4-cp314-cp314-win_amd64.whl' }
                )
            }
        }
        # CLI is unsupported under SYSTEM; this pinned module supplies Microsoft's supported machine package API.
        # Official PowerShell Gallery release checked 8 Oct 2026; package backend integration is verified separately.
        'winget-client'    = @{
            Version = '1.29.380'
            Modules = @{ 'Microsoft.WinGet.Client' = '1.29.380' }
        }
        'powershell7'      = @{
            Version  = '7.6.6.0'
            Packages = @(@{ Id = 'Microsoft.PowerShell'; Version = '7.6.6.0'; Source = 'winget' })
        }
        'az-powershell'    = @{
            Version = '16.4.0'
            Modules = @{
                'Az'                       = '16.4.0'
                'Az.StackHCI'              = '3.0.0'
                'Az.ConnectedMachine'      = '1.1.1'
                'Az.KeyVault'              = '6.6.1'
                'Az.DesktopVirtualization' = '6.0.0'
            }
        }
        'envchecker'       = @{
            Version = '10.2605.0.2006'
            Modules = @{ 'AzStackHci.EnvironmentChecker' = '10.2605.0.2006' }
        }
        'graph'            = @{
            Version = '2.41.1'
            Modules = @{ 'Microsoft.Graph' = '2.41.1' }
        }
        'azure-cli'        = @{
            Version    = '2.91.0'
            Packages   = @(@{ Id = 'Microsoft.AzureCLI'; Version = '2.91.0'; Source = 'winget' })
            Extensions = @{
                'ssh'                   = '2.0.9'
                'bastion'               = '1.4.3'
                'stack-hci-vm'          = '1.15.1'
                'connectedmachine'      = '3.0.0'
                'desktopvirtualization' = '1.0.0'
            }
        }
        'bicep'            = @{
            Version  = '0.48.1'
            Binary = @{
                DownloadUrl = 'https://github.com/Azure/bicep/releases/download/v0.48.1/bicep-win-x64.exe'
                Sha256 = '398AF294CF16AC4BECDBD008A77D148D0E8E91492309A6B60EC911B7E1CAB082'
                Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
            }
        }
        'terraform'        = @{
            Version  = '1.16.5'
            Packages = @(@{ Id = 'Hashicorp.Terraform'; Version = '1.16.5'; Source = 'winget'; MachineEvidence = @{ PackageId = 'Hashicorp.Terraform'; Kind = 'portable'; CatalogVersion = '1.16.5'; UninstallKey = 'Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe'; Publisher = 'HashiCorp'; Directory = 'WinGet/Packages/Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe'; Binary = 'terraform.exe'; SourceIdentifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; BinarySha256 = '23D7E340D2113729932C1ED9E658AF736FE9F9332B6B548508E23741B4376C58' } })
        }
        'packer'           = @{
            Version  = '1.16.1'
            Packages = @(@{ Id = 'Hashicorp.Packer'; Version = '1.16.1'; Source = 'winget'; MachineEvidence = @{ PackageId = 'Hashicorp.Packer'; Kind = 'portable'; CatalogVersion = '1.16.1'; UninstallKey = 'Hashicorp.Packer_Microsoft.Winget.Source_8wekyb3d8bbwe'; Publisher = 'HashiCorp'; Directory = 'WinGet/Packages/Hashicorp.Packer_Microsoft.Winget.Source_8wekyb3d8bbwe'; Binary = 'packer.exe'; SourceIdentifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; BinarySha256 = '391D7ADD64A6FC955CD8B167DB18BB285BD6EE5CE7EFBDEA1E5A2610CC49F2D6' } })
        }
        'ansible-wsl'      = @{
            Version            = '24.04'
            Distribution       = 'Ubuntu-24.04'
            AnsibleCoreVersion = '2.21.5'
        }
        'git'              = @{
            Version  = '2.55.0.5'
            # Bundled Git LFS runtime pin; upstream release https://github.com/git-lfs/git-lfs/releases/tag/v3.7.1
            LfsVersion = '3.7.1'
            LfsBinaryPath = 'mingw64/bin/git-lfs.exe'
            # Official v3.7.1 amd64 zip SHA256 8683CDC3D6C029B49393DCEBBAA6265BD6EFD9ABDCF837BE855B4CD42E5E80B6; exact real binary independently matches bundled Git.
            LfsBinarySha256 = '690F49B6AAA4D9DD707E08419D18F11AC2CB18051AA6779A6BADFF7D7C4EE95A'
            Packages = @(@{ Id = 'Git.Git'; Version = '2.55.0.5'; Source = 'winget'; MachineEvidence = @{ PackageId = 'Git.Git'; Kind = 'signed-inno'; CatalogVersion = '2.55.0.5'; UninstallKey = 'Git_is1'; Publisher = 'The Git Development Community'; Directory = 'Git'; Binary = 'cmd/git.exe'; Signer = 'CN=Johannes Schindelin, O=Johannes Schindelin, L=Bruehl, C=DE'; ProductVersion = '2.55.0.windows.5' } })
        }
        'windows-terminal' = @{
            Version = '1.25.2733.0'
            # Official release bundle and matching offline preinstallation kit; no Store acquisition.
            Msix = @{
                Name = 'Microsoft.WindowsTerminal'
                Version = '1.25.2733.0'
                RequireLicense = $true
                Architecture = 'x64'
                Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
                PublisherId = '8wekyb3d8bbwe'
                DownloadUrl = 'https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle'
                ArchiveSha256 = 'CCE6E9CC3C8457FA11CED1D2A7354888C7D6DB83C5ACE5D5891A52C95E3B21DA'
                ArchiveEntry = 'CascadiaPackage_1.25.2733.0_x64.msix'
                Sha256 = '6FC1DBDF7A91A2D97C94D3ADF3BEF56EEE17268B4B5C34232A7A002E34B5C188'
                License = @{
                    Name = 'Microsoft.WindowsTerminal.License'
                    DownloadUrl = 'https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle_Windows10_PreinstallKit.zip'
                    ArchiveSha256 = '151CB3EE9A93BA41AD7C412C0EFD165A1E47EDA6EF47D15A154C33AF1E1CEC9C'
                    ArchiveEntry = '3b30e8ba87e04b918b898a8ab16f4bf4_License1.xml'
                    Sha256 = '82A43837DCD6384D76D24AAF552C18579FC7B1270EC8BDAE4874D6B6DDCCAA7E'
                }
                Dependencies = @(
                    @{
                        Name = 'Microsoft.UI.Xaml.2.8'
                        Version = '8.2501.31001.0'
                        Architecture = 'x64'
                        Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
                        DownloadUrl = 'https://github.com/microsoft/terminal/releases/download/v1.25.2733.0/Microsoft.WindowsTerminal_1.25.2733.0_8wekyb3d8bbwe.msixbundle_Windows10_PreinstallKit.zip'
                        ArchiveSha256 = '151CB3EE9A93BA41AD7C412C0EFD165A1E47EDA6EF47D15A154C33AF1E1CEC9C'
                        ArchiveEntry = 'Microsoft.UI.Xaml.2.8_8.2501.31001.0_x64__8wekyb3d8bbwe.appx'
                        Sha256 = '2E7C2397D95F415FF97E26E3A63D52BE4C2E4BE3F885517E522B8E94E37B4FE2'
                    }
                )
            }
        }
        '7zip'             = @{
            Version  = '26.04'
            # Official x64 MSI ProductVersion = 26.04.00.0; its catalog/PE version is exactly 26.04.
            # Executable hash independently extracted from official MSI SHA256 0B01334A418654293513449F61D6BFC99E5196CA371E3C3DC961EDA57CD535C6.
            Packages = @(@{ Id = '7zip.7zip'; Version = '26.04'; Source = 'winget'; MachineEvidence = @{ PackageId = '7zip.7zip'; Kind = 'msi-file-hash'; CatalogVersion = '26.04.00.0'; PackageVersion = '26.04'; UninstallKey = '{23170F69-40C1-2702-2604-000001000000}'; Publisher = 'Igor Pavlov'; Directory = '7-Zip'; Binary = '7z.exe'; BinarySha256 = '95FFF19B73EFF77C87C0D7BD32822E43FB90DD2932459F962EB532D8DFB6BA53' } })
        }
        'vscode'           = @{
            Version    = '1.140.0'
            Packages   = @(@{
                    Id       = 'Microsoft.VisualStudioCode'
                    Version  = '1.140.0'
                    Source   = 'winget'
                    Override = '/VERYSILENT /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath'
                    MachineEvidence = @{ PackageId = 'Microsoft.VisualStudioCode'; Kind = 'signed-inno'; CatalogVersion = '1.140.0'; UninstallKey = '{EA457B21-F73E-494C-ACAB-524FDE069978}_is1'; Publisher = 'Microsoft Corporation'; Directory = 'Microsoft VS Code'; Binary = 'Code.exe'; Signer = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; ProductVersion = '1.140.0'; ProductJson = '07f806f999/resources/app/product.json'; Commit = '07f806f999227108933c2e30515b26eecc1fda74'; SystemAppId = '{{EA457B21-F73E-494C-ACAB-524FDE069978}' }
                })
            Extensions = @{
                'ms-vscode.PowerShell'                = '2025.4.0'
                'ms-azuretools.vscode-bicep'          = '0.48.1'
                'hashicorp.terraform'                 = '2.40.0'
                'redhat.ansible'                      = '26.8.2'
                'ms-python.python'                    = '2026.6.0'
                'hediet.vscode-drawio'                = '1.16.0'
                'eamodio.gitlens'                     = '19.3.0'
                'ms-vscode-remote.remote-wsl'         = '0.104.3'
                'msazurermtools.azurerm-vscode-tools' = '0.15.15'
            }
        }
        'office'           = @{
            # Microsoft 365 Apps, Current Channel version 2609 (16.0.<build>), pinned to a build. The Office Deployment Tool is
            # downloaded from this URL and must match the hash and carry a Microsoft signature.
            Version        = '16.0.20430.20146'
            DownloadUrl    = 'https://download.microsoft.com/download/6c1eeb25-cf8b-41d9-8d0d-cc1dbc032140/officedeploymenttool_20326-20112.exe'
            DownloadSha256 = 'FBB64358FD4168ACD52EE4EFE47FFD032B6231DFB415AE2DCE61B0E58BA67F86'
        }
        'rsat'             = @{
            Version  = 'N/A'
            Features = @(
                'RSAT-AD-Tools'
                'RSAT-AD-PowerShell'
                'RSAT-DNS-Server'
                'RSAT-DHCP'
                'GPMC'
                'RSAT-Clustering'
                'Hyper-V-Tools'
                'Hyper-V-PowerShell'
                'RSAT-File-Services'
            )
        }
        'local-identity'   = @{
            Version = '1.0.5'
            Modules = @{ 'AzureLocal.LocalIdentity.AdminSetup' = '1.0.5' }
        }
        'windows-app'      = @{
            Version = '2.0.1482.0'
            Msix = @{
                Name = 'MicrosoftCorporationII.Windows365'
                Version = '2.0.1482.0'
                Architecture = 'x64'
                Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
                PublisherId = '8wekyb3d8bbwe'
                StoreId = '9N1F85V9T8BN'
                # Mutable official link: a changed download fails the exact hash check.
                DownloadUrl = 'https://go.microsoft.com/fwlink/?linkid=2262633'
                Sha256 = '2FEF58ED626C5E611B70B1F0161F2B4F0FB877092F22B102BBDE2F15BE127AF4'
                # Direct Microsoft release/SDK archives verified 9 Oct 2026; hashes fail closed if source bytes change.
                Dependencies = @(
                    @{ Name = 'Microsoft.VCLibs.140.00'; Version = '14.0.33519.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = '9C17B521F9D690A1F504DA5108ED6EEC5669EB3A8FD1331EEF43E40D84E74283'; DownloadUrl = 'https://github.com/microsoft/winget-cli/releases/download/v1.12.350/DesktopAppInstaller_Dependencies.zip'; ArchiveSha256 = '906CAD3B2BE067D816B20EA4EB1DF541F8A23AC4A4AA9FED70CE675CD918E6A6'; ArchiveEntry = 'x64/Microsoft.VCLibs.140.00_14.0.33519.0_x64.appx' }
                    @{ Name = 'Microsoft.VCLibs.140.00.UWPDesktop'; Version = '14.0.33728.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = '077A3D1A5D0622BD3004DCA85F5E192D6E98EC79B83D4AA06766759EA6C09C3D'; DownloadUrl = 'https://github.com/microsoft/winget-cli/releases/download/v1.12.350/DesktopAppInstaller_Dependencies.zip'; ArchiveSha256 = '906CAD3B2BE067D816B20EA4EB1DF541F8A23AC4A4AA9FED70CE675CD918E6A6'; ArchiveEntry = 'x64/Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx' }
                    @{ Name = 'Microsoft.WindowsAppRuntime.2'; Version = '2.5.1.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = 'C1F5C71CF3A87CFB824C6257F4C1EE8787833B84FCC7DBD18C129786574F11B9'; DownloadUrl = 'https://aka.ms/windowsappsdk/2.5/2.5.1/Microsoft.WindowsAppRuntime.Redist.2.5.zip'; ArchiveSha256 = '3C6D3B4D80A194BB4F9A9A91E00F074B7D539929AB53FB7DDE3EF9D8A21DDBB4'; ArchiveEntry = 'MSIX/win10-x64/Microsoft.WindowsAppRuntime.2.msix' }
                )
            }
        }
        'drawio'           = @{
            Version  = '31.7.0'
            Packages = @(@{ Id = 'JGraph.Draw'; Version = '31.7.0'; Source = 'winget' })
        }
        'azcopy'           = @{
            Version  = '10.32.8'
            Packages = @(@{ Id = 'Microsoft.Azure.AZCopy.10'; Version = '10.32.8'; Source = 'winget'; MachineEvidence = @{ PackageId = 'Microsoft.Azure.AZCopy.10'; Kind = 'portable'; CatalogVersion = '10.32.8'; UninstallKey = 'Microsoft.Azure.AZCopy.10_Microsoft.Winget.Source_8wekyb3d8bbwe'; Publisher = 'Microsoft Corporation'; Directory = 'WinGet/Packages/Microsoft.Azure.AZCopy.10_Microsoft.Winget.Source_8wekyb3d8bbwe'; Binary = 'azcopy_windows_amd64_10.32.8/azcopy.exe'; SourceIdentifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; BinarySha256 = '98E2D74B4BF35268FECACD07A7580F58DDE013797BC820185815A577A6D76CFC' } })
        }
        'storage-explorer' = @{
            Version  = '1.46.0'
            Packages = @(@{ Id = 'Microsoft.Azure.StorageExplorer'; Version = '1.46.0'; Source = 'winget' })
        }
    }

    AnsibleCollections = @{
        'ansible.windows' = '3.8.0'
    }
}
