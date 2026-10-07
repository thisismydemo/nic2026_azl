variable "subscription_id" { type = string }
variable "location" { type = string }
variable "management_group_id" {
  type    = string
  default = ""
}
variable "log_analytics_workspace_id" {
  type    = string
  default = ""
}
variable "enforcement_mode" {
  type    = string
  default = "Default"
  validation {
    condition     = contains(["Default", "DoNotEnforce"], var.enforcement_mode)
    error_message = "enforcement_mode must be Default or DoNotEnforce."
  }
}
variable "assign_insights_policies" {
  type    = bool
  default = true
}
variable "names" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["rg_mon", "law", "init_hybrid_baseline", "asg_hybrid_baseline", "pol_insights_ama", "pol_insights_dcra", "pol_akv_backup_ext", "asg_insights_ama", "asg_insights_dcra", "asg_akv_backup_ext", "dcr_insights"] : contains(keys(var.names), k)])
    error_message = "names is missing a policy catalog key (contract §10)."
  }
}
