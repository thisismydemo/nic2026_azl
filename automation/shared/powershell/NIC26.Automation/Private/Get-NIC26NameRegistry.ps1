function Get-NIC26NameRegistry {
    <#
    .SYNOPSIS
        Table-driven registry of every resource-name type from design\shared\naming-standard.md.
    .DESCRIPTION
        One entry per type. Adding a type is one entry in $table below. Template tokens:
            {type} {org} {token} {purpose} {region} {instance} {suffix}
        Entry keys (defaults applied by this function):
            Type                 abbreviation used with -Type
            Template             name template (tokens above); literal text is kept as-is
            Description          what the type is
            MinLength/MaxLength  Azure or NetBIOS limits
            Regex                allowed characters for the whole name (default: lowercase alnum + hyphen, no leading/trailing hyphen)
            PurposeOptional      lab-wide singletons may omit the purpose (law, gal, vdws)
            PurposeAllowed       $false for types whose template has no {purpose}
            PurposeCompact       hyphens are stripped from the purpose (storage, gallery)
            PurposeRegex         purpose character rule (default lowercase alnum + single hyphens)
            PurposeValidSet      restrict the purpose to a set (session hosts)
            DefaultPurpose       purpose applied when none is given (node -> cluster number 01)
            PurposeIsParentName  the purpose is the parent resource's full name (nic, osdisk, datadisk, vhd, bmc, peer)
            SuffixMeaning        what -Suffix means when the template has {suffix}
            NoConsecutiveHyphens Key Vault rule
            RequireToken         name must contain the lab token (exempt types set $false)
            Generated            $false for fixed/exempt names: Test-NIC26ResourceName only
            FixedNames           allowed values for fixed-name types
            Global               no {region} in the template (Entra objects, policy, image definitions, site names)
            Example              from the naming standard
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if ($script:NIC26NameRegistry) {
        return $script:NIC26NameRegistry
    }

    $std = '{type}-{org}-{token}-{purpose}-{region}-{instance}'
    $compact = '{type}{org}{token}{purpose}{region}{instance}'
    $alnum = '^[a-z0-9]+$'

    $table = @(
        # --- Azure resources: standard pattern <type>-iic-nic26-<purpose>-eus-<##> -------------------------------
        @{ Type = 'rg'; Template = $std; Description = 'Resource group'; MaxLength = 90; Example = 'rg-iic-nic26-azl-eus-01' }
        @{ Type = 'vnet'; Template = $std; Description = 'Virtual network'; MaxLength = 64; Example = 'vnet-iic-nic26-avd-eus-01' }
        @{ Type = 'snet'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Subnet (lab spokes; Azure-fixed subnets use type fixedsubnet)'; MaxLength = 80; Global = $true; Example = 'snet-iic-nic26-hosts' }
        @{ Type = 'peer'; Template = 'peer-{purpose}-to-{suffix}'; Description = 'VNet peering; -Purpose is the source VNet name, -Suffix the target'; MaxLength = 80; Global = $true; PurposeIsParentName = $true; SuffixMeaning = 'target VNet short name'; Example = 'peer-vnet-iic-nic26-avd-eus-01-to-hub' }
        @{ Type = 'nsg'; Template = $std; Description = 'Network security group'; MaxLength = 80; Example = 'nsg-iic-nic26-jump-eus-01' }
        @{ Type = 'rt'; Template = $std; Description = 'Route table'; MaxLength = 80; Example = 'rt-iic-nic26-avd-eus-01' }
        @{ Type = 'pip'; Template = $std; Description = 'Public IP (avoid; the only one planned is the AVD NAT gateway address)'; MaxLength = 80; Example = 'pip-iic-nic26-jump-eus-01' }
        @{ Type = 'ng'; Template = $std; Description = 'NAT gateway (explicit outbound path for a spoke)'; MaxLength = 80; Example = 'ng-iic-nic26-avd-eus-01' }
        @{ Type = 'nic'; Template = 'nic-{purpose}-{instance}'; Description = 'Network interface; -Purpose is the VM resource name'; MaxLength = 80; Global = $true; PurposeIsParentName = $true; Example = 'nic-vm-iic-nic26-jump-eus-01-01' }
        @{ Type = 'pep'; Template = $std; Description = 'Private endpoint'; MaxLength = 80; Example = 'pep-iic-nic26-kvops-eus-01' }
        @{ Type = 'link'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Private DNS zone virtual network link'; MaxLength = 80; Global = $true; Example = 'link-iic-nic26-avd' }
        @{ Type = 'kv'; Template = $std; Description = 'Key Vault (3-24, no consecutive hyphens, globally unique)'; MinLength = 3; MaxLength = 24; NoConsecutiveHyphens = $true; Example = 'kv-iic-nic26-ops-eus-01' }
        @{ Type = 'st'; Template = $compact; Description = 'Storage account (3-24 lowercase alphanumeric, globally unique)'; MinLength = 3; MaxLength = 24; Regex = $alnum; PurposeCompact = $true; PurposeRegex = $alnum; Example = 'stiicnic26fslogixeus01' }
        @{ Type = 'law'; Template = $std; Description = 'Log Analytics workspace (lab-wide singleton; purpose optional)'; MinLength = 4; MaxLength = 63; PurposeOptional = $true; Example = 'law-iic-nic26-eus-01' }
        @{ Type = 'dcr'; Template = $std; Description = 'Data collection rule; purpose = <scope>-<purpose>'; MaxLength = 64; Example = 'dcr-iic-nic26-azl-insights-eus-01' }
        @{ Type = 'dce'; Template = $std; Description = 'Data collection endpoint'; MaxLength = 44; Example = 'dce-iic-nic26-azl-eus-01' }
        @{ Type = 'dcra'; Template = '{type}-{org}-{token}-{purpose}-{instance}'; Description = 'Data collection rule association (local convention, no region)'; MaxLength = 64; Global = $true; Example = 'dcra-iic-nic26-azl-01' }
        @{ Type = 'ag'; Template = $std; Description = 'Action group'; MaxLength = 260; Example = 'ag-iic-nic26-ops-eus-01' }
        @{ Type = 'alert'; Template = $std; Description = 'Alert rule; purpose = signal'; MaxLength = 260; Example = 'alert-iic-nic26-cpu-eus-01' }
        @{ Type = 'rsv'; Template = $std; Description = 'Recovery Services vault'; MinLength = 2; MaxLength = 50; Example = 'rsv-iic-nic26-azl-eus-01' }
        @{ Type = 'bkp'; Template = $std; Description = 'Backup policy; purpose = tier'; MaxLength = 150; Example = 'bkp-iic-nic26-tier1-eus-01' }
        @{ Type = 'asrpol'; Template = $std; Description = 'ASR replication policy'; MaxLength = 150; Example = 'asrpol-iic-nic26-tier1-eus-01' }
        @{ Type = 'id'; Template = $std; Description = 'User-assigned managed identity'; MinLength = 3; MaxLength = 128; Example = 'id-iic-nic26-deploy-eus-01' }
        @{ Type = 'init'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Azure Policy initiative (global, no region/instance)'; MaxLength = 64; Global = $true; Example = 'init-iic-nic26-hybrid-baseline' }
        @{ Type = 'pol'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Azure Policy definition'; MaxLength = 64; Global = $true; Example = 'pol-iic-nic26-akv-backup-ext' }
        @{ Type = 'asg'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Azure Policy assignment (64 at subscription scope; 24 at management-group scope)'; MaxLength = 64; Global = $true; Example = 'asg-iic-nic26-hybrid-baseline' }
        @{ Type = 'mc'; Template = $std; Description = 'Maintenance configuration'; MaxLength = 64; Example = 'mc-iic-nic26-azl-eus-01' }
        @{ Type = 'gal'; Template = $compact; Description = 'Compute gallery (no hyphens; lab-wide singleton, purpose optional)'; MaxLength = 80; Regex = $alnum; PurposeCompact = $true; PurposeOptional = $true; PurposeRegex = $alnum; Example = 'galiicnic26eus01' }
        @{ Type = 'imgdef'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Gallery image definition; purpose = os'; MaxLength = 80; Global = $true; Example = 'imgdef-iic-nic26-win11-avd' }
        @{ Type = 'it'; Template = $std; Description = 'Image Builder template; purpose = target'; MaxLength = 64; Example = 'it-iic-nic26-azure-eus-01' }
        @{ Type = 'vdws'; Template = $std; Description = 'AVD workspace (lab-wide singleton, purpose optional)'; MaxLength = 64; PurposeOptional = $true; Example = 'vdws-iic-nic26-eus-01' }
        @{ Type = 'vdpool'; Template = $std; Description = 'AVD host pool; purpose = realm'; MaxLength = 64; Example = 'vdpool-iic-nic26-azure-eus-01' }
        @{ Type = 'vdag'; Template = $std; Description = 'AVD application group; purpose = realm'; MaxLength = 64; Example = 'vdag-iic-nic26-azure-eus-01' }
        @{ Type = 'vdscaling'; Template = $std; Description = 'AVD scaling plan; purpose = realm'; MaxLength = 64; Example = 'vdscaling-iic-nic26-azure-eus-01' }
        @{ Type = 'vm'; Template = $std; Description = 'Virtual machine (Azure resource name); purpose = role'; MaxLength = 64; Example = 'vm-iic-nic26-jump-eus-01' }
        @{ Type = 'vmazl'; Template = 'vm-{org}-{token}-{purpose}-azl-{instance}'; Description = 'Azure Local VM (Azure resource name); purpose = role'; MaxLength = 64; Global = $true; Example = 'vm-iic-nic26-avd-azl-01' }
        @{ Type = 'osdisk'; Template = 'osdisk-{purpose}'; Description = 'OS disk; -Purpose is the VM resource name'; MaxLength = 80; Global = $true; PurposeIsParentName = $true; Example = 'osdisk-vm-iic-nic26-jump-eus-01' }
        @{ Type = 'datadisk'; Template = 'datadisk-{purpose}-{instance}'; Description = 'Data disk; -Purpose is the VM resource name'; MaxLength = 80; Global = $true; PurposeIsParentName = $true; Example = 'datadisk-vm-iic-nic26-jump-eus-01-01' }
        @{ Type = 'disk'; Template = $std; Description = 'Managed disk (temporary import disk); purpose = role'; MaxLength = 80; Example = 'disk-iic-nic26-azl-import-eus-01' }
        @{ Type = 'runout'; Template = $std; Description = 'Image Builder run output name; purpose = target'; MaxLength = 64; Example = 'runout-iic-nic26-azure-eus-01' }
        @{ Type = 'vhd'; Template = 'vhd-{purpose}-{instance}'; Description = 'Azure Local VM virtual hard disk; -Purpose is the VM resource name'; MaxLength = 80; Global = $true; PurposeIsParentName = $true; Example = 'vhd-vm-iic-nic26-avd-azl-01-01' }
        @{ Type = 'cl'; Template = $std; Description = 'Azure Local custom location'; MaxLength = 64; Example = 'cl-iic-nic26-azl-eus-01' }
        @{ Type = 'arb'; Template = $std; Description = 'Arc Resource Bridge'; MaxLength = 64; Example = 'arb-iic-nic26-azl-eus-01' }
        @{ Type = 'lnet'; Template = '{type}-{org}-{token}-{purpose}-{region}'; Description = 'Azure Local logical network (region, no instance)'; MaxLength = 64; Example = 'lnet-iic-nic26-compute-eus' }
        @{ Type = 'img'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Azure Local VM image; purpose = <os>-<ver>'; MaxLength = 80; Global = $true; Example = 'img-iic-nic26-win11-avd-25h2' }
        @{ Type = 'dep'; Template = '{type}-{org}-{token}-{purpose}-{instance}'; Description = 'Deployment name; purpose = solution'; MaxLength = 64; Global = $true; Example = 'dep-iic-nic26-lz-avd-01' }
        @{ Type = 'budget'; Template = '{type}-{org}-{token}-{purpose}-{instance}'; Description = 'Budget (local convention, no region); purpose = landing zone'; MaxLength = 63; Global = $true; Example = 'budget-iic-nic26-avd-01' }
        @{ Type = 'rp'; Template = '{type}-{org}-{token}-{purpose}-{instance}'; Description = 'ASR recovery plan (local convention, no region)'; MaxLength = 64; Global = $true; Example = 'rp-iic-nic26-tier1-01' }
        @{ Type = 'dnspr'; Template = $std; Description = 'DNS Private Resolver'; MaxLength = 80; Example = 'dnspr-iic-nic26-avd-eus-01' }
        @{ Type = 'spn'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Service principal / app registration (not sp-, reserved for storage paths)'; MaxLength = 120; Global = $true; Example = 'spn-iic-nic26-arc-onboard' }
        @{ Type = 'role'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Custom RBAC role definition (global, no region/instance)'; MaxLength = 128; Global = $true; Example = 'role-iic-nic26-aib-image' }
        @{ Type = 'grp'; Template = '{type}-{org}-{token}-{purpose}'; Description = 'Entra group; purpose = <scope>-<purpose>'; MaxLength = 256; Global = $true; Example = 'grp-iic-nic26-avd-azure' }
        @{ Type = 'secret'; Template = '{org}-{token}-{purpose}-{suffix}'; Description = 'Key Vault secret name <org>-<env>-<descriptor>-<field>; pass -Org per the HCS registry; -Suffix = field'; MaxLength = 127; Global = $true; Regex = '^[A-Za-z0-9-]+$'; SuffixMeaning = 'field (username, password, secret, client-id)'; Example = 'iic-nic26-jump-local-admin-password' }
        # --- Site / NetBIOS names (<= 15) ----------------------------------------------------------------------------
        @{ Type = 'clus'; Template = '{token}-clus{instance}'; Description = 'Azure Local cluster / CNO (also the Azure resource name)'; MaxLength = 15; Global = $true; PurposeAllowed = $false; Example = 'nic26-clus01' }
        @{ Type = 'node'; Template = '{token}-{purpose}-n{instance}'; Description = 'Azure Local node; -Purpose is the two-digit cluster number (default 01)'; MaxLength = 15; Global = $true; DefaultPurpose = '01'; PurposeRegex = '^\d{2}$'; Example = 'nic26-01-n01' }
        @{ Type = 'bmc'; Template = '{purpose}-i'; Description = 'Out-of-band controller (BMC); -Purpose is the node name'; MaxLength = 63; Global = $true; PurposeIsParentName = $true; Example = 'nic26-01-n01-i' }
        @{ Type = 'sw'; Template = '{token}-sw-{instance}'; Description = 'ToR / edge switch'; MaxLength = 15; Global = $true; PurposeAllowed = $false; Example = 'nic26-sw-01' }
        @{ Type = 'fw'; Template = '{token}-fw-{instance}'; Description = 'Firewall'; MaxLength = 15; Global = $true; PurposeAllowed = $false; Example = 'nic26-fw-01' }
        @{ Type = 'og'; Template = '{token}-og-{instance}'; Description = 'Console server'; MaxLength = 15; Global = $true; PurposeAllowed = $false; Example = 'nic26-og-01' }
        @{ Type = 'jmp'; Template = '{token}-jmp-{instance}'; Description = 'Jump server computer name'; MaxLength = 15; Global = $true; PurposeAllowed = $false; Example = 'nic26-jmp-01' }
        @{ Type = 'netbios'; Template = '{token}-{purpose}-{instance}'; Description = 'Generic computer / NetBIOS name <= 15 (jump server, appliances); session hosts use type sessionhost'; MaxLength = 15; Global = $true; Example = 'nic26-jmp-01' }
        @{ Type = 'sessionhost'; Template = '{token}-avd-{purpose}{instance}'; Description = 'AVD session host computer name; -Purpose = az | al | hv'; MaxLength = 15; Global = $true; PurposeValidSet = @('az', 'al', 'hv'); Example = 'nic26-avd-az01' }
        @{ Type = 'vlan'; Template = '{token}-{purpose}-{suffix}'; Description = 'VLAN name; -Suffix is the VLAN id'; MaxLength = 32; Global = $true; SuffixMeaning = 'VLAN id'; Example = 'nic26-mgmt-100' }
        @{ Type = 'vsw'; Template = '{token}-vsw-{purpose}'; Description = 'Manually created Hyper-V virtual switch'; MaxLength = 64; Global = $true; Example = 'nic26-vsw-lab' }
        @{ Type = 'sp'; Template = '{type}-{token}-{purpose}-{instance}'; Description = 'Azure Local storage path; purpose = <mirror>-<purpose>'; MaxLength = 64; Global = $true; Example = 'sp-nic26-m2-vmstore-01' }
        @{ Type = 'csv'; Template = '{type}-{token}-{purpose}-{instance}'; Description = 'Cluster shared volume; purpose = <mirror>-<purpose>'; MaxLength = 64; Global = $true; Example = 'csv-nic26-m2-vmstore-01' }
        @{ Type = 'share'; Template = '{token}-{purpose}'; Description = 'Azure Files share (3-63, lowercase, digits, hyphens)'; MinLength = 3; MaxLength = 63; Global = $true; Example = 'nic26-fslogix-profiles' }
        # --- Exempt from the nic26 rule (naming standard 3b): validated only, never generated ----------------------------
        @{ Type = 'pdnszone'; Template = $null; Description = 'Private DNS zone (Azure service-required name)'; MaxLength = 253; Regex = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; RequireToken = $false; Generated = $false; Global = $true; Example = 'privatelink.vaultcore.azure.net' }
        @{ Type = 'fixedsubnet'; Template = $null; Description = 'Azure-required subnet name'; MaxLength = 80; Regex = '^[A-Za-z]+$'; RequireToken = $false; Generated = $false; Global = $true; FixedNames = @('GatewaySubnet', 'AzureBastionSubnet', 'AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'RouteServerSubnet'); Example = 'GatewaySubnet' }
        @{ Type = 'tfstate'; Template = $null; Description = 'Terraform state blob key <solution>.tfstate'; MaxLength = 128; Regex = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?\.tfstate$'; RequireToken = $false; Generated = $false; Global = $true; Example = 'lz-azl.tfstate' }
        @{ Type = 'container'; Template = $null; Description = 'Blob container name (3-63, lowercase, digits, hyphens)'; MinLength = 3; MaxLength = 63; Regex = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; RequireToken = $false; Generated = $false; Global = $true; Example = 'tfstate' }
        @{ Type = 'imgver'; Template = $null; Description = 'Gallery image version (semver)'; MaxLength = 32; Regex = '^\d+\.\d+\.\d+$'; RequireToken = $false; Generated = $false; Global = $true; Example = '1.0.0' }
    )

    $registry = [ordered]@{}
    foreach ($raw in $table) {
        $entry = [ordered]@{
            Type                 = $raw.Type
            Template             = $raw.Template
            Description          = $raw.Description
            MinLength            = 1
            MaxLength            = $raw.MaxLength
            Regex                = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
            PurposeOptional      = $false
            PurposeAllowed       = $true
            PurposeCompact       = $false
            PurposeRegex         = '^[a-z0-9]+(-[a-z0-9]+)*$'
            PurposeValidSet      = $null
            DefaultPurpose       = $null
            PurposeIsParentName  = $false
            SuffixMeaning        = $null
            NoConsecutiveHyphens = $false
            RequireToken         = $true
            Generated            = $true
            FixedNames           = $null
            Global               = $false
            Example              = $raw.Example
        }
        foreach ($key in $raw.Keys) {
            $entry[$key] = $raw[$key]
        }
        if ($entry.Template -and ($entry.Template -notlike '*{purpose}*')) {
            $entry.PurposeAllowed = $false
        }
        if ($entry.Template -and ($entry.Template -notlike '*{region}*')) {
            $entry.Global = $true
        }
        $registry[$entry.Type] = $entry
    }

    $script:NIC26NameRegistry = $registry
    return $registry
}
