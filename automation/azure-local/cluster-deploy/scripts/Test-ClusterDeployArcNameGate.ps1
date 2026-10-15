#Requires -Version 7.0
<#
.SYNOPSIS
    READ-ONLY pre-Deploy gate: refuses the Deploy pass when the Arc machines are named by device ID and the seed node's
    MocArb package resolves the Arc machine in DeployVmoArcExtension from $env:COMPUTERNAME.
.DESCRIPTION
    Simplified machine provisioning names each node's Arc machine <device-id>-1 (arc_machine_names), not the host name.
    This script lists the MocArb package files on the seed node (nodes[0], or -SeedNodeName) that mention
    DeployVmoArcExtension, copies their text back (read-only: Get-ChildItem, Select-String, ReadAllText; nothing is run or
    changed on the node), parses them locally and decides with Get-ClusterDeployArcNameGateResult:
      Pass    every Arc machine carries its host name; or DeployVmoArcExtension does not read $env:COMPUTERNAME.
      Refuse  device-ID Arc names and the lookup is present; or device-ID Arc names and the function was not found
              (-AcceptUnverified passes that case with a warning, as an explicit owner decision).
    The node is reached over SSH (Posh-SSH, the transport node preparation proved before deployment; host key read over
    WinRM and pinned in memory, -AcceptKey only when WinRM cannot provide it) or WinRM, as the
    deployment local administrator resolved in memory from identity.local_admin_*_secret. -PackageFile analyses package
    files copied from the node instead, without any connection. Throws on Refuse unless -PassThru.
.PARAMETER InputFile
    terraform.generated.tfvars.json of cluster-deploy (Invoke-ClusterDeploy.ps1 -Stage Generate writes it).
.PARAMETER SeedNodeName
    Node to read (default: the first node).
.PARAMETER Transport
    Ssh (default) or WinRM.
.PARAMETER SearchRoot
    Folders on the node that hold the deployment packages.
.PARAMETER PackagePattern
    Wildcard of the package folder names.
.PARAMETER PackageFile
    Local copies of the package scripts to analyse instead of reading the node.
.PARAMETER Credential
    Node credential (default: identity.local_admin_username_secret / _password_secret from the inputs).
.PARAMETER AcceptUnverified
    Pass when the function cannot be found (never when the lookup is present). Owner decision.
.PARAMETER PassThru
    Return the gate result instead of throwing on Refuse.
.EXAMPLE
    .\Test-ClusterDeployArcNameGate.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json
.EXAMPLE
    .\Test-ClusterDeployArcNameGate.ps1 -InputFile ..\terraform\terraform.generated.tfvars.json -PackageFile .\copied\MocArb.psm1 -PassThru
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string]$InputFile,
    [string]$SeedNodeName,
    [ValidateSet('Ssh', 'WinRM')][string]$Transport = 'Ssh',
    [string[]]$SearchRoot = @('C:\NugetStore', 'C:\CloudDeployment'),
    [ValidatePattern('^[A-Za-z0-9.*_-]+$')][string]$PackagePattern = '*MocArb*',
    [string[]]$PackageFile,
    [pscredential]$Credential,
    [switch]$AcceptUnverified,
    [switch]$PassThru
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')
# SSH host key pinning (Get-NodePrepSshTrustStore / Open-NodePrepSshSession), shared with node preparation.
. (Join-Path $PSScriptRoot '..\..\..\shared\scripts\SshHostKeyPinning.Common.ps1')

$inputs = Get-ClusterDeployInputs -InputFile $InputFile
$seed = if ($SeedNodeName) { @($inputs.nodes | Where-Object { $_.name -eq $SeedNodeName }) } else { @($inputs.nodes[0]) }
if ($seed.Count -ne 1) { throw "Seed node '$SeedNodeName' is not in the inputs." }
$seed = $seed[0]
$renamed = @(Get-ClusterDeployDeviceIdArcName -Inputs $inputs)
$files = @()

if ($PackageFile) {
    $files = @(foreach ($path in $PackageFile) { [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $path).ProviderPath; Content = [IO.File]::ReadAllText($path) } })
    $SearchRoot = @($PackageFile)
}
elseif ($renamed.Count -eq 0) {
    Write-ClusterDeployLog -Message 'Every Arc machine carries its host name; the package is not read.'
}
else {
    # Read-only probe for Windows PowerShell 5.1 on the node; the result travels back as one base64 line.
    $roots = ($SearchRoot | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $probe = @"
`$out = @()
foreach (`$root in @($roots)) {
  if (-not (Test-Path -LiteralPath `$root)) { continue }
  `$packages = @(Get-ChildItem -Path `$root -Directory -Recurse -Depth 3 -Filter '$PackagePattern' -ErrorAction SilentlyContinue)
  foreach (`$package in `$packages) {
    Get-ChildItem -Path `$package.FullName -Recurse -File -Include *.ps1,*.psm1 -ErrorAction SilentlyContinue |
      Where-Object { Select-String -LiteralPath `$_.FullName -Pattern 'DeployVmoArcExtension' -SimpleMatch -Quiet } |
      ForEach-Object { `$out += New-Object psobject -Property @{ Path = `$_.FullName; Content = [IO.File]::ReadAllText(`$_.FullName) } }
  }
}
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @(`$out) -Depth 3 -Compress)))
"@
    if (-not $Credential) {
        [void](Import-ClusterDeployAutomationModule)
        $user = Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_username_secret -AsPlainText
        $Credential = [pscredential]::new($user, (Resolve-NIC26KeyVaultRef -Ref $inputs.identity.local_admin_password_secret))
    }
    $address = [string]$seed.management_ip
    Write-ClusterDeployLog -Message "Reading the MocArb package on $($seed.name) ($address, $Transport, read-only): $($SearchRoot -join ', ') / $PackagePattern"
    if ($Transport -eq 'Ssh') {
        Import-Module Posh-SSH -ErrorAction Stop
        # The host key is read from the node over WinRM and pinned in memory (a reinstalled node has a new key that
        # -AcceptKey refuses against the jump server's stored one); -AcceptKey only when WinRM cannot provide it.
        $trust = Get-NodePrepSshTrustStore -Nodes @(@{ Name = [string]$seed.name; Address = $address }) -Credential $Credential
        $session = Open-NodePrepSshSession -Address $address -Credential $Credential -Trust $trust -ConnectionTimeout 30
        try {
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
            $reply = Invoke-SSHCommand -SessionId $session.SessionId -Command "powershell -NoProfile -NonInteractive -EncodedCommand $encoded" -TimeOut 600
            if ($reply.ExitStatus -ne 0) { throw "The read-only probe failed on $($seed.name) (exit $($reply.ExitStatus)): $(($reply.Error + $reply.Output) -join ' ')" }
            $line = (@($reply.Output) -join '').Trim()
        }
        finally { Remove-SSHSession -SessionId $session.SessionId -ErrorAction SilentlyContinue | Out-Null }
    }
    else {
        $session = New-PSSession -ComputerName $address -Credential $Credential -Authentication Negotiate -ErrorAction Stop
        try { $line = ([string](Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create($probe)))).Trim() }
        finally { Remove-PSSession -Session $session }
    }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line))
    $files = @($json | ConvertFrom-Json -Depth 5)
}

$findings = @(foreach ($file in $files) { Test-ClusterDeployMocArbArcNameBug -Content ([string]$file.Content) -Path ([string]$file.Path) })
$gate = Get-ClusterDeployArcNameGateResult -Inputs $inputs -Finding $findings -SeedNode ([string]$seed.name) -SearchedRoot $SearchRoot -AcceptUnverified:$AcceptUnverified
if ($gate.Result -eq 'Refuse' -and -not $PassThru) { throw $gate.Message }
Write-ClusterDeployLog -Message $gate.Message -Level ($gate.Result -eq 'Pass' -and $gate.Reason -ne 'AcceptedUnverified' ? 'Info' : 'Warning')
return $gate
