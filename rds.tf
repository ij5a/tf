data "aws_kms_key" "rds_default" {
  key_id = "alias/aws/rds"
}

data "aws_rds_engine_version" "mysql" {
  engine  = "aurora-mysql"
  version = "8.0.mysql_aurora.3.10.3"
}

# Aurora clusters keyed by service: central (enable_serverless_aurora), plus an optional
# dedicated pr cluster (enable_pr_serverless_aurora) so pr load/scaling stay off central.
locals {
  aurora_cluster_keys = toset(concat(
    var.enable_serverless_aurora ? [for service in var.services : service if service == "central"] : [],
    var.enable_pr_serverless_aurora ? [for service in var.services : service if service == "pr"] : [],
  ))
}

resource "random_string" "this" {
  for_each = local.aurora_cluster_keys
  length   = 8
  special  = false
  upper    = false
}

# Optional random suffix for the Aurora cluster identifier.
# Used when recreating a cluster while the old one still exists in AWS
# (e.g. switching VPCs without destroying the legacy DB).
# Math: longest base today is "acme-prod-central" (17 chars),
# plus "-" + 6 random chars = 24 chars, plus AWS-appended "-N" instance
# suffix = 26 chars max. RDS limit is 63, so we have plenty of headroom.
# substr() is applied below as a defensive cap.
resource "random_string" "aurora_cluster_suffix" {
  for_each = var.aurora_cluster_identifier_random_suffix ? local.aurora_cluster_keys : toset([])
  length   = 6
  special  = false
  upper    = false
  numeric  = true
}

data "aws_iam_policy_document" "cloudwatch_logs_kms" {
  count = local.is_prod && var.enable_serverless_aurora ? 1 : 0

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt*",
      "kms:Describe*",
      "kms:Encrypt*",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]

    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "cloudwatch_logs" {
  count                   = local.is_prod && var.enable_serverless_aurora ? 1 : 0
  description             = "KMS key for RDS CloudWatch log group encryption"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 14
  policy                  = data.aws_iam_policy_document.cloudwatch_logs_kms[0].json
}

resource "aws_kms_alias" "cloudwatch_logs" {
  count         = local.is_prod && var.enable_serverless_aurora ? 1 : 0
  name          = "alias/${var.tags.project}-${var.tags.environment}-rds-cloudwatch-logs"
  target_key_id = aws_kms_key.cloudwatch_logs[0].key_id
}

module "aurora_mysql_v2" {
  source                                        = var.module_sources.rds_aurora.source
  version                                       = var.module_sources.rds_aurora.version
  for_each                                      = local.aurora_cluster_keys
  apply_immediately                             = true
  backup_retention_period                       = 7
  cluster_performance_insights_enabled          = true
  cluster_performance_insights_kms_key_id       = data.aws_kms_key.rds_default.arn
  cluster_performance_insights_retention_period = 7
  cluster_monitoring_interval                   = 60
  copy_tags_to_snapshot                         = true
  cluster_instance_class                        = "db.serverless"
  create_db_subnet_group                        = true
  create_security_group                         = true
  database_insights_mode                        = "standard"
  database_name                                 = replace("${var.tags.project}-${var.tags.environment}-${each.key}", "-", "")
  delete_automated_backups                      = true
  deletion_protection                           = true
  enable_http_endpoint                          = true
  engine                                        = data.aws_rds_engine_version.mysql.engine
  engine_mode                                   = "provisioned"
  engine_version                                = data.aws_rds_engine_version.mysql.version
  final_snapshot_identifier                     = "${var.tags.project}-${var.tags.environment}-${each.key}-${random_string.this[each.key].result}"
  iam_database_authentication_enabled           = true
  kms_key_id                                    = data.aws_kms_key.rds_default.arn
  manage_master_user_password                   = true
  manage_master_user_password_rotation          = false
  master_user_password_rotate_immediately       = false
  master_username                               = "root"
  name                                          = substr(var.aurora_cluster_identifier_random_suffix ? "${var.tags.project}-${var.tags.environment}-${each.key}-${random_string.aurora_cluster_suffix[each.key].result}" : "${var.tags.project}-${var.tags.environment}-${each.key}", 0, 63)
  skip_final_snapshot                           = false
  storage_encrypted                             = true
  storage_type                                  = "aurora"
  enabled_cloudwatch_logs_exports               = local.is_prod ? ["audit", "error", "slowquery"] : []
  create_cloudwatch_log_group                   = local.is_prod
  cloudwatch_log_group_retention_in_days        = 90
  cloudwatch_log_group_kms_key_id               = try(aws_kms_key.cloudwatch_logs[0].arn, null)
  subnets                                       = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  vpc_id                                        = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  cluster_parameter_group = {
    family      = "aurora-mysql8.0"
    description = "Aurora MySQL 8.0 cluster parameter group"
    parameters = concat([
      {
        name  = "character_set_server"
        value = "utf8mb4"
      },
      {
        name  = "collation_server"
        value = "utf8mb4_unicode_ci"
      },
      {
        name  = "general_log"
        value = "0"
      },
      {
        name         = "binlog_format"
        value        = "ROW"
        apply_method = "pending-reboot"
      },
      {
        name  = "net_read_timeout"
        value = "300"
      },
      {
        name  = "net_write_timeout"
        value = "300"
      },
      {
        name  = "wait_timeout"
        value = "28800"
      }
      ], local.is_prod ? [
      {
        name  = "server_audit_logging"
        value = "1"
      },
      {
        name  = "server_audit_events"
        value = "CONNECT,QUERY,TABLE"
      }
    ] : [])
  }

  security_group_ingress_rules = {
    vpc_ingress = {
      cidr_ipv4 = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
    }
    twingate_ingress = {
      cidr_ipv4 = var.twingate_vpc_cidr_block
    }
  }

  # pr has its own sizing vars so prod-only central overrides never apply to it.
  serverlessv2_scaling_configuration = each.key == "pr" ? var.pr_serverless_aurora_scaling_configuration : var.serverless_aurora_scaling_configuration

  # Every instance gets the env's promotion tier when set: Aurora consults the tier on readers
  # only (writers ignore it), and map keys don't track live roles after a failover.
  instances = {
    for i in range(1, (each.key == "pr" ? var.pr_aurora_instance_count : var.aurora_instance_count) + 1) :
    i => var.aurora_reader_promotion_tier != null ? { promotion_tier = var.aurora_reader_promotion_tier } : {}
  }
}

module "rds_scheduler" {
  source          = "./modules/rds-scheduler"
  enabled         = var.enable_rds_scheduler
  name            = "${var.aws_profile}-rds-scheduler"
  cron_start_time = var.rds_scheduler_cron_start_time
  cron_stop_time  = var.rds_scheduler_cron_stop_time
  module_sources = {
    iam_policy = var.module_sources.iam_policy
    iam_role   = var.module_sources.iam_role
  }
}

# Standalone MySQL RDS for the "de" (Decision Engine) service.
# Provisioned per-env when enable_de_mysql_rds=true AND "de" is in var.services.
# Replaces the cross-account peering to the legacy legacy-mysql in acme-dev.
# Pattern mirrors how elasticache.tf handles the de Valkey cluster:
# random_password -> secrets-manager module -> consumer.
resource "random_password" "de_mysql_rds_master_password" {
  count   = var.enable_de_mysql_rds && contains(var.services, "de") ? 1 : 0
  length  = 32
  special = false
}

module "de_mysql_rds_master_secret" {
  source        = var.module_sources.secrets_manager.source
  version       = var.module_sources.secrets_manager.version
  count         = var.enable_de_mysql_rds && contains(var.services, "de") ? 1 : 0
  name_prefix   = "${var.tags.project}-${var.tags.environment}-de-mysql-master-"
  description   = "Master password for the standalone MySQL RDS instance used by the de service"
  secret_string = random_password.de_mysql_rds_master_password[0].result
}

module "de_mysql_rds_security_group" {
  source      = var.module_sources.security_group.source
  version     = var.module_sources.security_group.version
  count       = var.enable_de_mysql_rds && contains(var.services, "de") ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-de-mysql"
  description = "Security group for the standalone MySQL RDS instance for the de service"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  ingress_cidr_blocks = compact([
    try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block),
    var.twingate_vpc_cidr_block,
  ])
  ingress_rules = ["mysql-tcp"]
}

module "de_mysql_rds" {
  source  = var.module_sources.rds.source
  version = var.module_sources.rds.version
  count   = var.enable_de_mysql_rds && contains(var.services, "de") ? 1 : 0

  identifier = "${var.tags.project}-${var.tags.environment}-de-mysql"

  engine               = "mysql"
  engine_version       = var.de_mysql_rds_config.engine_version
  family               = "mysql8.4"
  major_engine_version = "8.4"

  instance_class        = var.de_mysql_rds_config.instance_class
  allocated_storage     = var.de_mysql_rds_config.allocated_storage
  max_allocated_storage = var.de_mysql_rds_config.max_allocated_storage

  db_name  = replace("${var.tags.project}-${var.tags.environment}-de-db", "-", "_")
  username = "de_admin"
  port     = "3306"

  manage_master_user_password = false
  password_wo                 = random_password.de_mysql_rds_master_password[0].result
  password_wo_version         = 1

  multi_az                         = var.de_mysql_rds_config.multi_az
  backup_retention_period          = var.de_mysql_rds_config.backup_retention_period
  deletion_protection              = var.de_mysql_rds_config.deletion_protection
  skip_final_snapshot              = false
  final_snapshot_identifier_prefix = "${var.tags.project}-${var.tags.environment}-de-mysql-final"
  copy_tags_to_snapshot            = true
  apply_immediately                = true

  create_db_subnet_group = true
  subnet_ids             = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  vpc_security_group_ids = [module.de_mysql_rds_security_group[0].security_group_id]

  storage_encrypted                     = true
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  parameters = [
    {
      name  = "character_set_server"
      value = "utf8mb4"
    },
    {
      name  = "collation_server"
      value = "utf8mb4_unicode_ci"
    },
  ]

  # Picked up by the rds_scheduler module's resource group tag query; no-op in envs where the scheduler is disabled.
  tags = {
    Action = "StartStop"
  }
}

output "rds_endpoints" {
  description = "RDS endpoints keyed by service. 'central' and 'pr' = Aurora MySQL writer/reader/port ('pr' only when enable_pr_serverless_aurora=true). 'de' = standalone MySQL (writer == reader since single-instance) when enable_de_mysql_rds=true. Empty for envs with enable_serverless_aurora=false. Legacy DB hostnames (use_legacy_db=true) are not surfaced — they live outside tofu."
  value = merge(
    {
      for k, v in module.aurora_mysql_v2 : k => {
        writer = v.cluster_endpoint
        reader = v.cluster_reader_endpoint
        port   = v.cluster_port
      }
    },
    {
      for i, v in module.de_mysql_rds : "de" => {
        writer = v.db_instance_address
        reader = v.db_instance_address
        port   = v.db_instance_port
      }
    }
  )
}

output "aurora_master_user_secret_arns" {
  description = "Aurora master-user secret ARNs keyed by service ('central', plus 'pr' when enable_pr_serverless_aurora=true). Used by scripts/acme-sandbox-post-apply.sh to fetch the root password without listing secrets."
  value = {
    for k, v in module.aurora_mysql_v2 : k => v.cluster_master_user_secret[0].secret_arn
  }
}
