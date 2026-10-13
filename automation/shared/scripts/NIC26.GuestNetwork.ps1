#Requires -Version 7.0
<#
.SYNOPSIS
    Dot-source helper: default gateway checks inside Azure Local VMs over PowerShell Direct, from the cluster node that
    runs the VM. Used by the VM build scripts (SOFS, AVD Azure Local session hosts, IIC workload VMs, demo 4.4 VM).
.DESCRIPTION
    The logical network's DHCP (SDN host DHCP on static logical networks) supplies the IP address, DNS servers and the
    default gateway; the guest must get its gateway from DHCP only, never from an in-guest static route (owner,
    12 Oct 2026). These functions read and wait for that state; the only change they make is removing a persistent
    manual 0.0.0.0/0 route left by an earlier build (Remove-NIC26GuestPersistentDefaultRoute), and only when DHCP has
    supplied the gateway.
      Get-NIC26GuestNetworkState            DHCP enabled, DHCP-supplied gateway (DhcpDefaultGateway of the interface),
                                            active default routes with their origin, persistent default routes, DNS
                                            servers, TCP 443 to an Azure endpoint from the guest.
      Wait-NIC26GuestDhcpGateway            polls the state until DHCP has supplied a gateway; throws after the timeout.
      Remove-NIC26GuestPersistentDefaultRoute
                                            removes persistent 0.0.0.0/0 routes from the PersistentStore (ShouldProcess),
                                            leaves the active route in place (no connectivity change now; after a
                                            restart only the DHCP route remains).
    Credentials are PSCredential objects in the encrypted remoting session; nothing is written to disk or printed.
    Learn: PowerShell Direct (Manage Windows virtual machines with PowerShell Direct); Get-NetRoute; Manage Azure Local
    VMs (Enable guest management).
#>
Set-StrictMode -Version Latest

$script:NIC26GuestStateBlock = {
    param($endpoint)
    $ip = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' })[0]
    $if = Get-NetIPInterface -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4
    $guid = (Get-NetAdapter -InterfaceIndex $ip.InterfaceIndex).InterfaceGuid
    $reg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid" -ErrorAction SilentlyContinue
    $dhcpGw = @(if ($reg -and $reg.PSObject.Properties['DhcpDefaultGateway']) { $reg.DhcpDefaultGateway | Where-Object { $_ } })
    $active = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue)
    $persist = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
    $reach = $null
    if ($endpoint) {
        $h, $p = $endpoint.Split(':'); $c = [System.Net.Sockets.TcpClient]::new()
        try { $reach = $c.ConnectAsync($h, [int]$p).Wait(8000) -and $c.Connected } catch { $reach = $false } finally { $c.Dispose() }
    }
    [pscustomobject]@{
        Computer            = $env:COMPUTERNAME
        IPAddress           = $ip.IPAddress
        PrefixOrigin        = [string]$ip.PrefixOrigin
        DhcpEnabled         = [string]$if.Dhcp
        DhcpGateway         = ($dhcpGw -join ',')
        ActiveDefaultRoutes = (($active | ForEach-Object { "$($_.NextHop)/$($_.Protocol)/m$($_.RouteMetric)" }) -join ',')
        PersistentRoutes    = $persist.Count
        PersistentNextHops  = (($persist | ForEach-Object { $_.NextHop }) -join ',')
        DnsServers          = ((Get-DnsClientServerAddress -InterfaceIndex $ip.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ',')
        Endpoint            = $endpoint
        EndpointReachable   = $reach
    }
}

function Invoke-NIC26GuestDirect {
    <# Runs a script block in the VM (PowerShell Direct) on whichever node runs it; $null when no node runs the VM. #>
    param(
        [Parameter(Mandatory)][string[]]$NodeAddress, [Parameter(Mandatory)][pscredential]$NodeCredential,
        [Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][pscredential]$GuestCredential,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @()
    )
    foreach ($node in $NodeAddress) {
        $r = Invoke-Command -ComputerName $node -Credential $NodeCredential -ErrorAction Stop -ArgumentList $VmName, $GuestCredential, $ScriptBlock.ToString(), (, $ArgumentList) -ScriptBlock {
            param($name, [pscredential]$cred, $sbText, $argsIn)
            $vm = @(Get-VM | Where-Object { ($_.Name -eq $name -or $_.Name -like "$name-*") -and $_.State -eq 'Running' })[0]
            if (-not $vm) { return $null }
            try {
                $o = Invoke-Command -VMId $vm.Id -Credential $cred -ScriptBlock ([scriptblock]::Create($sbText)) -ArgumentList ([object[]]@($argsIn | ForEach-Object { $_ })) -ErrorAction Stop
                [pscustomobject]@{ Node = $env:COMPUTERNAME; HyperVName = $vm.Name; Output = $o; Error = $null }
            }
            catch { [pscustomobject]@{ Node = $env:COMPUTERNAME; HyperVName = $vm.Name; Output = $null; Error = $_.Exception.Message } }
        }
        if ($r) { return $r }
    }
    return $null
}

function Get-NIC26GuestNetworkState {
    <#
    .SYNOPSIS
        Reads DHCP / default gateway / persistent route state inside an Azure Local VM (read only).
    .EXAMPLE
        Get-NIC26GuestNetworkState -NodeAddress 192.0.2.11, 192.0.2.12 -NodeCredential $node -VmName vm-app-01 -GuestCredential $guest
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$NodeAddress, [Parameter(Mandatory)][pscredential]$NodeCredential,
        [Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][pscredential]$GuestCredential,
        [string]$TestEndpoint = 'management.azure.com:443'
    )
    $r = Invoke-NIC26GuestDirect -NodeAddress $NodeAddress -NodeCredential $NodeCredential -VmName $VmName -GuestCredential $GuestCredential -ScriptBlock $script:NIC26GuestStateBlock -ArgumentList $TestEndpoint
    if (-not $r) { return [pscustomobject]@{ VmName = $VmName; Node = $null; State = 'not-running'; Error = $null } }
    if ($r.Error) { return [pscustomobject]@{ VmName = $VmName; Node = $r.Node; State = 'guest-not-reachable'; Error = $r.Error } }
    $o = $r.Output
    [pscustomobject]@{
        VmName = $VmName; Node = $r.Node; State = 'ok'; Error = $null; Computer = $o.Computer; IPAddress = $o.IPAddress
        PrefixOrigin = $o.PrefixOrigin; DhcpEnabled = $o.DhcpEnabled; DhcpGateway = $o.DhcpGateway
        ActiveDefaultRoutes = $o.ActiveDefaultRoutes; PersistentRoutes = [int]$o.PersistentRoutes; PersistentNextHops = $o.PersistentNextHops
        DnsServers = $o.DnsServers; Endpoint = $o.Endpoint; EndpointReachable = $o.EndpointReachable
    }
}

function Wait-NIC26GuestDhcpGateway {
    <#
    .SYNOPSIS
        Waits until the guest has a DHCP-supplied default gateway (and, with -ExpectedGateway, that it matches).
        Throws after -TimeoutMinutes. Never adds a route.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$NodeAddress, [Parameter(Mandatory)][pscredential]$NodeCredential,
        [Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][pscredential]$GuestCredential,
        [string]$ExpectedGateway,
        [ValidateRange(1, 120)][int]$TimeoutMinutes = 15,
        [ValidateRange(5, 300)][int]$PollSeconds = 15
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $s = $null
    do {
        $s = Get-NIC26GuestNetworkState -NodeAddress $NodeAddress -NodeCredential $NodeCredential -VmName $VmName -GuestCredential $GuestCredential
        if ($s.State -eq 'ok' -and $s.DhcpGateway -and (-not $ExpectedGateway -or (@($s.DhcpGateway -split ',') -contains $ExpectedGateway))) { return $s }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    $detail = if ($s) { "state $($s.State), DHCP $(if ($s.State -eq 'ok') { $s.DhcpEnabled }), DHCP gateway '$(if ($s.State -eq 'ok') { $s.DhcpGateway })' $($s.Error)" } else { 'no state' }
    throw "${VmName}: no DHCP-supplied default gateway$(if ($ExpectedGateway) { " $ExpectedGateway" }) after $TimeoutMinutes min ($detail). No route is added: check the logical network's DHCP."
}

function Remove-NIC26GuestPersistentDefaultRoute {
    <#
    .SYNOPSIS
        Removes persistent 0.0.0.0/0 routes in the guest when DHCP supplies the gateway (cleanup of an earlier in-guest
        route). The active route stays until the next restart; refuses when DHCP has not supplied a gateway.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$NodeAddress, [Parameter(Mandatory)][pscredential]$NodeCredential,
        [Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][pscredential]$GuestCredential
    )
    $s = Get-NIC26GuestNetworkState -NodeAddress $NodeAddress -NodeCredential $NodeCredential -VmName $VmName -GuestCredential $GuestCredential
    if ($s.State -ne 'ok') { return [pscustomobject]@{ VmName = $VmName; Result = "skipped: $($s.State) $($s.Error)" } }
    if ($s.PersistentRoutes -eq 0) { return [pscustomobject]@{ VmName = $VmName; Result = 'no persistent default route' } }
    if (-not $s.DhcpGateway) { return [pscustomobject]@{ VmName = $VmName; Result = 'kept: DHCP has not supplied a gateway' } }
    if (-not $PSCmdlet.ShouldProcess($VmName, "Remove $($s.PersistentRoutes) persistent default route(s) via $($s.PersistentNextHops) (DHCP gateway $($s.DhcpGateway))")) { return }
    $null = Invoke-NIC26GuestDirect -NodeAddress $NodeAddress -NodeCredential $NodeCredential -VmName $VmName -GuestCredential $GuestCredential -ScriptBlock {
        Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
    }
    $after = Get-NIC26GuestNetworkState -NodeAddress $NodeAddress -NodeCredential $NodeCredential -VmName $VmName -GuestCredential $GuestCredential
    [pscustomobject]@{ VmName = $VmName; Result = "persistent routes $($s.PersistentRoutes) -> $($after.PersistentRoutes)"; After = $after }
}

function Invoke-NIC26GuestManagementRetry {
    <#
    .SYNOPSIS
        When the VM's Arc machine is not Connected, re-triggers guest management the documented way
        (az stack-hci-vm update --enable-agent true; Learn: Manage Azure Local VMs, Enable guest management) and waits
        for Connected. The guest agent's first-boot download of the Azure Connected Machine agent does not retry on its
        own after a failure (ArcAgentDownloadFailed), so a build re-triggers it once the guest has its gateway.
        Uses the Azure CLI (stack-hci-vm extension); returns the final Arc status.
    .EXAMPLE
        Invoke-NIC26GuestManagementRetry -SubscriptionId 00000000-0000-0000-0000-000000000000 -ResourceGroup rg-example -VmName vm-app-01
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$VmName,
        [ValidateRange(1, 60)][int]$TimeoutMinutes = 15
    )
    $az = (Get-Command az.cmd, az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $az) { throw 'Azure CLI (az) not found.' }
    $mId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/$VmName"
    $status = { (& $az resource show --ids $mId --query properties.status -o tsv --only-show-errors 2>$null | Out-String).Trim() }
    $s = & $status
    if ($s -eq 'Connected') { return [pscustomobject]@{ VmName = $VmName; Retriggered = $false; Status = $s } }
    if (-not $PSCmdlet.ShouldProcess($VmName, "az stack-hci-vm update --enable-agent true (Arc status '$s')")) { return }
    $out = & $az stack-hci-vm update -g $ResourceGroup --name $VmName --enable-agent true --subscription $SubscriptionId -o none --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "${VmName}: az stack-hci-vm update --enable-agent true failed: $(($out -replace '\s+', ' ').Trim())" }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do { Start-Sleep -Seconds 20; $s = & $status } while ($s -ne 'Connected' -and (Get-Date) -lt $deadline)
    [pscustomobject]@{ VmName = $VmName; Retriggered = $true; Status = $s }
}
