function Test-NIC26ResourceName {
    <#
    .SYNOPSIS
        Validates a name against the naming-standard rules for a registry type.
    .DESCRIPTION
        Checks length, allowed characters, the structural pattern of the type, Key Vault's no-consecutive-hyphens rule,
        fixed-name membership, and that the name contains the lab token (nic26) unless the registry marks the type
        exempt (fixed subnets, private DNS zones, image versions). Returns $true/$false; with -Detailed returns an object
        with the reasons.
    .PARAMETER Name
        The name to test.
    .PARAMETER Type
        Registry type abbreviation (see New-NIC26ResourceName).
    .PARAMETER Token
        Lab token that must be present (default nic26).
    .PARAMETER Detailed
        Return [pscustomobject] { Name, Type, IsValid, Length, Reasons } instead of a boolean.
    .EXAMPLE
        Test-NIC26ResourceName -Name 'kv-iic-nic26-ops-eus-01' -Type kv      # True
    .EXAMPLE
        Test-NIC26ResourceName -Name 'GatewaySubnet' -Type fixedsubnet -Detailed
    .OUTPUTS
        System.Boolean or System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$Type,

        [Parameter()]
        [ValidatePattern('^[a-z0-9]{3,8}$')]
        [string]$Token = (Get-NIC26NamingDefault -Name Token),

        [Parameter()]
        [switch]$Detailed
    )

    process {
        $reasons = [System.Collections.Generic.List[string]]::new()
        $registry = Get-NIC26NameRegistry
        $typeKey = Resolve-NIC26NameType -Type $Type
        $entry = $null
        if ($typeKey) {
            $entry = $registry[$typeKey]
        }
        else {
            $typeKey = $Type.Trim().ToLowerInvariant()
            $reasons.Add("unknown type '$Type' (known: $($registry.Keys -join ', '))")
        }

        if ([string]::IsNullOrWhiteSpace($Name)) {
            $reasons.Add('name is empty')
        }
        elseif ($entry) {
            if ($Name.Length -lt $entry.MinLength -or $Name.Length -gt $entry.MaxLength) {
                $reasons.Add("length $($Name.Length) is outside $($entry.MinLength)-$($entry.MaxLength) for type '$typeKey'")
            }
            if ($entry.Regex -and ($Name -cnotmatch $entry.Regex)) {
                $reasons.Add("contains characters not allowed for type '$typeKey' (rule $($entry.Regex))")
            }
            if ($entry.NoConsecutiveHyphens -and ($Name -match '--')) {
                $reasons.Add('contains consecutive hyphens')
            }
            if ($entry.RequireToken -and ($Name.ToLowerInvariant() -notlike "*$($Token.ToLowerInvariant())*")) {
                $reasons.Add("does not contain the lab token '$Token' (naming standard section 1)")
            }
            if ($entry.FixedNames -and ($Name -cnotin $entry.FixedNames)) {
                $reasons.Add("is not one of the fixed names: $($entry.FixedNames -join ', ')")
            }
            $structure = Get-NIC26NameStructureRegex -Entry $entry -Token $Token
            if ($structure -and ($Name -cnotmatch $structure)) {
                $reasons.Add("does not match the pattern '$($entry.Template)' for type '$typeKey' (example: $($entry.Example))")
            }
        }

        $isValid = ($reasons.Count -eq 0)
        if (-not $isValid) {
            Write-Verbose "Name '$Name' (type '$Type') is invalid: $($reasons -join '; ')"
        }
        if ($Detailed) {
            return [pscustomobject]@{
                Name    = $Name
                Type    = $typeKey
                IsValid = $isValid
                Length  = $Name.Length
                Reasons = $reasons.ToArray()
            }
        }
        return $isValid
    }
}
