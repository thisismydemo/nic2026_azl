# cluster-configure/monitoring — Insights, DCRs, alerts (outline §3.1)

Implements outline §3.1 and landing-zone §7.1–7.2 (decision A: the Insights DCR is created through the Insights flow, then managed in code).

| Control | How | Remove (live replay, D-014) |
|---|---|---|
| **Insights enablement** | `Enable-ClusterInsights.ps1 -Action Enable`: PUT `clusters/arcSettings/default/extensions/AzureMonitorWindowsAgent` (api `2023-08-01`, the exact resource the Microsoft at-scale policy deploys) + `dataCollectionRuleAssociations` (`2023-03-11`) on each node → `dcr-iic-nic26-azl-insights-eus-01` | `-Action Disable` deletes the associations (same as the portal's *Disable Insights*; data kept) |
| **Insights DCR** `dcr_insights` | The lab sets `manage_insights_dcr_in_iac=true` (D-054): IaC authors the DCR in the exact shape the Insights dialog creates (`perfCounterDataSource` five counters at `insights_sampling_seconds` = 10, `eventLogsDataSource` with the SDDC 3000-3004 and health channels) plus `insights_extra_event_channels` (Network ATC for the intent-drift alert, failover clustering Level 1-3). Without the flag the dialog creates it once (Microsoft's recommendation) | n/a (kept) |
| **Lab workspace** `law` | `create_workspace=true` (D-054) creates `law-iic-nic26-eus-01` (PerGB2018, `law_retention_days`, `law_daily_cap_gb`, resource-context access); every DCR and log alert here uses it. Note: a brand-new workspace needs a few minutes before DCRs can target its tables (first apply on 12 Oct failed with `InvalidOutputTable`; the re-run succeeded) | deleted only by hand |
| **Health alerts** | `Enable-ClusterInsights.ps1 -Action Enable` also installs `AzureEdgeAlerts` (publisher `Microsoft.AzureStack.HCI.Alerts`, type `AlertsForWindowsHCI`) on the cluster arcSettings, the same extension the portal's Health alerts tile installs; `alert_health_routing` (alert processing rule on the cluster, signal type not Metric) adds the action group | `-SkipHealthAlerts`; the rule is deleted by `-Action Remove` |
| **Recommended metric alerts** | `alert_cpu`, `alert_memory`, `alert_vol_read_latency`, `alert_vol_write_latency`, `alert_net_in`, `alert_net_out`: `Microsoft.Insights/metricAlerts` on the cluster resource with the Learn table's thresholds and the live metric names (`Hyper-V Hypervisor Logical Processor\% Total Run Time`, `Memory\Available Bytes`, `Cluster CSVFS\Avg. sec/Read` and `/Write`, `Network Adapter\Bytes Received/sec` and `Bytes Sent/sec`), split by `ClusterNodeName`, severity 3 | deleted |
| Extra fault channels | `-ExtraEventChannels 'Microsoft-Windows-Networking-NetworkATC/Operational!*'` patches the DCR's Microsoft-Event source (needed by the intent-drift alert) | `-Action Disable -RemoveExtraEventChannels` |
| VM Insights DCR `dcr-iic-nic26-azl-vminsights-eus-01` | Bicep `avm/res/insights/data-collection-rule:0.11.0` / Terraform `azurerm_monitor_data_collection_rule` (gap-fill; TF AVM is 0.1.0) | deleted by `-Action Remove` |
| Alert rules `alert-iic-nic26-{node-down,storage-health,intent-drift,capacity}-eus-01` | Bicep `avm/res/insights/scheduled-query-rule:0.6.0` / TF `azurerm_monitor_scheduled_query_rules_alert_v2`; PT5M / PT15M, action group `ag_ops` | deleted |
| Key Vault backup alerts `alert-iic-nic26-kv-backup-eus-01` | alert processing rule (`Microsoft.AlertsManagement/actionRules@2021-08-08` / `azurerm_monitor_alert_processing_rule_action_group`) scoped to the cluster RG, adds the action group to alerts whose name contains `KeyVault` (platform alerts `KeyVaultAccess`, `KeyVaultDoesNotExist`) | deleted |

Cost: the Insights DCR collects only the five counters and two channels Microsoft documents (plus the NetworkATC channel for the demo); alerts evaluate every 5 minutes against the workspace; the workspace daily cap is the landing zone's. The *(verify)* list: Heartbeat `ResourceType =~ "machines"` for Arc nodes; health-channel event levels/`RenderedDescription` text for the storage and capacity queries (tune after the first fault rehearsal, outline §4.2); the extension type name `AzureMonitorWindowsAgent` on `arcSettings` is from the Learn policy definition.

Live 12 Oct 2026 (R-entry in the verification log): workspace, both DCRs, 4 log alerts, 6 metric alerts, both processing rules; AMA and AzureEdgeAlerts Succeeded on both nodes; Heartbeat `ResourceType` = `machines` confirmed, so the node-down query needs no change. Catalog note: the workspace is the lab-wide singleton `law-iic-nic26-eus-01` (the registry allows an empty purpose for `law`, and the landing zone creates it under that name); pass the real workspace through `log_analytics_workspace_id` (landing-zone output, recorded in the environment file) — the derived name is a fallback only. Same for `action_group_id`.

## Run

```powershell
cd .\automation\azure-local\cluster-configure\monitoring\scripts
.\Invoke-MonitoringConfigure.ps1 -Action Apply -Execute          # workspace, both DCRs, log + metric alerts, routing rules
.\Enable-ClusterInsights.ps1 -Action Enable -Execute               # AMA + AzureEdgeAlerts on arcSettings, DCR association per node
# live replay: .\Enable-ClusterInsights.ps1 -Action Disable -Execute  →  on stage: -Action Enable -Execute
```

State: `..\scripts\Get-Day2ControlState.ps1` → control `monitoring` (Applied = AMA extension Succeeded, every node associated, all alert rules present).

## Node-down window (review R-35)

The node-down rule looks back **one hour** (the other rules use `alert_window_size`). A node that has been silent longer than the window has no Heartbeat rows and would drop out of the query result, so the alert would stop firing and auto-resolve while the node was still down. `node_heartbeat_minutes` is therefore limited to 5 to 45; the alert fires from that many minutes of silence until the node has been down an hour. The capacity rule now splits by `Computer` like the others.
