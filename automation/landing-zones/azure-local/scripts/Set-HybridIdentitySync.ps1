#Requires -Version 7.0
<#
.SYNOPSIS
    Microsoft Entra Cloud Sync for the hybrid identities (D-050): AD (OU=<ou_root>) to Entra ID with password hash sync,
    fully scripted. Plan by default; -Execute makes the changes.
.DESCRIPTION
    Rebuilds what was run by hand on 12 Oct 2026 (owner-approved per step), in the order Microsoft Learn documents it:
      CloudAccount  cloud-only member account with the Hybrid Identity Administrator role only (Learn: the account used to
                    register the agent must not be a guest); UPN and generated password in the ops vault (never printed).
                    https://learn.microsoft.com/entra/identity/hybrid/cloud-sync/how-to-prerequisites
      AdObjects     on a domain controller through Azure Run Command (AD objects only, nothing installed on the DC): KDS
                    root key check, custom gMSA in OU=<sync_server.ou>,OU=Servers,OU=<ou_root> retrievable only by the
                    sync server, Replicating Directory Changes + Replicating Directory Changes All on the domain root
                    (password hash sync; Tier 0), and read / group full control / create-delete user scoped to
                    OU=<ou_root> (agent 1.1.2334.0 and later no longer sets these for a custom gMSA).
                    https://learn.microsoft.com/entra/identity/hybrid/cloud-sync/how-to-prerequisites#custom-gmsa-account
                    https://learn.microsoft.com/entra/identity/hybrid/cloud-sync/gmsa-cloud-sync
      Agent         provisioning agent on the sync server (Run Command): download, Authenticode check (Valid, Microsoft
                    Corporation), silent install (/quiet). Skipped when Graph already lists the agent as active.
      Register      Microsoft.CloudSync.PowerShell on the sync server (Run Command, credentials in one protected
                    parameter): Connect-AADCloudSyncAzureAD -Credential (cloud account), Add-AADCloudSyncGMSA
                    -CustomGMSAName, Add-AADCloudSyncADDomain with the delegated join account. Skipped when Graph already
                    lists the agent as active (use -ForceAgent to repeat Agent and Register).
                    https://learn.microsoft.com/entra/identity/hybrid/cloud-sync/how-to-install-pshell
      Configure     Microsoft Graph (beta, as Learn documents): AD2AAD service principal from the application template,
                    jobs AD2AADProvisioning (+ AD2AADPasswordHash), secrets Domain / AppKey / SyncNotificationSettings (full
                    set, PUT), schema containerFilter = OU=<ou_root> and CredentialData <- [PasswordHash] on users and
                    inetOrgPersons. https://learn.microsoft.com/entra/identity/hybrid/cloud-sync/how-to-inbound-synch-ms-graph
      Start         starts the AD2AADProvisioning job when it is not active.
      Verify        read-only Graph read-back: account and role, agent, job, schema, tenant sync state, the expected users
                    and groups. Returns one row per check; sets exit code 1 when a check fails.
    Every value comes from hybrid_identity (and its cloud_sync block) in environment/azure-local/environment.yml and from
    the shared environment file (G5); no environment value is written in this script. No secret is printed: passwords are read
    from Key Vault into memory, sent to the VM only as a protected Run Command parameter, and the Run Command resource is
    removed afterwards. Graph calls use the Azure CLI (az rest) signed in to the tenant in the environment file; the
    Run Command and Key Vault calls use Az PowerShell with a process-scoped context.
    Entra Connect Sync is installed on the same server but left unconfigured: its wizard must not be run against this
    tenant while Cloud Sync owns OU=<ou_root> (Learn: coexistence on one server is supported; two engines for the same
    objects are not). Run from the Windows jump server (PowerShell 7, Az, Azure CLI, powershell-yaml).
.PARAMETER Stage
    Stages to run (always in the order above). Default: all.
.PARAMETER Execute
    Make the changes. Without it the script only reads and prints what it would do (plan).
.PARAMETER AllowKdsRootKeyCreation
    Allow AdObjects to create a KDS root key when the forest has none (forest-level change: back-dated 10 h as in Learn's
    method, then repadmin /syncall). Without it a missing key stops the stage.
.PARAMETER ForceAgent
    Run Agent and Register even when Graph lists the agent as active.
.PARAMETER EnvironmentPath
    Environment folder for Get-NIC26Config (default: <repo>\environment\azure-local).
.EXAMPLE
    ./Set-HybridIdentitySync.ps1                      # plan, all stages
.EXAMPLE
    ./Set-HybridIdentitySync.ps1 -Execute             # build or repair, then verify
.EXAMPLE
    ./Set-HybridIdentitySync.ps1 -Stage Verify        # read-back only
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Only a newly generated password and the account UPN are converted, in memory, to write them to Key Vault; nothing is printed or persisted elsewhere.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Invoke-Change routes every change through the script''s own ShouldProcess (captured as $script:Cmdlet) after the -Execute gate.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('CloudAccount', 'AdObjects', 'Agent', 'Register', 'Configure', 'Start', 'Verify')]
    [string[]]$Stage = @('CloudAccount', 'AdObjects', 'Agent', 'Register', 'Configure', 'Start', 'Verify'),
    [switch]$Execute,
    [switch]$AllowKdsRootKeyCreation,
    [switch]$ForceAgent,
    [string]$EnvironmentPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Cmdlet = $PSCmdlet
$StageOrder = @('CloudAccount', 'AdObjects', 'Agent', 'Register', 'Configure', 'Start', 'Verify')

Import-Module (Join-Path $PSScriptRoot '..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$v = (Get-NIC26Config @cfgArgs).values
$hi = $v.hybrid_identity; $ss = $hi.sync_server
if (-not $hi.Contains('cloud_sync')) { throw 'hybrid_identity.cloud_sync is missing from the environment file.' }
$cs = $hi.cloud_sync
function Get-Opt($Map, [string]$Key, $Default) { if ($Map.Contains($Key) -and $null -ne $Map[$Key]) { $Map[$Key] } else { $Default } }

$Domain = $v.ad_domain_fqdn
$DomainDn = 'DC=' + ($Domain -replace '\.', ',DC=')
$ScopeOu = "OU=$($hi.ou_root),$DomainDn"
$AgentMachine = "$($ss.computer_name).$Domain"
$ConfigName = $cs.configuration_name
$Phs = [bool](Get-Opt $cs 'password_hash_sync' $true)
$Vault = $v.kv_ops_name
$Graph = 'https://graph.microsoft.com'
$Tags = @{ project = 'nic26'; environment = 'demo'; workload = 'identity'; 'managed-by' = 'script' }
$Mode = if ($Execute) { 'EXECUTE' } else { 'PLAN' }

function Say([string]$Message) { Write-Output "$(Get-Date -AsUTC -Format HH:mm:ss) $Message" }
function Invoke-Change([string]$Target, [string]$Action, [scriptblock]$Do) {
    if (-not $Execute) { Say "  PLAN   $Action ($Target)"; return }
    if ($script:Cmdlet.ShouldProcess($Target, $Action)) { Say "  CHANGE $Action ($Target)"; & $Do }
}
function Use-Subscription([string]$SubscriptionId) {
    $null = Set-AzContext -Tenant $v.tenant_id -Subscription $SubscriptionId -Scope Process -WarningAction SilentlyContinue -WhatIf:$false
}
function Protect-Text([string]$Text) { $t = ($Text -replace '\s+', ' ').Trim(); if ($t.Length -gt 400) { $t.Substring(0, 400) + '...' } else { $t } }
# az rest: the body goes through a temporary file (deleted at once) so no value appears on a command line.
function Invoke-Graph([ValidateSet('get', 'post', 'put', 'patch')][string]$Method, [string]$Url, $Body, [switch]$Sensitive, [switch]$Eventual) {
    $azArgs = @('rest', '--method', $Method, '--url', $Url, '--only-show-errors')
    if ($Eventual) { $azArgs += @('--headers', 'ConsistencyLevel=eventual') }
    $tmp = $null
    try {
        if ($null -ne $Body) {
            $tmp = New-TemporaryFile
            $Body | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM
            $azArgs += @('--body', "@$tmp", '--headers', 'Content-Type=application/json')
        }
        $out = & az @azArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Graph $($Method.ToUpper()) $Url failed: $(if ($Sensitive) { '(response withheld)' } else { Protect-Text $out })" }
    }
    finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    if ($out.Trim()) { $out | ConvertFrom-Json }
}
# existence check from the vault's secret list (metadata only; no value is read)
function Test-VaultSecret([string]$Name) { [bool](@(Get-AzKeyVaultSecret -VaultName $Vault) | Where-Object { $_.Name -eq $Name }) }
function Get-RandomPassword {
    $c = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+=?'
    (-join (1..28 | ForEach-Object { $c[[Security.Cryptography.RandomNumberGenerator]::GetInt32($c.Length)] })) + 'a9!Q'
}
# Run Command: set, read the instance view, always remove (a protected parameter must not stay on the VM resource).
function Invoke-VmScript([string]$SubscriptionId, [string]$ResourceGroup, [string]$VmName, [string]$Name, [string]$Script, [hashtable]$Parameters = @{}, [hashtable]$Protected = @{}, [int]$TimeoutSeconds = 900) {
    Use-Subscription $SubscriptionId
    $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VmName
    $rc = @{ ResourceGroupName = $vm.ResourceGroupName; VMName = $vm.Name; RunCommandName = $Name; Location = $vm.Location; SourceScript = $Script; AsyncExecution = $false; TimeoutInSecond = $TimeoutSeconds }
    if ($Parameters.Count) { $rc.Parameter = @($Parameters.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = [string]$_.Value } }) }
    if ($Protected.Count) { $rc.ProtectedParameter = @($Protected.GetEnumerator() | ForEach-Object { @{ Name = $_.Key; Value = [string]$_.Value } }) }
    try {
        $null = Set-AzVMRunCommand @rc
        $iv = (Get-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -RunCommandName $Name -Expand InstanceView).InstanceView
        ($iv.Output -split "`r?`n") | Where-Object { $_ } | ForEach-Object { Say "    $_" }
        if ($iv.Error) { throw "Run Command $Name on $($vm.Name) failed: $(Protect-Text (($iv.Error -split "`r?`n" | Select-Object -First 6) -join ' '))" }
    }
    finally { $null = Remove-AzVMRunCommand -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -RunCommandName $Name -ErrorAction SilentlyContinue }
}
function Get-Agent {
    $a = Invoke-Graph get "$Graph/beta/onPremisesPublishingProfiles/provisioning/agents?`$expand=agentGroups"
    @($a.value | Where-Object { $_.machineName -eq $AgentMachine }) | Select-Object -First 1
}
function Get-CloudUser {
    $r = Invoke-Graph get "$Graph/v1.0/users?`$filter=userPrincipalName eq '$($cs.cloud_account_upn)'&`$select=id,userPrincipalName,userType,accountEnabled,onPremisesSyncEnabled"
    @($r.value) | Select-Object -First 1
}
function Get-SyncSp {
    $r = Invoke-Graph get "$Graph/beta/servicePrincipals?`$filter=displayName eq '$ConfigName'&`$select=id,appId,displayName,applicationTemplateId"
    $sp = @($r.value) | Select-Object -First 1
    if ($sp -and $sp.applicationTemplateId -ne $cs.application_template_id) { throw "Service principal '$ConfigName' exists but was not created from the AD2AAD template; rename configuration_name or remove it." }
    $sp
}
function Get-SyncJob($Sp, [string]$TemplateId) {
    if (-not $Sp) { return $null }
    @((Invoke-Graph get "$Graph/beta/servicePrincipals/$($Sp.id)/synchronization/jobs").value | Where-Object { $_.templateId -eq $TemplateId }) | Select-Object -First 1
}
$CredentialMapping = [pscustomobject]@{
    defaultValue = $null; exportMissingReferences = $false; flowBehavior = 'FlowWhenChanged'; flowType = 'Always'; matchingPriority = 0
    targetAttributeName = 'CredentialData'; source = [pscustomobject]@{ expression = '[PasswordHash]'; name = 'PasswordHash'; type = 'Attribute'; parameters = @() }
}
$PhsObjectMappings = @('Provision Active Directory users', 'Provision Active Directory inetOrgPersons')
function Test-SchemaState($Schema) {
    $rule = $Schema.synchronizationRules[0]
    $scopeOk = ($rule.PSObject.Properties.Name -contains 'containerFilter') -and $rule.containerFilter -and (@($rule.containerFilter.includedContainers) -join ';') -eq $ScopeOu
    $missing = @($rule.objectMappings | Where-Object { $_.name -in $PhsObjectMappings -and -not ($_.attributeMappings | Where-Object targetAttributeName -EQ 'CredentialData') } | ForEach-Object name)
    [pscustomobject]@{ ScopeOk = [bool]$scopeOk; PhsMissing = $missing }
}

$acct = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $acct -or $acct.tenantId -ne $v.tenant_id) { throw 'Azure CLI is not signed in to the tenant in the environment file (az login --tenant <tenant_id>).' }
Disable-AzContextAutosave -Scope Process | Out-Null
Say "Set-HybridIdentitySync $Mode - domain $Domain, scope $ScopeOu, sync server $AgentMachine, configuration '$ConfigName', password hash sync $Phs"
$run = @($StageOrder | Where-Object { $_ -in $Stage })

# ---- CloudAccount -----------------------------------------------------------------------------------------------------
if ('CloudAccount' -in $run) {
    Say '[CloudAccount]'
    Use-Subscription $v.subscription_id
    $pwName = $cs.cloud_account_password_secret; $unName = $cs.cloud_account_username_secret
    if (Test-VaultSecret $pwName) { Say "  OK     password secret $pwName present" }
    else { Invoke-Change "$Vault/$pwName" 'generate the cloud account password (never printed)' { $pw = Get-RandomPassword; $null = Set-AzKeyVaultSecret -VaultName $Vault -Name $pwName -SecretValue (ConvertTo-SecureString $pw -AsPlainText -Force) -Tag $Tags; Remove-Variable pw } }
    if (Test-VaultSecret $unName) { Say "  OK     username secret $unName present" }
    else { Invoke-Change "$Vault/$unName" 'store the cloud account UPN' { $null = Set-AzKeyVaultSecret -VaultName $Vault -Name $unName -SecretValue (ConvertTo-SecureString $cs.cloud_account_upn -AsPlainText -Force) -Tag $Tags } }
    $user = Get-CloudUser
    if ($user) {
        if ($user.userType -ne 'Member') { throw "$($cs.cloud_account_upn) is a $($user.userType); Learn requires a non-guest account." }
        Say "  OK     $($cs.cloud_account_upn) exists (Member, enabled $($user.accountEnabled))"
    }
    else {
        Invoke-Change $cs.cloud_account_upn 'create the cloud-only account (password from the vault)' {
            $pw = Get-AzKeyVaultSecret -VaultName $Vault -Name $pwName -AsPlainText
            try {
                $body = @{ accountEnabled = $true; displayName = (Get-Opt $cs 'cloud_account_display_name' ($cs.cloud_account_upn -split '@')[0]); mailNickname = ($cs.cloud_account_upn -split '@')[0]
                    userPrincipalName = $cs.cloud_account_upn; usageLocation = (Get-Opt $cs 'cloud_account_usage_location' 'US')
                    passwordProfile = @{ forceChangePasswordNextSignIn = $false; password = $pw }; passwordPolicies = 'DisablePasswordExpiration'
                }
                $null = Invoke-Graph post "$Graph/v1.0/users" $body -Sensitive
            }
            finally { Remove-Variable pw, body -ErrorAction SilentlyContinue }
        }
        if ($Execute) { Start-Sleep -Seconds 10; $user = Get-CloudUser }
    }
    if ($user) {
        $roles = @((Invoke-Graph get "$Graph/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($user.id)'&`$expand=roleDefinition").value)
        if ($roles | Where-Object { $_.roleDefinitionId -eq $cs.hybrid_identity_admin_role_id -and $_.directoryScopeId -eq '/' }) { Say '  OK     Hybrid Identity Administrator assigned (tenant scope)' }
        else { Invoke-Change $cs.cloud_account_upn 'assign Hybrid Identity Administrator (tenant scope, direct)' { $null = Invoke-Graph post "$Graph/v1.0/roleManagement/directory/roleAssignments" @{ principalId = $user.id; roleDefinitionId = $cs.hybrid_identity_admin_role_id; directoryScopeId = '/' } } }
        $other = @($roles | Where-Object { $_.roleDefinitionId -ne $cs.hybrid_identity_admin_role_id } | ForEach-Object { $_.roleDefinition.displayName })
        if ($other) { Say "  WARN   other roles on the account (least privilege: remove): $($other -join ', ')" }
    }
    else { Say '  PLAN   assign Hybrid Identity Administrator once the account exists' }
}

# ---- AdObjects --------------------------------------------------------------------------------------------------------
$AdScript = @'
param([string]$GmsaName, [string]$RetrieverComputer, [string]$OuRoot, [string]$SyncOu, [string]$AllowKdsCreate)
$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$dom = Get-ADDomain; $root = $dom.DistinguishedName; $ou = "OU=$OuRoot,$root"; $nb = $dom.NetBIOSName
$k = Get-KdsRootKey
if (-not $k) {
    if ($AllowKdsCreate -ne 'true') { throw 'The forest has no KDS root key. Rerun with -AllowKdsRootKeyCreation (forest-level change) or create it per Learn first.' }
    # two DCs: key back-dated per Learn's method, then forced replication so both DCs have it now
    $null = Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))
    $null = repadmin /syncall /AdeP 2>&1
    'KDS root key created (back-dated) and replication forced'
} else { "KDS root key present: $(@($k).Count)" }
$sync = Get-ADComputer $RetrieverComputer
$g = Get-ADServiceAccount -Filter "Name -eq '$GmsaName'" -Properties PrincipalsAllowedToRetrieveManagedPassword
if (-not $g) {
    New-ADServiceAccount -Name $GmsaName -DNSHostName "$GmsaName.$($dom.DNSRoot)" -PrincipalsAllowedToRetrieveManagedPassword $sync -KerberosEncryptionType AES256 -Path "OU=$SyncOu,OU=Servers,$ou" -Description 'NIC26 Entra Cloud Sync agent (managed-by=script)'
    'gMSA created'
} elseif (@($g.PrincipalsAllowedToRetrieveManagedPassword) -notcontains $sync.DistinguishedName) {
    Set-ADServiceAccount $GmsaName -PrincipalsAllowedToRetrieveManagedPassword (@($g.PrincipalsAllowedToRetrieveManagedPassword) + $sync.DistinguishedName)
    'gMSA exists; sync server added to PrincipalsAllowedToRetrieveManagedPassword'
} else { 'gMSA exists' }
$sid = (Get-ADServiceAccount $GmsaName).SID
function Get-Ace([string]$Dn) { @((Get-Acl "AD:$Dn").Access | Where-Object { try { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -eq $sid } catch { $false } }) }
# password hash sync: Replicating Directory Changes + Replicating Directory Changes All on the domain root
$acl = Get-Acl "AD:$root"
$have = @(Get-Ace $root | ForEach-Object { [string]$_.ObjectType })
$add = 0
$cfgNc = (Get-ADRootDSE).configurationNamingContext
foreach ($right in 'DS-Replication-Get-Changes', 'DS-Replication-Get-Changes-All') {
    # rightsGuid of the extended right, looked up by name in the configuration partition
    $r = [string](Get-ADObject -SearchBase "CN=Extended-Rights,$cfgNc" -LDAPFilter "(&(objectClass=controlAccessRight)(name=$right))" -Properties rightsGuid).rightsGuid
    if (-not $r) { throw "extended right $right not found" }
    if ($have -notcontains $r) { $acl.AddAccessRule([System.DirectoryServices.ActiveDirectoryAccessRule]::new($sid, 'ExtendedRight', 'Allow', [guid]$r)); $add++ }
}
if ($add) { Set-Acl "AD:$root" $acl }
# custom gMSA table, scoped to OU=<ou_root>: read on the synced object classes, full control on groups, create/delete users
$a = "$nb\$GmsaName$"
$null = dsacls $ou /I:S /G "${a}:RP;;user" "${a}:RP;;group" "${a}:RP;;contact" "${a}:RP;;inetOrgPerson" "${a}:RP;;computer" "${a}:RP;;foreignSecurityPrincipal" "${a}:GA;;group"; $e1 = $LASTEXITCODE
$null = dsacls $ou /I:T /G "${a}:CCDC;user"; $e2 = $LASTEXITCODE
$rootAces = @(Get-Ace $root); $ouAces = @(Get-Ace $ou)
"replication ACEs on domain root: $($rootAces.Count) (added $add); OU ACEs: $($ouAces.Count); dsacls exit $e1/$e2"
if ($e1 -ne 0 -or $e2 -ne 0 -or $rootAces.Count -lt 2) { throw "AD rights for $a incomplete (dsacls $e1/$e2, root ACEs $($rootAces.Count))" }
"gMSA retrievable by: $((Get-ADServiceAccount $GmsaName -Properties PrincipalsAllowedToRetrieveManagedPassword).PrincipalsAllowedToRetrieveManagedPassword -join ',')"
'@
if ('AdObjects' -in $run) {
    Say "[AdObjects] on $($hi.dc_vm_name) (Run Command, AD objects only)"
    $adParams = @{ GmsaName = $cs.gmsa_name; RetrieverComputer = $ss.computer_name; OuRoot = $hi.ou_root; SyncOu = $ss.ou; AllowKdsCreate = $AllowKdsRootKeyCreation.IsPresent.ToString().ToLower() }
    Invoke-Change $hi.dc_vm_name "KDS root key check; gMSA $($cs.gmsa_name) in OU=$($ss.ou),OU=Servers,OU=$($hi.ou_root) retrievable by $($ss.computer_name)$; replication rights on $DomainDn; read/group full control/create-delete user on $ScopeOu" {
        Invoke-VmScript -SubscriptionId $v.subscriptions.identity -ResourceGroup $hi.dc_resource_group -VmName $hi.dc_vm_name -Name 'nic26-cs-gmsa' -Script $AdScript -Parameters $adParams -TimeoutSeconds 600
    }
}

# ---- Agent / Register -------------------------------------------------------------------------------------------------
$AgentScript = @'
param([string]$InstallerUrl, [string]$InstallDir)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$exe = Join-Path $InstallDir 'AADConnectProvisioningAgentSetup.exe'
if (-not (Test-Path $exe)) { Invoke-WebRequest -Uri $InstallerUrl -OutFile $exe -UseBasicParsing }
$sig = Get-AuthenticodeSignature $exe
"installer $([math]::Round((Get-Item $exe).Length/1MB,1)) MB, signature $($sig.Status), $($sig.SignerCertificate.Subject)"
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'installer signature not valid - stop' }
"version: $((Get-Item $exe).VersionInfo.ProductVersion)"
if (-not (Get-Service AADConnectProvisioningAgent -ErrorAction SilentlyContinue)) {
    $p = Start-Process $exe -ArgumentList '/quiet' -PassThru; $p.WaitForExit(); "install exit: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "agent install exit $($p.ExitCode)" }
}
Get-Service AADConnectProvisioningAgent, AADConnectAgentUpdater -ErrorAction SilentlyContinue | ForEach-Object { "service $($_.Name): $($_.Status)" }
"module: $(Test-Path 'C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\Microsoft.CloudSync.PowerShell.dll')"
'@
$RegisterScript = @'
param([string]$Payload, [string]$DomainName, [string]$GmsaName)
$ErrorActionPreference = 'Stop'
$p = $Payload | ConvertFrom-Json
Import-Module 'C:\Program Files\Microsoft Azure AD Connect Provisioning Agent\Microsoft.CloudSync.PowerShell.dll'
$hia = [pscredential]::new($p.HiaUpn, (ConvertTo-SecureString $p.HiaPw -AsPlainText -Force))
try { Connect-AADCloudSyncAzureAD -Credential $hia; 'Entra connected' } catch { "ENTRA CONNECT FAILED: $($_.Exception.Message)"; throw }
try { Add-AADCloudSyncGMSA -CustomGMSAName "$GmsaName$"; 'gMSA set' } catch { "GMSA FAILED: $($_.Exception.Message)"; throw }
$dc = [pscredential]::new($p.DomUser, (ConvertTo-SecureString $p.DomPw -AsPlainText -Force))
try { Add-AADCloudSyncADDomain -DomainName $DomainName -Credential $dc; 'domain added' } catch { "DOMAIN FAILED: $($_.Exception.Message)"; throw }
Restart-Service AADConnectProvisioningAgent
Start-Sleep 15
$start = (Get-CimInstance Win32_Service -Filter "Name='AADConnectProvisioningAgent'").StartName
"agent service account: $start state: $((Get-Service AADConnectProvisioningAgent).Status)"
if ($start -notlike "*\$GmsaName$") { throw "agent service does not run as the gMSA ($start)" }
'@
if ('Agent' -in $run -or 'Register' -in $run) {
    $agent = Get-Agent
    $registered = $agent -and $agent.status -eq 'active'
    if ($registered -and -not $ForceAgent) { Say "[Agent/Register] OK agent $AgentMachine is $($agent.status) in Entra (groups: $(@($agent.agentGroups | ForEach-Object { $_.displayName }) -join ', ')); skipped (use -ForceAgent to repeat)" }
    else {
        if ('Agent' -in $run) {
            Say "[Agent] on $($ss.vm_name) (Run Command)"
            Invoke-Change $ss.vm_name "download the provisioning agent, check the Microsoft signature, install /quiet (expected version $(Get-Opt $cs 'agent_version' 'latest'))" {
                Invoke-VmScript -SubscriptionId $v.subscription_id -ResourceGroup $ss.resource_group -VmName $ss.vm_name -Name 'nic26-cs-agent' -Script $AgentScript -Parameters @{ InstallerUrl = $cs.agent_installer_url; InstallDir = $cs.agent_install_dir } -TimeoutSeconds 1200
            }
        }
        if ('Register' -in $run) {
            Say "[Register] on $($ss.vm_name) (Run Command, one protected parameter)"
            Invoke-Change $ss.vm_name "Connect-AADCloudSyncAzureAD ($($cs.cloud_account_upn)), Add-AADCloudSyncGMSA $($cs.gmsa_name)$, Add-AADCloudSyncADDomain $Domain ($($v.ad_domain_netbios)\$($hi.join_account))" {
                Use-Subscription $v.subscription_id
                $payload = @{
                    HiaUpn = Get-AzKeyVaultSecret -VaultName $Vault -Name $cs.cloud_account_username_secret -AsPlainText
                    HiaPw = Get-AzKeyVaultSecret -VaultName $Vault -Name $cs.cloud_account_password_secret -AsPlainText
                    DomUser = "$($v.ad_domain_netbios)\$($hi.join_account)"
                    DomPw = Get-AzKeyVaultSecret -VaultName $Vault -Name $hi.join_password_secret -AsPlainText
                } | ConvertTo-Json -Compress
                try { Invoke-VmScript -SubscriptionId $v.subscription_id -ResourceGroup $ss.resource_group -VmName $ss.vm_name -Name 'nic26-cs-register' -Script $RegisterScript -Parameters @{ DomainName = $Domain; GmsaName = $cs.gmsa_name } -Protected @{ Payload = $payload } }
                finally { Remove-Variable payload -ErrorAction SilentlyContinue }
                $agent = Get-Agent
                Say "  agent in Entra: $(if ($agent) { "$($agent.machineName) $($agent.status)" } else { 'not listed yet' })"
            }
        }
    }
}

# ---- Configure --------------------------------------------------------------------------------------------------------
if ('Configure' -in $run -or 'Start' -in $run -or 'Verify' -in $run) { $sp = Get-SyncSp } else { $sp = $null }
if ('Configure' -in $run) {
    Say '[Configure] Microsoft Graph'
    if ($sp) { Say "  OK     service principal '$ConfigName' $($sp.id)" }
    else {
        Invoke-Change $ConfigName "instantiate application template $($cs.application_template_id)" {
            $script:sp = (Invoke-Graph post "$Graph/beta/applicationTemplates/$($cs.application_template_id)/instantiate" @{ displayName = $ConfigName }).servicePrincipal
            Start-Sleep -Seconds 20
        }
    }
    $templates = @('AD2AADProvisioning') + $(if ($Phs) { 'AD2AADPasswordHash' } else { @() })
    $job = $null
    foreach ($t in $templates) {
        $j = Get-SyncJob $sp $t
        if ($j) { Say "  OK     job $t $($j.id)" }
        else { Invoke-Change $ConfigName "create synchronization job $t" { $null = Invoke-Graph post "$Graph/beta/servicePrincipals/$($sp.id)/synchronization/jobs" @{ templateId = $t } } }
    }
    if ($sp) { $job = Get-SyncJob $sp 'AD2AADProvisioning' }
    # secrets: PUT replaces the whole set (Learn: no PATCH), so the full set is always sent; the values are not secret
    # but the endpoint is not read back by this script.
    $secrets = @{ value = @(
            @{ key = 'Domain'; value = (@{ domain = $Domain } | ConvertTo-Json -Compress) },
            @{ key = 'AppKey'; value = (@{ appKeyScenario = $(if ($Phs) { 'AD2AADPasswordHash' } else { 'AD2AADProvisioning' }) } | ConvertTo-Json -Compress) },
            @{ key = 'SyncNotificationSettings'; value = (@{ Enabled = [bool](Get-Opt $cs 'notification_email_enabled' $false); DeleteThresholdEnabled = $true; DeleteThresholdValue = [int](Get-Opt $cs 'delete_threshold' 50) } | ConvertTo-Json -Compress) })
    }
    Invoke-Change $ConfigName "PUT synchronization secrets, full set, always sent (Domain=$Domain, AppKey, SyncNotificationSettings delete threshold $(Get-Opt $cs 'delete_threshold' 50))" { $null = Invoke-Graph put "$Graph/beta/servicePrincipals/$($sp.id)/synchronization/secrets" $secrets }
    if ($job) {
        $schemaUrl = "$Graph/beta/servicePrincipals/$($sp.id)/synchronization/jobs/$($job.id)/schema"
        $schema = Invoke-Graph get $schemaUrl
        $state = Test-SchemaState $schema
        $needPhs = $Phs -and $state.PhsMissing.Count -gt 0
        if ($state.ScopeOk -and -not $needPhs) { Say "  OK     schema: scope $ScopeOu$(if ($Phs) { ', CredentialData on users and inetOrgPersons' })" }
        else {
            Invoke-Change $ConfigName "schema: containerFilter $ScopeOu$(if ($needPhs) { "; CredentialData <- [PasswordHash] on $($state.PhsMissing -join ', ')" })" {
                $rule = $schema.synchronizationRules[0]
                $rule | Add-Member -Force -NotePropertyName containerFilter -NotePropertyValue ([pscustomobject]@{ includedContainers = @($ScopeOu) })
                if ($Phs) {
                    foreach ($om in $rule.objectMappings | Where-Object { $_.name -in $PhsObjectMappings }) {
                        # the backend does not de-duplicate: add only where missing
                        if (-not ($om.attributeMappings | Where-Object targetAttributeName -EQ 'CredentialData')) { $om.attributeMappings = @($om.attributeMappings) + $CredentialMapping }
                    }
                }
                $null = Invoke-Graph put $schemaUrl $schema
                $rb = Test-SchemaState (Invoke-Graph get $schemaUrl)
                Say "  read-back: scope $(if ($rb.ScopeOk) { 'OK' } else { 'WRONG' }); PHS mappings missing: $(if ($rb.PhsMissing) { $rb.PhsMissing -join ', ' } else { 'none' })"
            }
        }
    }
    else { Say '  PLAN   schema: containerFilter and CredentialData once the provisioning job exists' }
}

# ---- Start ------------------------------------------------------------------------------------------------------------
if ('Start' -in $run) {
    Say '[Start]'
    $org = @((Invoke-Graph get "$Graph/beta/organization?`$select=onPremisesSyncEnabled,onPremisesSyncStatus").value)[0]
    Say "  tenant onPremisesSyncEnabled $($org.onPremisesSyncEnabled), state $((@($org.onPremisesSyncStatus | Where-Object { $_ } | ForEach-Object { $_.state })) -join ',')"
    $job = Get-SyncJob $sp 'AD2AADProvisioning'
    if ($job -and $job.status.code -eq 'Active' -and $job.schedule.state -eq 'Active') { Say "  OK     AD2AADProvisioning Active (interval $($job.schedule.interval))" }
    else { Invoke-Change $ConfigName 'start the AD2AADProvisioning job' { $j = Get-SyncJob $sp 'AD2AADProvisioning'; $null = Invoke-Graph post "$Graph/beta/servicePrincipals/$($sp.id)/synchronization/jobs/$($j.id)/start" $null } }
}

# ---- Verify (read-only) -----------------------------------------------------------------------------------------------
if ('Verify' -in $run) {
    Say '[Verify] read-only Graph read-back'
    $rows = [System.Collections.Generic.List[object]]::new()
    function Add-Row([string]$Check, [bool]$Ok, [string]$Detail, [switch]$Warn) { $rows.Add([pscustomobject]@{ Check = $Check; Status = $(if ($Ok) { 'Pass' } elseif ($Warn) { 'Warn' } else { 'Fail' }); Detail = $Detail }) }
    $user = Get-CloudUser
    if ($user) {
        $roles = @((Invoke-Graph get "$Graph/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId eq '$($user.id)'&`$expand=roleDefinition").value)
        $names = @($roles | ForEach-Object { $_.roleDefinition.displayName })
        Add-Row 'cloud account' ($user.userType -eq 'Member' -and $user.accountEnabled -and -not $user.onPremisesSyncEnabled) "$($user.userPrincipalName) $($user.userType), enabled $($user.accountEnabled)"
        Add-Row 'cloud account role' ($roles.Count -eq 1 -and $roles[0].roleDefinitionId -eq $cs.hybrid_identity_admin_role_id) "roles: $($names -join ', ')"
    }
    else { Add-Row 'cloud account' $false "$($cs.cloud_account_upn) not found" }
    $agent = Get-Agent
    Add-Row 'provisioning agent' ([bool]($agent -and $agent.status -eq 'active')) $(if ($agent) { "$($agent.machineName) $($agent.status)" } else { "$AgentMachine not registered" })
    $job = Get-SyncJob $sp 'AD2AADProvisioning'
    if ($job) {
        $last = $job.status.lastExecution
        Add-Row 'provisioning job' ($job.status.code -eq 'Active' -and -not $job.status.quarantine -and $last -and $last.state -eq 'Succeeded') "code $($job.status.code), last $(if ($last) { "$($last.state) $($last.timeEnded)" } else { 'none' }), interval $($job.schedule.interval)$(if ($job.status.quarantine) { ', QUARANTINED' })"
        $st = Test-SchemaState (Invoke-Graph get "$Graph/beta/servicePrincipals/$($sp.id)/synchronization/jobs/$($job.id)/schema")
        Add-Row 'scope' $st.ScopeOk "containerFilter $ScopeOu"
        if ($Phs) { Add-Row 'password hash mapping' ($st.PhsMissing.Count -eq 0) "CredentialData missing on: $(if ($st.PhsMissing) { $st.PhsMissing -join ', ' } else { 'none' })" }
    }
    else { Add-Row 'provisioning job' $false "no AD2AADProvisioning job on '$ConfigName'" }
    $org = @((Invoke-Graph get "$Graph/beta/organization?`$select=onPremisesSyncEnabled,onPremisesSyncStatus,onPremisesLastSyncDateTime,onPremisesLastPasswordSyncDateTime").value)[0]
    $states = @(@($org.onPremisesSyncStatus | Where-Object { $_ } | ForEach-Object { $_.state }))
    Add-Row 'tenant sync state' ([bool]$org.onPremisesSyncEnabled -and $states -contains 'enabled') "onPremisesSyncEnabled $($org.onPremisesSyncEnabled), state $($states -join ','), last sync $($org.onPremisesLastSyncDateTime)"
    if ($Phs) {
        $feat = @((Invoke-Graph get "$Graph/beta/directory/onPremisesSynchronization").value)[0]
        Add-Row 'password hash sync (tenant)' ([bool]$feat.features.passwordSyncEnabled) "passwordSyncEnabled $($feat.features.passwordSyncEnabled); last password sync $(if ($org.onPremisesLastPasswordSyncDateTime) { $org.onPremisesLastPasswordSyncDateTime } else { 'not reported - confirm with a test sign-in' })" -Warn
    }
    $synced = @((Invoke-Graph get "$Graph/v1.0/users?`$filter=onPremisesSyncEnabled eq true&`$select=userPrincipalName,onPremisesDistinguishedName&`$count=true&`$top=999" -Eventual).value)
    $expected = @()
    if ($hi.Contains('test_users') -and $hi.test_users.count -gt 0) { $expected = @(1..$hi.test_users.count | ForEach-Object { "$($hi.test_users.prefix)$_@$($hi.upn_suffix)" }) }
    $syncedUpns = @($synced | ForEach-Object { $_.userPrincipalName })
    $missingUsers = @($expected | Where-Object { $_ -notin $syncedUpns })
    Add-Row 'hybrid users' ($missingUsers.Count -eq 0) "expected $($expected.Count), missing: $(if ($missingUsers) { $missingUsers -join ', ' } else { 'none' })"
    $outside = @($synced | Where-Object { $_.onPremisesDistinguishedName -notlike "*,$ScopeOu" })
    Add-Row 'scope respected' ($outside.Count -eq 0) "synced users outside $ScopeOu`: $($outside.Count)"
    $extra = @($syncedUpns | Where-Object { $_ -notin $expected })
    if ($extra) { Add-Row 'other synced users' $false "also in scope (they live under OU=$($hi.ou_root)): $($extra -join ', ')" -Warn }
    $groups = @((Invoke-Graph get "$Graph/v1.0/groups?`$filter=onPremisesSyncEnabled eq true&`$select=displayName&`$count=true&`$top=999" -Eventual).value)
    $groupNames = @($groups | ForEach-Object { $_.displayName })
    $missingGroups = @($hi.groups | ForEach-Object { $_.name } | Where-Object { $_ -notin $groupNames })
    Add-Row 'hybrid groups' ($missingGroups.Count -eq 0) "expected $(@($hi.groups).Count), missing: $(if ($missingGroups) { $missingGroups -join ', ' } else { 'none' })"
    $rows
    if (@($rows | Where-Object Status -EQ 'Fail').Count) { Say 'Verify: FAIL'; $global:LASTEXITCODE = 1 } else { Say 'Verify: PASS'; $global:LASTEXITCODE = 0 }
}
