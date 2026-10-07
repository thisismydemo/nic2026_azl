variable "subscription_id" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "maintenance_window" {
  type = object({
    start_date_time = string
    duration        = string
    time_zone       = string
    recur_every     = string
  })
  default = {
    start_date_time = "2026-10-05 02:00"
    duration        = "03:00"
    time_zone       = "W. Europe Standard Time"
    recur_every     = "Week Sunday"
  }
}
variable "patch_classifications" {
  type    = list(string)
  default = ["Critical", "Security", "UpdateRollup", "Definition"]
}
variable "reboot_setting" {
  type    = string
  default = "IfRequired"
  validation {
    condition     = contains(["IfRequired", "Never", "Always"], var.reboot_setting)
    error_message = "reboot_setting must be IfRequired, Never or Always."
  }
}
variable "dynamic_scope_tags" {
  type    = map(list(string))
  default = { workload = ["azure-local"] }
}
variable "dynamic_scope_os_types" {
  type    = list(string)
  default = ["Windows", "Linux"]
}
variable "names" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["rg_mon", "mc_azl", "mc_azl_dynscope"] : contains(keys(var.names), k)])
    error_message = "names must contain rg_mon, mc_azl and mc_azl_dynscope (contract §10)."
  }
}
