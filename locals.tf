locals {
  is_prod = var.tags.environment == "prod"

  # 5-min SAT,SUN re-zero; envs opt out with autoscaling_schedule.weekend_guard = false
  weekend_guard_schedule = "cron(0/5 * ? * SAT,SUN *)"

  # dual-domain migration: run a second hostname alongside domain_name until old-name traffic is zero
  enable_additional_domain = var.enable_route53 && var.additional_domain_name != ""

  # break-glass lever for CloudFront VPC-Origins outages; operator steps in cf-vpc-origin-breakglass.md
  enable_breakglass = var.enable_alb && var.enable_breakglass_public_alb
  # bg origin hostname rides the aws.example.com tree wherever an env dual-runs it
  breakglass_domain = local.enable_additional_domain ? var.additional_domain_name : var.domain_name
  # in-state parent zone when this env owns it (acme-sandbox), else the shared parent by ID
  additional_parent_zone_id = var.additional_parent_zone_name != "" ? aws_route53_zone.additional_parent[0].zone_id : var.additional_main_route_53_zone_id
}
