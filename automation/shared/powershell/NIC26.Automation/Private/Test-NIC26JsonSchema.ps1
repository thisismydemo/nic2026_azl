function Test-NIC26JsonSchema {
    <#
    .SYNOPSIS
        Validates a dictionary against a JSON Schema (draft 2020-12) file with Test-Json; throws a readable error on failure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Object,

        [Parameter(Mandatory)]
        [string]$SchemaFile,

        [Parameter()]
        [string]$Subject = 'object'
    )

    if (-not (Test-Path -LiteralPath $SchemaFile -PathType Leaf)) {
        throw "Schema file not found: $SchemaFile"
    }

    $json = $Object | ConvertTo-Json -Depth 100 -Compress
    $schemaErrors = $null
    $isValid = Test-Json -Json $json -SchemaFile $SchemaFile -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if ($isValid) {
        return $true
    }

    $messages = @()
    foreach ($schemaError in @($schemaErrors)) {
        $messages += $schemaError.Exception.Message
        if ($schemaError.Exception.PSObject.Properties['InnerException'] -and $schemaError.Exception.InnerException) {
            $messages += $schemaError.Exception.InnerException.Message
        }
    }
    $detail = ($messages | Where-Object { $_ } | Select-Object -Unique) -join [Environment]::NewLine
    throw "$Subject failed schema validation against '$(Split-Path -Path $SchemaFile -Leaf)':$([Environment]::NewLine)$detail"
}
