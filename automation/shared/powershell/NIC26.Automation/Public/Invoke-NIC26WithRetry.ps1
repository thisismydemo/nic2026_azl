function Invoke-NIC26WithRetry {
    <#
    .SYNOPSIS
        Runs a script block with bounded exponential backoff (default up to 5 minutes) for retryable errors such as RBAC propagation.
    .DESCRIPTION
        Retries only when the error message matches -RetryOn (default: 403/Forbidden/Unauthorized/RBAC/429/timeouts).
        Any other error is rethrown immediately. The delay doubles from -InitialSeconds up to -MaxDelaySeconds and the
        total wait never exceeds -MaxMinutes; the last error is rethrown when the budget is exhausted. Only the attempt
        number, activity label and a trimmed error message are logged - never values.
    .PARAMETER ScriptBlock
        The work to run. Its output is returned.
    .PARAMETER MaxMinutes
        Total retry budget in minutes (default 5; the contract's RBAC-propagation bound).
    .PARAMETER InitialSeconds
        First delay (default 2); doubles each attempt.
    .PARAMETER MaxDelaySeconds
        Cap for a single delay (default 60).
    .PARAMETER RetryOn
        Regex matched against the exception message and FullyQualifiedErrorId.
    .PARAMETER Activity
        Label used in log lines.
    .PARAMETER ArgumentList
        Arguments passed to the script block.
    .EXAMPLE
        Invoke-NIC26WithRetry -Activity 'read secret' -ScriptBlock { Get-AzKeyVaultSecret -VaultName $v -Name $n }
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [ValidateRange(0, 120)]
        [double]$MaxMinutes = 5,

        [Parameter()]
        [ValidateRange(0, 300)]
        [double]$InitialSeconds = 2,

        [Parameter()]
        [ValidateRange(0, 600)]
        [double]$MaxDelaySeconds = 60,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$RetryOn = '(?i)\b403\b|forbidden|unauthorized|\brbac\b|does not have .*permission|not authorized|caller .* access|\b429\b|too many requests|timed? ?out|temporar(y|ily)|try again|retry later|service unavailable|\b503\b',

        [Parameter()]
        [string]$Activity = 'operation',

        [Parameter()]
        [object[]]$ArgumentList = @()
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
    $delay = $InitialSeconds
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $output = & $ScriptBlock @ArgumentList
            if ($attempt -gt 1) {
                Write-NIC26Log -Message "'$Activity' succeeded on attempt $attempt" -Level Verbose
            }
            return $output
        }
        catch {
            $errorText = @($_.Exception.Message, $_.FullyQualifiedErrorId) -join ' '
            $inner = $_.Exception.InnerException
            while ($inner) {
                $errorText += ' ' + $inner.Message
                $inner = $inner.InnerException
            }
            if ($errorText -notmatch $RetryOn) {
                throw
            }
            $now = [DateTime]::UtcNow
            if ($now.AddSeconds($delay) -gt $deadline) {
                Write-NIC26Log -Message "'$Activity' failed on attempt $attempt and the retry budget of $MaxMinutes minute(s) is exhausted" -Level Warning
                throw
            }
            $summary = $_.Exception.Message
            if ($summary.Length -gt 160) {
                $summary = $summary.Substring(0, 160) + '...'
            }
            Write-NIC26Log -Message "'$Activity' attempt $attempt failed with a retryable error ($summary); waiting $delay s" -Level Warning
            Start-NIC26Sleep -Seconds $delay
            $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        }
    }
}
