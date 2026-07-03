variable "module_sources" {
  description = "Map of module sources and versions for external Terraform modules"
  type = map(object({
    source  = string
    version = string
  }))
  default = {
    alb = {
      source  = "terraform-aws-modules/alb/aws"
      version = "~> 10.5.0"
    }
    cloudfront = {
      source  = "terraform-aws-modules/cloudfront/aws"
      version = "~> 6.7.0"
    }
    cloudwatch = {
      source  = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
      version = "~> 5.7.2"
    }
    ecs_cluster = {
      source  = "terraform-aws-modules/ecs/aws//modules/cluster"
      version = "~> 7.5.0"
    }
    ecs_service = {
      source  = "terraform-aws-modules/ecs/aws//modules/service"
      version = "~> 7.5.0"
    }
    elasticache = {
      source  = "terraform-aws-modules/elasticache/aws"
      version = "~> 1.11.0"
    }
    fck_nat = {
      source  = "RaJiska/fck-nat/aws"
      version = "~> 1.6.0"
    }
    iam_policy = {
      source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
      version = "~> 6.6.1"
    }
    iam_role = {
      source  = "terraform-aws-modules/iam/aws//modules/iam-role"
      version = "~> 6.6.1"
    }
    lambda = {
      source  = "terraform-aws-modules/lambda/aws"
      version = "~> 8.8.1"
    }
    notify_slack = {
      source  = "terraform-aws-modules/notify-slack/aws"
      version = "~> 7.5.0"
    }
    rds = {
      source  = "terraform-aws-modules/rds/aws"
      version = "~> 7.2.0"
    }
    rds_aurora = {
      source  = "terraform-aws-modules/rds-aurora/aws"
      version = "~> 10.2.0"
    }
    s3_bucket = {
      source  = "terraform-aws-modules/s3-bucket/aws"
      version = "~> 5.14.0"
    }
    secrets_manager = {
      source  = "terraform-aws-modules/secrets-manager/aws"
      version = "~> 2.1.0"
    }
    security_group = {
      source  = "terraform-aws-modules/security-group/aws"
      version = "~> 5.3.1"
    }
    vpc = {
      source  = "terraform-aws-modules/vpc/aws"
      version = "~> 6.6.1"
    }
  }
}

variable "allowed_ip_addresses" {
  description = "List of allowed IP addresses"
  type        = list(string)
  default     = []
}

variable "waf_allowed_ip_addresses" {
  description = "List of IP addresses allowed in the WAF whitelist only (not added to NLB/EG security groups)"
  type        = list(string)
  default     = []
}

variable "aws_profile" {
  description = "AWS profile"
  type        = string
  default     = "default"
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Number of days to retain log events. Default is 7 days"
  type        = number
  default     = 7
}

variable "dms_migration_details" {
  description = "Details for DMS migration. Enable DMS using the enable_dms variable."
  type = object({
    source_db_endpoint          = optional(string, "source-db.example.com")
    source_db_name              = optional(string, "source_database")
    source_db_security_group_id = optional(string, "sg-foo")
    target_db_endpoint          = optional(string, "target-db.example.com")
    target_db_name              = optional(string, "target_database")
    target_db_security_group_id = optional(string, "sg-bar")
    migration_type              = optional(string, "full-load-and-cdc")
    table_mappings = optional(string, <<-EOF
    {
      "rules": [
        {
          "rule-type": "selection",
          "rule-id": "1",
          "rule-name": "1",
          "object-locator": {
            "schema-name": "%",
            "table-name": "%"
          },
          "rule-action": "include",
          "filters": []
        }
      ]
    }
  EOF
    )
    source_engine_name = optional(string, "aurora")
    target_engine_name = optional(string, "aurora-serverless")
    compute_config = optional(object({
      min_capacity_units = number
      max_capacity_units = number
      }), {
      min_capacity_units = 1
      max_capacity_units = 1
    })
  })
  default = {}
}

variable "dms_source_db_username" {
  description = "Source database username for DMS"
  type        = string
  sensitive   = true
  default     = ""
}

variable "dms_source_db_password" {
  description = "Source database password for DMS"
  type        = string
  sensitive   = true
  default     = ""
}

variable "dms_target_db_username" {
  description = "Target database username for DMS"
  type        = string
  sensitive   = true
  default     = ""
}

variable "dms_target_db_password" {
  description = "Target database password for DMS"
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_name" {
  description = "Domain name"
  type        = string
  default     = "example.com"
}

variable "enable_acm" {
  description = "Enable ACM for the domain"
  type        = bool
  default     = true
}

variable "enable_alb" {
  description = "Enable Application Load Balancer (ALB)"
  type        = bool
  default     = true
}

variable "enable_dms" {
  description = "Enable DMS for database migration"
  type        = bool
  default     = false
}

variable "enable_codepipeline" {
  description = "Enable CodePipeline for CI/CD"
  type        = bool
  default     = true
}

variable "enable_codepipeline_image_promotion_step" {
  description = "Enable image promotion step in CodePipeline"
  type        = bool
  default     = false
}

variable "enable_cloudfront" {
  description = "Enable CloudFront for the domain"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_alarms" {
  description = "Enable CloudWatch alarm rules for CloudFront/ECS/Route53 (alerts only; dashboard is gated separately by enable_cloudwatch_dashboard)"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_dashboard" {
  description = "Enable the per-environment CloudWatch overview dashboard (aws_cloudwatch_dashboard.main)"
  type        = bool
  default     = true
}

variable "enable_cloudwatch_logging" {
  description = "Determines whether CloudWatch logging is configured for this container definition."
  type        = bool
  default     = true
}

variable "enable_ecs" {
  description = "Enable ECS for the services"
  type        = bool
  default     = true
}

variable "container_insights" {
  description = "ECS Container Insights mode (enhanced, enabled, or disabled). null = env default: prod gets enhanced, other envs enabled."
  type        = string
  default     = null

  validation {
    condition     = var.container_insights == null || contains(["enhanced", "enabled", "disabled"], var.container_insights)
    error_message = "container_insights must be enhanced, enabled, or disabled (or null for the env default)."
  }
}

variable "enable_elasticache" {
  description = "Enable ElastiCache for Redis"
  type        = bool
  default     = true
}

variable "enable_account_security" {
  description = "Enable account-level security settings (EBS snapshot public access, SSM document sharing). Only enable for the primary environment per AWS account."
  type        = bool
  default     = false
}

variable "enable_guardduty" {
  description = "Enable Amazon GuardDuty threat detection"
  type        = bool
  default     = false
}

variable "enable_lambda" {
  description = "Enable Lambda functions"
  type        = bool
  default     = true
}

variable "enable_nlb" {
  description = "Enable Network Load Balancer (NLB) for the EG service and for testing purposes"
  type        = bool
  default     = true
}

variable "nlb_name_suffix" {
  description = "Optional suffix to append to the NLB name (e.g., 'v2')"
  type        = string
  default     = ""
}

variable "enable_phpmyadmin" {
  description = "Enable phpMyAdmin for database management"
  type        = bool
  default     = false
}

variable "enable_standalone_phpmyadmin" {
  description = "Stand up phpMyAdmin behind its own public CloudFront + CF-WAF + internal ALB, independent of the apigw front door. Requires enable_ecs and enable_phpmyadmin. Interim tool for the prod Aurora migration; folds back into the apigw path once the full compute stack (enable_alb/enable_cloudfront) lands."
  type        = bool
  default     = false
}

variable "enable_iso8583_playground" {
  description = "Enable iso8583-playground internal test tool"
  type        = bool
  default     = false
}

variable "waf_managed_rules_block_mode" {
  description = "Promote AWS managed WAF rule groups (Common, SQLi, KnownBadInputs) from count mode to block mode. Only enable after observing count-mode metrics show no false positives."
  type        = bool
  default     = false
}

variable "enable_serverless_aurora" {
  description = "Enable Serverless Aurora for the database"
  type        = bool
  default     = true
}

variable "enable_rds_scheduler" {
  description = "Enable or disable the RDS scheduler module"
  type        = bool
  default     = false
}

variable "enable_de_mysql_rds" {
  description = "Create a dedicated standalone MySQL RDS instance for the de (Decision Engine) service in this env's VPC. Requires 'de' to be in var.services. Replaces the cross-account peering to the legacy legacy-mysql in acme-dev."
  type        = bool
  default     = false
}

variable "de_mysql_rds_config" {
  description = "Sizing config for the standalone MySQL RDS instance created when enable_de_mysql_rds is true."
  type = object({
    instance_class          = optional(string, "db.t4g.micro")
    engine_version          = optional(string, "8.4.7")
    allocated_storage       = optional(number, 20)
    max_allocated_storage   = optional(number, 100)
    backup_retention_period = optional(number, 7)
    multi_az                = optional(bool, false)
    deletion_protection     = optional(bool, true)
  })
  default = {}
}

variable "require_secure_transport" {
  description = "Require a verified TLS connection to MySQL for the api, api-reconciler, and de services. When true, the RDS CA path env var is injected into those services so the app verifies the DB server certificate. Enable per-env once the service makes the RDS CA bundle available at that path (e.g. fetched at container start)."
  type        = bool
  default     = false
}

variable "enable_route53" {
  description = "Enable Route 53 for DNS management"
  type        = bool
  default     = true
}

variable "enable_s3" {
  description = "Enable S3 for static file storage"
  type        = bool
  default     = true
}

variable "enable_slack_notifications" {
  description = "Enable Slack notifications (master switch)"
  type        = bool
  default     = true
}

variable "enable_alert_notifications" {
  description = "Enable Slack alert notifications (CloudWatch alarms, GuardDuty findings)"
  type        = bool
  default     = true
}

variable "enable_deployment_notifications" {
  description = "Enable Slack deployment notifications (CodePipeline events)"
  type        = bool
  default     = true
}

variable "enable_vpc" {
  description = "Enable VPC for the services"
  type        = bool
  default     = true
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC flow logs delivered to S3 (parquet, hive-compatible partitions, 600s aggregation). Creates a per-env S3 bucket with a 365-day lifecycle."
  type        = bool
  default     = true
}

variable "manage_existing_vpc_flow_log" {
  description = "Create an aws_flow_log against the existing VPC referenced by existing_vpc_details. Only meaningful when use_existing_vpc is true. Set to true exactly once per shared legacy VPC (one env owns each shared VPC's flow log). Default false to avoid duplicate flow logs."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "Enable WAF for the CloudFront distribution"
  type        = bool
  default     = true
}

variable "enable_pagerduty" {
  description = "Enable PagerDuty notifications for CloudWatch alarms (us-east-1)"
  type        = bool
  default     = false
}

variable "existing_vpc_details" {
  description = "Details of the existing VPC to use if use_existing_vpc is true."
  type = object({
    id                      = string
    cidr_block              = string
    public_subnet_ids       = optional(list(string), [])
    private_subnet_ids      = optional(list(string), [])
    public_route_table_ids  = optional(list(string), [])
    private_route_table_ids = optional(list(string), [])
  })
  default = {
    id                      = "vpc-foobar"
    cidr_block              = "10.99.0.0/16"
    public_subnet_ids       = ["subnet-foobar-public-1", "subnet-foobar-public-2"]
    private_subnet_ids      = ["subnet-foobar-private-1", "subnet-foobar-private-2"]
    public_route_table_ids  = ["rtb-foobar-public-1", "rtb-foobar-public-2"]
    private_route_table_ids = ["rtb-foobar-private-1", "rtb-foobar-private-2"]
  }
}

variable "enable_external_processor" {
  description = "Use external-processor (extproc) components running outside of Acme infrastructure. external-processor consists of the following components: api, de, and eg."
  type        = bool
  default     = false
}

variable "issuer_code" {
  description = "The code name for the issuer for PR and EG services. It should be uppercase. This variable is used by the ALB module using enable_external_processor."
  type        = string
  default     = ""
}

variable "image_promotion_source_environment" {
  description = "Source environment for image promotion. `enable_codepipeline_image_promotion_step` must be `true`."
  type        = string
  default     = "dev"
}

variable "image_promotion_source_ecr" {
  description = "Source ECR repository for image promotion. `enable_codepipeline_image_promotion_step` must be `true`."
  type        = string
  default     = "111111111111.dkr.ecr.sa-east-1.amazonaws.com/acme-platform-image"
}

variable "image_promotion_destination_environment" {
  description = "Destination environment for image promotion. `enable_codepipeline_image_promotion_step` must be `true`."
  type        = string
  default     = "qa"
}

variable "image_promotion_destination_ecr" {
  description = "Destination ECR repository for image promotion. `enable_codepipeline_image_promotion_step` must be `true`."
  type        = string
  default     = "111111111111.dkr.ecr.sa-east-1.amazonaws.com/acme-platform-image"
}

variable "image_repository_name" {
  description = "ECR repository name"
  type        = string
  default     = "acme-platform-image"
}

variable "legacy_endpoints" {
  description = "Legacy endpoints. The use_legacy_endpoints flag must be true to use this."
  type        = list(string)
  default     = ["legacy.example.com"]
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

variable "phpmyadmin_image" {
  description = "Docker image for phpMyAdmin"
  type        = string
  default     = "333333333333.dkr.ecr.sa-east-1.amazonaws.com/tools/phpmyadmin:5.2.2-apache"
}

variable "iso8583_playground_image" {
  description = "Docker image for iso8583-playground"
  type        = string
  default     = "333333333333.dkr.ecr.sa-east-1.amazonaws.com/tools/iso8583-playground:v0.1.3-20260612-03"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "sa-east-1"
}

variable "rds_scheduler_cron_start_time" {
  description = "Cron expression for the start time of the RDS instances"
  type        = string
  default     = "cron(0 7 ? * MON-FRI *)" # 3 PM PHT
}

variable "rds_scheduler_cron_stop_time" {
  description = "Cron expression for the stop time of the RDS instances"
  type        = string
  default     = "cron(0 16 ? * MON-FRI *)" # 12 AM PHT
}

variable "aurora_instance_count" {
  description = "Number of Aurora instances to create. Defaults to 1 for non-prod, override to 2+ for prod or benchmarking."
  type        = number
  default     = 1
}

variable "aurora_cluster_identifier_random_suffix" {
  description = "Append a random 6-character suffix to the Aurora cluster identifier (e.g. acme-prod-central-abc123). Use when recreating a cluster while the old one still exists in AWS to avoid name conflicts. Default false keeps the bare identifier. Final name is truncated to RDS's 63-character limit if necessary."
  type        = bool
  default     = false
}

variable "serverless_aurora_scaling_configuration" {
  description = "Serverless Aurora scaling configuration. 1 ACU = 2 GB of RAM."
  type = object({
    min_capacity = number
    max_capacity = number
  })
  default = {
    min_capacity = 0
    max_capacity = 1
  }
}

variable "services" {
  description = "List of services to enable"
  type        = list(string)
  default = [
    "api",
    "api-reconciler",
    "apigw-central",
    "apigw-pr",
    "authenticator",
    "central",
    "de",
    "eg",
    "pr",
    "spa"
  ]
}

variable "service_overall_cpu_mem_combination" {
  description = "Overall CPU and memory combination for the services. See: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html"
  type = object({
    cpu = number
    mem = number
  })
  default = {
    cpu = 512
    mem = 1024
  }
}

variable "service_repositories" {
  description = "Map of services to their image repositories"
  type        = map(string)
  default = {
    api            = "acme-api"
    api-reconciler = "acme-api"
    apigw-central  = "acme-apigw"
    apigw-pr       = "acme-apigw"
    authenticator  = "acme-saas"
    central        = "acme-central"
    de             = "acme-de"
    eg             = "acme-eg"
    pr             = "acme-saas"
    spa            = "spa"
  }
}

variable "service_specs" {
  description = "Map of services and their specifications following this format (CPU:Memory)"
  type        = map(string)
  default = {
    api            = "100:300"
    api-reconciler = "100:300"
    apigw-central  = "200:300"
    apigw-pr       = "200:300"
    authenticator  = "200:300"
    central        = "500:500"
    de             = "100:300"
    eg             = "100:300"
    pr             = "200:300"
  }
}

variable "service_ports" {
  description = "Map of services and their ports"
  type        = map(number)
  default = {
    api            = 4434
    api-reconciler = 4434
    apigw-central  = 8080
    apigw-pr       = 8080
    authenticator  = 5000
    central        = 4434
    de             = 4434
    eg             = 5002
    pr             = 5000
  }
}

variable "autoscaling_schedule" {
  description = "Cron schedules for ECS autoscaling (business_hours = scale up, off_hours = scale down)"
  type = object({
    business_hours = string
    off_hours      = string
  })
  default = {
    business_hours = "cron(0 7 ? * MON-FRI *)"  # 3 PM PHT
    off_hours      = "cron(0 18 ? * MON-FRI *)" # 2 AM PHT
  }
}

variable "service_task_count" {
  description = "Map of services and their task count (Desired:Minimum:Maximum)"
  type        = map(string)
  default = {
    api            = "1:1:1"
    api-reconciler = "1:1:1"
    apigw-central  = "1:1:1"
    apigw-pr       = "1:1:1"
    authenticator  = "1:1:1"
    central        = "1:1:1"
    de             = "1:1:1"
    eg             = "1:1:1"
    pr             = "1:1:1"
  }
}

variable "slack_username" {
  description = "Slack username"
  type        = string
  default     = "aws-acme"
}

variable "tags" {
  description = "Tags for the resources"
  type        = map(string)
  default = {
    project     = "acme"
    environment = "dev"
    tf          = "true"
  }
}

variable "twingate_ip" {
  description = "Twingate IP address"
  type        = string
  default     = "192.0.2.10/32"
}

variable "twingate_transit_gateway_id" {
  description = "Twingate Transit Gateway ID. This has been created manually in the master payer account. Required if use_twingate_transit_gateway is true."
  type        = string
  default     = "tgw-0aaaaaaaaaaaaaaaa"
}

variable "twingate_vpc_cidr_block" {
  description = "Twingate VPC CIDR block"
  type        = string
  default     = "10.255.0.0/16"
}

variable "twingate_vpc_route_table_ids" {
  description = "Twingate VPC route table IDs"
  type        = list(string)
  default = [
    "rtb-0aaaaaaaaaaaaaaa1",
    "rtb-0aaaaaaaaaaaaaaa2"
  ]
}

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

variable "use_legacy_endpoints" {
  description = "Switch to use legacy endpoints. The legacy_endpoints variable must be set."
  type        = bool
  default     = false
}

# tflint-ignore: terraform_unused_declarations
variable "use_existing_vpc" {
  description = "Use existing VPC instead of creating a new one."
  type        = bool
  default     = false
}

variable "use_service_specs" {
  description = "Use custom service specifications. Please see the service_specs variable."
  type        = bool
  default     = false
}

variable "use_twingate_transit_gateway" {
  description = "Use Twingate Transit Gateway to allow access from local network to AWS resources."
  type        = string
  default     = false
}

variable "use_private_nlb_for_eg" {
  description = "Use private NLB for EG service only."
  type        = bool
  default     = false
}

variable "use_public_nlb_for_eg" {
  description = "Use public NLB for EG service only."
  type        = bool
  default     = false
}

variable "main_route_53_zone_id" {
  description = "Main Route 53 zone ID"
  type        = string
  default     = "Z0123456789ABCDEFGHIJ"
}

variable "route_53_health_check_urls" {
  description = "Extra HTTPS URLs to create Route 53 health checks for (e.g. legacy EB/EKS endpoints in hybrid envs). The Fargate app paths /api/v1/version and /call-center/log-in are always auto-created when var.domain_name is set; this list is additive."
  type        = list(string)
  default     = []
}

variable "cloudwatch_route53_dashboard" {
  description = "Cross-environment Route 53 health check dashboard. Map of label to health check ID."
  type        = map(string)
  default     = {}
}

variable "enable_vpn_alarms" {
  description = "Create CloudWatch alarms for legacy out-of-band Site-to-Site VPN connections (active tunnel only)."
  type        = bool
  default     = false
}

variable "vpn_log_group_name" {
  description = "Existing CloudWatch log group receiving VPN tunnel logs."
  type        = string
  default     = "/aws/vpn/acme-prod"
}
