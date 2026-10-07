function Start-NIC26Sleep {
    <#
    .SYNOPSIS
        Sleep wrapper so tests can mock the wait without changing retry logic.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Waiting changes no state; wrapper exists so Pester can mock it.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, 3600)]
        [double]$Seconds
    )

    if ($Seconds -gt 0) {
        Start-Sleep -Milliseconds ([int][Math]::Ceiling($Seconds * 1000))
    }
}
