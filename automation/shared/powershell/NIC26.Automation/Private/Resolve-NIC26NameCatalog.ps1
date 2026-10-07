function Resolve-NIC26NameCatalog {
    <#
    .SYNOPSIS
        Resolves a manifest's names: catalog to concrete names with New-NIC26ResourceName (CONTRACT.md section 10).
    .DESCRIPTION
        Supported catalog entry shapes (solution.schema.json nameSpec):
          { type, purpose?, instance?, region?, suffix?, org? }          generated name
          { type: peer|vnetpeering|peering, from, to }                   peer-<from>-to-<to>; from/to are catalog keys or literals
          { type: nic|osdisk|datadisk|vhd|bmc, parent, instance? }       parent is the catalog key (or literal name) of the VM/node
          { type: netbios, purpose }                                     computer names <= 15 (nic26-jmp-01)
          { type: <exempt type>, fixed|name: <value>, exempt: true }     Azure-fixed names: pdnszone/pdns, fixedsubnet, imgver,
                                                                         tfstate, container; unknown types need exempt: true
          { ..., reserved: true }                                        metadata only: the name is resolved like any other
        Org, token and region default to the config values org / token / location_short when present. Entries that
        reference other keys are resolved after their dependencies. Every name is validated; any violation fails
        the conversion with all problems listed.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Collections.IDictionary]$Catalog,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Values
    )

    $names = [ordered]@{}
    if ($null -eq $Catalog -or $Catalog.Count -eq 0) {
        return $names
    }

    # Config values win; the module defaults are consulted only for a value the config does not carry.
    $defaults = @{}
    if ($Values.Contains('org') -and $Values['org']) { $defaults.Org = [string]$Values['org'] } else { $defaults.Org = Get-NIC26NamingDefault -Name Org }
    if ($Values.Contains('token') -and $Values['token']) { $defaults.Token = [string]$Values['token'] } else { $defaults.Token = Get-NIC26NamingDefault -Name Token }
    if ($Values.Contains('location_short') -and $Values['location_short']) { $defaults.Region = [string]$Values['location_short'] } else { $defaults.Region = Get-NIC26NamingDefault -Name Region }

    $registry = Get-NIC26NameRegistry
    $failures = [System.Collections.Generic.List[string]]::new()
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Catalog.Keys) { $pending.Add([string]$key) }

    $referenceKeys = @('from', 'to', 'parent')
    $resolveReference = {
        param([string]$Reference)
        if ($Catalog.Contains($Reference)) {
            if ($names.Contains($Reference)) { return [string]$names[$Reference] }
            return $null
        }
        return $Reference
    }

    while ($pending.Count -gt 0) {
        $progress = $false
        foreach ($key in @($pending)) {
            $spec = $Catalog[$key]
            if ($spec -isnot [System.Collections.IDictionary]) {
                $failures.Add("names.$key must be a mapping { type, purpose, ... }")
                $pending.Remove($key) | Out-Null
                $progress = $true
                continue
            }

            # Defer until referenced catalog keys are resolved.
            $waiting = $false
            foreach ($refKey in $referenceKeys) {
                if ($spec.Contains($refKey) -and $null -ne $spec[$refKey]) {
                    $reference = [string]$spec[$refKey]
                    if ($Catalog.Contains($reference) -and -not $names.Contains($reference)) {
                        if ($reference -eq $key) {
                            $failures.Add("names.$key references itself through '$refKey'")
                            $pending.Remove($key) | Out-Null
                            $progress = $true
                        }
                        $waiting = $true
                        break
                    }
                }
            }
            if ($waiting) { continue }

            $pending.Remove($key) | Out-Null
            $progress = $true

            $rawType = ''
            if ($spec.Contains('type') -and $null -ne $spec['type']) { $rawType = [string]$spec['type'] }
            $typeKey = Resolve-NIC26NameType -Type $rawType
            $isExemptFlag = $spec.Contains('exempt') -and [bool]$spec['exempt']
            $fixedValue = $null
            if ($spec.Contains('fixed') -and $null -ne $spec['fixed']) { $fixedValue = [string]$spec['fixed'] }
            elseif ($spec.Contains('name') -and $null -ne $spec['name']) { $fixedValue = [string]$spec['name'] }

            try {
                if ($null -ne $fixedValue) {
                    if ([string]::IsNullOrWhiteSpace($fixedValue)) {
                        throw 'fixed name is empty'
                    }
                    if ($typeKey) {
                        $entry = $registry[$typeKey]
                        if ($entry.Generated -and -not $isExemptFlag) {
                            throw "type '$typeKey' is generated; remove 'fixed'/'name' and use purpose/instance/region/suffix (or add exempt: true for an Azure-fixed name)"
                        }
                        if (-not $entry.Generated) {
                            $check = Test-NIC26ResourceName -Name $fixedValue -Type $typeKey -Token $defaults.Token -Detailed
                            if (-not $check.IsValid) {
                                throw "fixed name '$fixedValue' is invalid for type '$typeKey': $($check.Reasons -join '; ')"
                            }
                        }
                    }
                    elseif (-not $isExemptFlag) {
                        throw "unknown type '$rawType' for fixed name '$fixedValue'; add 'exempt: true' for an Azure-fixed name or use a registry type"
                    }
                    if ($fixedValue -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
                        throw "fixed name '$fixedValue' contains characters outside letters, digits, '.', '_', '/', '-'"
                    }
                    $names[$key] = $fixedValue
                    continue
                }

                if (-not $typeKey) {
                    throw "unknown type '$rawType' (known: $($registry.Keys -join ', '))"
                }

                $arguments = @{
                    Type   = $typeKey
                    Org    = $defaults.Org
                    Token  = $defaults.Token
                    Region = $defaults.Region
                }
                if ($spec.Contains('purpose') -and $null -ne $spec['purpose'] -and [string]$spec['purpose'] -ne '') { $arguments.Purpose = [string]$spec['purpose'] }
                if ($spec.Contains('instance') -and $null -ne $spec['instance']) { $arguments.Instance = [int]$spec['instance'] }
                if ($spec.Contains('region') -and $spec['region']) { $arguments.Region = [string]$spec['region'] }
                if ($spec.Contains('suffix') -and $null -ne $spec['suffix'] -and [string]$spec['suffix'] -ne '') { $arguments.Suffix = [string]$spec['suffix'] }
                if ($spec.Contains('org') -and $spec['org']) { $arguments.Org = [string]$spec['org'] }

                if ($spec.Contains('parent') -and $null -ne $spec['parent']) {
                    $parentName = & $resolveReference ([string]$spec['parent'])
                    if (-not $parentName) { throw "parent '$($spec['parent'])' did not resolve" }
                    $arguments.Purpose = $parentName
                }
                if ($spec.Contains('from') -or $spec.Contains('to')) {
                    if (-not ($spec.Contains('from') -and $spec.Contains('to'))) { throw "peering entries need both 'from' and 'to'" }
                    $fromName = & $resolveReference ([string]$spec['from'])
                    $toName = & $resolveReference ([string]$spec['to'])
                    if (-not $fromName -or -not $toName) { throw "from/to '$($spec['from'])'/'$($spec['to'])' did not resolve" }
                    $arguments.Purpose = $fromName
                    $arguments.Suffix = $toName
                }

                $names[$key] = New-NIC26ResourceName @arguments
            }
            catch {
                $failures.Add("names.$key -> $($_.Exception.Message)")
            }
        }

        if (-not $progress) {
            $failures.Add("names catalog has unresolved or circular references among: $($pending -join ', ')")
            break
        }
    }

    if ($failures.Count -gt 0) {
        throw "Name catalog resolution failed:$([Environment]::NewLine)$($failures -join [Environment]::NewLine)"
    }
    return $names
}
