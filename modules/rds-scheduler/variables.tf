variable "module_sources" {
  description = "Map of module sources and versions for external Terraform modules"
  type = map(object({
    source  = string
    version = string
  }))
  default = {
    iam_policy = {
      source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
      version = "~> 6.6.1"
    }
    iam_role = {
      source  = "terraform-aws-modules/iam/aws//modules/iam-role"
      version = "~> 6.6.1"
    }
  }
}

variable "enabled" {
  description = "Enable or disable the RDS scheduler module"
  type        = bool
  default     = false
}

variable "name" {
  description = "Module instance name"
  type        = string
  default     = "rds-scheduler-for-client-env"
}

variable "cron_start_time" {
  description = "Cron expression for the start time of the RDS instances"
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)" # 3 PM PHT
}

variable "cron_stop_time" {
  description = "Cron expression for the stop time of the RDS instances"
  type        = string
  default     = "cron(0 16 ? * MON-FRI *)" # 12 AM PHT
}
