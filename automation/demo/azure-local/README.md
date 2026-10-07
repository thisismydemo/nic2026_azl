# demo-azure-local — Azure Local session demo helpers

Scripts behind the live beats of planning/sessions/azure-local/outline.md. All of them run on the Windows jump server, reach the cluster **only** over PowerShell remoting (cluster FQDN / node names); Azure reads use the operator's Az context. Read-only scripts change nothing; every disruptive script defaults to `-WhatIf`, requires `-Execute`, prints its **UNDO command first**, records a fault lock and is idempotent.

| Beat | Script | Mode |
|---|---|---|
| §2.6 red baseline → §3.7 green gate | `Test-Day2Readiness.ps1` | read-only; exit code 0/1 |
| pre-session reset (D-014) | `Reset-Day2Controls.ps1` → live `Restore-Day2Controls.ps1 -Control <key>` | `-WhatIf` default; lists exactly what it removes/applies |
| §2.5/§2.6/§4.2 | `Show-ClusterState.ps1` | read-only dashboard (nodes, S2D, intents, ARB, LCM) |
| §4.1 | `Invoke-LcmReadiness.ps1` | read-only (`-RunReadinessCheck` runs Test-EnvironmentReadiness) |
| §4.2 drive | `Invoke-DriveFault.ps1` / `Undo-DriveFault.ps1` | `-Execute`; PnP disable (or `-Method Retire`) of one healthy data drive |
| §4.2 drift | `Invoke-IntentDrift.ps1` / `Undo-IntentDrift.ps1` | `-Execute`; JumboPacket on ONE Compute adapter of ONE node; status before/after |
| every fault | `Test-FaultPreflight.ps1` | read-only refusal gate shared by the fault helpers (also knows a node-outage fault for layers that add one) |
| §3.3 / §4.5 / §5 | `Show-AsrState.ps1`, `Start-AsrPlannedFailover.ps1`, `Get-AsrFailoverStatus.ps1` | start is `-WhatIf` default; status read-only |
| before the session | `Test-DemoSmoke.ps1` | read-only pass/fail list; exit code |

## Fault safety (outline §4.2: drive → drift → node, never stacked)

`Test-FaultPreflight.ps1` refuses (RED) when: another fault lock exists · any node is not Up · the pool or a volume is not Healthy · **a storage/repair job is running** · `Debug-StorageSubSystem` reports a Major/Critical fault · any intent is not Success · the witness is not Online. Drive adds "≥ 2 healthy data drives on the node, volumes mirrored"; NodePowerOff adds "the other node Up, every physical disk Healthy, witness Online". Each `Undo-*` clears the lock **only after** storage is Healthy again (`-ResyncTimeoutMinutes`), so the next fault keeps refusing until the cluster really recovered.

```powershell
.\Show-ClusterState.ps1 -Count 20 -IntervalSeconds 20 -SkipUpdate     # second window during the beats
.\Invoke-DriveFault.ps1 -NodeName nic26-01-n01 -Execute ; .\Undo-DriveFault.ps1 -Execute
.\Invoke-IntentDrift.ps1 -NodeName nic26-01-n02 -Execute ; .\Undo-IntentDrift.ps1 -Execute
```

Drive fault method: `Disable-PnpDevice` on the drive's device instance (the pool shows Lost Communication; nothing is written to the drive). If the serial-to-PnP mapping is ambiguous the script says so and `-Method Retire` (`Set-PhysicalDisk -Usage Retired`) is the fallback; the undo re-enables / un-retires and waits for the repair. Drift: `*JumboPacket` 1514 → 4088 on the first Compute-intent adapter (`-AdapterName`, `-DriftValue`); ATC remediates on its next pass or on `Set-NetIntentRetryState -Name Compute`.

## Day-2 controls

`day2-controls.yml` maps every outline §3 control to the remove/apply scripts **owned by the cluster-configure solutions** (`automation/azure-local/cluster-configure/<solution>/scripts/...`) and marks the ones that are never removed before a session (`reversible: false`: backup, Site Recovery, PIM access, security baseline, workload platform). `Reset-Day2Controls.ps1` lists exactly what it would remove and refuses `-Execute` while a remove step is missing (`-SkipMissing` to proceed); it records the removed keys so `Restore-Day2Controls.ps1` re-applies them in outline order. The keys are also the contract for `Get-Day2ControlState.ps1` rows `{ Control, Status = Present|Missing|Partial|Unknown, Detail }` consumed by `Test-Day2Readiness.ps1` (`-ControlStateScript`, `-ControlStatePath` or `-ControlState`).

## Inputs

From `Get-NIC26Config -Scope azure-local` (see `solution.yml`): `cluster_name`, `identity.dns_zone`, `nodes[]` (name, management_ip), `intents[]`, `log_analytics_workspace_id`, naming segments. Names (`rg-…-azl`, `rsv-…-azl`, `rp-…-tier1`, `kv-…-ops/azl`) are resolved by `New-NIC26ResourceName`; every script accepts explicit overrides (`-ComputerName`, `-ResourceGroupName`, `-VaultName`, …).

## Tests

```powershell
Import-Module Pester -RequiredVersion 5.9.1
Invoke-Pester -Path .\automation\demo\azure-local\tests -Output Detailed
```

Covers: preflight refusals (repair running, other fault active, node down, unhealthy disk/volume/intent/witness, unknown node), WhatIf defaults and UNDO-first output, `-Execute` paths with mocked remoting, typed confirmation, undo flows and lock lifecycle, readiness red/green and exit code, reset/restore ordering and state file, ASR refusals, dashboard hygiene. No Azure or device is contacted.
