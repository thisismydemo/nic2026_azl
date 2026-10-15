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
    One stage, or All (Prereqs, Generate, Validate, Preview; Execute only with -Execute). Watch resumes polling a pass that
    is already submitted (never submits).
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
    [ValidateSet('Prereqs', 'Generate', 'Validate', 'Preview', 'Execute', 'Watch', 'All')][string]$Stage = 'All',
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
# The retry helper is a public module command; dot-source it in this script scope because
# stage execution occurs here (nested module imports do not leak exported commands).
$retryHelper = Join-Path (Get-ClusterDeployRepoRoot) 'automation\shared\powershell\NIC26.Automation\Public\Invoke-NIC26WithRetry.ps1'
if (-not (Get-Command Invoke-NIC26WithRetry -ErrorAction SilentlyContinue)) { . $retryHelper }

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

# Polls one submitted pass to its end: ARM deployment (Bicep) + deploymentSettings reportedProperties (both tools).
$waitPass = {
    param($inputs, $deploymentName, $submitAt)
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
    if (-not $final) { throw "Pass '$Pass' did not finish within $TimeoutMinutes min (elapsed $([int]$elapsed.TotalMinutes) min). It may still be running: resume with -Stage Watch (never resubmits)." }
    Write-ClusterDeployLog -Message "Pass '$Pass' finished with status '$final' after $([int]$elapsed.TotalMinutes) min (ARM deployment '$deploymentName')."
    if ($final -ne 'Success') { throw "Pass '$Pass' ended with status '$final'. Inspect the failed step(s) above and the cluster resource's Deployments blade." }
    if ($Pass -eq 'Deploy') { Write-ClusterDeployLog -Message 'Next: Test-ClusterPostDeployment.ps1, then Set-ClusterVaultPublicAccess.ps1 -Mode Disable (design §5.3 phase flag).' }
}

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
            $eceNames = Get-ClusterDeploySecretName -Inputs $inputs
            foreach ($secretName in @($eceNames.LocalAdmin, $eceNames.WitnessKey)) {
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
                if (-not $BackendConfig) {
                    # No explicit file: render the state location from terraform_backend in the environment file.
                    try { $BackendConfig = (New-NIC26TerraformBackendConfig -Solution (Split-Path -Path $tfDir -Parent) -Config (Get-NIC26Config -Scope 'azure-local') -Execute -WhatIf:$false).FullName }
                    catch { throw "Terraform Preview/Execute needs -BackendConfig <backend.hcl> or terraform_backend in the environment file (contract §3): $($_.Exception.Message)" }
                }
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
            # Repeat the state guard here so a standalone -Stage Execute cannot skip Preview's check (GPT review, 10 Oct).
            $state = Get-ClusterDeploymentSettingsState -SubscriptionId $inputs.subscription_id -ResourceGroupName $inputs.names.rg_azl -ClusterName $inputs.cluster_name
            if ($Pass -eq 'Deploy' -and $state.ValidationStatus -ne 'Success') {
                throw "Refusing the Deploy pass: the last Validate pass did not report Success (validationStatus='$($state.ValidationStatus)'). Run -Pass Validate first."
            }
            if ($state.ValidationStatus -eq 'InProgress' -or $state.DeploymentStatus -eq 'InProgress') {
                throw "Refusing pass '$Pass': a previous operation is still running (validation=$($state.ValidationStatus), deployment=$($state.DeploymentStatus)). Use -Stage Watch."
            }
            # The pass reads both ECE secrets while it runs (Deploy takes hours): refuse a missing, disabled or soon-expiring secret before submitting.
            $eceNames = Get-ClusterDeploySecretName -Inputs $inputs
            foreach ($secretName in @($eceNames.LocalAdmin, $eceNames.WitnessKey)) {
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

            & $waitPass $inputs $deploymentName $submitAt
        }
        'Watch' {
            # Resume polling a pass that is already submitted (the watcher was interrupted); never submits anything.
            $inputs = Get-ClusterDeployInputs -InputFile $tfVarsFile
            Assert-ClusterDeployAzContext -SubscriptionId $inputs.subscription_id
            $deploymentName = "$($inputs.names.deployment_name)-$($Pass.ToLowerInvariant())"
            $armRecord = Get-AzResourceGroupDeployment -ResourceGroupName $inputs.names.rg_azl -Name $deploymentName -ErrorAction SilentlyContinue
            if (-not $armRecord -and $Tool -eq 'Bicep') { throw "No ARM deployment '$deploymentName' to watch; submit the pass with -Stage Execute -Execute." }
            $submitAt = if ($armRecord) { $armRecord.Timestamp.ToLocalTime().AddMinutes(-1) } else { Get-Date }
            Write-ClusterDeployLog -Message "Watching pass '$Pass' ($deploymentName, ARM state $($armRecord.ProvisioningState))."
            & $waitPass $inputs $deploymentName $submitAt
        }
    }
}
Write-ClusterDeployLog -Message "Run took $([int]((Get-Date) - $started).TotalMinutes) min."
