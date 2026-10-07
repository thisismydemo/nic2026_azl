function Get-NIC26InputAliasMap {
    <#
    .SYNOPSIS
        Canonical-name aliases: design variables tables that name the same value differently resolve to the one schema key.
    .DESCRIPTION
        The converters look an input up by its own name first; when absent and no 'path' is declared, the alias target is
        tried. Keep this list short and documented in shared/README.md.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        region_short            = 'location_short'                 # design/azure-local/landing-zone.md 10.6
        lab_token               = 'token'                          # design/avd/landing-zone.md 11.5
        p2s_pool                = 'p2s_client_pool'                # design/avd/landing-zone.md 11.5
        identity_spoke_prefix   = 'identity_spoke_address_space'   # lz-azure-local (added input)
        management_spoke_prefix = 'management_spoke_address_space' # lz-azure-local (added input)
        avd_spoke_prefix        = 'avd_vnet_prefix'                # Azure Local design name for the AVD spoke prefix
        key_vault_ops_name      = 'kv_ops_name'                    # design/avd/hybrid-hyperv-hosts.md 16.1
    }
}
