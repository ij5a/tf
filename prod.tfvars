# Prod — full environment. All services and protections on.
tags = {
  project     = "acme"
  environment = "prod"
  tf          = "true"
}

region      = "sa-east-1"
aws_profile = "acme-prod"
domain_name = "app.example.com"

# Networking + edge protection.
enable_nlb                   = true
enable_waf                   = true
waf_managed_rules_block_mode = true
use_public_nlb_for_eg        = true

# Encrypt the CloudFront→ALB and ALB→ECS hops (TLS on the full client path).
enable_https_origin = true
enable_tls_to_ecs   = true

# Account hardening + threat detection + alerting.
enable_account_security  = true
enable_guardduty         = true
enable_pagerduty         = true
require_secure_transport = true

# Observability.
enable_cloudwatch_dashboard = true
enable_vpn_alarms           = true

# Aurora Serverless v2, 2 instances, sized for prod.
container_insights    = "enhanced"
aurora_instance_count = 2
serverless_aurora_scaling_configuration = {
  min_capacity = 4
  max_capacity = 10
}

# Per-service prod task scaling (desired:min:max).
use_service_specs = true
service_task_count = {
  api            = "2:2:6"
  api-reconciler = "1:1:1"
  apigw-central  = "2:2:4"
  apigw-pr       = "2:2:4"
  authenticator  = "2:2:4"
  central        = "2:2:6"
  de             = "2:2:4"
  eg             = "2:2:4"
  pr             = "2:2:4"
}

# WAF allow-list + ALB ingress (RFC 5737 placeholder ranges).
waf_allowed_ip_addresses = [
  "192.0.2.0/24",     # office VPN
  "198.51.100.10/32", # CI runner
]
allowed_ip_addresses = [
  "192.0.2.0/24",
]

# Route 53 health checks for extra (non-Fargate) endpoints.
route_53_health_check_urls = ["https://legacy.example.com/health"]

# Twingate transit gateway (created manually in the master payer account).
use_twingate_transit_gateway = true
twingate_transit_gateway_id  = "tgw-0aaaaaaaaaaaaaaaa"
twingate_vpc_cidr_block      = "10.255.0.0/16"
twingate_vpc_route_table_ids = ["rtb-0aaaaaaaaaaaaaaa1", "rtb-0aaaaaaaaaaaaaaa2"]

# DMS migration from a legacy MySQL into Aurora. Passwords come from a
# gitignored secrets*.tfvars — never commit real values.
enable_dms = true
dms_migration_details = {
  source_db_endpoint = "legacy-mysql.cluster-aaaaexample0.sa-east-1.rds.amazonaws.com"
  source_db_name     = "acme"
  target_db_endpoint = "acme-prod-central.cluster-example0.sa-east-1.rds.amazonaws.com"
  target_db_name     = "acme"
  migration_type     = "full-load-and-cdc"
}
dms_source_db_username = "migrator"
dms_target_db_username = "migrator"
