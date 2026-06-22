variable "use_legacy_db" {
  description = "Use legacy database (not Serverless Aurora)"
  type        = bool
  default     = false
}

variable "use_legacy_redis" {
  description = "Use legacy Redis (not Valkey)"
  type        = bool
  default     = false
}

variable "legacy_db_redis_server_details" {
  description = "Details of the legacy database and redis servers"
  type = object({
    vpc = object({
      rt_ids     = list(string)
      cidr_block = string
      id         = string
      owner_id   = string
    })

    db = optional(object({
      sg_id = string
    }))

    redis = optional(object({
      sg_id = string
    }))
  })
  default = {
    vpc = {
      rt_ids     = []
      cidr_block = ""
      id         = ""
      owner_id   = ""
    }

    db = {
      sg_id = ""
    }

    redis = {
      sg_id = ""
    }
  }
}

variable "new_vpc_id" {
  description = "ID of the new VPC"
  type        = string
  default     = ""
}

variable "new_vpc_cidr_block" {
  description = "CIDR block of the new VPC"
  type        = string
  default     = ""
}

variable "new_vpc_private_route_table_ids" {
  description = "IDs of the private route tables in the new VPC"
  type        = list(string)
  default     = [""]
}
