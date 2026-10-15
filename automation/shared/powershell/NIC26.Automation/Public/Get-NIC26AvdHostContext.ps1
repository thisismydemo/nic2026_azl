function Get-NIC26AvdHostContext {
    <#
    .SYNOPSIS
        Derives the subscription, resource groups, host pool and machine names of one AVD realm (or the image build) from the environment config.
    .DESCRIPTION
        The registration, health-check and image-build scripts take the same few values every time (subscription, host
        resource group, host pool and its resource group, VM or Arc machine names, image template names). They are not
        typed: they follow from the environment file and the solution name catalogs. This function resolves them:
          azure    subscription_id_avd; hosts RG names.rg_hosts (lz-avd); pool names.hostpool_azure and RG names.rg_control;
                   VMs names.vm_azure_<n> for n = 1 .. host_pools.azure.session_host_count (session-hosts-azure catalog).
          azl      subscription_id_azl (Arc machines) and the pool's subscription_id_avd; hosts RG azl_session_hosts.resource_group
                   (else names.rg_azl_cluster); machines azl_session_hosts.hosts[].name (else names.vm_azl_<n> for
                   n = 1 .. host_pools.azl.session_host_count).
          hybrid   subscription_id_avd; Arc RG names.rg_arc; machines hybrid.vms[].name (else the sessionhost_hv<nn> names).
          image    subscription_id_avd; RG names.rg_img (lz-avd); templates names.it_azure and names.it_azl (images/azure catalog).
        Explicit script parameters always win; this only supplies the values the operator left out.
    .PARAMETER Realm
        azure | azl | hybrid | image
    .PARAMETER Config
        Object returned by Get-NIC26Config -Scope avd (its 'values' are used) or a dictionary of canonical values.
    .EXAMPLE
        $ctx = Get-NIC26AvdHostContext -Realm azure -Config (Get-NIC26Config -Scope avd)
        $ctx.HostPoolName; $ctx.VmName
    .OUTPUTS
        System.Management.Automation.PSCustomObject (Realm, SubscriptionId, ResourceGroupName, HostPoolSubscriptionId,
        HostPoolResourceGroup, HostPoolName, VmName, ArcResourceGroup, TemplateName)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('azure', 'azl', 'hybrid', 'image')]
        [string]$Realm,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Config
    )

    $values = ConvertTo-NIC26ConfigValues -Config $Config
    $automationRoot = Get-NIC26AutomationRoot
    $catalog = {
        param([string]$Folder)
        $manifest = Get-NIC26SolutionManifest -Path (Join-Path $automationRoot $Folder)
        return (Resolve-NIC26NameCatalog -Catalog $manifest['names'] -Values $values)
    }
    $text = { param([string]$Key) if ($values.Contains($Key) -and $values[$Key]) { [string]$values[$Key] } else { '' } }
    $count = {
        param([string]$Pool)
        if ($values.Contains('host_pools') -and $values['host_pools'].Contains($Pool) -and $values['host_pools'][$Pool].Contains('session_host_count')) { return [int]$values['host_pools'][$Pool]['session_host_count'] }
        return 0
    }

    $avdSubscription = & $text 'subscription_id_avd'
    $lz = & $catalog 'landing-zones/avd'
    $result = [ordered]@{
        Realm                  = $Realm
        SubscriptionId         = $avdSubscription
        ResourceGroupName      = ''
        HostPoolSubscriptionId = $avdSubscription
        HostPoolResourceGroup  = ''
        HostPoolName           = ''
        VmName                 = @()
        ArcResourceGroup       = ''
        TemplateName           = @()
    }

    if ($Realm -eq 'image') {
        $images = & $catalog 'avd/images/azure'
        $result.ResourceGroupName = [string]$lz['rg_img']
        $result.TemplateName = @([string]$images['it_azure'], [string]$images['it_azl'])
        return [pscustomobject]$result
    }

    $control = & $catalog 'avd/control-plane'
    $result.HostPoolResourceGroup = [string]$control['rg_control']
    $result.HostPoolName = [string]$control["hostpool_$Realm"]

    switch ($Realm) {
        'azure' {
            $names = & $catalog 'avd/session-hosts-azure'
            $result.ResourceGroupName = [string]$lz['rg_hosts']
            $result.VmName = @(1..(& $count 'azure') | ForEach-Object { [string]$names["vm_azure_$_"] } | Where-Object { $_ })
        }
        'azl' {
            $names = & $catalog 'avd/session-hosts-azure-local'
            $result.SubscriptionId = & $text 'subscription_id_azl'
            $hosts = if ($values.Contains('azl_session_hosts')) { $values['azl_session_hosts'] } else { $null }
            $result.ResourceGroupName = if ($hosts -and $hosts.Contains('resource_group')) { [string]$hosts['resource_group'] } else { [string]$lz['rg_azl_cluster'] }
            $result.VmName = if ($hosts -and $hosts.Contains('hosts')) { @($hosts['hosts'] | ForEach-Object { [string]$_['name'] }) }
            else { @(1..(& $count 'azl') | ForEach-Object { [string]$names["vm_azl_$_"] } | Where-Object { $_ }) }
        }
        'hybrid' {
            $names = & $catalog 'avd/session-hosts-hybrid'
            $result.ArcResourceGroup = [string]$names['rg_arc']
            $result.ResourceGroupName = [string]$names['rg_arc']
            $hybrid = if ($values.Contains('hybrid')) { $values['hybrid'] } else { $null }
            $result.VmName = if ($hybrid -and $hybrid.Contains('vms')) { @($hybrid['vms'] | ForEach-Object { [string]$_['name'] }) }
            else { @($names.Keys | Where-Object { $_ -like 'sessionhost_hv*' } | Sort-Object | ForEach-Object { [string]$names[$_] }) }
        }
    }
    return [pscustomobject]$result
}
