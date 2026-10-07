variable "subscription_id" { type = string }
variable "location" { type = string }
variable "tags" { type = map(string) }
variable "cluster_name" { type = string }
variable "nodes" {
  type = list(object({
    name          = string
    management_ip = string
    storage_ips   = optional(map(string))
    lom1_mac      = optional(string)
  }))
}
variable "log_analytics_workspace_id" {
  type    = string
  default = ""
}
variable "action_group_id" {
  type    = string
  default = ""
}
variable "alert_evaluation_frequency" {
  type    = string
  default = "PT5M"
}
variable "alert_window_size" {
  type    = string
  default = "PT15M"
}
variable "node_heartbeat_minutes" {
  type    = number
  default = 10
  validation {
    condition     = var.node_heartbeat_minutes >= 5 && var.node_heartbeat_minutes <= 45
    error_message = "node_heartbeat_minutes must be 5 to 45: the node-down rule looks back one hour."
  }
}
variable "enable_vm_insights_dcr" {
  type    = bool
  default = true
}
variable "manage_insights_dcr_in_iac" {
  type    = bool
  default = false
}
variable "names" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["rg_azl", "rg_mon", "law", "ag_ops", "dcr_insights", "dcr_vminsights", "alert_node_down", "alert_storage_health", "alert_intent_drift", "alert_capacity", "alert_kv_backup"] : contains(keys(var.names), k)])
    error_message = "names is missing a monitoring catalog key (contract §10)."
  }
}
