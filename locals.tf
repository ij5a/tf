locals {
  is_prod = var.tags.environment == "prod"

  # dual-domain migration: run a second hostname alongside domain_name until old-name traffic is zero
  enable_additional_domain = var.enable_route53 && var.additional_domain_name != ""
  # in-state parent zone when this env owns it (acme-sandbox), else the shared parent by ID
  additional_parent_zone_id = var.additional_parent_zone_name != "" ? aws_route53_zone.additional_parent[0].zone_id : var.additional_main_route_53_zone_id
}
