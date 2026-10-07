function Test-NIC26TranscriptActive {
    <#
    .SYNOPSIS
        Returns $true when a PowerShell transcript (Start-Transcript) is recording in the current host.
    .DESCRIPTION
        PowerShell exposes no public API for this; the host UI's internal IsTranscribing property is read through
        reflection. If that fails, the conservative answer is $true when $env:NIC26_ASSUME_TRANSCRIPT is set, else $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $ui = $Host.UI
        $type = $ui.GetType()
        while ($null -ne $type) {
            $property = $type.GetProperty('IsTranscribing', [System.Reflection.BindingFlags]'Instance,NonPublic,Public')
            if ($null -ne $property) {
                return [bool]$property.GetValue($ui)
            }
            $type = $type.BaseType
        }
    }
    catch {
        Write-Verbose "Transcript detection via reflection failed: $($_.Exception.Message)"
    }
    return [bool]$env:NIC26_ASSUME_TRANSCRIPT
}
