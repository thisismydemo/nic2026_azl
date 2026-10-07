@{
    # NIC 2026 automation - PSScriptAnalyzer settings (automation/CONTRACT.md section 8).
    # Usage: Invoke-ScriptAnalyzer -Path <folder> -Recurse -Settings automation\shared\powershell\PSScriptAnalyzerSettings.psd1
    # All default rules run (nothing is excluded globally). The rules listed under IncludeRules are the ones the contract
    # calls out explicitly; they are default rules, so listing them documents intent without narrowing the set because
    # IncludeDefaultRules keeps every other default rule active.
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    IncludeRules        = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSAvoidUsingWriteHost'
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidGlobalVars'
        'PSUseCompatibleSyntax'
        'PSPlaceOpenBrace'
        'PSPlaceCloseBrace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSAvoidTrailingWhitespace'
        'PSUseCorrectCasing'
    )
    # Nothing is excluded repo-wide. Where a rule cannot apply, the function carries an inline
    # [Diagnostics.CodeAnalysis.SuppressMessageAttribute] with a Justification (grep for it to audit):
    #   - PSUseShouldProcessForStateChangingFunctions on New-NIC26ResourceName (pure function; name fixed by the contract)
    #     and Start-NIC26Sleep (mockable wait wrapper).
    #   - PSUseSingularNouns on ConvertTo-NIC26TfVars / ConvertTo-NIC26AnsibleVars (names fixed by the contract).
    #   - PSUseDeclaredVarsMoreThanAssignments in Pester files (BeforeAll variables are consumed inside It blocks).
    # PSAvoidUsingWriteHost is never suppressed: Write-NIC26Log uses Write-Information.
    ExcludeRules        = @()
    Rules               = @{
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            IndentationSize     = 4
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $false
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAvoidUsingCmdletAliases  = @{
            allowlist = @()
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
    }
}
