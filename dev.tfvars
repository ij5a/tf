# Dev — lean environment. Most optional features off; shows the feature-flag pattern.
tags = {
  project     = "acme"
  environment = "dev"
  tf          = "true"
}

region      = "sa-east-1"
aws_profile = "acme-dev"
domain_name = "dev.example.com"

# Optional features off in dev to keep it cheap.
enable_nlb                   = false
enable_waf                   = false
enable_guardduty             = false
enable_account_security      = false
enable_dms                   = false
enable_cloudwatch_dashboard  = false
enable_pagerduty             = false
enable_vpn_alarms            = false
use_twingate_transit_gateway = false

# Smallest Aurora footprint (Serverless v2, scale to zero off-hours).
aurora_instance_count = 1
serverless_aurora_scaling_configuration = {
  min_capacity = 0
  max_capacity = 1
}
