function Write-NIC26Log {
    <#
    .SYNOPSIS
        Writes a timestamped log line (names and IDs only) to the matching PowerShell stream and, optionally, a log file.
    .DESCRIPTION
        Levels map to streams: Info -> Information (always shown), Warning -> Warning, Error -> Error (non-terminating),
        Verbose -> Verbose, Debug -> Debug. Never uses Write-Host. Anything passed with -Sensitive is refused: the
        message is replaced by a redaction marker and the original text is not written anywhere. Log files hold the
        same lines; set $env:NIC26_LOG_FILE or -LogFile to append.
    .PARAMETER Message
        Text to log. Names, IDs, counts, paths - never secret values.
    .PARAMETER Level
        Debug | Verbose | Info | Warning | Error (default Info).
    .PARAMETER Sensitive
        Declares that the message contains a secret or token; the function refuses to log it.
    .PARAMETER Source
        Optional component label (for example the calling solution).
    .PARAMETER LogFile
        Optional file to append to (default $env:NIC26_LOG_FILE).
    .EXAMPLE
        Write-NIC26Log -Message "Resolved 12 inputs for lz-avd"
    .EXAMPLE
        Write-NIC26Log -Message $token -Sensitive    # writes only a redaction marker
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Debug', 'Verbose', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter()]
        [switch]$Sensitive,

        [Parameter()]
        [string]$Source,

        [Parameter()]
        [string]$LogFile = $env:NIC26_LOG_FILE
    )

    if ($Sensitive) {
        $Message = '<redacted: a value marked -Sensitive is never logged>'
    }

    $sourceText = ''
    if ($Source) {
        $sourceText = " [$Source]"
    }
    $line = '{0} [{1}] NIC26{2} {3}' -f [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Level.ToUpperInvariant(), $sourceText, $Message

    switch ($Level) {
        'Debug' { Write-Debug -Message $line }
        'Verbose' { Write-Verbose -Message $line }
        'Warning' { Write-Warning -Message $line }
        'Error' {
            # Non-terminating by default (the module scope runs with $ErrorActionPreference = 'Stop'); the caller's -ErrorAction wins.
            $errorAction = 'Continue'
            if ($PSBoundParameters.ContainsKey('ErrorAction')) {
                $errorAction = $PSBoundParameters['ErrorAction']
            }
            Write-Error -Message $line -ErrorAction $errorAction
        }
        default { Write-Information -MessageData $line -Tags 'NIC26' -InformationAction Continue }
    }

    if ($LogFile) {
        $directory = Split-Path -Path $LogFile -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -Path $directory -ItemType Directory -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8
    }
}
