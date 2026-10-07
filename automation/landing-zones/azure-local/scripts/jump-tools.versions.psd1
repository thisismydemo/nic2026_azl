# Pinned versions for Install-JumpTools.ps1. Every version is changed only by a commit, so a rebuild reproduces the same machine.
# Resolved 6 Oct 2026 from the authoritative source of each tool (winget manifests, PowerShell Gallery, the Azure CLI extension index,
# PyPI, Ansible Galaxy, the VS Code Marketplace, Microsoft's Current Channel history). 'TODO-PIN' is refused by -Execute for the
# selected tools; 'N/A' marks a component that is not version-pinned (a Microsoft Store package: presence is checked).
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
            Packages = @(@{ Id = 'Microsoft.Bicep'; Version = '0.48.1'; Source = 'winget' })
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
            Version  = '1.2.7391.0'
            Packages = @(
                @{ Id = '9N1F85V9T8BN'; Version = 'N/A'; Source = 'msstore' }
                @{ Id = 'Microsoft.RemoteDesktopClient'; Version = '1.2.7391.0'; Source = 'winget' }
            )
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
