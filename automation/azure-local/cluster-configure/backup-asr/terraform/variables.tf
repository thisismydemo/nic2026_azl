variable "subscription_id" {
  type = string
}

variable "location" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "names" {
  type = map(string)
}

variable "asr_policy" {
  type = object({
    replication_frequency_seconds           = number
    recovery_point_retention_hours          = number
    app_consistent_snapshot_frequency_hours = number
  })
  default = {
    replication_frequency_seconds           = 300
    recovery_point_retention_hours          = 24
    app_consistent_snapshot_frequency_hours = 1
  }
}

variable "backup_policy" {
  type = object({
    schedule_run_time_utc = string
    retention_days        = number
    instant_restore_days  = number
  })
  default = {
    schedule_run_time_utc = "02:00"
    retention_days        = 30
    instant_restore_days  = 2
  }
}
