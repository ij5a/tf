data "aws_iam_policy_document" "allow_cf_to_use_cmk_s3" {
  for_each = var.enable_s3 && var.enable_cloudfront ? toset([for service in var.services : service if service == "spa"]) : toset([])
  statement {
    sid    = "AllowCFToUseCMKS3"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
    ]

    resources = [
      "*",
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_arn]
    }
  }

  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions = [
      "kms:*"
    ]

    resources = ["*"]
  }
}

resource "aws_kms_key" "cmk_s3" {
  for_each                = var.enable_s3 && var.enable_cloudfront ? toset([for service in var.services : service if service == "spa"]) : toset([])
  description             = "KMS key for the S3 bucket for the spa service."
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.allow_cf_to_use_cmk_s3["spa"].json
}

module "s3_access_logs" {
  count                                      = var.enable_s3 && var.enable_cloudfront && local.is_prod ? 1 : 0
  source                                     = var.module_sources.s3_bucket.source
  version                                    = var.module_sources.s3_bucket.version
  bucket_prefix                              = "${var.tags.project}-${var.tags.environment}-access-logs-"
  block_public_acls                          = true
  block_public_policy                        = true
  control_object_ownership                   = true
  force_destroy                              = true
  ignore_public_acls                         = true
  object_ownership                           = "BucketOwnerPreferred"
  restrict_public_buckets                    = true
  attach_deny_insecure_transport_policy      = true
  attach_access_log_delivery_policy          = true
  access_log_delivery_policy_source_accounts = [data.aws_caller_identity.current.account_id]
}

# Managed outside the module so the deprecated rule.prefix attribute doesn't flow through
# the module's s3_bucket_lifecycle_configuration_rules output (AWS provider 6.x deprecation).
resource "aws_s3_bucket_lifecycle_configuration" "s3_access_logs" {
  count  = var.enable_s3 && var.enable_cloudfront && local.is_prod ? 1 : 0
  bucket = module.s3_access_logs[0].s3_bucket_id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

module "elb_access_logs" {
  count                                 = var.enable_alb && local.is_prod ? 1 : 0
  source                                = var.module_sources.s3_bucket.source
  version                               = var.module_sources.s3_bucket.version
  bucket_prefix                         = "${var.tags.project}-${var.tags.environment}-elb-access-logs-"
  block_public_acls                     = true
  block_public_policy                   = true
  control_object_ownership              = true
  force_destroy                         = true
  ignore_public_acls                    = true
  object_ownership                      = "BucketOwnerPreferred"
  restrict_public_buckets               = true
  attach_deny_insecure_transport_policy = true
  attach_elb_log_delivery_policy        = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
      bucket_key_enabled = true
    }
  }
}

# Managed outside the module so the deprecated rule.prefix attribute doesn't flow through
# the module's s3_bucket_lifecycle_configuration_rules output (AWS provider 6.x deprecation).
resource "aws_s3_bucket_lifecycle_configuration" "elb_access_logs" {
  count  = var.enable_alb && local.is_prod ? 1 : 0
  bucket = module.elb_access_logs[0].s3_bucket_id

  rule {
    id     = "expire-elb-access-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 90
    }
  }
}

module "s3_bucket" {
  source                                = var.module_sources.s3_bucket.source
  version                               = var.module_sources.s3_bucket.version
  for_each                              = var.enable_s3 && var.enable_cloudfront ? toset(concat([for service in var.services : service if service == "spa"], ["storage"])) : toset([])
  block_public_acls                     = true
  block_public_policy                   = true
  bucket_prefix                         = "${var.tags.project}-${var.tags.environment}-${each.key}-"
  control_object_ownership              = true
  force_destroy                         = true
  ignore_public_acls                    = true
  object_ownership                      = "BucketOwnerPreferred"
  restrict_public_buckets               = true
  attach_deny_insecure_transport_policy = true
  attach_policy                         = each.key == "spa"
  policy                                = each.key == "spa" ? data.aws_iam_policy_document.policy_for_cloudfront_private_content[0].json : null

  versioning = {
    enabled = true
  }

  logging = local.is_prod ? {
    target_bucket = module.s3_access_logs[0].s3_bucket_id
    target_prefix = "${each.key}/"
  } : {}

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = aws_kms_key.cmk_s3["spa"].key_id
        sse_algorithm     = "aws:kms"
      }
      blocked_encryption_types = ["NONE"]
      bucket_key_enabled       = true
    }
  }
}

data "aws_iam_policy_document" "policy_for_cloudfront_private_content" {
  count = var.enable_s3 && var.enable_cloudfront && contains(var.services, "spa") ? 1 : 0

  statement {
    sid    = "PolicyForCloudFrontPrivateContent"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${module.s3_bucket["spa"].s3_bucket_arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_arn]
    }
  }
}

locals {
  create_vpc_flow_logs_bucket = var.enable_vpc_flow_logs && (
    (var.enable_vpc && !var.use_existing_vpc) ||
    (var.use_existing_vpc && var.manage_existing_vpc_flow_log)
  )
}

data "aws_iam_policy_document" "vpc_flow_logs_kms" {
  count = local.create_vpc_flow_logs_bucket ? 1 : 0

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

  # With bucket_key_enabled = true, S3 itself (not delivery.logs.amazonaws.com)
  # is the principal that calls KMS during the SSE-KMS encrypt path. Match the
  # AWS-managed "auto-s3" pattern used by the pre-existing manually-created
  # acme-prod-sa-east-1-vpc-flow-logs bucket: scope by kms:ViaService.
  statement {
    sid    = "AllowAccessThroughS3"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }

  # Direct delivery service path (no S3 mediation) — kept for completeness;
  # broadened action list to AWS canonical for VPC flow logs delivery.
  statement {
    sid    = "AllowVPCFlowLogsToUseKey"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_kms_key" "vpc_flow_logs" {
  count                   = local.create_vpc_flow_logs_bucket ? 1 : 0
  description             = "KMS key for ${var.tags.project}-${var.tags.environment} VPC flow logs S3 bucket"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.vpc_flow_logs_kms[0].json
}

resource "aws_kms_alias" "vpc_flow_logs" {
  count         = local.create_vpc_flow_logs_bucket ? 1 : 0
  name          = "alias/${var.tags.project}-${var.tags.environment}-vpc-flow-logs"
  target_key_id = aws_kms_key.vpc_flow_logs[0].key_id
}

data "aws_iam_policy_document" "vpc_flow_logs_bucket" {
  count = local.create_vpc_flow_logs_bucket ? 1 : 0

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.tags.project}-${var.tags.environment}-${var.region}-vpc-flow-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions = [
      "s3:GetBucketAcl",
      "s3:ListBucket",
    ]
    resources = ["arn:aws:s3:::${var.tags.project}-${var.tags.environment}-${var.region}-vpc-flow-logs"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  # Hive-compatible partition path. VPC flow logs configured with
  # HiveCompatiblePartitions=true write to AWSLogs/aws-account-id=<acct>/...
  # instead of the classic AWSLogs/<acct>/... prefix, so we need an
  # explicit Allow for the hive path or PutObject fails with "Access error".
  statement {
    sid    = "AWSLogDeliveryWrite1"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${var.tags.project}-${var.tags.environment}-${var.region}-vpc-flow-logs/AWSLogs/aws-account-id=${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

module "vpc_flow_logs_bucket" {
  count                                 = local.create_vpc_flow_logs_bucket ? 1 : 0
  source                                = var.module_sources.s3_bucket.source
  version                               = var.module_sources.s3_bucket.version
  bucket                                = "${var.tags.project}-${var.tags.environment}-${var.region}-vpc-flow-logs"
  block_public_acls                     = true
  block_public_policy                   = true
  control_object_ownership              = true
  force_destroy                         = false
  ignore_public_acls                    = true
  object_ownership                      = "BucketOwnerPreferred"
  restrict_public_buckets               = true
  attach_deny_insecure_transport_policy = true
  attach_policy                         = true
  policy                                = data.aws_iam_policy_document.vpc_flow_logs_bucket[0].json

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = aws_kms_key.vpc_flow_logs[0].arn
        sse_algorithm     = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }
}

# Managed outside the module so the deprecated rule.prefix attribute doesn't flow through
# the module's s3_bucket_lifecycle_configuration_rules output (AWS provider 6.x deprecation).
resource "aws_s3_bucket_lifecycle_configuration" "vpc_flow_logs" {
  count  = local.create_vpc_flow_logs_bucket ? 1 : 0
  bucket = module.vpc_flow_logs_bucket[0].s3_bucket_id

  rule {
    id     = "expire-flow-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 365
    }
  }
}

# One archive per AWS account, not per env, so the name carries the account's env not this stack's.
locals {
  aurora_audit_archive_name = "acme-prod-aurora-audit-archive"
}

data "aws_iam_policy_document" "aurora_audit_archive_kms" {
  count = var.enable_aurora_audit_log_archive ? 1 : 0

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

  # CloudWatch Logs writes the export objects itself, so it needs a data key for the bucket's SSE-KMS default.
  statement {
    sid    = "AllowCloudWatchLogsExport"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/cluster/*"]
    }
  }
}

# prevent_destroy so flipping the archive flag back off fails the plan instead of quietly scheduling
# deletion of the key that a locked evidence bucket needs to stay readable.
resource "aws_kms_key" "aurora_audit_archive" {
  count                   = var.enable_aurora_audit_log_archive ? 1 : 0
  description             = "KMS key for the Aurora audit log archive S3 bucket"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.aurora_audit_archive_kms[0].json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "aurora_audit_archive" {
  count         = var.enable_aurora_audit_log_archive ? 1 : 0
  name          = "alias/${local.aurora_audit_archive_name}"
  target_key_id = aws_kms_key.aurora_audit_archive[0].key_id
}

data "aws_iam_policy_document" "aurora_audit_archive_bucket" {
  count = var.enable_aurora_audit_log_archive ? 1 : 0

  statement {
    sid    = "AWSLogsExportAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/cluster/*"]
    }
  }

  statement {
    sid    = "AWSLogsExportWrite"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/rds/cluster/*"]
    }
  }

  # The header denies below only fire when the caller sends its own encryption or object-lock headers,
  # so headerless export puts keep the bucket defaults; the last one blocks both ways of losing an object.
  statement {
    sid    = "DenyWrongEncryptionAlgorithm"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["false"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [aws_kms_key.aurora_audit_archive[0].arn]
    }
  }

  statement {
    sid    = "DenyCustomerProvidedKey"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-customer-algorithm"
      values   = ["false"]
    }
  }

  statement {
    sid    = "DenyKmsWithoutKeyId"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyShortObjectLockRetention"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = [
      "s3:PutObject",
      "s3:PutObjectRetention",
    ]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "NumericLessThan"
      variable = "s3:object-lock-remaining-retention-days"
      values   = ["365"]
    }
  }

  statement {
    sid    = "DenyRetentionRemoval"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObjectRetention"]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
    condition {
      test     = "Null"
      variable = "s3:object-lock-remaining-retention-days"
      values   = ["true"]
    }
  }

  statement {
    sid    = "DenyEvidenceHiding"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]
    resources = ["arn:aws:s3:::${local.aurora_audit_archive_name}/*"]
  }
}

# Holds the Aurora audit logs exported out of CloudWatch before their log groups are swapped to the
# Infrequent Access class. Object Lock is GOVERNANCE, not COMPLIANCE, while the retention scope is unsettled.
module "aurora_audit_archive_bucket" {
  count                                 = var.enable_aurora_audit_log_archive ? 1 : 0
  source                                = var.module_sources.s3_bucket.source
  version                               = var.module_sources.s3_bucket.version
  bucket                                = local.aurora_audit_archive_name
  block_public_acls                     = true
  block_public_policy                   = true
  control_object_ownership              = true
  force_destroy                         = false
  ignore_public_acls                    = true
  object_lock_enabled                   = true
  object_ownership                      = "BucketOwnerPreferred"
  restrict_public_buckets               = true
  attach_deny_insecure_transport_policy = true
  attach_policy                         = true
  policy                                = data.aws_iam_policy_document.aurora_audit_archive_bucket[0].json

  versioning = {
    enabled = true
  }

  object_lock_configuration = {
    rule = {
      default_retention = {
        mode = "GOVERNANCE"
        days = 365
      }
    }
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = aws_kms_key.aurora_audit_archive[0].arn
        sse_algorithm     = "aws:kms"
      }
      bucket_key_enabled = true
    }
  }
}

# Managed outside the module so the deprecated rule.prefix attribute doesn't flow through
# the module's s3_bucket_lifecycle_configuration_rules output (AWS provider 6.x deprecation).
resource "aws_s3_bucket_lifecycle_configuration" "aurora_audit_archive" {
  count  = var.enable_aurora_audit_log_archive ? 1 : 0
  bucket = module.aurora_audit_archive_bucket[0].s3_bucket_id

  rule {
    id     = "archive-then-expire-audit-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
