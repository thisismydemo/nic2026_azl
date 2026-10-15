#Requires -Version 7.0
<#
.SYNOPSIS
    Recovers Azure-side Azure Local VM management after a node reboot made the VM-management agent (vmoService)
    regenerate its PKI: brings both nodes back onto the shared PKI set on the cluster volume, then re-feeds the Arc
    Resource Bridge azlocal-overlay extension with the matching root CA and overlay token.
    Incident record: planning/incidents/20261012-arb-vmo-trust-after-sbe.md (option E + A). Internal.
.DESCRIPTION
    Stages (run in this order; -Stage All runs them all and stops at the first failed stop condition):
      PreCheck    read only: nodes Up, CSVs Online, shared PKI hashes, root thumbprint, pool kid, overlay.jwt kid/verify
      Evidence    copy the shared pki folder to C:\ProgramData\nic26-incident\<date>\pki-csv on the first node (admins-only ACL)
      StopAgents  Stop-Service vmoService on the second node, then the first; hashes must be unchanged
      StartFirst  Start-Service vmoService on the first node; no "cluster PKI regenerated"; hashes unchanged;
                  overlay.jwt reaches the expected kid and verifies against the shared pool key
      StartSecond same on the second node, then a stable watch (overlay.jwt stays on the expected kid, node TLS
                  certificates on :50052 chain to the expected root)
      ReFeed      PATCH all four protected settings of the bridge extension (root CA + token, base64, no newline);
                  guards: kid, signature, token validity > 30 days, root matches the node certificates
      Reload      check the bridge pods restarted; otherwise one graceful restart of the bridge VM (Learn: troubleshoot
                  Arc resource bridge; same method as 11 Oct)
      Verify      bridge logs free of x509 / invalid token; dispatcher nodes online
    Nothing changes without -Execute. Secrets (cluster admin, token, keys) stay in memory; only metadata is printed.
    Lab values come from environment/azure-local (Get-NIC26Config); the expected root thumbprint and signing kid are
    parameters (read them from the PreCheck output / the incident record).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Private helpers inside a script that is gated as a whole (-Execute); they never run on their own.')]
[CmdletBinding()]
param(
    [ValidateSet('PreCheck', 'Evidence', 'StopAgents', 'StartFirst', 'StartSecond', 'ReFeed', 'Reload', 'Verify', 'All')]
    [string]$Stage = 'PreCheck',
    [Parameter(Mandatory)][string]$ExpectedRootThumbprint,
    [Parameter(Mandatory)][string]$ExpectedKid,
    [string]$KubectlPath,
    [string]$KubeconfigPath,
    [int]$TokenWaitMinutes = 20,
    [int]$StableWatchMinutes = 20,
    [string]$EnvironmentPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\..\..\shared\powershell\NIC26.Automation') -Force
$cfgArgs = @{ Scope = 'azure-local' }; if ($EnvironmentPath) { $cfgArgs.Path = $EnvironmentPath }
$v = (Get-NIC26Config @cfgArgs).values
Disable-AzContextAutosave -Scope Process | Out-Null
$null = Set-AzContext -Tenant $v.tenant_id -Subscription $v.subscription_id -Scope Process -WarningAction SilentlyContinue -WhatIf:$false
$first = @($v.nodes)[0]; $second = @($v.nodes)[1]
# Cluster admin from the identity block's keyvault:// references (G5: no secret names in code)
function Split-KvRef([string]$Ref) { if ($Ref -notmatch '^keyvault://([^/]+)/(.+)$') { throw "Not a keyvault:// reference: $Ref" }; @{ Vault = $Matches[1]; Name = $Matches[2] } }
$ur = Split-KvRef $v.identity.local_admin_username_secret; $pr = Split-KvRef $v.identity.local_admin_password_secret
$u = Get-AzKeyVaultSecret -VaultName $ur.Vault -Name $ur.Name -AsPlainText
$cred = [pscredential]::new($u, (Get-AzKeyVaultSecret -VaultName $pr.Vault -Name $pr.Name).SecretValue)
$ext = "/subscriptions/$($v.subscription_id)/resourceGroups/$($v.vm_management.resource_group)/providers/Microsoft.ResourceConnector/appliances/$($v.cluster_name)-arcbridge/providers/Microsoft.KubernetesConfiguration/extensions/azlocal-overlay"
$pkiDir = 'C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\vmo\pki'
$ExpectedRootThumbprint = $ExpectedRootThumbprint.ToUpperInvariant()
function Step($m) { "$(Get-Date -AsUTC -Format 'HH:mm:ss')Z $m" }
function Stop-Run($m) { throw "STOP CONDITION: $m - nothing further is changed; see the incident record (fallback D)." }
function B64U([string]$s) { $s = $s.Replace('-', '+').Replace('_', '/'); while ($s.Length % 4) { $s += '=' }; [Convert]::FromBase64String($s) }

function Get-PkiState {
    # Pulls the shared PKI into memory on this machine (public material + token); returns metadata only.
    $r = Invoke-Command -ComputerName $first.management_ip -Credential $cred -ArgumentList $pkiDir -ScriptBlock {
        param($d)
        $h = @{}; foreach ($f in 'ca-pool.json', 'rootca.pem', 'jwt-signing-pool.json') { $h[$f] = (Get-FileHash "$d\$f" -Algorithm SHA256).Hash }
        $pool = Get-Content -Raw "$d\jwt-signing-pool.json" | ConvertFrom-Json
        [pscustomobject]@{ Hashes = $h; PubKeys = @($pool.payload.keys); Kids = @($pool.payload.key_metas.kid); Jwt = (Get-Content -Raw "$d\overlay.jwt").Trim()
            CaPem = (Get-Content -Raw "$d\rootca.pem").TrimEnd("`r", "`n"); CaPool = (Get-Content -Raw "$d\ca-pool.json" | ConvertFrom-Json)
        }
    }
    $parts = $r.Jwt.Split('.')
    $hdr = [Text.Encoding]::UTF8.GetString((B64U $parts[0])) | ConvertFrom-Json
    $clm = [Text.Encoding]::UTF8.GetString((B64U $parts[1])) | ConvertFrom-Json
    $verifies = $false
    foreach ($pem in $r.PubKeys) {
        $ec = [Security.Cryptography.ECDsa]::Create(); $ec.ImportFromPem($pem)
        if ($ec.VerifyData([Text.Encoding]::ASCII.GetBytes("$($parts[0]).$($parts[1])"), (B64U $parts[2]), [Security.Cryptography.HashAlgorithmName]::SHA256)) { $verifies = $true }
    }
    $ca = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($r.CaPem)
    [pscustomobject]@{
        Hashes = $r.Hashes; RootThumbprint = $ca.Thumbprint; PoolKids = $r.Kids; JwtKid = [string]$hdr.kid; JwtVerifies = $verifies
        JwtExp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$clm.exp).UtcDateTime; CaPem = $r.CaPem; Jwt = $r.Jwt; CaCert = $ca
    }
}
function Show-Pki($s) {
    Step "root $($s.RootThumbprint); pool kids $($s.PoolKids -join ','); overlay.jwt kid $($s.JwtKid) verifies=$($s.JwtVerifies) exp $($s.JwtExp.ToString('u'))"
    Step ("hashes: " + (($s.Hashes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value.Substring(0,12))" }) -join ' '))
}
function Assert-HashesUnchanged($base) {
    $now = Get-PkiState
    foreach ($f in 'ca-pool.json', 'rootca.pem', 'jwt-signing-pool.json') { if ($now.Hashes[$f] -ne $base.Hashes[$f]) { Stop-Run "$f changed" } }
    if ($now.RootThumbprint -ne $ExpectedRootThumbprint) { Stop-Run "root is now $($now.RootThumbprint)" }
    $now
}
function Get-AgentLog($node, [datetime]$since) {
    Invoke-Command -ComputerName $node.management_ip -Credential $cred -ArgumentList $since -ScriptBlock {
        param($since)
        $f = Get-ChildItem 'C:\ProgramData\vmo\logs' -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        # only lines newer than $since (JSON lines carry 'timestamp'); vmoService also restarts itself after a stop
        # (failure action RESTART after 10 s), so old lines must never count as new events
        $f | ForEach-Object { Get-Content $_.FullName -Tail 4000 } | Select-String -Pattern 'cluster storage base resolved|PKI initialized|PKI regenerated|JWT authentication failed|republished CA pool' |
            Where-Object { try { ([datetimeoffset]::Parse(($_.Line | ConvertFrom-Json).timestamp)).UtcDateTime -ge $since } catch { $false } } |
            ForEach-Object { $_.Line } | Select-Object -Last 40
    }
}
function Get-NodeLeafOk($node, $caCert) {
    try {
        $tcp = [Net.Sockets.TcpClient]::new($node.management_ip, 50052)
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
        $ssl.AuthenticateAsClient($node.name)
        $leaf = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
        $ssl.Dispose(); $tcp.Dispose()
        $ch = [Security.Cryptography.X509Certificates.X509Chain]::new(); $ch.ChainPolicy.TrustMode = 'CustomRootTrust'
        $null = $ch.ChainPolicy.CustomTrustStore.Add($caCert); $ch.ChainPolicy.RevocationMode = 'NoCheck'
        $ch.Build($leaf)
    }
    catch { $false }
}
function Invoke-Node($node, [scriptblock]$sb) { Invoke-Command -ComputerName $node.management_ip -Credential $cred -ScriptBlock $sb }
function Start-Agent($node, $base) {
    $t0 = (Get-Date).ToUniversalTime()
    if ($Execute) { Invoke-Node $node { Start-Service vmoService; (Get-Service vmoService).Status } | ForEach-Object { Step "$($node.name) vmoService $_" } } else { Step "PLAN: Start-Service vmoService on $($node.name)"; return $base }
    $deadline = (Get-Date).AddMinutes($TokenWaitMinutes)
    do {
        Start-Sleep 60
        $log = Get-AgentLog $node $t0
        if ($log -match 'PKI regenerated') { Stop-Run "$($node.name) logged 'cluster PKI regenerated'" }
        $s = Assert-HashesUnchanged $base
        Step "$($node.name): overlay.jwt kid $($s.JwtKid) verifies=$($s.JwtVerifies); log: $((@($log) | Select-Object -Last 2) -join ' | ')"
        if ($s.JwtKid -eq $ExpectedKid -and $s.JwtVerifies) { return $s }
    } while ((Get-Date) -lt $deadline)
    Stop-Run "overlay.jwt not on kid $ExpectedKid within $TokenWaitMinutes min after starting $($node.name)"
}
$order = 'PreCheck', 'Evidence', 'StopAgents', 'StartFirst', 'StartSecond', 'ReFeed', 'Reload', 'Verify'
$run = if ($Stage -eq 'All') { $order } else { @($Stage) }
Step "Repair-VmoTrust stages: $($run -join ', ') (execute=$([bool]$Execute))"
$base = Get-PkiState; Show-Pki $base
if ($base.RootThumbprint -ne $ExpectedRootThumbprint) { Stop-Run "shared root is $($base.RootThumbprint), expected $ExpectedRootThumbprint" }
if ($base.PoolKids -notcontains $ExpectedKid) { Stop-Run "shared signing pool has no kid $ExpectedKid" }

foreach ($st in $run) {
    switch ($st) {
        'PreCheck' {
            Invoke-Node $first { Get-ClusterNode | ForEach-Object { "node $($_.Name) $($_.State)" }; Get-ClusterSharedVolume | ForEach-Object { "csv $($_.Name) $($_.State)" }; Get-Service vmoService | ForEach-Object { "vmoService $($_.Status)" } } | ForEach-Object { Step $_ }
            foreach ($n in $first, $second) { Step "$($n.name) TLS :50052 chains to shared root: $(Get-NodeLeafOk $n $base.CaCert)" }
        }
        'Evidence' {
            if (-not $Execute) { Step "PLAN: copy $pkiDir to C:\ProgramData\nic26-incident\<date>\pki-csv on $($first.name)"; break }
            Invoke-Command -ComputerName $first.management_ip -Credential $cred -ArgumentList $pkiDir -ScriptBlock {
                param($d) $t = "C:\ProgramData\nic26-incident\$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmm'))\pki-csv"
                New-Item -ItemType Directory -Force -Path $t | Out-Null; Copy-Item "$d\*" $t -Recurse -Force
                $acl = New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true, $false)
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                Set-Acl -Path (Split-Path $t) -AclObject $acl; "evidence copied to $t ($((Get-ChildItem $t -Recurse -File).Count) files)" } | ForEach-Object { Step $_ }
        }
        'StopAgents' {
            foreach ($n in $second, $first) {
                if ($Execute) { Invoke-Node $n { Stop-Service vmoService -Force; (Get-Service vmoService).Status } | ForEach-Object { Step "$($n.name) vmoService $_" } } else { Step "PLAN: Stop-Service vmoService on $($n.name)" }
            }
            if ($Execute) { $null = Assert-HashesUnchanged $base; Step 'hashes unchanged after stop' }
        }
        'StartFirst' { $null = Start-Agent $first $base }
        'StartSecond' {
            $s = Start-Agent $second $base
            if ($Execute) {
                $end = (Get-Date).AddMinutes($StableWatchMinutes)
                while ((Get-Date) -lt $end) {
                    Start-Sleep 120
                    $s = Assert-HashesUnchanged $base
                    if ($s.JwtKid -ne $ExpectedKid -or -not $s.JwtVerifies) { Stop-Run "overlay.jwt flipped to kid $($s.JwtKid) during the watch" }
                    foreach ($n in $first, $second) { if (-not (Get-NodeLeafOk $n $base.CaCert)) { Stop-Run "$($n.name) TLS certificate no longer chains to the shared root" } }
                    foreach ($n in $first, $second) { if (Get-AgentLog $n (Get-Date).AddMinutes(-3) | Select-String 'PKI regenerated') { Stop-Run "$($n.name) regenerated PKI" } }
                    Step "stable: kid $($s.JwtKid), both nodes chain to the shared root"
                }
            }
        }
        'ReFeed' {
            $s = Get-PkiState
            if ($s.JwtKid -ne $ExpectedKid -or -not $s.JwtVerifies) { Stop-Run "token kid $($s.JwtKid) verifies=$($s.JwtVerifies)" }
            if ($s.JwtExp -lt (Get-Date).ToUniversalTime().AddDays(30)) { Stop-Run "token expires $($s.JwtExp.ToString('u'))" }
            foreach ($n in $first, $second) { if (-not (Get-NodeLeafOk $n $s.CaCert)) { Stop-Run "$($n.name) certificate does not chain to the root being fed" } }
            if (-not $Execute) { Step 'PLAN: PATCH azlocal-overlay protected settings (4 keys) with the shared root + token'; break }
            $ca64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s.CaPem)); $jwt64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s.Jwt))
            $body = @{ properties = @{ configurationProtectedSettings = @{ 'global.vmoBootstrap.vmoRootCA' = $ca64; 'global.vmoBootstrap.overlayJWT' = $jwt64; 'vmoRootCA' = $ca64; 'overlayJWT' = $jwt64 } } } | ConvertTo-Json -Depth 5
            foreach ($try in 1, 2) {
                $r = Invoke-AzRestMethod -Method PATCH -Path "$ext`?api-version=2023-05-01" -Payload $body
                Step "PATCH try $try status $($r.StatusCode)"
                $e = $null
                for ($i = 0; $i -lt 40; $i++) { Start-Sleep 30; $e = (Invoke-AzRestMethod -Method GET -Path "$ext`?api-version=2023-05-01").Content | ConvertFrom-Json; if ($e.properties.provisioningState -notin 'Updating', 'Creating', 'Accepted') { break } }
                Step "extension $($e.properties.provisioningState) $($e.properties.currentVersion)"
                if ($e.properties.provisioningState -eq 'Succeeded') { break }
                if ($try -eq 2) { Remove-Variable ca64, jwt64, body; Stop-Run 'extension update failed twice' }
            }
            Remove-Variable ca64, jwt64, body
        }
        'Reload' {
            $pods = { if ($KubectlPath -and $KubeconfigPath) { & $KubectlPath --kubeconfig $KubeconfigPath get pods -A -o custom-columns='NAME:.metadata.name,START:.status.startTime' 2>$null | Select-String 'infra-windows-manager|network-windows-manager|overlay' | ForEach-Object { $_.Line } } }
            $before = & $pods; Step "pods: $($before -join ' ; ')"
            if (-not $Execute) { Step 'PLAN: wait 10 min for the overlay pods to restart; otherwise one graceful bridge VM restart'; break }
            Start-Sleep 600
            $after = & $pods; Step "pods after 10 min: $($after -join ' ; ')"
            if ($KubectlPath -and ((@($before) -join '|') -eq (@($after) -join '|'))) {
                Step 'pods did not restart: one graceful restart of the bridge VM'
                # find the owner node, then connect to it directly (a nested Invoke-Command is a second hop and fails)
                $grp = Invoke-Command -ComputerName $first.management_ip -Credential $cred -ScriptBlock {
                    @(Get-ClusterGroup | Where-Object { $_.Name -like '*control-plane-0*' }) | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Owner = [string]$_.OwnerNode } } }
                if (-not $grp) { Stop-Run 'bridge VM role not found' }
                $ownerIp = (@($v.nodes) | Where-Object { $_.name -eq @($grp)[0].Owner }).management_ip
                Invoke-Command -ComputerName $ownerIp -Credential $cred -ArgumentList @($grp)[0].Name -ScriptBlock {
                    param($n) Stop-VM -Name $n -Force:$false -Confirm:$false; Start-VM -Name $n; "bridge VM $n $((Get-VM -Name $n).State)" } | ForEach-Object { Step $_ }
                for ($i = 0; $i -lt 40; $i++) { Start-Sleep 30; $a = (Invoke-AzRestMethod -Method GET -Path "/subscriptions/$($v.subscription_id)/resourceGroups/$($v.vm_management.resource_group)/providers/Microsoft.ResourceConnector/appliances/$($v.cluster_name)-arcbridge?api-version=2022-10-27").Content | ConvertFrom-Json; if ($i -ge 6 -and $a.properties.status -eq 'Running') { break } }
                Step "bridge status $($a.properties.status)"
            }
        }
        'Verify' {
            foreach ($n in $first, $second) { $l = Get-AgentLog $n (Get-Date).AddMinutes(-10); Step "$($n.name) recent JWT failures: $(@($l | Select-String 'JWT authentication failed').Count)" }
            $r = az stack-hci-vm network nsg list -g $v.vm_management.resource_group --subscription $v.subscription_id --query '[].{n:name,s:properties.provisioningState}' -o tsv --only-show-errors 2>&1
            Step "NSG list via Azure: $(@($r).Count) entries"
        }
    }
}
Step 'done'
