# Pinned versions for Install-JumpTools.ps1. Every version is changed only by a commit, so a rebuild reproduces the same machine.
# Resolved 6 Oct 2026 from the authoritative source of each tool (winget manifests, PowerShell Gallery, the Azure CLI extension index,
# PyPI, Ansible Galaxy, the VS Code Marketplace, Microsoft's Current Channel history). 'TODO-PIN' is refused by -Execute for the
# selected tools; 'N/A' is reserved for built-in Windows features; package versions must match exactly.
@{
    Tools              = @{
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
            Packages = @(@{ Id = 'Hashicorp.Terraform'; Version = '1.16.5'; Source = 'winget' })
        }
        'packer'           = @{
            Version  = '1.16.1'
            Packages = @(@{ Id = 'Hashicorp.Packer'; Version = '1.16.1'; Source = 'winget' })
        }
        'ansible-wsl'      = @{
            Version            = '24.04'
            Distribution       = 'Ubuntu-24.04'
            AnsibleCoreVersion = '2.21.5'
        }
        'git'              = @{
            Version  = '2.55.0.5'
            Packages = @(@{ Id = 'Git.Git'; Version = '2.55.0.5'; Source = 'winget' })
        }
        'windows-terminal' = @{
            Version  = '1.25.2733.0'
            Packages = @(@{ Id = 'Microsoft.WindowsTerminal'; Version = '1.25.2733.0'; Source = 'winget' })
        }
        '7zip'             = @{
            Version  = '26.04'
            Packages = @(@{ Id = '7zip.7zip'; Version = '26.04'; Source = 'winget' })
        }
        'vscode'           = @{
            Version    = '1.140.0'
            Packages   = @(@{
                    Id       = 'Microsoft.VisualStudioCode'
                    Version  = '1.140.0'
                    Source   = 'winget'
                    Override = '/VERYSILENT /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,addtopath'
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
                # Acquired with Microsoft's documented winget download route, inspected 8 Oct 2026.
                Dependencies = @(
                    @{ Name = 'Microsoft.VCLibs.140.00'; Version = '14.0.33519.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = '9C17B521F9D690A1F504DA5108ED6EEC5669EB3A8FD1331EEF43E40D84E74283' }
                    @{ Name = 'Microsoft.VCLibs.140.00.UWPDesktop'; Version = '14.0.33728.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = '077A3D1A5D0622BD3004DCA85F5E192D6E98EC79B83D4AA06766759EA6C09C3D' }
                    @{ Name = 'Microsoft.WindowsAppRuntime.2'; Version = '2.5.1.0'; Architecture = 'x64'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'; Sha256 = '9F3CA8FF888CFFFC872A6C8B015A38BD91051D4E97D0A92A7D4CB41CC1E6EE6C' }
                )
            }
        }
        'drawio'           = @{
            Version  = '31.7.0'
            Packages = @(@{ Id = 'JGraph.Draw'; Version = '31.7.0'; Source = 'winget' })
        }
        'azcopy'           = @{
            Version  = '10.32.8'
            Packages = @(@{ Id = 'Microsoft.Azure.AZCopy.10'; Version = '10.32.8'; Source = 'winget' })
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
