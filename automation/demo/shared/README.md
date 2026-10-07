# demo-shared: console prerequisites and the DemoCommon module

Shared by the demo scripts of both sessions. Everything runs on a **Windows operator machine** (a jump server or your own admin workstation) under your own sign-in. Nothing deploys; the only state these scripts change is a small fault-lock registry on that machine.

| Script | Purpose |
|---|---|
| `scripts/Test-DemoPrerequisites.ps1` | Pass/fail list for the operator session: PowerShell 7.4+, Windows, no transcript, modules, Az context, environment files, state folder, no fault lock |
| `scripts/Start-DemoRecording.ps1` | Prepares the presenter console (transcript guard, hygiene terms, window title, checklist) |
| `scripts/DemoCommon.psd1/.psm1` | Module: screen-hygiene filter, guards, fault locks, mockable wrappers (remoting, Az, Graph, Key Vault, Site Recovery, AVD) |

## Screen hygiene

`Write-DemoScreen` / `Hide-DemoSensitiveText` mask, before anything reaches the console: the tenant domain, tenant and subscription IDs, the owner e-mail and `screen_hidden_terms` from your environment file; and **every GUID**. Add your own organisation or tenant short names to `screen_hidden_terms` (or call `Add-DemoHiddenTerm`). Every on-stage script in `demo/azure-local` and `demo/avd` prints through this filter. `tests/DemoShared.Tests.ps1` proves the masking.

## Fault-lock registry

`New-/Get-/Remove-DemoFaultLock` keep one JSON per active fault under `$env:NIC26_DEMO_STATE_DIR` (default `%LOCALAPPDATA%\nic26-demo`). The fault helpers refuse while another fault is active and clear the lock only when the undo verified recovery. `Test-DemoPrerequisites.ps1` and both smoke tests report an active lock as RED.

## Tests and gates

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path .\automation\demo\shared\tests -Output Detailed
Invoke-ScriptAnalyzer -Path .\automation\demo -Recurse -Settings .\automation\shared\powershell\PSScriptAnalyzerSettings.psd1
```

Tests mock every Az/Graph/remoting wrapper; no Azure, no device, no transcript. Environment variables used by the tests and by offline authoring: `NIC26_ASSUME_PLATFORM=Windows|Linux`, `NIC26_ASSUME_TRANSCRIPT=1`, `NIC26_DEMO_STATE_DIR`.
