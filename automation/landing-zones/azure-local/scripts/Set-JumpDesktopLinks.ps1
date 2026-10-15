#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.ResourceGraph, Az.KeyVault
<#
.SYNOPSIS
    Puts the sessions' web tools on the jump server's desktop (owner, 13 Oct): a folder of .url shortcuts per group and
    one index page, on the Public desktop so every account on the server sees them. Default is a plan; -Execute writes.
.DESCRIPTION
    Inputs (G5, nothing lab-specific in this file):
      environment/azure-local/jump-desktop-links.psd1   JumpVmName, FolderName, Groups[].Links[] (Url or Resource)
    Resource links are resolved by Azure Resource Graph (name + type) in the current tenant and become portal URLs
    (https://portal.azure.com/#@<tenant>/resource<id><blade>); {tenant} in a Url is replaced by the tenant id.
    The shortcuts are written by Run Command (Invoke-AzVMRunCommand, RunPowerShellScript) as SYSTEM into
    C:\Users\Public\Desktop\<FolderName>\ plus C:\Users\Public\Desktop\<FolderName>.html. Rerunnable: the folder is
    replaced each run. Shortcuts only; nothing is installed and no browser setting changes. No secrets involved.
    Runs in the caller's Az context; pin it per process first (Disable-AzContextAutosave -Scope Process; Set-AzContext
    -Tenant <tenant> -Subscription <subscription> -Scope Process).
.PARAMETER LinksPath
    The links data file (default: <repo>/environment/azure-local/jump-desktop-links.psd1).
.PARAMETER Execute
    Write the shortcuts on the jump server. Without it the script prints the resolved links only.
.EXAMPLE
    ./Set-JumpDesktopLinks.ps1             # resolve and print
.EXAMPLE
    ./Set-JumpDesktopLinks.ps1 -Execute
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$LinksPath,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
if (-not $LinksPath) { $LinksPath = Join-Path $repo 'environment\azure-local\jump-desktop-links.psd1' }
$data = Import-PowerShellDataFile -Path $LinksPath
$ctx = Get-AzContext
if (-not $ctx) { throw 'No Az context: sign in and pin the tenant and subscription first.' }
$tenant = $ctx.Tenant.Id

function Write-Step([string]$Message) { Write-Information -MessageData "[jump-links] $Message" -InformationAction Continue }
function Get-ResourceId([string]$Name, [string]$Type) {
    $q = "resources | where name =~ '$($Name -replace "'", "''")' and type =~ '$($Type -replace "'", "''")' | project id"
    $r = @(Search-AzGraph -Query $q -UseTenantScope -First 5)
    if ($r.Count -ne 1) { throw "Resource '$Name' ($Type): $($r.Count) matches, expected 1." }
    $r[0].id
}

# resolve every link
$groups = foreach ($g in $data.Groups) {
    $links = foreach ($l in $g.Links) {
        if ($l.ContainsKey('Url')) { $url = $l.Url.Replace('{tenant}', $tenant) }
        else {
            $id = Get-ResourceId -Name $l.Resource.Name -Type $l.Resource.Type
            $blade = if ($l.ContainsKey('Blade')) { $l.Blade } else { '/overview' }
            $url = "https://portal.azure.com/#@$tenant/resource$id$blade"
        }
        [pscustomobject]@{ Title = $l.Title; Url = $url }
    }
    [pscustomobject]@{ Name = $g.Name; Links = @($links) }
}
foreach ($g in $groups) { Write-Step "$($g.Name): $($g.Links.Count) links"; foreach ($l in $g.Links) { Write-Step "  $($l.Title)  $($l.Url)" } }

if (-not $Execute) { Write-Step 'Plan only. Run with -Execute to write the shortcuts on the jump server.'; return }

# temporary demo users with their passwords (owner, 14 Oct): read from Key Vault now, never printed, never stored in the repo
$accounts = $null
if ($data.ContainsKey('TestAccounts')) {
    $ta = $data.TestAccounts
    $rows = for ($i = 0; $i -lt $ta.Users.Count; $i++) {
        $pw = Get-AzKeyVaultSecret -VaultName $ta.Vault -Name ($ta.SecretFormat -f ($i + 1)) -AsPlainText
        [pscustomobject]@{ User = $ta.Users[$i]; Password = $pw; Use = ($ta.Users[$i] -eq $ta.Use) }
    }
    $accounts = @{ Rows = @($rows); AdminUpn = $ta.AdminUpn; Note = $ta.Note }
    Write-Step "Test accounts: $($rows.Count) users, passwords read from $($ta.Vault)"
}

$vm = @(Search-AzGraph -Query "resources | where type =~ 'microsoft.compute/virtualmachines' and name =~ '$($data.JumpVmName)' | project name, resourceGroup, subscriptionId" -UseTenantScope -First 2)
if ($vm.Count -ne 1) { throw "Jump server '$($data.JumpVmName)': $($vm.Count) matches, expected 1." }
if ($vm[0].subscriptionId -ne $ctx.Subscription.Id) { $null = Set-AzContext -Subscription $vm[0].subscriptionId -Scope Process -WhatIf:$false }

$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ Folder = $data.FolderName; Groups = $groups; Accounts = $accounts } | ConvertTo-Json -Depth 6 -Compress)))
$remote = @"
`$ErrorActionPreference = 'Stop'
`$d = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json
`$desk = Join-Path `$env:PUBLIC 'Desktop'
`$root = Join-Path `$desk `$d.Folder
if (Test-Path `$root) { Remove-Item `$root -Recurse -Force }
`$null = New-Item -ItemType Directory -Path `$root
`$bad = [IO.Path]::GetInvalidFileNameChars()
`$enc = { param(`$s) [Net.WebUtility]::HtmlEncode(`$s) }
`$html = [Text.StringBuilder]::new('<!doctype html><html><head><meta charset="utf-8"><title>' + (& `$enc `$d.Folder) + '</title><style>body{font:15px Segoe UI,sans-serif;margin:24px;background:#f6f8f8;color:#1a1b1b}h1{font-size:22px}h2{font-size:16px;margin:20px 0 6px;color:#0b5f66}a{color:#0b5f66;text-decoration:none}a:hover{text-decoration:underline}ul{margin:0;padding-left:18px}li{margin:3px 0}</style></head><body><h1>' + (& `$enc `$d.Folder) + '</h1>')
if (`$d.Accounts) {
  `$null = `$html.Append('<div style="border:2px solid #fdba12;border-radius:8px;padding:8px 14px;background:#fffdf3"><h2>Test accounts (temporary demo users)</h2><table style="border-collapse:collapse">')
  foreach (`$r in `$d.Accounts.Rows) { `$b = if (`$r.Use) { ' style="font-weight:700"' } else { '' }; `$null = `$html.Append('<tr' + `$b + '><td style="padding:2px 18px 2px 0"><code>' + (& `$enc `$r.User) + '</code>' + `$(if (`$r.Use) { ' (use this one)' } else { '' }) + '</td><td><code>' + (& `$enc `$r.Password) + '</code></td></tr>') }
  `$null = `$html.Append('</table><p>Admin (portal, jump server): <code>' + (& `$enc `$d.Accounts.AdminUpn) + '</code> (your own password)</p><p>' + (& `$enc `$d.Accounts.Note) + '</p></div>')
}
`$n = 0
foreach (`$g in `$d.Groups) {
  `$gd = Join-Path `$root ((`$g.Name.ToCharArray() | Where-Object { `$bad -notcontains `$_ }) -join '')
  `$null = New-Item -ItemType Directory -Path `$gd
  `$null = `$html.Append('<h2>' + (& `$enc `$g.Name) + '</h2><ul>')
  foreach (`$l in `$g.Links) {
    `$f = Join-Path `$gd (((`$l.Title.ToCharArray() | Where-Object { `$bad -notcontains `$_ }) -join '') + '.url')
    Set-Content -Path `$f -Value "[InternetShortcut]`r`nURL=`$(`$l.Url)`r`n" -Encoding ascii
    `$null = `$html.Append('<li><a href="' + (& `$enc `$l.Url) + '" target="_blank">' + (& `$enc `$l.Title) + '</a></li>')
    `$n++
  }
  `$null = `$html.Append('</ul>')
}
`$null = `$html.Append('</body></html>')
Set-Content -Path (Join-Path `$desk (`$d.Folder + '.html')) -Value `$html.ToString() -Encoding utf8
"WROTE `$n shortcuts in `$((Get-ChildItem `$root -Directory).Count) folders under `$root; index page `$(Join-Path `$desk (`$d.Folder + '.html'))"
"@
Write-Step "Writing on $($vm[0].name) by Run Command"
$r = Invoke-AzVMRunCommand -ResourceGroupName $vm[0].resourceGroup -VMName $vm[0].name -CommandId 'RunPowerShellScript' -ScriptString $remote
$out = ($r.Value | Where-Object Code -like '*StdOut*').Message
$err = ($r.Value | Where-Object Code -like '*StdErr*').Message
if ($err) { throw "Run Command stderr: $err" }
Write-Step $out
if ($out -notmatch '^WROTE \d+ shortcuts') { throw 'Run Command did not confirm the shortcuts.' }
