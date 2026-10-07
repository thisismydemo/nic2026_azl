# Inputs = solution.yml inputs (canonical snake_case). Values from terraform.generated.tfvars.json (ConvertTo-NIC26TfVars).
variable "subscription_id" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "cluster_name" { type = string }
variable "identity" { type = map(string) }
variable "nodes" {
  type = list(object({
    name          = string
    management_ip = string
    storage_ips   = optional(map(string))
    lom1_mac      = optional(string)
  }))
}
variable "logical_networks" {
  type = list(object({
    name        = string
    vlan_id     = number
    subnet      = string
    gateway     = string
    ip_pool     = object({ start = string, end = string })
    dns_servers = list(string)
  }))
}
variable "storage" {
  type = object({
    volumes = list(object({ name = string, resiliency = string, size_gb = number }))
    storage_paths = list(object({
      name   = string
      volume = string
      path   = optional(string)
    }))
  })
}
variable "vm_switch_name" {
  type    = string
  default = "ConvergedSwitch(compute)"
}
variable "marketplace_images" {
  type = list(object({
    key                = string
    publisher          = string
    offer              = string
    sku                = string
    os_type            = string
    version            = optional(string, "")
    hyper_v_generation = optional(string, "V2")
  }))
  default = []
}
variable "enable_network_security_group" {
  type    = bool
  default = false
}
variable "names" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["rg_azl", "cl_azl"] : contains(keys(var.names), k)])
    error_message = "names must contain rg_azl and cl_azl (contract §10)."
  }
}
