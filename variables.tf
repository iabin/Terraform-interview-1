variable "name" {
  description = "Prefix for all resources created by the module (vaults, keys, plan, role)."
  type        = string
  default     = "cloudfoundation"
}

variable "owner" {
  description = "Value of the Owner tag a resource must carry to be selected for backup (e.g. a team mailbox)."
  type        = string
}

variable "extra_selection_tags" {
  description = "Additional tag key/value pairs a resource must ALL match (AND) to be selected, on top of ToBackup=true and Owner."
  type        = map(string)
  default     = {}
}

variable "rules" {
  description = <<-EOT
    Backup rules. Each rule defines the backup frequency (cron), its retention,
    and optionally the cross-region (dr_copy) and cross-account (central_copy)
    copies with their own retention. Copies run at the frequency of the rule
    they belong to, so different copy frequencies need different rules.
  EOT
  type = list(object({
    name                    = string
    schedule                = string
    start_window            = optional(number, 60)
    completion_window       = optional(number, 480)
    retention_days          = number
    cold_storage_after_days = optional(number)
    dr_copy                 = optional(object({ retention_days = number }))
    central_copy            = optional(object({ retention_days = number }))
  }))
  default = [
    {
      name           = "daily"
      schedule       = "cron(0 3 * * ? *)"
      retention_days = 35
      dr_copy        = { retention_days = 35 }
      central_copy   = { retention_days = 90 }
    }
  ]
}

variable "vault_lock" {
  description = "Vault Lock (WORM) settings applied to the three vaults. Setting changeable_for_days starts the compliance-mode countdown (irreversible after the grace period). Leave it unset and the lock stays governance-style changeable."
  type = object({
    enabled             = optional(bool, true)
    min_retention_days  = optional(number, 7)
    max_retention_days  = optional(number, 365)
    changeable_for_days = optional(number)
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
