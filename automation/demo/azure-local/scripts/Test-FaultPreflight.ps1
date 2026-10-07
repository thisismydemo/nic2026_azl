#Requires -Version 7.0
<#
.SYNOPSIS
    Read-only preflight shared by the three fault helpers (outline §4.2): decides whether the 2-node cluster can take
    ONE fault right now, and refuses otherwise.
.DESCRIPTION
    Collects one health snapshot (Get-DemoClusterHealth over PowerShell remoting, or -Health for a pre-collected one)
    and evaluates the refusal conditions:
      - no other fault is active (fault lock registry) unless -AllowActiveFault names the one being undone;
      - every node Up; the target node exists;
      - storage pool Healthy; every virtual disk Healthy; no storage/repair job running; no Major/Critical storage fault;
      - every Network ATC intent ConfigurationStatus Success; witness online.
    Per fault: Drive requires >= 2 healthy data drives on the target node; NodePowerOff requires the OTHER node Up,
    witness online and every physical disk Healthy ("never stack faults on a 2-node cluster"). Prints the red/green
    table and returns {Passed, Checks, Health}.
.PARAMETER Fault
    Drive | IntentDrift | NodePowerOff
.PARAMETER NodeName
    Target node of the fault.
.PARAMETER ComputerName
    Remoting target (default: the cluster FQDN from the environment file).
.PARAMETER Health
    A pre-collected snapshot (tests / reuse); skips remoting.
.PARAMETER AllowActiveFault
    The fault lock that may exist (used by the Undo scripts).
.PARAMETER Quiet
    Do not print the table.
.EXAMPLE
    $pre = ./Test-FaultPreflight.ps1 -Fault Drive -NodeName <node name>
    if (-not $pre.Passed) { throw 'refused' }
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Drive', 'IntentDrift', 'NodePowerOff')]
    [string] $Fault,

    [Parameter(Mandatory)]
    [string] $NodeName,

    [Parameter()]
    [string] $ComputerName,

    [Parameter()]
    [object] $Health,

    [Parameter()]
    [ValidateSet('', 'Drive', 'IntentDrift', 'NodePowerOff')]
    [string] $AllowActiveFault = '',

    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$demoCommon = Join-Path $PSScriptRoot '..' '..' 'shared' 'scripts' 'DemoCommon.psd1'
if (-not (Get-Module -Name DemoCommon)) { Import-Module $demoCommon -Global }

if (-not $ComputerName) {
    $config = Get-DemoConfig -Scope 'azure-local'
    Initialize-DemoScreenHygiene -Config $config
    $ComputerName = (Get-DemoAzlNameSet -Config $config).RemotingTarget
}
if ($null -eq $Health) { $Health = Get-DemoClusterHealth -ComputerName $ComputerName }

$checks = [System.Collections.Generic.List[pscustomobject]]::new()
$section = "preflight/$Fault"

# other faults
$locks = @(Get-DemoFaultLock -Scope 'azure-local' | Where-Object { $_.Fault -ne $AllowActiveFault })
$checks.Add((New-DemoCheck -Section $section -Name 'No other fault active' -Passed ($locks.Count -eq 0) -Detail $(if ($locks.Count -eq 0) { 'fault lock registry clean' } else { (@($locks | ForEach-Object { "$($_.Fault) on $($_.Target) since $($_.StartedAt)" }) -join '; ') + ' -> run its Undo first' })))

# nodes
$nodes = @($Health.Nodes)
$downNodes = @($nodes | Where-Object { $_.State -ne 'Up' })
$targetNode = @($nodes | Where-Object { $_.Name -eq $NodeName })
$checks.Add((New-DemoCheck -Section $section -Name 'Target node exists' -Passed ($targetNode.Count -eq 1) -Detail $NodeName))
$checks.Add((New-DemoCheck -Section $section -Name 'All nodes Up' -Passed ($downNodes.Count -eq 0 -and $nodes.Count -ge 2) -Detail ((@($nodes | ForEach-Object { "$($_.Name)=$($_.State)" })) -join ', ')))

# storage
$pool = $Health.Pool
$poolOk = ($null -ne $pool -and $pool.HealthStatus -eq 'Healthy' -and $pool.OperationalStatus -eq 'OK')
$checks.Add((New-DemoCheck -Section $section -Name 'Storage pool Healthy/OK' -Passed $poolOk -Detail $(if ($pool) { "$($pool.FriendlyName): $($pool.HealthStatus)/$($pool.OperationalStatus)" } else { 'no pool found' })))
$vdisks = @($Health.VirtualDisks)
$badVdisks = @($vdisks | Where-Object { $_.HealthStatus -ne 'Healthy' })
$checks.Add((New-DemoCheck -Section $section -Name 'All virtual disks Healthy' -Passed ($badVdisks.Count -eq 0 -and $vdisks.Count -gt 0) -Detail $(if ($badVdisks.Count -eq 0) { "$($vdisks.Count) volume(s)" } else { (@($badVdisks | ForEach-Object { "$($_.FriendlyName)=$($_.HealthStatus)/$($_.OperationalStatus)" }) -join ', ') })))
$jobs = @($Health.StorageJobs)
$checks.Add((New-DemoCheck -Section $section -Name 'No storage/repair job running' -Passed ($jobs.Count -eq 0) -Detail $(if ($jobs.Count -eq 0) { 'none' } else { (@($jobs | ForEach-Object { "$($_.Name) $($_.JobState) $($_.PercentComplete)%" }) -join ', ') + ' -> REFUSED while a repair runs' })))
$faults = @($Health.Faults | Where-Object { $_.Severity -in @('Major', 'Critical', 'Fatal') })
$checks.Add((New-DemoCheck -Section $section -Name 'No storage fault reported' -Passed ($faults.Count -eq 0) -Detail $(if ($faults.Count -eq 0) { 'Debug-StorageSubSystem clean' } else { (@($faults | ForEach-Object { "$($_.Severity): $($_.FaultType)" }) -join '; ') })))

# intents
$intents = @($Health.Intents)
$badIntents = @($intents | Where-Object { $_.ConfigurationStatus -ne 'Success' })
$checks.Add((New-DemoCheck -Section $section -Name 'All Network ATC intents Success' -Passed ($badIntents.Count -eq 0 -and $intents.Count -gt 0) -Detail $(if ($badIntents.Count -eq 0) { "$($intents.Count) intent/host rows" } else { (@($badIntents | ForEach-Object { "$($_.IntentName)@$($_.Host)=$($_.ConfigurationStatus)" }) -join ', ') })))

# witness
$witnessOk = ($null -ne $Health.Quorum -and $Health.Quorum.WitnessState -eq 'Online')
$checks.Add((New-DemoCheck -Section $section -Name 'Cloud witness Online' -Passed $witnessOk -Detail $(if ($Health.Quorum) { "$($Health.Quorum.WitnessName): $($Health.Quorum.WitnessState)" } else { 'unknown' })))

switch ($Fault) {
    'Drive' {
        $nodeDisks = @($Health.PhysicalDisks | Where-Object { $_.Node -eq $NodeName -and $_.Usage -in @('Auto-Select', 'AutoSelect', 'Data') })
        $healthyNodeDisks = @($nodeDisks | Where-Object { $_.HealthStatus -eq 'Healthy' })
        $checks.Add((New-DemoCheck -Section $section -Name 'Target node has >= 2 healthy data drives' -Passed ($healthyNodeDisks.Count -ge 2 -and $healthyNodeDisks.Count -eq $nodeDisks.Count) -Detail "$($healthyNodeDisks.Count)/$($nodeDisks.Count) healthy on $NodeName"))
        $mirror2 = @($vdisks | Where-Object { $_.ResiliencySettingName -eq 'Mirror' })
        $checks.Add((New-DemoCheck -Section $section -Name 'Volumes are mirrored (one fault tolerated)' -Passed ($mirror2.Count -eq $vdisks.Count -and $vdisks.Count -gt 0) -Detail "$($mirror2.Count)/$($vdisks.Count) Mirror"))
    }
    'IntentDrift' {
        $hostRows = @($intents | Where-Object { $_.Host -eq $NodeName })
        $checks.Add((New-DemoCheck -Section $section -Name 'Target node has intent status rows' -Passed ($hostRows.Count -gt 0) -Detail "$($hostRows.Count) on $NodeName"))
    }
    'NodePowerOff' {
        $others = @($nodes | Where-Object { $_.Name -ne $NodeName })
        $otherUp = @($others | Where-Object { $_.State -eq 'Up' })
        $checks.Add((New-DemoCheck -Section $section -Name 'The other node is Up' -Passed ($others.Count -ge 1 -and $otherUp.Count -eq $others.Count) -Detail ((@($others | ForEach-Object { "$($_.Name)=$($_.State)" })) -join ', ')))
        $allDisks = @($Health.PhysicalDisks)
        $badDisks = @($allDisks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        $checks.Add((New-DemoCheck -Section $section -Name 'Every physical disk Healthy (no degraded storage before a node loss)' -Passed ($badDisks.Count -eq 0 -and $allDisks.Count -gt 0) -Detail "$($allDisks.Count - $badDisks.Count)/$($allDisks.Count) healthy"))
        $checks.Add((New-DemoCheck -Section $section -Name 'Witness required for 2-node node loss' -Passed $witnessOk -Detail 'quorum survives only with the witness'))
    }
}

$result = [pscustomobject]@{
    Fault   = $Fault
    Node    = $NodeName
    Passed  = ((Get-DemoCheckExitCode -Check $checks.ToArray()) -eq 0)
    Checks  = $checks.ToArray()
    Health  = $Health
}
if (-not $Quiet) {
    Write-DemoCheckTable -Check $result.Checks -Title ('Fault preflight: {0} on {1} -> {2}' -f $Fault, $NodeName, $(if ($result.Passed) { 'GO' } else { 'REFUSED' }))
}
return $result
