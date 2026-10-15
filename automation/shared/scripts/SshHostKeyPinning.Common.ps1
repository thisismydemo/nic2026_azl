# SSH host key pinning for Posh-SSH 4, shared by node preparation (os-provisioning, private) and the cluster-deploy
# Arc-name gate (published). Dot-sourced. Pure functions where possible so the decisions are unit-tested
# (os-provisioning/tests/NodePreparation.Tests.ps1); no secret value is logged or returned by any function here.
#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# SSH host key pinning. A reinstalled node presents a new host key; Posh-SSH -AcceptKey accepts an unknown key but
# refuses a CHANGED one against the jump server's persistent trusted-host store ("Host key could not be verified", seen
# live 11 Oct 2026). The key is read from the node itself over WinRM (authenticated as the deployment admin) and pinned in
# an in-memory store, so the persistent store is neither read nor changed. Posh-SSH 4 compares the stored value with
# Renci.SshNet HostKeyEventArgs.FingerPrintSHA256: base64 of the SHA-256 of the key blob, '=' padding removed, no
# 'SHA256:' prefix (the text ssh-keygen -lf prints after 'SHA256:'), keyed by the -ComputerName string (host:port when the
# port is not 22). RSA names ssh-rsa / rsa-sha2-256 / rsa-sha2-512 match each other in Posh-SSH.

function ConvertTo-NodePrepSshHostKeyFingerprint {
    <#
    .SYNOPSIS
        Host key name and fingerprint, in the Posh-SSH 4 trusted-host format, of one OpenSSH public key line
        ('<type> <base64 blob> [comment]'). Pure. Throws when the line is not a public key or the blob's own type name
        differs from the declared one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$PublicKey)
    $parts = @($PublicKey.Trim() -split '\s+')
    if ($parts.Count -lt 2) { throw "Not an OpenSSH public key line: '$PublicKey'." }
    try { $blob = [Convert]::FromBase64String($parts[1]) }
    catch { throw "The key data of '$($parts[0])' is not base64." }
    # RFC 4253 6.6: the blob starts with its own key type as an SSH string (uint32 length, then the name).
    $length = if ($blob.Length -ge 4) { ([int]$blob[0] -shl 24) -bor ([int]$blob[1] -shl 16) -bor ([int]$blob[2] -shl 8) -bor [int]$blob[3] } else { 0 }
    if ($length -le 0 -or $length -gt $blob.Length - 4) { throw "The key data of '$($parts[0])' is not an SSH public key blob." }
    $innerName = [Text.Encoding]::ASCII.GetString($blob, 4, $length)
    if ($innerName -cne $parts[0]) { throw "Key type mismatch: the line says '$($parts[0])', the key data says '$innerName'." }
    $hash = [Security.Cryptography.SHA256]::HashData($blob)
    return [pscustomobject]@{ HostKeyName = $parts[0]; Fingerprint = [Convert]::ToBase64String($hash).TrimEnd('=') }
}

function Get-NodePrepSshHostPublicKey {
    <#
    .SYNOPSIS
        READ-ONLY: the node's OpenSSH host public keys (ed25519, ecdsa, rsa when present) read over WinRM (HTTP 5985,
        Negotiate) as the given credential. Throws when WinRM does not answer or refuses. Wrapper for tests.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$OpenTimeoutSeconds = 30
    )
    $option = New-PSSessionOption -OpenTimeout ($OpenTimeoutSeconds * 1000) -OperationTimeout 60000
    # Node side: Windows PowerShell 5.1.
    $lines = Invoke-Command -ComputerName $Address -Credential $Credential -Authentication Negotiate -SessionOption $option -ErrorAction Stop -ScriptBlock {
        foreach ($type in @('ed25519', 'ecdsa', 'rsa')) {
            $path = Join-Path $env:ProgramData ('ssh\ssh_host_' + $type + '_key.pub')
            if (Test-Path -LiteralPath $path) { [string](Get-Content -LiteralPath $path -TotalCount 1) }
        }
    }
    return [string[]]@($lines | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

function Get-NodePrepSshTrustStore {
    <#
    .SYNOPSIS
        Pins each node's SSH host keys, read from the node over WinRM, in an in-memory Posh-SSH trusted-host store keyed
        by the address the scripts connect to. Returns a hashtable address -> store, or address -> $null when WinRM did
        not provide a key (the caller then falls back to -AcceptKey). Logs the mode per node. The jump server's
        persistent trusted-host store is never used.
    .PARAMETER Nodes
        Objects or hashtables with Name and Address.
    .PARAMETER Store
        Existing in-memory store to add to (default: a new New-SSHMemoryTrustedHostStore).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][object[]]$Nodes,
        [Parameter(Mandatory)][pscredential]$Credential,
        [object]$Store
    )
    if ($null -eq $Store) { $Store = New-SSHMemoryTrustedHostStore }
    if ($null -eq $Store) { throw 'New-SSHMemoryTrustedHostStore returned nothing; refusing to fall through to the persistent store.' }
    $trust = @{}
    foreach ($n in $Nodes) {
        $name = [string]$n.Name
        $address = [string]$n.Address
        try { $lines = @(Get-NodePrepSshHostPublicKey -Address $address -Credential $Credential) }
        catch {
            Write-Information "[$name] SSH host key: WinRM to $address did not provide it ($($_.Exception.Message)); SSH falls back to -AcceptKey (a changed key fails)." -InformationAction Continue
            $trust[$address] = $null
            continue
        }
        $keys = @(foreach ($line in $lines) {
                try { ConvertTo-NodePrepSshHostKeyFingerprint -PublicKey $line }
                catch { Write-Warning "[$name] ignoring an unreadable SSH host key: $($_.Exception.Message)" }
            })
        if (-not $keys.Count) {
            Write-Information "[$name] SSH host key: no host public key under ProgramData\ssh on $address (sshd not started yet?); SSH falls back to -AcceptKey (a changed key fails)." -InformationAction Continue
            $trust[$address] = $null
            continue
        }
        foreach ($k in $keys) { $null = Add-SSHTrustedHost -HostName $address -HostKeyName $k.HostKeyName -Fingerprint $k.Fingerprint -TrustedHostStore $Store }
        $trust[$address] = $Store
        Write-Information "[$name] SSH host key pinned for $address from the node over WinRM: $(@($keys | ForEach-Object { "$($_.HostKeyName) SHA256:$($_.Fingerprint)" }) -join ', ') (-TrustedHostStore in memory, -ErrorOnUntrusted)." -InformationAction Continue
    }
    return $trust
}

function Get-NodePrepSshTrustParameter {
    <#
    .SYNOPSIS
        Host key parameters for New-SSHSession / Set-SCPItem: the pinned in-memory store with -ErrorOnUntrusted, or
        -AcceptKey when no key was pinned for the address. Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [AllowNull()][hashtable]$Trust
    )
    if ($null -ne $Trust -and $Trust.ContainsKey($Address) -and $null -ne $Trust[$Address]) {
        return @{ TrustedHostStore = $Trust[$Address]; ErrorOnUntrusted = $true }
    }
    return @{ AcceptKey = $true }
}

function Open-NodePrepSshSession {
    <#
    .SYNOPSIS
        New-SSHSession to the node with the pinned host key (Get-NodePrepSshTrustStore) or the -AcceptKey fallback.
        Throws when the session cannot be opened (including an untrusted host key in pinned mode).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][pscredential]$Credential,
        [AllowNull()][hashtable]$Trust,
        [int]$ConnectionTimeout = 30
    )
    $hostKey = Get-NodePrepSshTrustParameter -Address $Address -Trust $Trust
    return New-SSHSession -ComputerName $Address -Credential $Credential -ConnectionTimeout $ConnectionTimeout -ErrorAction Stop @hostKey
}
