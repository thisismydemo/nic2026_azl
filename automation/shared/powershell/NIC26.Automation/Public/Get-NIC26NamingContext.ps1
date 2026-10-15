function Get-NIC26NamingContext {
    <#
    .SYNOPSIS
        Returns the deployment-specific naming values (org, token, region, location, shared tags, secret prefix) from the environment config.
    .DESCRIPTION
        Scripts never carry the organisation, the naming token, the region code or the tag values as literals: they call this
        function with the object returned by Get-NIC26Config and use the result with New-NIC26ResourceName (-Org, -Token,
        -Region) and as the tag map. Values come from the config keys org, token, location_short, location, tags and
        secret_name_prefix; a key the config does not carry falls back to the module defaults (NamingDefaults.psd1 or the
        NIC26_ORG / NIC26_TOKEN / NIC26_REGION variables) for org, token and region only. TagPairs is the same map as key=value strings for az CLI --tags. Tags are returned as an ordered
        dictionary copy; callers may add keys freely.
    .PARAMETER Config
        Object returned by Get-NIC26Config (its 'values' are used) or a dictionary of canonical values.
    .EXAMPLE
        $cfg = Get-NIC26Config -Scope avd
        $ctx = Get-NIC26NamingContext -Config $cfg
        New-NIC26ResourceName -Type dep -Purpose avd-workbook -Org $ctx.Org -Token $ctx.Token
    .OUTPUTS
        System.Management.Automation.PSCustomObject (Org, Token, Region, Location, Tags, TagPairs, SecretNamePrefix, Project)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowNull()]
        [object]$Config
    )

    $values = ConvertTo-NIC26ConfigValues -Config $Config
    $pick = {
        param([string]$Key, [string]$DefaultName)
        if ($values.Contains($Key) -and -not [string]::IsNullOrWhiteSpace([string]$values[$Key])) { return [string]$values[$Key] }
        if ($DefaultName) { return (Get-NIC26NamingDefault -Name $DefaultName) }
        return ''
    }
    $tags = [ordered]@{}
    if ($values.Contains('tags') -and $values['tags'] -is [System.Collections.IDictionary]) {
        foreach ($key in $values['tags'].Keys) { $tags[[string]$key] = [string]$values['tags'][$key] }
    }
    $project = if ($tags.Contains('project')) { [string]$tags['project'] } else { '' }

    return [pscustomobject]@{
        Org              = (& $pick 'org' 'Org')
        Token            = (& $pick 'token' 'Token')
        Region           = (& $pick 'location_short' 'Region')
        Location         = (& $pick 'location' '')
        Tags             = $tags
        TagPairs         = @($tags.Keys | ForEach-Object { "$_=$($tags[$_])" })
        SecretNamePrefix = (& $pick 'secret_name_prefix' '')
        Project          = $project
    }
}
