# Variables mirror solution.yml inputs 1:1 (same canonical snake_case names; contract §2, §6).
# Values arrive from terraform.generated.tfvars.json (ConvertTo-NIC26TfVars); nothing is defaulted to a tenant value.

# --- placement ------------------------------------------------------------------------------------
variable "tenant_id" {
  type        = string
  description = "Entra tenant ID (GUID)."
}
variable "subscription_id" {
  type        = string
  description = "Azure Local landing-zone subscription ID (GUID)."
}
variable "management_group_id" {
  type        = string
  description = "Parent management group ID; the policy initiative definition is stored here (design §2.3). Empty skips it."
  default     = ""
}
variable "location" {
  type        = string
  description = "Azure region for every resource (D-010). No default is assumed."
}
variable "org" {
  type        = string
  description = "Naming segment <org> (accepted for parameter-file parity; names come from var.names)."
}
variable "token" {
  type        = string
  description = "Naming segment <token> (parity only)."
}
variable "region_short" {
  type        = string
  description = "Naming segment <region> (parity only)."
}
variable "tags" {
  type        = map(string)
  description = "The seven required tags (naming standard §3a)."
}

# --- governance -----------------------------------------------------------------------------------
variable "budget_monthly_amount" {
  type        = number
  description = "Monthly budget amount (design §2.5)."
}
variable "budget_contact_emails" {
  type        = list(string)
  description = "Budget and action-group e-mail recipients."
}
variable "defender_servers_plan" {
  type        = string
  description = "Defender for Servers plan: P1 | P2 | off (design §7.3)."
  default     = "off"
  validation {
    condition     = contains(["P1", "P2", "off"], var.defender_servers_plan)
    error_message = "defender_servers_plan must be P1, P2 or off."
  }
}
variable "enable_defender_keyvault" {
  type    = bool
  default = false
}
variable "enable_defender_storage" {
  type    = bool
  default = false
}

# --- network --------------------------------------------------------------------------------------
variable "spoke_address_space" { type = string }
variable "subnet_jump_prefix" { type = string }
variable "subnet_pe_prefix" { type = string }
variable "subnet_mgmt_prefix" { type = string }
variable "subnet_asr_prefix" { type = string }
variable "subnet_asr_test_prefix" { type = string }
variable "dns_servers" {
  type        = list(string)
  description = "VNet custom DNS servers (the existing domain controllers)."
}
variable "hub_vnet_id" {
  type        = string
  description = "Existing hub VNet resource ID (shared; referenced only)."
}
variable "hub_resource_group_name" { type = string }
variable "hub_subscription_id" { type = string }
variable "bastion_subnet_prefix" { type = string }
variable "p2s_client_pool" { type = string }
variable "identity_spoke_vnet_id" { type = string }
variable "management_spoke_vnet_id" { type = string }
variable "onprem_prefixes" { type = list(string) }
variable "avd_spoke_vnet_id" {
  type    = string
  default = ""
}
variable "identity_spoke_prefix" { type = string }
variable "management_spoke_prefix" { type = string }
variable "avd_spoke_prefix" {
  type    = string
  default = ""
}
variable "enable_identity_peering" {
  type        = bool
  description = "P-13: direct spoke<->identity peerings (one resource on the shared identity VNet; owner approval)."
  default     = false
}
variable "enable_management_peering" {
  type        = bool
  description = "P-13: direct spoke<->management peerings (one resource on the shared management VNet; owner approval)."
  default     = false
}
variable "enable_private_endpoints" {
  type        = bool
  description = "Owner decision D-029: false (default) = no private endpoints; both vaults use their public endpoint, no privatelink zones or links, monitor private link off. true restores the private-endpoint design."
  default     = false
}
variable "enable_monitor_private_link" {
  type    = bool
  default = false
}
variable "privatelink_vaultcore_zone_id" {
  type        = string
  description = "Existing shared privatelink.vaultcore.azure.net zone to reuse; empty creates the lab's own zone (P-11)."
  default     = ""
}

# --- identity / security --------------------------------------------------------------------------
variable "group_object_ids" {
  type        = map(string)
  description = "Object IDs keyed by catalog key: grp_lab_operators, grp_azl_admins, grp_azl_operators, grp_azl_readers."
}
variable "pim_max_activation_hours" {
  type    = number
  default = 8
}
variable "manage_pim_in_iac" {
  type        = bool
  description = "Create PIM eligible assignments from Terraform instead of Initialize-LzPim.ps1."
  default     = false
}
variable "kv_soft_delete_days" {
  type    = number
  default = 7
}
variable "kv_public_network_access" {
  type        = map(string)
  description = "{ ops = Enabled|Disabled, azl = Enabled|Disabled } (design §5.3)."
}
variable "azl_rp_app_object_id" {
  type        = string
  description = "Object ID of the Azure Local resource provider first-party application (design §6.2, O6)."
}

# --- monitoring -----------------------------------------------------------------------------------
variable "law_retention_days" {
  type    = number
  default = 30
}
variable "law_daily_cap_gb" {
  type    = number
  default = 2
}

# --- cluster prerequisites / BC-DR ----------------------------------------------------------------
variable "enable_voucher_storage" {
  type    = bool
  default = false
}
variable "rsv_storage_redundancy" {
  type    = string
  default = "LocallyRedundant"
  validation {
    condition     = contains(["LocallyRedundant", "ZoneRedundant", "GeoRedundant"], var.rsv_storage_redundancy)
    error_message = "rsv_storage_redundancy must be LocallyRedundant, ZoneRedundant or GeoRedundant."
  }
}

# --- management (jump server) ---------------------------------------------------------------------
variable "enable_jump_server" {
  type    = bool
  default = true
}
variable "jump_vm_size" {
  type    = string
  default = "Standard_D4s_v4"
}
variable "jump_data_disk_gb" {
  type    = number
  default = 256
}
variable "jump_private_ip" {
  type    = string
  default = ""
}
variable "jump_encryption_at_host" {
  type    = bool
  default = false
}
variable "jump_admin_username_secret" {
  type        = string
  description = "keyvault:// reference (name only) consumed by the deploy script; parity only."
  default     = ""
}
variable "jump_admin_password_secret" {
  type        = string
  description = "keyvault:// reference (name only) consumed by the deploy script; parity only."
  default     = ""
}
# Run-time secure values: supplied by Invoke-LzAzureLocalDeploy.ps1 through TF_VAR_* in the process environment only.
# `ephemeral` keeps them out of plan and state; they are consumed solely by azapi `sensitive_body` (write-only).
variable "jump_admin_username" {
  type      = string
  sensitive = true
  ephemeral = true
  default   = null
}
variable "jump_admin_password" {
  type      = string
  sensitive = true
  ephemeral = true
  default   = null
}

# --- orchestration --------------------------------------------------------------------------------
variable "enabled_stages" {
  type        = list(string)
  description = "IaC stages to deploy in this run (subset of S1..S7)."
  default     = ["S1", "S2", "S3", "S4", "S5", "S6", "S7"]
}
variable "names" {
  type        = map(string)
  description = "Resolved name catalog (contract §10) - the ONLY source of resource names."
}

variable "central_log_analytics_workspace_id" {
  type        = string
  default     = ""
  description = "Resource ID of the central Log Analytics workspace of the platform management subscription; when set no workload workspace is created."
}

variable "deploy_platform_scope_items" {
  type        = bool
  default     = false
  description = "Deploy subscription policy and Defender, the activity-log export and the peerings on platform-owned VNets; false leaves them to their owners."
}
