#Requires -Version 7.0
<#
.SYNOPSIS
    Stage S0: creates the Entra security groups of the Azure Local landing zone (design §6.1) with Microsoft Graph PowerShell.
.DESCRIPTION
    Entra groups are not Azure resources, so both IaC tracks share this one script (design LZ-12). Idempotent by display
    name: an existing group is reported and reused, never modified. Group names come from the solution manifest's
    names catalog (keys grp_*) resolved by New-NIC26ResourceName (shared module NIC26.Automation) - the script never
    builds a name itself. Default is -WhatIf (lists what would be created). -Execute creates the missing groups.
    The resulting {catalog key -> object ID} map is written to -OutputPath (names and object IDs only, no secrets) for
    the operator to paste into the environment file as group_object_ids.
.PARAMETER SolutionPath
    Folder containing solution.yml (defaults to the parent of this script).
.PARAMETER OutputPath
    Where to write the group_object_ids JSON (default: scratch file in the solution folder, git-ignored *.generated.*).
.PARAMETER Execute
    Create missing groups. Without it nothing is created.
.PARAMETER GroupNames
    Override: explicit map of catalog key -> display name (used by tests; normally resolved from the manifest).
.EXAMPLE
    ./New-LzEntraGroups.ps1                     # WhatIf: shows which groups exist and which would be created
    ./New-LzEntraGroups.ps1 -Execute            # creates the missing ones
.NOTES
    Requires Microsoft.Graph.Groups and Connect-MgGraph -Scopes 'Group.ReadWrite.All' (Group.Read.All suffices for WhatIf).
    Requires the NIC26.Automation module (Get-NIC26SolutionManifest, New-NIC26ResourceName) unless -GroupNames is given.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string] $SolutionPath = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'group-object-ids.generated.json'),
    [switch] $Execute,
    [hashtable] $GroupNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LzGroupNames {
    [CmdletBinding()]
    param([string] $SolutionPath)
    $manifest = Get-NIC26SolutionManifest -Path (Join-Path $SolutionPath 'solution.yml')
    $result = @{}
    foreach ($key in ($manifest.names.Keys | Where-Object { $_ -like 'grp_*' })) {
        $entry = $manifest.names[$key]
        $result[$key] = New-NIC26ResourceName -Type $entry.type -Purpose $entry.purpose
    }
    return $result
}

if (-not $GroupNames) { $GroupNames = Resolve-LzGroupNames -SolutionPath $SolutionPath }
if ($GroupNames.Count -eq 0) { throw 'No grp_* entries found in the names catalog.' }

$plan = foreach ($key in ($GroupNames.Keys | Sort-Object)) {
    $display = $GroupNames[$key]
    $escaped = $display.Replace("'", "''")
    $existing = Get-MgGroup -Filter "displayName eq '$escaped'" -ConsistencyLevel eventual -CountVariable c -ErrorAction Stop | Select-Object -First 1
    [pscustomobject]@{
        Key         = $key
        DisplayName = $display
        ObjectId    = $existing ? $existing.Id : $null
        Action      = $existing ? 'exists' : 'create'
    }
}

$plan | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue
$toCreate = @($plan | Where-Object Action -EQ 'create')

if ($toCreate.Count -gt 0 -and -not $Execute) {
    Write-Warning "WhatIf (default): $($toCreate.Count) group(s) would be created. Re-run with -Execute to create them."
}
elseif ($toCreate.Count -gt 0) {
    foreach ($g in $toCreate) {
        if ($PSCmdlet.ShouldProcess($g.DisplayName, 'New-MgGroup (security group, no owners, assigned membership)')) {
            $created = New-MgGroup -DisplayName $g.DisplayName -MailEnabled:$false -MailNickname ($g.DisplayName -replace '[^a-zA-Z0-9]', '') -SecurityEnabled:$true `
                -Description "NIC26 Azure Local landing zone (design §6.1): $($g.Key)"
            $g.ObjectId = $created.Id
            $g.Action = 'created'
        }
    }
}

$map = [ordered]@{}
foreach ($g in $plan) { $map[$g.Key] = $g.ObjectId }
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write group_object_ids JSON (names and object IDs only)')) {
    ([pscustomobject]@{ group_object_ids = $map }) | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputPath -Encoding utf8
    Write-Information "group_object_ids written to $OutputPath - copy into environment/azure-local/*.yml" -InformationAction Continue
}
return $plan
