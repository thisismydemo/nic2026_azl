variable "subscription_id" { type = string }
variable "group_object_ids" { type = map(string) }
variable "pim_max_activation_hours" {
  type    = number
  default = 8
}
variable "pim_assignments" {
  type = list(object({
    group = string
    role  = string
  }))
  default = [
    { group = "azl_admins", role = "Azure Stack HCI Administrator" },
    { group = "azl_admins", role = "Reader" },
    { group = "azl_operators", role = "Azure Stack HCI VM Contributor" },
    { group = "azl_operators", role = "Reader" },
  ]
}
variable "names" { type = map(string) }
