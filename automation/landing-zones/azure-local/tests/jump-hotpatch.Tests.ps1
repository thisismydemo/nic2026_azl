#Requires -Version 7.0
<#
.SYNOPSIS
    Verifies effective jump-server hotpatch inputs after the live ARM rejection.
.NOTES
    Author: Kristopher Turner
    TaskReference: T-3.1.2
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Jump-server hotpatch platform safety' {
    It 'keeps hotpatch enabled and explicitly preserves platform safety checks' {
        $path = Join-Path $PSScriptRoot '../bicep/modules/management.bicep'
        $json = & az bicep build --file $path --stdout
        $LASTEXITCODE | Should -Be 0
        $compiled = ($json -join "`n") | ConvertFrom-Json
        $vm = @($compiled.resources | Where-Object name -EQ 'vm-jump')
        $vm.Count | Should -Be 1
        $vm[0].properties.parameters.enableHotpatching.value | Should -BeTrue
        $vm[0].properties.parameters.bypassPlatformSafetyChecksOnUserSchedule.value | Should -BeFalse
    }
}
