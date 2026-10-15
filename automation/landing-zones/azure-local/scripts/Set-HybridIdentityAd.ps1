#Requires -Version 7.0
<#
.SYNOPSIS
    AD side of the hybrid identities for the SOFS/FSLogix example (D-050): OU tree, delegated domain-join account, UPN
    suffix, groups and hybrid test users. Runs on the domain controller through Azure Run Command (AD objects only;
    nothing is installed on the DC). Default is a dry run; -Execute applies.
.DESCRIPTION
    Idempotent. All values come from hybrid_identity in the azure-local environment file and the shared file (G5).
    Without -Execute the script reads the configuration, reports what it would do (vault secrets, Run Command on the DC)
    and returns before any Azure or AD call (contract §7). With -Execute it performs the steps below.
      - OU=<ou_root> with Servers\<server_ous>, Users, Groups (protected from accidental deletion)
      - join account delegated on each Servers\<ou> for computer objects only (create/delete, reset password, logon and
        account-restriction properties, validated DNS host name and SPN writes); the principal is written with the
        domain's real NetBIOS name (Get-ADDomain), and every dsacls exit code and the resulting ACE count are checked
      - UPN suffix added to the forest; groups; test users with the UPN suffix, added to their groups
    Passwords: generated here when missing, stored in the ops vault, passed to the DC as one protected Run Command
    parameter, never printed. The Run Command resource is removed afterwards.
.PARAMETER Path
    Environment folder for Get-NIC26Config (default: <repo>\environment\azure-local).
.PARAMETER ResetTestUserPasswords
    Reset an existing test user to the password held in the vault (owner, 14 Oct).
.PARAMETER Execute
    Apply the changes. Without it the script only reports what it would do.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Generated passwords and the join account UPN are converted in memory only to write them to Key Vault.')]
[CmdletBinding(SupportsShouldProcess)]
param([string]$Path, [switch]$ResetTestUserPasswords, [switch]$Execute)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($Path) { $cfgArgs.Path = $Path }
$config = Get-NIC26Config @cfgArgs
$v = $config.values
$hi = $v.hybrid_identity
$tags = @{ project = (Get-NIC26NamingContext -Config $config).Project; purpose = 'hybrid-identity-sofs'; 'managed-by' = 'script' }
if (-not $Execute) {
    Write-Information "Set-HybridIdentityAd: would ensure the join/test-user secrets in $($v.kv_ops_name) and run the AD setup (OU=$($hi.ou_root), join account $($hi.join_account), $(@($hi.server_ous).Count) server OUs) on $($hi.dc_vm_name) by Run Command (what-if; pass -Execute to apply)." -InformationAction Continue
    return
}

$null = Set-AzContext -Subscription $v.subscription_id -Tenant $v.tenant_id -WarningAction SilentlyContinue -WhatIf:$false
function Get-RandomPassword { $c = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'; -join (1..24 | ForEach-Object { $c[[Security.Cryptography.RandomNumberGenerator]::GetInt32($c.Length)] }) + 'a9!Q' }
function Get-OrNewSecret([string]$Name) {
    $s = Get-AzKeyVaultSecret -VaultName $v.kv_ops_name -Name $Name -ErrorAction SilentlyContinue
    if ($s) { return ($s.SecretValue | ConvertFrom-SecureString -AsPlainText) }
    $pw = Get-RandomPassword; $null = Set-AzKeyVaultSecret -VaultName $v.kv_ops_name -Name $Name -SecretValue (ConvertTo-SecureString $pw -AsPlainText -Force) -Tag $tags; return $pw
}
$joinUpn = "$($hi.join_account)@$($v.ad_domain_fqdn)"
if (-not (Get-AzKeyVaultSecret -VaultName $v.kv_ops_name -Name $hi.join_username_secret -ErrorAction SilentlyContinue)) {
    $null = Set-AzKeyVaultSecret -VaultName $v.kv_ops_name -Name $hi.join_username_secret -SecretValue (ConvertTo-SecureString $joinUpn -AsPlainText -Force) -Tag $tags
}
$users = @()
if ($hi.Contains('test_users') -and $hi.test_users.count -gt 0) {
    foreach ($i in 1..$hi.test_users.count) {
        $users += [ordered]@{ sam = "$($hi.test_users.prefix)$i"; pw = Get-OrNewSecret ($hi.test_users.password_secret_format -f $i) }
    }
}
$payload = [ordered]@{
    ouRoot = $hi.ou_root; serverOus = @($hi.server_ous); upnSuffix = $hi.upn_suffix; joinAccount = $hi.join_account
    joinUpn = $joinUpn; joinPw = Get-OrNewSecret $hi.join_password_secret
    groups = @($hi.groups | ForEach-Object { @{ name = $_.name; description = $_.description } })
    users = $users; userGroups = @($hi.test_users.groups); resetPw = [bool]$ResetTestUserPasswords
} | ConvertTo-Json -Compress -Depth 5

$dcScript = @'
param([string]$Payload)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$p = $Payload | ConvertFrom-Json
$d = Get-ADDomain
function Set-Ou([string]$Name, [string]$Parent) { $dn = "OU=$Name,$Parent"; if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) { New-ADOrganizationalUnit -Name $Name -Path $Parent -ProtectedFromAccidentalDeletion $true }; $dn }
$root = Set-Ou $p.ouRoot $d.DistinguishedName
$servers = Set-Ou 'Servers' $root
$ouUsers = Set-Ou 'Users' $root
$ouGroups = Set-Ou 'Groups' $root
$forest = Get-ADForest
if ($p.upnSuffix -and $forest.UPNSuffixes -notcontains $p.upnSuffix) { Set-ADForest -Identity $forest -UPNSuffixes @{ Add = $p.upnSuffix } }
$jp = ConvertTo-SecureString $p.joinPw -AsPlainText -Force
if (-not (Get-ADUser -Filter "SamAccountName -eq '$($p.joinAccount)'" -ErrorAction SilentlyContinue)) {
    New-ADUser -Name $p.joinAccount -SamAccountName $p.joinAccount -UserPrincipalName $p.joinUpn -Path $ouUsers -AccountPassword $jp -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true -Description 'Domain join for the server OUs only'
} else { Set-ADAccountPassword -Identity $p.joinAccount -Reset -NewPassword $jp }
$acct = "$($d.NetBIOSName)\$($p.joinAccount)"
$sid = (Get-ADUser $p.joinAccount).SID
foreach ($name in $p.serverOus) {
    $ou = Set-Ou $name $servers
    $null = dsacls $ou /I:T /G "${acct}:CCDC;computer"; $e1 = $LASTEXITCODE
    $null = dsacls $ou /I:S /G "${acct}:CA;Reset Password;computer" "${acct}:WP;Logon Information;computer" "${acct}:WP;Account Restrictions;computer" "${acct}:WS;Validated write to DNS host name;computer" "${acct}:WS;Validated write to service principal name;computer"; $e2 = $LASTEXITCODE
    $n = @((Get-Acl "AD:$ou").Access | Where-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid } catch { $false } }).Count
    if ($e1 -ne 0 -or $e2 -ne 0 -or $n -lt 6) { throw "delegation on $ou failed (dsacls $e1/$e2, ACEs $n)" }
    "OU $name delegated to $acct ($n ACEs)"
}
foreach ($g in $p.groups) { if (-not (Get-ADGroup -Filter "Name -eq '$($g.name)'" -ErrorAction SilentlyContinue)) { New-ADGroup -Name $g.name -GroupScope Global -GroupCategory Security -Path $ouGroups -Description $g.description } }
"groups: $(($p.groups | ForEach-Object name) -join ', ')"
foreach ($u in $p.users) {
    $upn = "$($u.sam)@$($p.upnSuffix)"
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.sam)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $u.sam -DisplayName $u.sam -SamAccountName $u.sam -UserPrincipalName $upn -EmailAddress $upn -Path $ouUsers -AccountPassword (ConvertTo-SecureString $u.pw -AsPlainText -Force) -Enabled $true -PasswordNeverExpires $true
    } elseif ($p.resetPw) {
        # -ResetTestUserPasswords (owner, 14 Oct): bring an existing test user back to the password in the vault
        Set-ADAccountPassword -Identity $u.sam -Reset -NewPassword (ConvertTo-SecureString $u.pw -AsPlainText -Force)
        Unlock-ADAccount -Identity $u.sam; Enable-ADAccount -Identity $u.sam
        "reset: $($u.sam)"
    }
    foreach ($g in $p.userGroups) { Add-ADGroupMember -Identity $g -Members $u.sam }
}
"users: $(($p.users | ForEach-Object { "$($_.sam)@$($p.upnSuffix)" }) -join ', ')"
'@
$null = Set-AzContext -Subscription $v.subscriptions.identity -Tenant $v.tenant_id -WarningAction SilentlyContinue -WhatIf:$false
$dc = Get-AzVM -ResourceGroupName $hi.dc_resource_group -Name $hi.dc_vm_name
$rcName = "$($config.values.token)-hybrid-identity-ad"
try {
    $null = Set-AzVMRunCommand -ResourceGroupName $dc.ResourceGroupName -VMName $dc.Name -RunCommandName $rcName -Location $dc.Location -SourceScript $dcScript -ProtectedParameter @(@{ Name = 'Payload'; Value = $payload }) -AsyncExecution:$false -TimeoutInSecond 900
    $iv = (Get-AzVMRunCommand -ResourceGroupName $dc.ResourceGroupName -VMName $dc.Name -RunCommandName $rcName -Expand InstanceView).InstanceView
    if ($iv.Error) { throw "AD setup on $($dc.Name) failed: $($iv.Error)" }
    ($iv.Output -split "`r?`n") | Where-Object { $_ }
}
finally {
    # the protected parameter must not stay on the VM resource
    $null = Remove-AzVMRunCommand -ResourceGroupName $dc.ResourceGroupName -VMName $dc.Name -RunCommandName $rcName -ErrorAction SilentlyContinue
}
