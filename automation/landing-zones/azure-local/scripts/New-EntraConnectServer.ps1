<#
.SYNOPSIS
    Builds the Microsoft Entra Connect Sync server for the hybrid identities (D-050): an Azure VM in the nic26 management
    subnet, AD-joined, with Entra Connect installed. Never on a domain controller (owner, 12 Oct 2026; Learn: member server,
    Tier 0 asset).
.DESCRIPTION
    Steps (each idempotent):
      1. Local admin secret in the ops vault (generated, never printed).
      2. NSG rules: identity NSG allows the AD ports Entra Connect needs from this VM only (Learn: Entra Connect ports);
         mgmt NSG allows HTTP 80 out from this VM (certificate revocation lists).
      3. AD: OU=Sync under OU=Servers,OU=NIC26; the join account is delegated on it (same rights as Servers/SOFS, AVD).
      4. VM: Windows Server 2025 Datacenter Azure Edition, Standard_D2s_v6 (NVMe), Trusted Launch, static IP, no public IP.
      5. Domain join (JsonADDomainExtension) into OU=Sync.
      6. Entra Connect: TLS 1.2 for .NET, MSI from the Microsoft Download Center (signature checked), silent install.
    The configuration wizard (Hybrid Identity Administrator + Enterprise Admin sign-in, OU filter OU=NIC26, password hash
    sync) is the owner's interactive step on the VM; nothing is synchronized by this script.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a newly generated password and the operator-supplied admin name are converted, in memory, to write them to Key Vault; nothing is printed or persisted elsewhere.')]
[CmdletBinding()]
param(
    # Local administrator name for the sync server, needed only on the first run (when the vault has no username secret yet).
    [string]$AdminUserName,
    # Environment folder for Get-NIC26Config (default: <repo>\environment\azure-local). All lab values come from
    # hybrid_identity in that file and from the shared file (G5): no lab value is written in this script.
    [string]$EnvironmentPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$v = (Get-NIC26Config @cfgArgs).values
$hi = $v.hybrid_identity; $ss = $hi.sync_server
$TenantId = $v.tenant_id; $SubscriptionId = $v.subscription_id; $identitySubId = $v.subscriptions.identity
$Location = $v.location; $DomainName = $v.ad_domain_fqdn; $OpsVault = $v.kv_ops_name
$ResourceGroupName = $ss.resource_group; $VmName = $ss.vm_name; $ComputerName = $ss.computer_name; $VmSize = $ss.vm_size
$PrivateIp = $ss.private_ip; $VnetResourceGroup = $ss.vnet_resource_group; $VnetName = $ss.vnet_name; $SubnetName = $ss.subnet_name
$MgmtNsgName = $ss.mgmt_nsg_name; $IdentityNsgResourceGroup = $hi.dc_resource_group; $IdentityNsgName = $hi.identity_nsg_name
$dcIp = @($v.identity_dc_ips)[0]
$tags = @{ project = 'nic26'; environment = 'demo'; workload = 'identity'; role = 'entra-connect-sync'; 'managed-by' = 'script' }
function Step($m) { "$(Get-Date -Format HH:mm:ss) $m" }

# 1. local admin secret ----------------------------------------------------------------------------------------------
$null = Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -WarningAction SilentlyContinue -WhatIf:$false
$kvTags = @{ project = 'nic26'; purpose = 'entra-connect-sync'; 'managed-by' = 'script' }
$userSecret = $ss.admin_username_secret; $pwSecret = $ss.admin_password_secret
if (-not (Get-AzKeyVaultSecret -VaultName $OpsVault -Name $userSecret -ErrorAction SilentlyContinue)) {
    $null = Set-AzKeyVaultSecret -VaultName $OpsVault -Name $userSecret -SecretValue (ConvertTo-SecureString $(if ($AdminUserName) { $AdminUserName } else { throw 'First run: pass -AdminUserName (the vault has no admin username secret yet).' }) -AsPlainText -Force) -Tag $kvTags
}
if (-not (Get-AzKeyVaultSecret -VaultName $OpsVault -Name $pwSecret -ErrorAction SilentlyContinue)) {
    $c = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'
    $pw = -join (1..24 | ForEach-Object { $c[[Security.Cryptography.RandomNumberGenerator]::GetInt32($c.Length)] }) + 'a9!Q'
    $null = Set-AzKeyVaultSecret -VaultName $OpsVault -Name $pwSecret -SecretValue (ConvertTo-SecureString $pw -AsPlainText -Force) -Tag $kvTags
    Remove-Variable pw
}
$adminCred = [pscredential]::new((Get-AzKeyVaultSecret -VaultName $OpsVault -Name $userSecret -AsPlainText), (Get-AzKeyVaultSecret -VaultName $OpsVault -Name $pwSecret).SecretValue)
$joinUser = Get-AzKeyVaultSecret -VaultName $OpsVault -Name $hi.join_username_secret -AsPlainText
$joinPw = (Get-AzKeyVaultSecret -VaultName $OpsVault -Name $hi.join_password_secret).SecretValue
Step 'secrets ready (ops vault)'

# 2. NSG rules -------------------------------------------------------------------------------------------------------
$mgmtNsg = Get-AzNetworkSecurityGroup -Name $MgmtNsgName -ResourceGroupName $VnetResourceGroup
if (-not ($mgmtNsg.SecurityRules | Where-Object Name -eq 'AllowSyncCrlHttpOutbound')) {
    $null = $mgmtNsg | Add-AzNetworkSecurityRuleConfig -Name 'AllowSyncCrlHttpOutbound' -Description 'Entra Connect: certificate revocation lists (HTTP 80)' -Direction Outbound -Priority 125 -Access Allow -Protocol Tcp -SourceAddressPrefix "$PrivateIp/32" -SourcePortRange '*' -DestinationAddressPrefix Internet -DestinationPortRange 80
    $null = $mgmtNsg | Set-AzNetworkSecurityGroup
}
Step "mgmt NSG: AllowSyncCrlHttpOutbound (125, TCP 80 from $PrivateIp)"
$null = Set-AzContext -Subscription $identitySubId -Tenant $TenantId -WarningAction SilentlyContinue -WhatIf:$false
$idNsg = Get-AzNetworkSecurityGroup -Name $IdentityNsgName -ResourceGroupName $IdentityNsgResourceGroup
$changed = $false
if (-not ($idNsg.SecurityRules | Where-Object Name -eq 'Allow-AD-TCP-From-Nic26Sync')) {
    $null = $idNsg | Add-AzNetworkSecurityRuleConfig -Name 'Allow-AD-TCP-From-Nic26Sync' -Description "Entra Connect server ${ComputerName}: AD ports (Learn: Entra Connect ports)" -Direction Inbound -Priority 141 -Access Allow -Protocol Tcp -SourceAddressPrefix "$PrivateIp/32" -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '53', '88', '135', '389', '445', '464', '636', '3268', '3269', '9389', '49152-65535'
    $changed = $true
}
if (-not ($idNsg.SecurityRules | Where-Object Name -eq 'Allow-AD-UDP-From-Nic26Sync')) {
    $null = $idNsg | Add-AzNetworkSecurityRuleConfig -Name 'Allow-AD-UDP-From-Nic26Sync' -Description "Entra Connect server ${ComputerName}: AD ports (Learn: Entra Connect ports)" -Direction Inbound -Priority 142 -Access Allow -Protocol Udp -SourceAddressPrefix "$PrivateIp/32" -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange '53', '88', '123', '389', '464'
    $changed = $true
}
if ($changed) { $null = $idNsg | Set-AzNetworkSecurityGroup }
Step "identity NSG: Allow-AD-TCP/UDP-From-Nic26Sync (141/142, source $PrivateIp only)"

# 3. AD: OU tree and join-account delegation (Set-HybridIdentityAd.ps1 - Run Command on the DC, AD objects only) ---------
$adArgs = @{}; if ($EnvironmentPath) { $adArgs.Path = $EnvironmentPath }
& (Join-Path $PSScriptRoot 'Set-HybridIdentityAd.ps1') @adArgs | ForEach-Object { Step "AD: $_" }
$ouPath = "OU=$($ss.ou),OU=Servers,OU=$($hi.ou_root),DC=" + ($DomainName -replace '\.', ',DC=')

# 4. VM ----------------------------------------------------------------------------------------------------------------
$null = Set-AzContext -Subscription $SubscriptionId -Tenant $TenantId -WarningAction SilentlyContinue -WhatIf:$false
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) {
    $subnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup | Get-AzVirtualNetworkSubnetConfig -Name $SubnetName
    $nicName = "nic-$VmName-01"
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if (-not $nic) {
        $ipc = New-AzNetworkInterfaceIpConfig -Name ipconfig1 -SubnetId $subnet.Id -PrivateIpAddress $PrivateIp -Primary
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location -IpConfiguration $ipc -Tag $tags
    }
    $cfg = New-AzVMConfig -VMName $VmName -VMSize $VmSize -SecurityType TrustedLaunch -DiskControllerType NVMe -Tags $tags |
        Set-AzVMOperatingSystem -Windows -ComputerName $ComputerName -Credential $adminCred -ProvisionVMAgent -EnableAutoUpdate -PatchMode AutomaticByPlatform |
        Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus $ss.image_sku -Version latest |
        Set-AzVMOSDisk -Name "osdisk-$VmName" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB $ss.os_disk_gb |
        Add-AzVMNetworkInterface -Id $nic.Id -Primary |
        Set-AzVMBootDiagnostic -Enable -ResourceGroupName $ResourceGroupName |
        Set-AzVMUefi -EnableVtpm $true -EnableSecureBoot $true
    $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $cfg -Tag $tags
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName
}
Step "VM: $($vm.Name) $($vm.HardwareProfile.VmSize) state=$($vm.ProvisioningState)"

# 5. domain join -------------------------------------------------------------------------------------------------------
$ext = Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Name 'JoinDomain' -ErrorAction SilentlyContinue
if (-not $ext -or $ext.ProvisioningState -ne 'Succeeded') {
    # plain [string] values: a PSObject-wrapped string sends the extension's JSON serializer into a stack overflow
    $settings = @{ Name = [string]$DomainName; OUPath = [string]$ouPath; User = [string]$joinUser; Restart = 'true'; Options = '3' }
    $protected = @{ Password = [string]($joinPw | ConvertFrom-SecureString -AsPlainText) }
    $null = Set-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Location $Location -Name 'JoinDomain' -Publisher Microsoft.Compute -ExtensionType JsonADDomainExtension -TypeHandlerVersion 1.3 -Settings $settings -ProtectedSettings $protected
    Remove-Variable protected
}
Step "domain join: $((Get-AzVMExtension -ResourceGroupName $ResourceGroupName -VMName $VmName -Name 'JoinDomain').ProvisioningState) ($ouPath)"

# 6. Entra Connect install ------------------------------------------------------------------------------------------
$install = @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
"domain: $((Get-CimInstance Win32_ComputerSystem).Domain)  OS: $((Get-CimInstance Win32_OperatingSystem).Caption)"
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319') {
    New-ItemProperty $k -Name SchUseStrongCrypto -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty $k -Name SystemDefaultTlsVersions -Value 1 -PropertyType DWord -Force | Out-Null
}
# Run Command sets a process-scope policy, so this reports an override; the LocalMachine value is still written
try { Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force } catch { if ($_.FullyQualifiedErrorId -notmatch 'ExecutionPolicyOverride') { throw } }
"execution policy LocalMachine: $(Get-ExecutionPolicy -Scope LocalMachine)"
$dir = 'C:\Install\EntraConnect'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
$msi = Join-Path $dir 'AzureADConnect.msi'
if (-not (Test-Path $msi)) { Invoke-WebRequest -Uri '__MSI_URL__' -OutFile $msi -UseBasicParsing }
$sig = Get-AuthenticodeSignature $msi
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "MSI signature not valid: $($sig.Status) $($sig.SignerCertificate.Subject)" }
"MSI $([math]::Round((Get-Item $msi).Length/1MB,1)) MB, signature $($sig.Status), $($sig.SignerCertificate.Subject)"
$p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$dir\install.log`"" -Wait -PassThru
"msiexec exit: $($p.ExitCode)"
$wiz = 'C:\Program Files\Microsoft Azure Active Directory Connect\AzureADConnect.exe'
"wizard present: $(Test-Path $wiz)  version: $((Get-Item $wiz -ErrorAction SilentlyContinue).VersionInfo.ProductVersion)"
'DC reachability: ' + ((Test-NetConnection -ComputerName '__DC_IP__' -Port 389 -WarningAction SilentlyContinue).TcpTestSucceeded)
'Entra reachability: ' + ((Test-NetConnection -ComputerName login.microsoftonline.com -Port 443 -WarningAction SilentlyContinue).TcpTestSucceeded)
'@
$install = $install.Replace('__MSI_URL__', $ss.entra_connect_msi_url).Replace('__DC_IP__', $dcIp)
$null = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName -RunCommandName 'nic26-entra-connect-install' -Location $Location -SourceScript $install -AsyncExecution:$false -TimeoutInSecond 1800
$iv = (Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName -RunCommandName 'nic26-entra-connect-install' -Expand InstanceView).InstanceView
Step "Entra Connect install: $($iv.ExecutionState) exit $($iv.ExitCode)"; $iv.Output; if ($iv.Error) { 'ERRORS:'; $iv.Error }
$null = Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName -RunCommandName 'nic26-entra-connect-install'
