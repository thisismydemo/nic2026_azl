# Inputs = solution.yml inputs (canonical snake_case; contract §2/§6). Values come from terraform.generated.tfvars.json
# (ConvertTo-NIC26TfVars) plus -var deployment_mode=... from Invoke-ClusterDeploy.ps1. No defaults carry tenant data.

variable "tenant_id" { type = string }
variable "subscription_id" { type = string }
variable "location" { type = string }
variable "token" {
  type = string
  validation {
    condition     = length(var.token) <= 8
    error_message = "token is used as the deployment namingPrefix and must be at most 8 characters."
  }
}
variable "tags" { type = map(string) }

variable "cluster_name" { type = string }
variable "identity" {
  type = object({
    model                       = string
    dns_zone                    = string
    deployment_identity_name    = string
    local_admin_username_secret = string
    local_admin_password_secret = string
  })
  validation {
    condition     = var.identity.model == "local-identity-keyvault"
    error_message = "identity.model must be local-identity-keyvault (D-008)."
  }
}
variable "kv_azl_name" { type = string }
variable "witness" {
  type = object({
    type                 = string
    storage_account_name = string
    storage_key_secret   = optional(string)
  })
  validation {
    condition     = var.witness.type == "cloud"
    error_message = "A two-node system needs a cloud witness (witness.type = cloud)."
  }
}
variable "azl_rp_app_object_id" { type = string }
variable "local_admin_secret_name" {
  type    = string
  default = ""
}
variable "witness_key_secret_name" {
  type    = string
  default = ""
}

variable "nodes" {
  type = list(object({
    name          = string
    management_ip = string
    storage_ips   = object({ smb1 = string, smb2 = string })
    lom1_mac      = optional(string)
  }))
  validation {
    condition     = !contains([for n in var.nodes : lower(n.name)], lower(var.cluster_name))
    error_message = "cluster_name must differ from every node name."
  }
}
variable "intents" {
  type = list(object({
    name          = string
    traffic_types = list(string)
    adapters      = list(string)
    overrides = optional(object({
      jumbo_packet           = optional(number)
      rdma_protocol          = optional(string)
      storage_vlans          = optional(list(number))
      enable_storage_auto_ip = optional(bool)
      rdma_enabled           = optional(bool)
    }))
  }))
}
variable "ip_plan" {
  type = object({
    management_subnet   = string
    default_gateway     = string
    infrastructure_pool = object({ start = string, end = string })
    cluster_ip          = optional(string)
    dns_servers         = list(string)
    dns_zone            = string
    ntp_servers         = optional(list(string))
    reserved_ranges     = optional(list(string))
    storage_auto_ip     = bool
  })
}
variable "vlans" {
  type = map(object({
    id         = number
    name       = optional(string)
    subnet     = string
    gateway    = optional(string)
    routed     = optional(bool)
    dhcp_range = optional(object({ start = string, end = string }))
  }))
}
variable "qos" {
  type = object({
    storage_priority          = number
    cluster_priority          = number
    storage_bandwidth_percent = number
    cluster_bandwidth_percent = optional(number)
    jumbo_frame_size          = number
  })
}
variable "rdma_protocol" {
  type    = string
  default = ""
  validation {
    condition     = contains(["", "RoCEv2", "iWARP", "RoCE"], var.rdma_protocol)
    error_message = "rdma_protocol must be '', RoCEv2, iWARP or RoCE (string; never a numeric keyword)."
  }
}
variable "networking_type" {
  type    = string
  default = "switchedMultiServerDeployment"
}
variable "networking_pattern" {
  type    = string
  default = "custom"
}

variable "release" {
  type = object({
    azure_local_version = string
    sbe_version         = optional(string)
    os_build            = optional(string)
  })
}
variable "sbe" {
  type = object({
    version                = optional(string)
    family                 = optional(string)
    publisher              = optional(string)
    manifest_source        = optional(string)
    manifest_creation_date = optional(string)
  })
  default = {}
}
variable "security_settings" {
  type = object({
    drift_control_enforced    = bool
    credential_guard_enforced = bool
    smb_signing_enforced      = bool
    smb_cluster_encryption    = bool
    bitlocker_boot_volume     = bool
    bitlocker_data_volumes    = bool
    wdac_enforced             = bool
  })
  default = {
    drift_control_enforced    = true
    credential_guard_enforced = true
    smb_signing_enforced      = true
    smb_cluster_encryption    = true
    bitlocker_boot_volume     = true
    bitlocker_data_volumes    = true
    wdac_enforced             = true
  }
}
variable "observability" {
  type = object({
    streaming_data_client = bool
    eu_location           = bool
    episodic_data_upload  = bool
  })
  default = {
    streaming_data_client = true
    eu_location           = false
    episodic_data_upload  = true
  }
}
variable "storage_configuration_mode" {
  type    = string
  default = "InfraOnly"
  validation {
    condition     = contains(["Express", "InfraOnly", "KeepStorage"], var.storage_configuration_mode)
    error_message = "storage_configuration_mode must be Express, InfraOnly or KeepStorage."
  }
}
variable "logs_retention_days" {
  type    = number
  default = 30
}
variable "assign_hci_rp_role" {
  type    = bool
  default = false
}

variable "deployment_mode" {
  type    = string
  default = "Validate"
  validation {
    condition     = contains(["Validate", "Deploy"], var.deployment_mode)
    error_message = "deployment_mode must be Validate or Deploy."
  }
}
variable "names" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["rg_azl", "rg_sec", "kv_azl", "st_witness", "st_diag", "cl_azl"] : contains(keys(var.names), k)])
    error_message = "names must contain rg_azl, rg_sec, kv_azl, st_witness, st_diag and cl_azl (contract §10)."
  }
}
