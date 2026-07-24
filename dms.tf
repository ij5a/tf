resource "aws_dms_endpoint" "source" {
  count         = var.enable_dms ? 1 : 0
  engine_name   = var.dms_migration_details.source_engine_name
  endpoint_id   = "${var.tags.project}-${var.tags.environment}-source"
  endpoint_type = "source"

  server_name   = var.dms_migration_details.source_db_endpoint
  port          = 3306
  database_name = var.dms_migration_details.source_db_name
  username      = var.dms_source_db_username
  password      = var.dms_source_db_password
}

resource "aws_dms_endpoint" "target" {
  count         = var.enable_dms ? 1 : 0
  engine_name   = var.dms_migration_details.target_engine_name
  endpoint_id   = "${var.tags.project}-${var.tags.environment}-target"
  endpoint_type = "target"

  server_name   = try(module.aurora_mysql_v2["central"].cluster_endpoint, var.dms_migration_details.target_db_endpoint)
  port          = 3306
  database_name = var.dms_migration_details.target_db_name
  username      = var.dms_target_db_username
  password      = var.dms_target_db_password
}

resource "aws_iam_role" "dms_service_role" {
  count = var.enable_dms ? 1 : 0
  name  = "${var.tags.project}-${var.tags.environment}-dms-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "dms.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "dms_secrets_manager_policy" {
  count = var.enable_dms ? 1 : 0
  name  = "${var.tags.project}-${var.tags.environment}-dms-secrets-manager-policy"
  role  = aws_iam_role.dms_service_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = module.aurora_mysql_v2["central"].cluster_master_user_secret[0].secret_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "dms_vpc_policy_attachment" {
  count      = var.enable_dms ? 1 : 0
  role       = aws_iam_role.dms_service_role[0].id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

module "security_group" {
  count       = var.enable_dms ? 1 : 0
  source      = var.module_sources.security_group.source
  version     = var.module_sources.security_group.version
  name        = "${var.tags.project}-${var.tags.environment}-dms-sg"
  description = "Security group for DMS"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  # Source egress via SG reference only when NOT using legacy-db peering. With use_legacy_db
  # the source is in a peered VPC, reached via CIDR (egress_with_cidr_blocks below).
  egress_with_source_security_group_id = concat(
    var.use_legacy_db ? [] : [
      {
        from_port                = 3306
        to_port                  = 3306
        protocol                 = "tcp"
        description              = "MySQL DB access to the source database using port 3306"
        source_security_group_id = var.dms_migration_details.source_db_security_group_id
      }
    ],
    [
      {
        from_port                = 3306
        to_port                  = 3306
        protocol                 = "tcp"
        description              = "MySQL DB access to the target database using port 3306"
        source_security_group_id = try(module.aurora_mysql_v2["central"].security_group_id, var.dms_migration_details.target_db_security_group_id)
      }
    ]
  )

  egress_with_cidr_blocks = var.use_legacy_db ? [
    {
      from_port   = 3306
      to_port     = 3306
      protocol    = "tcp"
      description = "MySQL DB access to the source database (legacy peered VPC) using port 3306"
      cidr_blocks = var.legacy_db_redis_server_details.vpc.cidr_block
    }
  ] : []
}

# When use_legacy_db, the peering module adds a CIDR ingress on the source SG, so this
# SG-reference rule is redundant and would race the peering connection coming up.
resource "aws_security_group_rule" "dms_source_db_access" {
  count                    = var.enable_dms && !var.use_legacy_db ? 1 : 0
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  description              = "Allow DMS access to source database"
  security_group_id        = var.dms_migration_details.source_db_security_group_id
  source_security_group_id = module.security_group[0].security_group_id
}

resource "aws_security_group_rule" "dms_target_db_access" {
  count                    = var.enable_dms ? 1 : 0
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  description              = "Allow DMS access to target database"
  security_group_id        = try(module.aurora_mysql_v2["central"].security_group_id, var.dms_migration_details.target_db_security_group_id)
  source_security_group_id = module.security_group[0].security_group_id
}

resource "aws_dms_replication_config" "serverless" {
  count                         = var.enable_dms ? 1 : 0
  replication_config_identifier = "${var.tags.project}-${var.tags.environment}-migration"
  replication_type              = var.dms_migration_details.migration_type
  source_endpoint_arn           = aws_dms_endpoint.source[0].endpoint_arn
  target_endpoint_arn           = aws_dms_endpoint.target[0].endpoint_arn
  table_mappings                = var.dms_migration_details.table_mappings
  start_replication             = true

  replication_settings = jsonencode({
    FullLoadSettings = {
      TargetTablePrepMode = "TRUNCATE_BEFORE_LOAD"
      CommitRate          = var.dms_migration_details.full_load_settings.commit_rate
      MaxFullLoadSubTasks = var.dms_migration_details.full_load_settings.max_full_load_sub_tasks
    }

    Logging = {
      EnableLogging    = true
      EnableLogContext = true
    }
  })

  compute_config {
    min_capacity_units          = var.dms_migration_details.compute_config.min_capacity_units
    max_capacity_units          = var.dms_migration_details.compute_config.max_capacity_units
    replication_subnet_group_id = aws_dms_replication_subnet_group.dms_subnet_group[0].replication_subnet_group_id
    vpc_security_group_ids      = [module.security_group[0].security_group_id]
  }

  depends_on = [
    module.security_group,
    module.vpc_peering_for_legacy_db_redis_servers,
    aws_security_group_rule.dms_source_db_access,
    aws_security_group_rule.dms_target_db_access
  ]
}

resource "aws_dms_replication_subnet_group" "dms_subnet_group" {
  count                                = var.enable_dms ? 1 : 0
  replication_subnet_group_id          = "${var.tags.project}-${var.tags.environment}-dms-subnet-group"
  replication_subnet_group_description = "Subnet group for DMS replication instances"
  subnet_ids                           = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  depends_on                           = [aws_iam_role_policy_attachment.dms_vpc_policy_attachment]
}
