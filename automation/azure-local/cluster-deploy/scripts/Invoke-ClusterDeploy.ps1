#Requires -Version 7.0
<#
.SYNOPSIS
    Runs ONE pass of the Azure Local cloud deployment (-Pass Validate | Deploy) from the generated inputs:
    Generate -> Validate (build) -> Preview (what-if / plan) -> [Execute: deploy + poll].
.DESCRIPTION
    Outline §2.4: two passes of the same template. Validate creates the cluster resource, edge devices, role assignments
    and the diagnostics storage account, then runs the Environment Checker (about 10 minutes). Deploy re-PUTs the
    deployment settings with deploymentMode=Deploy and takes 2.5–3 hours ("Deploy Moc and ARB Stack" alone 40–45 min).
    Nothing changes in Azure unless -Execute is given (default -WhatIf: the run stops after Preview). The two ECE
    secrets must already exist in the cluster vault (Set-ClusterDeploymentSecrets.ps1); the script checks their NAMES only.
    Progress is read from clusters/deploymentSettings/default reportedProperties (step names and statuses) with a
    bounded retry on transient errors; elapsed time is reported honestly at the end.
.PARAMETER Pass
    Validate or Deploy. Deploy refuses to start unless the last Validate reported Success.
.PARAMETER Tool
    Bicep (demo path) or Terraform (parity path, azapi).
.PARAMETER Stage
    One stage, or All (Prereqs, Generate, Validate, Preview; Execute only with -Execute).
.PARAMETER BackendConfig
    Terraform only: backend-config file from environment/ (never committed).
.PARAMETER TimeoutMinutes
    Polling budget. Default 45 for Validate, 240 for Deploy.
.PARAMETER Execute
    Required to submit the deployment (owner approval). ConfirmImpact High.
.EXAMPLE
    .\Invoke-ClusterDeploy.ps1 -Pass Validate                 # generate, build, what-if; changes nothing
    .\Invoke-ClusterDeploy.ps1 -Pass Validate -Execute        # ~10 min
    .\Invoke-ClusterDeploy.ps1 -Pass Deploy -Execute          # 2.5–3 h, polls every 5 min
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateSet('Validate', 'Deploy')][string]$Pass,
    [ValidateSet('Bicep', 'Terraform')][string]$Tool = 'Bicep',
    [ValidateSet('Prereqs', 'Generate', 'Validate', 'Preview', 'Execute', 'All')][string]$Stage = 'All',
    [string]$Scope = 'azure-local',
    [string]$Solution = 'cluster-deploy',
    [string]$BackendConfig,
    [int]$PollIntervalSeconds = 120,
    [int]$TimeoutMinutes = 0,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClusterDeploy.Common.ps1')

# Hard guard first: a Deploy pass without -Execute never touches Azure (contract §7).
if ($Stage -in 'Execute', 'All' -and -not $Execute) {
    if ($Stage -eq 'Execute') { throw "Stage Execute requires -Execute (owner approval). Pass '$Pass' was not submitted." }
    Write-Warning "WhatIf (default): pass '$Pass' will stop after Preview. Add -Execute to submit it."
}
if (-not $Execute) { $WhatIfPreference = $true }
if ($TimeoutMinutes -le 0) { $TimeoutMinutes = if ($Pass -eq 'Deploy') { 240 } else { 45 } }

$root = Get-ClusterDeploySolutionRoot
$bicepDir = Join-Path $root 'bicep'
$tfDir = Join-Path $root 'terraform'
$tfVarsFile = Join-Path $tfDir 'terraform.generated.tfvars.json'
$bicepParamFile = Join-Path $bicepDir 'main.generated.bicepparam'
$stages = if ($Stage -eq 'All') { @('Prereqs', 'Generate', 'Validate', 'Preview') + $(if ($Execute) { @('Execute') } else { @() }) } else { @($Stage) }
$started = Get-Date

foreach ($current in $stages) {
    Write-ClusterDeployLog -Message "=== Stage: $current (pass $Pass, $Tool) ==="
    switch ($current) {
        'Prereqs' {
            foreach ($cmd in @('az') + $(if ($Tool -eq 'Terraform') { @('terraform') } else { @() })) {
                if (-not (Test-ClusterDeployCommand -Name $cmd)) { throw "'$cmd' is not installed on this machine." }
            }
            Write-ClusterDeployLog -Message "NIC26.Automation present: $(Import-ClusterDeployAutomationModule -Optional)"
            Write-ClusterDeployLog -Message 'Deployment gate (outline §2): landing zone S1–S8 done, both nodes Arc-connected in rg_azl, firmware/switches/OS ready, Environment Checker green, secrets written by Set-ClusterDeploymentSecrets.ps1.'
        }
        'Generate' {
            [void](Import-ClusterDeployAutomationModule)
            $config = Get-NIC26Config -Scope $Scope
            # The generated files are local, git-ignored inputs that the Validate and Preview stages read. Writing them changes nothing in
            # Azure, so they are written even in the default WhatIf run (otherwise the dry run stops at Preview with "Input file not found").
            ConvertTo-NIC26BicepParam -Solution $Solution -Config $config -Execute -WhatIf:$false | Out-Null
            ConvertTo-NIC26TfVars -Solution $Solution -Config $config -Execute -WhatIf:$false | Out-Null
            Write-ClusterDeployLog -Message "Generated $bicepParamFile and $tfVarsFile (git-ignored; deployment_mode is passed per run, not generated)."
        }
        'Validate' {
            if ($Tool -eq 'Bicep') {
                $files = @((Join-Path $bicepDir 'main.bicep')) + @(Get-ChildItem -Path (Join-Path $bicepDir 'modules') -Filter '*.bicep' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                foreach ($f in $files) { Invoke-ClusterDeployNative -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $f, '--stdout') -PassThru | Out-Null }
                if (Test-Path $bicepParamFile) { Invoke-ClusterDeployNative -FilePath 'az' -ArgumentList @('bicep', 'build-params', '--file', $bicepParamFile, '--stdout') -PassThru | Out-Null }
            }
            else {
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('fmt', '-check', '-recursive') -WorkingDirectory $tfDir
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('init', '-backend=false', '-input=false') -WorkingDirectory $tfDir
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('validate') -WorkingDirectory $tfDir
            }
            Write-ClusterDeployLog -Message 'Template validation passed.'
        }
        'Preview' {
            $inputs = Get-ClusterDeployInputs -InputFile $tfVarsFile
            Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
            # Read-only pre-checks shared by both tools: the two ECE secrets exist (names only) and the previous pass state.
            foreach ($secretName in @("$($inputs.cluster_name)-LocalAdminCredential", "$($inputs.cluster_name)-WitnessStorageKey")) {
                $present = [bool](Get-AzKeyVaultSecret -VaultName $inputs.kv_azl_name -Name $secretName -ErrorAction SilentlyContinue)
                Write-ClusterDeployLog -Message "Cluster vault '$($inputs.kv_azl_name)' secret '$secretName' present: $present" -Level ($present ? 'Info' : 'Warning')
            }
            $state = Get-ClusterDeploymentSettingsState -SubscriptionId $inputs.subscription_id -ResourceGroupName $inputs.names.rg_azl -ClusterName $inputs.cluster_name
            Write-ClusterDeployLog -Message "deploymentSettings exists=$($state.Exists) validation=$($state.ValidationStatus) deployment=$($state.DeploymentStatus)"
            if ($Pass -eq 'Deploy' -and $state.ValidationStatus -ne 'Success') {
                throw "Refusing the Deploy pass: the last Validate pass did not report Success (validationStatus='$($state.ValidationStatus)'). Run -Pass Validate first."
            }
            $deploymentName = "$($inputs.names.deployment_name)-$($Pass.ToLowerInvariant())"
            if ($Tool -eq 'Bicep') {
                Invoke-ClusterDeployNative -FilePath 'az' -ArgumentList @('deployment', 'group', 'what-if', '--subscription', $inputs.subscription_id, '--resource-group', $inputs.names.rg_azl, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--mode', 'Incremental', '--parameters', $bicepParamFile, '--parameters', "deployment_mode=$Pass")
            }
            else {
                if (-not $BackendConfig) { throw 'Terraform Preview/Execute needs -BackendConfig <environment/.../backend.hcl> (contract §3).' }
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('init', '-input=false', "-backend-config=$BackendConfig") -WorkingDirectory $tfDir
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('plan', '-input=false', "-var-file=$tfVarsFile", "-var=deployment_mode=$Pass", "-out=$Solution-$($Pass.ToLowerInvariant()).tfplan") -WorkingDirectory $tfDir
            }
        }
        'Execute' {
            if (-not $Execute) { throw 'Execute requires -Execute.' }
            $inputs = Get-ClusterDeployInputs -InputFile $tfVarsFile
            Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
            $deploymentName = "$($inputs.names.deployment_name)-$($Pass.ToLowerInvariant())"
            $target = "cluster $($inputs.cluster_name) in $($inputs.names.rg_azl) (pass $Pass, $Tool)"
            if (-not $PSCmdlet.ShouldProcess($target, "Submit Azure Local $Pass")) { break }
            # The pass reads both ECE secrets while it runs (Deploy takes hours): refuse a missing, disabled or soon-expiring secret before submitting.
            $localAdminName = if ($inputs.PSObject.Properties.Name -contains 'local_admin_secret_name' -and $inputs.local_admin_secret_name) { [string]$inputs.local_admin_secret_name } else { "$($inputs.cluster_name)-LocalAdminCredential" }
            $witnessKeyName = if ($inputs.PSObject.Properties.Name -contains 'witness_key_secret_name' -and $inputs.witness_key_secret_name) { [string]$inputs.witness_key_secret_name } else { "$($inputs.cluster_name)-WitnessStorageKey" }
            foreach ($secretName in @($localAdminName, $witnessKeyName)) {
                $secret = Get-AzKeyVaultSecret -VaultName $inputs.kv_azl_name -Name $secretName -ErrorAction Stop
                $problem = Test-ClusterDeploySecretUsable -Secret $secret -ValidUntil ((Get-Date).ToUniversalTime().AddMinutes($TimeoutMinutes + 30))
                if ($problem) { throw "Refusing to submit pass '$Pass': secret '$secretName' in '$($inputs.kv_azl_name)' is $problem. Run Set-ClusterDeploymentSecrets.ps1 -Execute (-Overwrite to rotate)." }
            }
            $submitAt = Get-Date
            if ($Tool -eq 'Bicep') {
                Invoke-ClusterDeployNative -FilePath 'az' -ArgumentList @('deployment', 'group', 'create', '--no-wait', '--subscription', $inputs.subscription_id, '--resource-group', $inputs.names.rg_azl, '--name', $deploymentName, '--template-file', (Join-Path $bicepDir 'main.bicep'), '--mode', 'Incremental', '--parameters', $bicepParamFile, '--parameters', "deployment_mode=$Pass")
            }
            else {
                $planFile = Join-Path $tfDir "$Solution-$($Pass.ToLowerInvariant()).tfplan"
                if (-not (Test-Path $planFile)) { throw 'No plan file; run the Preview stage first.' }
                # terraform apply blocks for the whole pass (azapi timeout 4 h); polling below then only confirms the end state.
                Invoke-ClusterDeployNative -FilePath 'terraform' -ArgumentList @('apply', '-input=false', $planFile) -WorkingDirectory $tfDir
            }

            # Poll: ARM deployment (Bicep) + deploymentSettings reportedProperties (both tools). Bounded; transient errors retried.
            $deadline = $submitAt.AddMinutes($TimeoutMinutes)
            $lastSteps = ''
            $final = $null
            do {
                Start-Sleep -Seconds $PollIntervalSeconds
                $state = Invoke-NIC26WithRetry -Activity 'poll deploymentSettings' -MaxMinutes 5 -ScriptBlock {
                    Get-ClusterDeploymentSettingsState -SubscriptionId $inputs.subscription_id -ResourceGroupName $inputs.names.rg_azl -ClusterName $inputs.cluster_name
                }
                # The deployment name is reused per pass: only a record stamped after this submission counts, so the state of an earlier run is never read as this one.
                $armState = 'n/a'
                if ($Tool -eq 'Bicep') {
                    $armRecord = Get-AzResourceGroupDeployment -ResourceGroupName $inputs.names.rg_azl -Name $deploymentName -ErrorAction SilentlyContinue
                    $armState = if ($armRecord -and $armRecord.Timestamp.ToUniversalTime() -ge $submitAt.ToUniversalTime().AddMinutes(-2)) { [string]$armRecord.ProvisioningState } else { 'Pending' }
                }
                $stepsText = ($state.Steps | Where-Object { $_.Status -and $_.Status -ne 'Success' } | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', '
                if ($stepsText -ne $lastSteps) { Write-ClusterDeployLog -Message "[$([int]((Get-Date) - $submitAt).TotalMinutes) min] arm=$armState provisioning=$($state.ProvisioningState) validation=$($state.ValidationStatus) deployment=$($state.DeploymentStatus) | $stepsText"; $lastSteps = $stepsText }
                $final = Resolve-ClusterDeployPassOutcome -Tool $Tool -Pass $Pass -ArmState $armState -ValidationStatus ([string]$state.ValidationStatus) -DeploymentStatus ([string]$state.DeploymentStatus)
            } while (-not $final -and (Get-Date) -lt $deadline)

            $elapsed = (Get-Date) - $submitAt
            if (-not $final) { throw "Pass '$Pass' did not finish within $TimeoutMinutes min (elapsed $([int]$elapsed.TotalMinutes) min). It may still be running: watch the cluster's Deployments blade or re-run with -Stage Execute later only after checking state." }
            Write-ClusterDeployLog -Message "Pass '$Pass' finished with status '$final' after $([int]$elapsed.TotalMinutes) min (ARM deployment '$deploymentName')."
            if ($final -ne 'Success') { throw "Pass '$Pass' ended with status '$final'. Inspect the failed step(s) above and the cluster resource's Deployments blade." }
            if ($Pass -eq 'Deploy') { Write-ClusterDeployLog -Message 'Next: Test-ClusterPostDeployment.ps1, then Set-ClusterVaultPublicAccess.ps1 -Mode Disable (design §5.3 phase flag).' }
        }
    }
}
Write-ClusterDeployLog -Message "Run took $([int]((Get-Date) - $started).TotalMinutes) min."
