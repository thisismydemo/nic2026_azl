# cluster-configure/monitoring — Insights, DCRs, alerts (outline §3.1)

Implements outline §3.1 and landing-zone §7.1–7.2 (decision A: the Insights DCR is created through the Insights flow, then managed in code).

| Control | How | Remove (live replay, D-014) |
|---|---|---|
| **Insights enablement** | `Enable-ClusterInsights.ps1 -Action Enable`: PUT `clusters/arcSettings/default/extensions/AzureMonitorWindowsAgent` (api `2023-08-01`, the exact resource the Microsoft at-scale policy deploys) + `dataCollectionRuleAssociations` (`2023-03-11`) on each node → `dcr-iic-nic26-azl-insights-eus-01` | `-Action Disable` deletes the associations (same as the portal's *Disable Insights*; data kept) |
| **Insights DCR** `dcr_insights` | created **once** in the portal dialog (Azure Local → Capabilities → Insights → Get started → Create New, name = catalog name, workspace `law`). `manage_insights_dcr_in_iac=true` authors it (five counters, health + SDDC channels) **against Microsoft's recommendation**; off by default | n/a (kept) |
| Extra fault channels | `-ExtraEventChannels 'Microsoft-Windows-Networking-NetworkATC/Operational!*'` patches the DCR's Microsoft-Event source (needed by the intent-drift alert) | `-Action Disable -RemoveExtraEventChannels` |
| VM Insights DCR `dcr-iic-nic26-azl-vminsights-eus-01` | Bicep `avm/res/insights/data-collection-rule:0.11.0` / Terraform `azurerm_monitor_data_collection_rule` (gap-fill; TF AVM is 0.1.0) | deleted by `-Action Remove` |
| Alert rules `alert-iic-nic26-{node-down,storage-health,intent-drift,capacity}-eus-01` | Bicep `avm/res/insights/scheduled-query-rule:0.6.0` / TF `azurerm_monitor_scheduled_query_rules_alert_v2`; PT5M / PT15M, action group `ag_ops` | deleted |
| Key Vault backup alerts `alert-iic-nic26-kv-backup-eus-01` | alert processing rule (`Microsoft.AlertsManagement/actionRules@2021-08-08` / `azurerm_monitor_alert_processing_rule_action_group`) scoped to the cluster RG, adds the action group to alerts whose name contains `KeyVault` (platform alerts `KeyVaultAccess`, `KeyVaultDoesNotExist`) | deleted |

Cost: the Insights DCR collects only the five counters and two channels Microsoft documents (plus the NetworkATC channel for the demo); alerts evaluate every 5 minutes against the workspace; the workspace daily cap is the landing zone's. The *(verify)* list: Heartbeat `ResourceType =~ "machines"` for Arc nodes; health-channel event levels/`RenderedDescription` text for the storage and capacity queries (tune after the first fault rehearsal, outline §4.2); the extension type name `AzureMonitorWindowsAgent` on `arcSettings` is from the Learn policy definition.

Catalog note: the workspace is the lab-wide singleton `law-iic-nic26-eus-01` (the registry allows an empty purpose for `law`, and the landing zone creates it under that name); pass the real workspace through `log_analytics_workspace_id` (landing-zone output, recorded in the environment file) — the derived name is a fallback only. Same for `action_group_id`.

## Run

```powershell
cd .\automation\azure-local\cluster-configure\monitoring\scripts
.\Invoke-MonitoringConfigure.ps1 -Action Apply -Execute          # DCR (VM Insights), alerts, routing rule
.\Enable-ClusterInsights.ps1 -Action Enable -ExtraEventChannels 'Microsoft-Windows-Networking-NetworkATC/Operational!*' -Execute
# live replay: .\Enable-ClusterInsights.ps1 -Action Disable -Execute  →  on stage: -Action Enable -Execute
```

State: `..\..\scripts\Get-Day2ControlState.ps1` → control `monitoring` (Applied = AMA extension Succeeded, every node associated, all alert rules present).

## Node-down window (review R-35)

The node-down rule looks back **one hour** (the other rules use `alert_window_size`). A node that has been silent longer than the window has no Heartbeat rows and would drop out of the query result, so the alert would stop firing and auto-resolve while the node was still down. `node_heartbeat_minutes` is therefore limited to 5 to 45; the alert fires from that many minutes of silence until the node has been down an hour. The capacity rule now splits by `Computer` like the others.
