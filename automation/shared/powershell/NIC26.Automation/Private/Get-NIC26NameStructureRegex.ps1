function Get-NIC26NameStructureRegex {
    <#
    .SYNOPSIS
        Builds the structural regex for a registry entry from its template (used by Test-NIC26ResourceName).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Entry,

        [Parameter()]
        [string]$Token = (Get-NIC26NamingDefault -Name Token)
    )

    if (-not $Entry.Template) {
        return $null
    }

    $purposePattern = '[a-z0-9]+(-[a-z0-9]+)*'
    if ($Entry.PurposeCompact) {
        $purposePattern = '[a-z0-9]+'
    }
    if ($Entry.PurposeValidSet) {
        $purposePattern = '(' + (($Entry.PurposeValidSet | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    }
    elseif ($Entry.PurposeRegex -and $Entry.PurposeRegex -ne '^[a-z0-9]+(-[a-z0-9]+)*$' -and $Entry.PurposeRegex -ne '^[a-z0-9]+$') {
        $purposePattern = $Entry.PurposeRegex.TrimStart('^').TrimEnd('$')
    }

    $template = $Entry.Template
    if ($Entry.PurposeOptional) {
        if ($template -like '*-{purpose}*') {
            $template = $template.Replace('-{purpose}', '{optpurposehyphen}')
        }
        else {
            $template = $template.Replace('{purpose}', '{optpurpose}')
        }
    }

    $parts = [regex]::Split($template, '(\{[a-z]+\})')
    $builder = [System.Text.StringBuilder]::new('^')
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) {
            continue
        }
        switch ($part) {
            '{type}' { $null = $builder.Append([regex]::Escape($Entry.Type)) }
            '{org}' { $null = $builder.Append('[a-z0-9]{2,8}') }
            '{token}' { $null = $builder.Append([regex]::Escape($Token)) }
            '{purpose}' { $null = $builder.Append($purposePattern) }
            '{optpurposehyphen}' { $null = $builder.Append("(-$purposePattern)?") }
            '{optpurpose}' { $null = $builder.Append("($purposePattern)?") }
            '{region}' { $null = $builder.Append('[a-z0-9]{2,8}') }
            '{instance}' { $null = $builder.Append('\d{2}') }
            '{suffix}' { $null = $builder.Append('[a-z0-9]+([.-][a-z0-9]+)*') }
            default { $null = $builder.Append([regex]::Escape($part)) }
        }
    }
    $null = $builder.Append('$')
    return $builder.ToString()
}
