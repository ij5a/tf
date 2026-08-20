# TEMPORARY: SSM-only EC2 dump host and S3 bucket.
# Turn it off after the dump; bucket deletion includes remaining objects.

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.enable_db_dump_host ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

module "db_dump_host_security_group" {
  source  = var.module_sources["security_group"].source
  version = var.module_sources["security_group"].version
  count   = var.enable_db_dump_host ? 1 : 0

  name        = "${var.tags.project}-${var.tags.environment}-db-dump-host"
  description = "DB dump host security group"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  tags = {
    Name = "${var.tags.project}-${var.tags.environment}-db-dump-host"
  }

  ingress_rules = {}

  egress_rules = {
    https = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      description = "SSM, S3, package access"
      cidr_ipv4   = "0.0.0.0/0"
    }
    mysql = {
      from_port   = 3306
      to_port     = 3306
      ip_protocol = "tcp"
      description = "Target DB access"
      cidr_ipv4   = "0.0.0.0/0"
    }
    sftp = {
      from_port   = 22
      to_port     = 22
      ip_protocol = "tcp"
      description = "SFTP handover to an external endpoint"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_dump_host" {
  for_each = var.enable_db_dump_host ? toset(var.db_dump_host_config.db_security_group_ids) : toset([])

  security_group_id            = each.value
  referenced_security_group_id = module.db_dump_host_security_group[0].id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  description                  = "DB dump host"
}

module "db_dump_host_bucket" {
  source  = var.module_sources["s3_bucket"].source
  version = var.module_sources["s3_bucket"].version
  count   = var.enable_db_dump_host ? 1 : 0

  bucket_prefix                         = "${var.tags.project}-${var.tags.environment}-db-dump-"
  block_public_acls                     = true
  block_public_policy                   = true
  control_object_ownership              = true
  force_destroy                         = true
  ignore_public_acls                    = true
  object_ownership                      = "BucketOwnerPreferred"
  restrict_public_buckets               = true
  attach_deny_insecure_transport_policy = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
      bucket_key_enabled = true
    }
  }
}

# Separate resource avoids the provider 6.x lifecycle deprecation.
resource "aws_s3_bucket_lifecycle_configuration" "db_dump_host" {
  count  = var.enable_db_dump_host ? 1 : 0
  bucket = module.db_dump_host_bucket[0].s3_bucket_id

  rule {
    id     = "expire-db-dumps"
    status = "Enabled"

    filter {}

    expiration {
      days = var.db_dump_host_config.dump_expiry_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "db_dump_host_s3" {
  count = var.enable_db_dump_host ? 1 : 0

  statement {
    sid       = "ListDumpBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [module.db_dump_host_bucket[0].s3_bucket_arn]
  }

  statement {
    sid    = "ManageDumpObjects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${module.db_dump_host_bucket[0].s3_bucket_arn}/*"]
  }
}

module "db_dump_host_s3_policy" {
  source  = var.module_sources["iam_policy"].source
  version = var.module_sources["iam_policy"].version
  count   = var.enable_db_dump_host ? 1 : 0

  name_prefix = "${var.tags.project}-${var.tags.environment}-db-dump-host-"
  path        = "/"
  description = "DB dump host S3 access"
  policy      = data.aws_iam_policy_document.db_dump_host_s3[0].json
}

module "db_dump_host_iam_role" {
  source  = var.module_sources["iam_role"].source
  version = var.module_sources["iam_role"].version
  count   = var.enable_db_dump_host ? 1 : 0

  name                    = "${var.tags.project}-${var.tags.environment}-db-dump-host"
  use_name_prefix         = true
  description             = "DB dump host instance role"
  create_instance_profile = true

  policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    DumpBucket                   = module.db_dump_host_s3_policy[0].arn
  }

  trust_policy_permissions = {
    TrustEc2 = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "Service"
        identifiers = ["ec2.amazonaws.com"]
      }]
    }
  }
}

resource "aws_instance" "db_dump_host" {
  count = var.enable_db_dump_host ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023_arm64[0].value
  instance_type               = var.db_dump_host_config.instance_type
  subnet_id                   = var.db_dump_host_config.subnet_id != null ? var.db_dump_host_config.subnet_id : try(module.vpc[0].private_subnets[0], var.existing_vpc_details.private_subnet_ids[0])
  associate_public_ip_address = false
  vpc_security_group_ids      = [module.db_dump_host_security_group[0].id]
  iam_instance_profile        = module.db_dump_host_iam_role[0].instance_profile_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.db_dump_host_config.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    dnf install -y https://dev.mysql.com/get/mysql84-community-release-el9-1.noarch.rpm

    # Keep MySQL repo access on the SG's 443 egress.
    sed -i 's|http://repo.mysql.com|https://repo.mysql.com|g' /etc/yum.repos.d/mysql-community*.repo
    # Replace the expired key from the pinned release package.
    curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2025 -o /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql-2025
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-mysql-2025
    sed -i 's|RPM-GPG-KEY-mysql-2023|RPM-GPG-KEY-mysql-2025|g' /etc/yum.repos.d/mysql-community*.repo
    dnf install -y --allowerasing mysql-community-client mysql-shell zstd gnupg2

    cat > /etc/profile.d/db-dump.sh <<'PROFILE'
    export DUMP_BUCKET="${module.db_dump_host_bucket[0].s3_bucket_id}"
    export DB_HOST="${var.db_dump_host_config.db_endpoint}"
    PROFILE
  EOT

  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [ami]
  }

  tags = merge(var.tags, {
    Name = "${var.tags.project}-${var.tags.environment}-db-dump-host"
  })

  depends_on = [module.db_dump_host_iam_role]
}

data "aws_iam_policy_document" "db_dump_host_scheduler" {
  count = var.enable_db_dump_host ? 1 : 0

  statement {
    sid       = "StartStopDumpHost"
    effect    = "Allow"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.db_dump_host[0].arn]
  }

  statement {
    sid       = "DescribeEc2"
    effect    = "Allow"
    actions   = ["ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }

  statement {
    sid     = "StartAutomation"
    effect  = "Allow"
    actions = ["ssm:StartAutomationExecution"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.region}::document/AWS-StartEC2Instance",
      "arn:aws:ssm:${data.aws_region.current.region}::document/AWS-StopEC2Instance",
      "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:automation-execution/*",
    ]
  }

  statement {
    sid       = "GetAutomation"
    effect    = "Allow"
    actions   = ["ssm:GetAutomationExecution"]
    resources = ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:automation-execution/*"]
  }

  statement {
    sid       = "PassSchedulerRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.tags.project}-${var.tags.environment}-db-dump-scheduler"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

module "db_dump_host_scheduler_policy" {
  source  = var.module_sources["iam_policy"].source
  version = var.module_sources["iam_policy"].version
  count   = var.enable_db_dump_host ? 1 : 0

  name_prefix = "${var.tags.project}-${var.tags.environment}-db-dump-scheduler-"
  path        = "/"
  description = "DB dump host schedule"
  policy      = data.aws_iam_policy_document.db_dump_host_scheduler[0].json
}

module "db_dump_host_scheduler_role" {
  source  = var.module_sources["iam_role"].source
  version = var.module_sources["iam_role"].version
  count   = var.enable_db_dump_host ? 1 : 0

  name = "${var.tags.project}-${var.tags.environment}-db-dump-scheduler"
  # A fixed name makes PassRole target this role exactly.
  use_name_prefix = false
  description     = "DB dump host SSM scheduler"
  policies        = { Scheduler = module.db_dump_host_scheduler_policy[0].arn }

  trust_policy_permissions = {
    TrustSsm = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "Service"
        identifiers = ["ssm.amazonaws.com"]
      }]
      condition = [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [data.aws_caller_identity.current.account_id]
      }]
    }
  }
}

# Default crons are UTC; timezone reinterprets them, so restate them in local time.
resource "aws_ssm_maintenance_window" "db_dump_host_start" {
  count             = var.enable_db_dump_host ? 1 : 0
  name              = "${var.tags.project}-${var.tags.environment}-db-dump-start"
  description       = "Start DB dump host"
  schedule          = var.db_dump_host_config.schedule.start
  schedule_timezone = var.db_dump_host_config.schedule.timezone
  duration          = 1
  cutoff            = 0
}

resource "aws_ssm_maintenance_window" "db_dump_host_stop" {
  count             = var.enable_db_dump_host ? 1 : 0
  name              = "${var.tags.project}-${var.tags.environment}-db-dump-stop"
  description       = "Stop DB dump host"
  schedule          = var.db_dump_host_config.schedule.stop
  schedule_timezone = var.db_dump_host_config.schedule.timezone
  duration          = 1
  cutoff            = 0
}

resource "aws_ssm_maintenance_window_target" "db_dump_host_start" {
  count         = var.enable_db_dump_host ? 1 : 0
  window_id     = aws_ssm_maintenance_window.db_dump_host_start[0].id
  name          = "${var.tags.project}-${var.tags.environment}-db-dump-start-target"
  description   = "DB dump host start target"
  resource_type = "INSTANCE"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.db_dump_host[0].id]
  }
}

resource "aws_ssm_maintenance_window_target" "db_dump_host_stop" {
  count         = var.enable_db_dump_host ? 1 : 0
  window_id     = aws_ssm_maintenance_window.db_dump_host_stop[0].id
  name          = "${var.tags.project}-${var.tags.environment}-db-dump-stop-target"
  description   = "DB dump host stop target"
  resource_type = "INSTANCE"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.db_dump_host[0].id]
  }
}

resource "aws_ssm_maintenance_window_task" "db_dump_host_start" {
  count            = var.enable_db_dump_host ? 1 : 0
  name             = "${var.tags.project}-${var.tags.environment}-db-dump-start-task"
  description      = "Start DB dump host"
  max_concurrency  = 1
  max_errors       = 1
  priority         = 1
  task_arn         = "AWS-StartEC2Instance"
  task_type        = "AUTOMATION"
  service_role_arn = module.db_dump_host_scheduler_role[0].arn
  window_id        = aws_ssm_maintenance_window.db_dump_host_start[0].id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.db_dump_host_start[0].id]
  }

  task_invocation_parameters {
    automation_parameters {
      document_version = "$LATEST"

      parameter {
        name   = "AutomationAssumeRole"
        values = [module.db_dump_host_scheduler_role[0].arn]
      }

      parameter {
        name   = "InstanceId"
        values = ["{{ RESOURCE_ID }}"]
      }
    }
  }
}

resource "aws_ssm_maintenance_window_task" "db_dump_host_stop" {
  count            = var.enable_db_dump_host ? 1 : 0
  name             = "${var.tags.project}-${var.tags.environment}-db-dump-stop-task"
  description      = "Stop DB dump host"
  max_concurrency  = 1
  max_errors       = 1
  priority         = 1
  task_arn         = "AWS-StopEC2Instance"
  task_type        = "AUTOMATION"
  service_role_arn = module.db_dump_host_scheduler_role[0].arn
  window_id        = aws_ssm_maintenance_window.db_dump_host_stop[0].id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.db_dump_host_stop[0].id]
  }

  task_invocation_parameters {
    automation_parameters {
      document_version = "$LATEST"

      parameter {
        name   = "AutomationAssumeRole"
        values = [module.db_dump_host_scheduler_role[0].arn]
      }

      parameter {
        name   = "InstanceId"
        values = ["{{ RESOURCE_ID }}"]
      }
    }
  }
}

output "db_dump_host_instance_id" {
  description = "DB dump host instance ID"
  value       = try(aws_instance.db_dump_host[0].id, null)
}

output "db_dump_host_bucket_name" {
  description = "DB dump bucket name"
  value       = try(module.db_dump_host_bucket[0].s3_bucket_id, null)
}

output "db_dump_host_stop_window_id" {
  description = "DB dump stop window ID"
  value       = try(aws_ssm_maintenance_window.db_dump_host_stop[0].id, null)
}
