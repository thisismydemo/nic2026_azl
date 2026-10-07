function Invoke-NIC26ArmDeployment {
    <#
    .SYNOPSIS
        Previews or runs a subscription-scoped ARM/Bicep deployment through a compact REST request.
    .DESCRIPTION
        New-AzSubscriptionDeployment sends the template larger than it is, so a landing-zone template with several inlined
        Azure Verified Modules (about 2 MB compact) is refused with RequestContentTooLarge (4 MB). This function compiles
        a .bicep file (az bicep build), merges the parameter file with the overrides and posts a compact body with
        Invoke-AzRestMethod: POST .../whatIf for -Preview, PUT for a real deployment. It polls until the operation ends
        and returns the outcome. Secure values in -ParameterOverrides are used only inside the request body; they are never
        written to a stream, a file or an error message.
    .PARAMETER Preview
        Run what-if instead of deploying.
    .EXAMPLE
        Invoke-NIC26ArmDeployment -SubscriptionId $sub -Name lz -Location eastus -TemplateFile main.bicep -ParameterFile p.json -Preview
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Location,
        [Parameter(Mandatory)][string] $TemplateFile,
        [Parameter(Mandatory)][string] $ParameterFile,
        [hashtable] $ParameterOverrides = @{},
        [switch] $Preview
    )

    # Reads a key from a dictionary or an object, or returns $null.
    function Get-NIC26Field {
        param($Object, [string] $Key)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Key) ? $Object[$Key] : $null }
        return $Object.PSObject.Properties[$Key] ? $Object.$Key : $null
    }

    # Reads one response header by name, case-insensitively.
    function Get-NIC26Header {
        param($Headers, [string] $Key)
        if ($null -eq $Headers) { return $null }
        foreach ($h in $Headers.GetEnumerator()) {
            if ([string]::Equals([string]$h.Key, $Key, [StringComparison]::OrdinalIgnoreCase)) { return @($h.Value)[0] }
        }
        return $null
    }

    # Builds the error text from the service error code, message and nested details, never from the request body.
    function Get-NIC26ArmFailureMessage {
        param($Data, [string] $Context)
        $properties = Get-NIC26Field $Data 'properties'
        $detail = Get-NIC26Field $Data 'error'
        if ($null -eq $detail) { $detail = Get-NIC26Field $properties 'error' }
        $code = Get-NIC26Field $detail 'code'
        $message = Get-NIC26Field $detail 'message'
        $leaves = [System.Collections.Generic.List[string]]::new()
        $walk = {
            param($node)
            foreach ($d in @(Get-NIC26Field $node 'details')) {
                if ($null -eq $d) { continue }
                if ($null -ne (Get-NIC26Field $d 'details')) { & $walk $d } else { $leaves.Add(('{0}: {1}' -f (Get-NIC26Field $d 'code'), (Get-NIC26Field $d 'message'))) }
            }
        }
        & $walk $detail
        $inner = @($leaves | Select-Object -First 6)
        return ('{0}: {1} - {2}{3}' -f $Context, ($code ?? 'UnknownError'), ($message ?? 'The request or deployment failed.'), ($inner ? (' [' + ($inner -join ' | ') + ']') : ''))
    }

    $templateJson = $null
    switch ([IO.Path]::GetExtension($TemplateFile).ToLowerInvariant()) {
        '.bicep' {
            $errFile = [IO.Path]::GetTempFileName()
            try {
                $lines = @(& az bicep build --file $TemplateFile --stdout 2> $errFile)
                if ($LASTEXITCODE -ne 0) { throw ('Bicep compilation failed: ' + ((Get-Content -LiteralPath $errFile -TotalCount 5) -join ' | ')) }
                $templateJson = $lines -join "`n"
            }
            finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        }
        '.json' { $templateJson = Get-Content -LiteralPath $TemplateFile -Raw }
        default { throw 'TemplateFile must be a .bicep or .json file.' }
    }

    $template = ConvertFrom-Json -InputObject $templateJson -AsHashtable -Depth 100
    $parameterDocument = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ParameterFile -Raw) -AsHashtable -Depth 100
    $params = Get-NIC26Field $parameterDocument 'parameters'
    if ($params -isnot [System.Collections.IDictionary]) { throw 'ParameterFile must contain a parameters object.' }
    foreach ($key in $ParameterOverrides.Keys) {
        $value = $ParameterOverrides[$key]
        if ($value -is [securestring]) { $value = [System.Net.NetworkCredential]::new('', $value).Password }
        $params[$key] = @{ value = $value }
    }

    $body = @{ location = $Location; properties = @{ mode = 'Incremental'; template = $template; parameters = $params } } | ConvertTo-Json -Depth 100 -Compress
    $mode = $Preview ? 'WhatIf' : 'Deploy'
    $resource = "/subscriptions/$SubscriptionId/providers/Microsoft.Resources/deployments/$Name"
    $path = $Preview ? "$resource/whatIf?api-version=2022-09-01" : "${resource}?api-version=2022-09-01"
    Write-Information "$mode request submitted for deployment '$Name'." -InformationAction Continue
    try { $response = Invoke-AzRestMethod -Method ($Preview ? 'POST' : 'PUT') -Path $path -Payload $body -ErrorAction Stop }
    catch { throw "$mode request could not be sent." }

    $deadline = [datetime]::UtcNow.AddMinutes(60)
    $pollUri = $null
    while ($true) {
        $code = [int](Get-NIC26Field $response 'StatusCode')
        $data = [string]::IsNullOrWhiteSpace([string](Get-NIC26Field $response 'Content')) ? @{} : (ConvertFrom-Json -InputObject $response.Content -AsHashtable -Depth 100)
        if ($code -lt 200 -or $code -ge 300) { throw (Get-NIC26ArmFailureMessage $data "$mode request failed (HTTP $code)") }
        $properties = Get-NIC26Field $data 'properties'
        $state = (Get-NIC26Field $properties 'provisioningState') ?? (Get-NIC26Field $data 'status')
        if ($state -eq 'Failed') { throw (Get-NIC26ArmFailureMessage $data "$mode failed") }
        if ($Preview) {
            $again = ($code -eq 202)
            if ($again -and -not $pollUri) {
                $headers = Get-NIC26Field $response 'Headers'
                $pollUri = (Get-NIC26Header $headers 'Location') ?? (Get-NIC26Header $headers 'Azure-AsyncOperation')
                if (-not $pollUri) { throw 'What-if returned HTTP 202 without a Location or Azure-AsyncOperation header.' }
            }
        }
        else { $again = ($code -eq 202 -or $state -in 'Running', 'Accepted') }
        if (-not $again) { break }
        if ([datetime]::UtcNow -ge $deadline) { throw "$mode polling timed out after 60 minutes." }
        Write-Information "$mode is in progress; checking again in 10 seconds." -InformationAction Continue
        Start-Sleep -Seconds 10
        try { $response = $Preview ? (Invoke-AzRestMethod -Method GET -Uri $pollUri -ErrorAction Stop) : (Invoke-AzRestMethod -Method GET -Path $path -ErrorAction Stop) }
        catch { throw "$mode polling request could not be sent." }
    }

    $changes = $null
    $outputs = $null
    if ($Preview) {
        $changes = @(foreach ($c in @(Get-NIC26Field $properties 'changes')) { if ($null -ne $c) { [pscustomobject]@{ ChangeType = Get-NIC26Field $c 'changeType'; ResourceId = Get-NIC26Field $c 'resourceId' } } })
    }
    else {
        $outputs = @{}
        $raw = Get-NIC26Field $properties 'outputs'
        if ($raw -is [System.Collections.IDictionary]) { foreach ($k in $raw.Keys) { $outputs[$k] = Get-NIC26Field $raw[$k] 'value' } }
    }
    Write-Information "$mode succeeded for deployment '$Name'." -InformationAction Continue
    [pscustomobject]@{
        Status        = 'Succeeded'
        Mode          = $mode
        Changes       = $changes
        Outputs       = $outputs
        CorrelationId = (Get-NIC26Field $properties 'correlationId')
    }
}
