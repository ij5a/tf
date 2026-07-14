variable "domain_name" {
  description = "Domain name"
  type        = string
  default     = "example.com"
}

variable "additional_domain_name" {
  description = "Optional second domain added to the cert SANs (apex + wildcard), validated in its own zone"
  type        = string
  default     = ""
}
