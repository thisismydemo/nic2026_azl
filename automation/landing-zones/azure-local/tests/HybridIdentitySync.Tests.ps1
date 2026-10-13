#Requires -Version 7.0
# Pester 5 static tests for scripts/Set-HybridIdentitySync.ps1 (Microsoft Entra Cloud Sync, D-050): conventions, stages,
# plan-by-default (every write sits inside an Invoke-Change block), protected Run Command parameters, no secret output,
# no lab literals (G5), and every cloud_sync key the script reads exists in the environment schema. Nothing calls Azure.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'BeforeAll variables are consumed inside It blocks.')]
param()

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Path = Join-Path $script:Root 'scripts\Set-HybridIdentitySync.ps1'
    $script:Text = Get-Content $script:Path -Raw
    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
    $script:ParseErrors = @($errors)
    $script:RepoRoot = (Resolve-Path (Join-Path $script:Root '..\..\..')).Path
    $script:SchemaPath = Join-Path $script:RepoRoot 'automation\shared\schemas\azure-local.environment.schema.json'
    $script:EnvPath = Join-Path $script:RepoRoot 'environment\azure-local\environment.yml'
    # commands that change state; each call must sit inside a script block passed to Invoke-Change
    $script:Writers = @('Set-AzKeyVaultSecret', 'Invoke-VmScript', 'Set-AzVMRunCommand', 'Remove-AzVMRunCommand')
    function Get-InvokeChangeBlocks {
        @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Change' }, $true) |
                ForEach-Object { $_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] } })
    }
    function Test-Inside($Node, $Blocks) { foreach ($b in $Blocks) { if ($Node.Extent.StartOffset -ge $b.Extent.StartOffset -and $Node.Extent.EndOffset -le $b.Extent.EndOffset) { return $true } }; $false }
    function Get-FunctionBody([string]$Name) { ($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true) | Select-Object -First 1).Body }
}

Describe 'Set-HybridIdentitySync.ps1 conventions' -Tag 'Scripts', 'Identity' {
    It 'parses without errors' { $script:ParseErrors | Should -BeNullOrEmpty }
    It 'requires PowerShell 7, StrictMode, Stop and has comment-based help' {
        $script:Text | Should -Match '#Requires -Version 7\.0'
        $script:Text | Should -Match 'Set-StrictMode -Version Latest'
        $script:Text | Should -Match "\`$ErrorActionPreference = 'Stop'"
        $script:Text | Should -Match '(?s)<#.*\.SYNOPSIS.*\.DESCRIPTION.*#>'
    }
    It 'plans by default: SupportsShouldProcess and an -Execute switch' {
        $script:Text | Should -Match 'SupportsShouldProcess'
        $script:Text | Should -Match '\[switch\]\s*\$Execute'
        $script:Text | Should -Match "if \(-not \`$Execute\) \{ Say ""  PLAN"
    }
    It 'reads every value from the environment file through Get-NIC26Config' {
        $script:Text | Should -Match 'Get-NIC26Config'
        $script:Text | Should -Match '\$hi\.cloud_sync'
    }
}

Describe 'Set-HybridIdentitySync.ps1 stages' -Tag 'Scripts', 'Identity' {
    BeforeAll {
        $script:Expected = @('CloudAccount', 'AdObjects', 'Agent', 'Register', 'Configure', 'Start', 'Verify')
        $p = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Stage' }
        $vs = $p.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $script:StageSet = @($vs.PositionalArguments | ForEach-Object { $_.Value })
    }
    It 'offers exactly the seven stages, in build order' { $script:StageSet | Should -Be $script:Expected }
    It 'defaults to all stages' { $script:Text | Should -Match ([regex]::Escape("[string[]]`$Stage = @('" + ($script:Expected -join "', '") + "')")) }
    It 'runs stages in the fixed order whatever order is passed' { $script:Text | Should -Match '\$run = @\(\$StageOrder \| Where-Object \{ \$_ -in \$Stage \}\)' }
    It 'has a section for stage <_>' -ForEach @('CloudAccount', 'AdObjects', 'Agent', 'Register', 'Configure', 'Start', 'Verify') {
        $script:Text | Should -Match ([regex]::Escape("'$_' -in `$run"))
    }
    It 'Verify is read-only (no Invoke-Change, no write verbs, no POST/PUT)' {
        $verify = $script:Text.Substring($script:Text.IndexOf('# ---- Verify'))
        $verify | Should -Not -Match 'Invoke-Change|Set-Az|New-Az|Remove-Az|Invoke-VmScript'
        $verify | Should -Not -Match 'Invoke-Graph (post|put|patch)'
    }
}

Describe 'Set-HybridIdentitySync.ps1 safety' -Tag 'Scripts', 'Identity' {
    It 'every state-changing command call sits inside an Invoke-Change block (plan by default)' {
        $blocks = Get-InvokeChangeBlocks
        $blocks.Count | Should -BeGreaterThan 5
        $fnInvokeVm = Get-FunctionBody 'Invoke-VmScript'
        $calls = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $script:Writers }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $inHelper = $fnInvokeVm -and $c.Extent.StartOffset -ge $fnInvokeVm.Extent.StartOffset -and $c.Extent.EndOffset -le $fnInvokeVm.Extent.EndOffset
            ($inHelper -or (Test-Inside $c $blocks)) | Should -BeTrue -Because "$($c.Extent.Text) (line $($c.Extent.StartLineNumber)) must be gated by -Execute"
        }
        $graphWrites = @($script:Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Graph' -and $n.CommandElements.Count -gt 1 -and $n.CommandElements[1].Extent.Text -in 'post', 'put', 'patch' }, $true))
        $graphWrites.Count | Should -BeGreaterThan 3
        foreach ($c in $graphWrites) { (Test-Inside $c $blocks) | Should -BeTrue -Because "$($c.Extent.Text.Substring(0, [Math]::Min(80, $c.Extent.Text.Length))) (line $($c.Extent.StartLineNumber)) must be gated by -Execute" }
    }
    It 'passes credentials to the VM only as a protected Run Command parameter and always removes the Run Command' {
        $script:Text | Should -Match '-Protected @\{ Payload = \$payload \}'
        $fn = (Get-FunctionBody 'Invoke-VmScript').Extent.Text
        $fn | Should -Match 'ProtectedParameter'
        $fn | Should -Match '(?s)finally \{[^}]*Remove-AzVMRunCommand'
        # the password values never go into the plain (visible) parameter set
        $script:Text | Should -Not -Match '-Parameters @\{[^}]*(Pw|Password|Payload)'
    }
    It 'never writes a secret to output' {
        $sayLines = @($script:Text -split "`n" | Where-Object { $_ -match '\bSay\b|Write-(Output|Host|Information|Verbose)' })
        $sayLines | Should -Not -Match '\$(pw|payload|body)\b|HiaPw|DomPw|-AsPlainText'
        # -AsPlainText results are only assigned (vault reads into memory), never emitted
        @($script:Text -split "`n" | Where-Object { $_ -match 'Get-AzKeyVaultSecret[^\r\n]*-AsPlainText' }) | ForEach-Object { $_ | Should -Match '(=|HiaUpn|HiaPw|DomPw)\s' }
        $script:Text | Should -Match 'Remove-Variable pw'
        $script:Text | Should -Match 'Remove-Variable payload'
    }
    It 'the user-create call withholds the Graph response on failure' { $script:Text | Should -Match 'Invoke-Graph post "\$Graph/v1\.0/users" \$body -Sensitive' }
    It 'needs an explicit switch before creating a forest KDS root key' {
        $script:Text | Should -Match '\[switch\]\$AllowKdsRootKeyCreation'
        $script:Text | Should -Match "if \(\`$AllowKdsCreate -ne 'true'\) \{ throw"
    }
    It 'checks the agent installer signature before installing' { $script:Text | Should -Match "Get-AuthenticodeSignature(?s).*O=Microsoft Corporation(?s).*'/quiet'" }
}

Describe 'Set-HybridIdentitySync.ps1 has no lab literals (G5)' -Tag 'Scripts', 'Identity' {
    It 'contains no GUID, IPv4 address, tenant domain, vault, VM or account name' {
        $code = $script:Text
        [regex]::Matches($code, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object Value |
            Should -BeNullOrEmpty -Because 'GUIDs come from the environment file; AD extended rights are looked up by name'
        $code | Should -Not -Match '\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b'
        # generic shapes here; the lab's own names (domain, UPN suffix, accounts, gMSA, server, secret prefix) are checked by
        # the next test, which reads them from the environment file, so this public test carries no lab literal
        # (owner approved 13 Oct)
        $code | Should -Not -Match '(?i)\.onmicrosoft\.com|msappproxy\.net'
        $code | Should -Not -Match '(?i)\bkv-[a-z0-9-]+|\bvm-[a-z]+-[a-z0-9-]+|(?<![\w/#-])gmsa-[a-z0-9-]+\$?'   # a gMSA name, not a Learn URL fragment
    }
    It 'does not repeat any value of hybrid_identity from the environment file' -Skip:(-not (Test-Path (Join-Path (Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) '..\..\..')).Path 'environment\azure-local\environment.yml'))) {
        if (-not (Get-Module -ListAvailable powershell-yaml)) { Set-ItResult -Skipped -Because 'powershell-yaml is not installed'; return }
        Import-Module powershell-yaml
        $hi = (Get-Content $script:EnvPath -Raw | ConvertFrom-Yaml).hybrid_identity
        $allowed = @('US', 'Sync', 'SOFS', 'AVD', 'NIC26')   # generic words that also occur in prose
        $values = [System.Collections.Generic.List[string]]::new()
        function Add-Values($Node) {
            if ($Node -is [System.Collections.IDictionary]) { foreach ($k in $Node.Keys) { Add-Values $Node[$k] } }
            elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) { foreach ($i in $Node) { Add-Values $i } }
            elseif ($Node -is [string] -and $Node.Length -ge 4 -and $Node -notin $allowed) { $values.Add($Node) }
        }
        Add-Values $hi
        $values.Count | Should -BeGreaterThan 20
        foreach ($val in $values) { $script:Text.Contains($val) | Should -BeFalse -Because "'$val' belongs in environment.yml only" }
    }
}

Describe 'cloud_sync configuration contract' -Tag 'Scripts', 'Identity' {
    BeforeAll {
        $schema = Get-Content $script:SchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $script:CsSchema = $schema.properties.hybrid_identity.properties.cloud_sync
        $script:Used = @([regex]::Matches($script:Text, '\$cs\.(\w+)') | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches($script:Text, "Get-Opt \`$cs '(\w+)'") | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    }
    It 'the schema defines hybrid_identity.cloud_sync and rejects unknown keys' {
        $script:CsSchema | Should -Not -BeNullOrEmpty
        $script:CsSchema.additionalProperties | Should -BeFalse
    }
    It 'every cloud_sync key the script reads is in the schema' {
        $script:Used.Count | Should -BeGreaterThan 8
        foreach ($k in $script:Used) { $script:CsSchema.properties.Keys | Should -Contain $k }
    }
    It 'every key the script reads without a default is required by the schema' {
        $direct = @([regex]::Matches($script:Text, '\$cs\.(\w+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($k in $direct) { $script:CsSchema.required | Should -Contain $k }
    }
}
