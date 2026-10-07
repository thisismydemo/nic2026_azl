function Merge-NIC26Hashtable {
    <#
    .SYNOPSIS
        Deep-merges two dictionaries; keys from -Overlay win. Nested dictionaries merge recursively, lists are replaced.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Collections.IDictionary]$Base,

        [Parameter(Mandatory)]
        [AllowNull()]
        [System.Collections.IDictionary]$Overlay
    )

    $result = [ordered]@{}
    if ($null -ne $Base) {
        foreach ($key in $Base.Keys) {
            $result[$key] = Copy-NIC26Value -Value $Base[$key]
        }
    }
    if ($null -ne $Overlay) {
        foreach ($key in $Overlay.Keys) {
            $incoming = $Overlay[$key]
            if ($result.Contains($key) -and ($result[$key] -is [System.Collections.IDictionary]) -and ($incoming -is [System.Collections.IDictionary])) {
                $result[$key] = Merge-NIC26Hashtable -Base $result[$key] -Overlay $incoming
            }
            else {
                $result[$key] = Copy-NIC26Value -Value $incoming
            }
        }
    }
    return $result
}
