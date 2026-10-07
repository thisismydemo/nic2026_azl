function ConvertTo-NIC26BicepLiteral {
    <#
    .SYNOPSIS
        Serializes a value as a Bicep literal (strings, numbers, booleans, null, arrays, objects) for .bicepparam files.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter()]
        [ValidateRange(0, 64)]
        [int]$Indent = 0
    )

    $pad = ' ' * ($Indent * 2)
    $padInner = ' ' * (($Indent + 1) * 2)

    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte]) {
        return $Value.ToString([cultureinfo]::InvariantCulture)
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        # Bicep has no float literal; keep whole numbers as int, otherwise emit a string.
        if ([Math]::Floor([double]$Value) -eq [double]$Value) {
            return ([long]$Value).ToString([cultureinfo]::InvariantCulture)
        }
        return "'" + ([double]$Value).ToString([cultureinfo]::InvariantCulture) + "'"
    }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) {
            return '{}'
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('{')
        foreach ($key in $Value.Keys) {
            $keyText = [string]$key
            if ($keyText -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
                $keyText = "'" + ($keyText -replace '\\', '\\' -replace "'", "\'") + "'"
            }
            $lines.Add("$padInner$keyText`: $(ConvertTo-NIC26BicepLiteral -Value $Value[$key] -Indent ($Indent + 1))")
        }
        $lines.Add("$pad}")
        return ($lines -join "`n")
    }
    if (($Value -is [System.Collections.IEnumerable]) -and ($Value -isnot [string])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return '[]'
        }
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add('[')
        foreach ($item in $items) {
            $lines.Add("$padInner$(ConvertTo-NIC26BicepLiteral -Value $item -Indent ($Indent + 1))")
        }
        $lines.Add("$pad]")
        return ($lines -join "`n")
    }

    $text = [string]$Value
    $escaped = $text -replace '\\', '\\' -replace "'", "\'" -replace '\$\{', '\${' -replace "`r", '\r' -replace "`n", '\n' -replace "`t", '\t'
    return "'" + $escaped + "'"
}
