#Requires -Version 7.0
<#
.SYNOPSIS
    Prepares the presenter console before a live beat or a recording: guards, hygiene, title, checklist. Changes nothing remote.
.DESCRIPTION
    Refuses if a transcript is active (nothing on this console may be transcribed during a demo), loads the
    screen-hygiene terms from the environment config, sets the window title to an IIC label, clears the screen,
    and prints the pre-beat checklist (fault locks clean, recording running, fallback clip path). -Stop removes the
    marker and resets the title. The recording itself is done by the capture tool, not by this script.
.PARAMETER Session
    azure-local | avd
.PARAMETER Beat
    Short label of the beat (e.g. '4.2 drive fault') for the title and the marker.
.PARAMETER Stop
    End the demo-screen mode.
.EXAMPLE
    ./Start-DemoRecording.ps1 -Session azure-local -Beat '4.2 drive fault'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('azure-local', 'avd')]
    [string] $Session,

    [Parameter()]
    [string] $Beat = '',

    [switch] $Stop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

$marker = Join-Path (Get-DemoStateRoot) 'demo-screen.json'

if ($Stop) {
    if ($PSCmdlet.ShouldProcess($marker, 'End demo-screen mode')) {
        if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }
        $env:NIC26_DEMO_SCREEN = $null
        $Host.UI.RawUI.WindowTitle = 'PowerShell 7'
    }
    Write-DemoScreen -InputObject 'Demo-screen mode ended.' -Raw
    return
}

if (Test-DemoTranscriptActive) {
    throw 'A transcript is active on this console. Run Stop-Transcript before any demo beat (nothing on the presenter screen is transcribed).'
}

$config = Get-DemoConfig -Scope $Session
Initialize-DemoScreenHygiene -Config $config

if ($PSCmdlet.ShouldProcess($marker, 'Start demo-screen mode')) {
    $env:NIC26_DEMO_SCREEN = '1'
    $Host.UI.RawUI.WindowTitle = ('IIC - NIC 2026 - {0}{1}' -f $Session, $(if ($Beat) { " - $Beat" } else { '' }))
    [pscustomobject]@{ Session = $Session; Beat = $Beat; StartedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
    Clear-Host
}

$locks = @(Get-DemoFaultLock -Scope all)
$checklist = @(
    New-DemoCheck -Section 'console' -Name 'Transcript off' -Passed $true
    New-DemoCheck -Section 'console' -Name 'Screen-hygiene terms loaded' -Passed ((Get-DemoHiddenTermList).Count -gt 0) -Detail ('{0} term(s) + built-in prefixes + GUIDs' -f (Get-DemoHiddenTermList).Count)
    New-DemoCheck -Section 'state' -Name 'No fault lock active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target)" }) -join '; ') })
    New-DemoCheck -Section 'recording' -Name 'Capture tool recording (manual)' -Skipped -Detail 'start OBS/recorder now; fallback clip in presentation/<session>/fallback/'
)
Write-DemoCheckTable -Check $checklist -Title ('Demo screen ready: {0} {1}' -f $Session, $Beat)
