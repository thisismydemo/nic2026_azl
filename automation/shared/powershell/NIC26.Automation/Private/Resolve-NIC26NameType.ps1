function Resolve-NIC26NameType {
    <#
    .SYNOPSIS
        Maps a catalog/CLI type (including accepted aliases) to its registry key; returns $null when unknown.
    .DESCRIPTION
        Aliases accepted in solution.yml catalogs: vnetpeering | peering -> peer; pdns | privatednszone -> pdnszone;
        computername | hostname -> netbios; gallery -> gal; storage -> st; keyvault -> kv.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Type
    )

    $aliases = @{
        vnetpeering     = 'peer'
        peering         = 'peer'
        pdns            = 'pdnszone'
        privatednszone  = 'pdnszone'
        computername    = 'netbios'
        hostname        = 'netbios'
        gallery         = 'gal'
        storage         = 'st'
        keyvault        = 'kv'
    }

    $key = $Type.Trim().ToLowerInvariant()
    if ([string]::IsNullOrEmpty($key)) {
        return $null
    }
    if ($aliases.ContainsKey($key)) {
        $key = $aliases[$key]
    }
    $registry = Get-NIC26NameRegistry
    if ($registry.Contains($key)) {
        return $key
    }
    return $null
}
