#Requires -Version 7.0
<#
.SYNOPSIS
    Stage S0: registers the resource providers and preview features the Azure Local landing zone needs (design §2.2).
.DESCRIPTION
    Provider registration is a subscription-level, non-declarative action, so it is a script in both IaC tracks.
    Default is -WhatIf: the script lists every provider/feature with its current state and what it WOULD register.
    Nothing is registered unless -Execute is given. Never touches any subscription other than -SubscriptionId.
    Read-only Azure calls (Get-AzResourceProvider / Get-AzProviderFeature) run in both modes.
.PARAMETER SubscriptionId
    The landing-zone subscription (from Get-NIC26Config -Scope azure-local: subscription_id).
.PARAMETER Execute
    Perform the registrations. Without it the script only reports.
.EXAMPLE
    ./Register-LzProviders.ps1 -SubscriptionId (Get-NIC26Config -Scope azure-local).subscription_id
.EXAMPLE
    ./Register-LzProviders.ps1 -SubscriptionId $sub -Execute
.NOTES
    Requires Az.Accounts and Az.Resources and an existing Az context (Connect-AzAccount) with Owner/Contributor on the subscription.
    Feature AzureLocalZTP (Microsoft.DeviceOnboarding) must be Registered and the provider re-registered afterwards (design §2.2).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $SubscriptionId,

    [switch] $Execute
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Design §2.2 list (hyperconverged deployment + simplified provisioning + landing-zone needs).
$script:Providers = @(
    'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
    'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
    'Microsoft.HybridContainerService', 'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector',
    'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights', 'Microsoft.KeyVault',
    'Microsoft.DeviceOnboarding', 'Microsoft.Edge', 'Microsoft.ManagedIdentity', 'Microsoft.PolicyInsights',
    'Microsoft.OperationalInsights', 'Microsoft.OperationsManagement', 'Microsoft.RecoveryServices',
    'Microsoft.Network', 'Microsoft.Security', 'Microsoft.Maintenance', 'Microsoft.EdgeMarketplace',
    'Microsoft.Compute'
)
$script:Features = @(
    @{ Namespace = 'Microsoft.DeviceOnboarding'; Name = 'AzureLocalZTP' }      # simplified machine provisioning (preview)
    @{ Namespace = 'Microsoft.Compute'; Name = 'EncryptionAtHost' }            # management-plane MP-02 (jump_encryption_at_host)
)

function Get-LzProviderPlan {
    [CmdletBinding()]
    param([string] $SubscriptionId)
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'No Az context. Run Connect-AzAccount first.' }
    if ($ctx.Subscription.Id -ne $SubscriptionId) {
        $null = Set-AzContext -WhatIf:$false -SubscriptionId $SubscriptionId
    }
    $plan = foreach ($p in $script:Providers) {
        $state = (Get-AzResourceProvider -ProviderNamespace $p -ErrorAction SilentlyContinue | Select-Object -First 1).RegistrationState
        [pscustomobject]@{ Kind = 'Provider'; Name = $p; State = ($state ?? 'Unknown'); Action = ($state -eq 'Registered' ? 'none' : 'Register-AzResourceProvider') }
    }
    $plan += foreach ($f in $script:Features) {
        $state = (Get-AzProviderFeature -ProviderNamespace $f.Namespace -FeatureName $f.Name -ErrorAction SilentlyContinue).RegistrationState
        [pscustomobject]@{ Kind = 'Feature'; Name = "$($f.Namespace)/$($f.Name)"; State = ($state ?? 'NotRegistered'); Action = ($state -eq 'Registered' ? 'none' : 'Register-AzProviderFeature (then re-register the provider)') }
    }
    return $plan
}

$plan = Get-LzProviderPlan -SubscriptionId $SubscriptionId
$plan | Format-Table -AutoSize | Out-String | Write-Information -InformationAction Continue

$pending = @($plan | Where-Object Action -NE 'none')
if ($pending.Count -eq 0) { Write-Information 'Nothing to do: every provider and feature is Registered.' -InformationAction Continue; return $plan }

if (-not $Execute) {
    Write-Warning "WhatIf (default): $($pending.Count) item(s) would be registered. Re-run with -Execute to register them."
    return $plan
}

foreach ($item in $pending) {
    if ($item.Kind -eq 'Feature') {
        $ns, $name = $item.Name -split '/', 2
        if ($PSCmdlet.ShouldProcess("$ns/$name in $SubscriptionId", 'Register-AzProviderFeature')) {
            $null = Register-AzProviderFeature -ProviderNamespace $ns -FeatureName $name
            $null = Register-AzResourceProvider -ProviderNamespace $ns   # re-register after the feature flag (design §2.2)
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess("$($item.Name) in $SubscriptionId", 'Register-AzResourceProvider')) {
            $null = Register-AzResourceProvider -ProviderNamespace $item.Name
        }
    }
}
Write-Information 'Registration requested. Registration is asynchronous; re-run without -Execute to watch the state.' -InformationAction Continue
return (Get-LzProviderPlan -SubscriptionId $SubscriptionId)
