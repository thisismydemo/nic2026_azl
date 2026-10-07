# cluster-configure/defender — Defender for Servers toggle (outline §3.5)

Design §7.3 option A: foundational CSPM is set by the landing zone; **Defender for Servers Plan 2** is switched on in Day-2 Ready and is the reversible control for the live replay. Apply sets `Microsoft.Security/pricings/VirtualMachines` to Standard/`defender_servers_plan`; Remove sets it to Free (the only way to "remove" a pricing). Key Vault and Storage plans are flags (default off). Preview note: Defender for Cloud on Azure Local is documented as preview (Learn: Manage system security with Defender for Cloud); MDE is auto-provisioned through the Defender for Endpoint integration on the Arc nodes and Arc VMs.

| Track | Resource |
|---|---|
| Bicep (subscription scope) | gap-fill `Microsoft.Security/pricings@2024-01-01` (no AVM module; same as the landing zone) |
| Terraform | `azurerm_security_center_subscription_pricing` (destroy = Free) |

```powershell
cd .\automation\azure-local\cluster-configure\defender\scripts
.\Set-DefenderServersPlan.ps1 -Action Apply -Execute     # P2
.\Set-DefenderServersPlan.ps1 -Action Remove -Execute    # Free — before the session; Apply again on stage
```

State: `..\..\scripts\Get-Day2ControlState.ps1` → control `defender` (Applied = VirtualMachines tier Standard with the configured sub plan). Compliance/secure score is not instant (outline §3.5).
