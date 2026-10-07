variable "subscription_id" { type = string }
variable "defender_servers_plan" {
  type    = string
  default = "P2"
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
variable "names" { type = map(string) }
