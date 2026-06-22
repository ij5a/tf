resource "aws_ebs_snapshot_block_public_access" "this" {
  count = var.enable_account_security ? 1 : 0
  state = "block-all-sharing"
}

resource "aws_ebs_encryption_by_default" "this" {
  count   = var.enable_account_security ? 1 : 0
  enabled = true
}

resource "aws_ebs_encryption_by_default" "us_east_1" {
  count    = var.enable_account_security ? 1 : 0
  provider = aws.us-east-1
  enabled  = true
}

resource "aws_ssm_service_setting" "document_public_sharing" {
  count         = var.enable_account_security ? 1 : 0
  setting_id    = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

module "readonly_role" {
  count   = var.enable_account_security ? 1 : 0
  source  = var.module_sources.iam_role.source
  version = var.module_sources.iam_role.version

  name        = "ops-readonly"
  description = "Read-only role assumable from the main (master payer) account."

  policies = {
    "ReadOnlyAccess" = "arn:aws:iam::aws:policy/ReadOnlyAccess"
  }

  trust_policy_permissions = {
    AllowMainAccountAssume = {
      actions = ["sts:AssumeRole", "sts:TagSession"]
      principals = [{
        type        = "AWS"
        identifiers = ["arn:aws:iam::333333333333:root"]
      }]
    }
  }
}

module "support_role" {
  count   = var.enable_account_security ? 1 : 0
  source  = var.module_sources.iam_role.source
  version = var.module_sources.iam_role.version

  name        = "aws-support-access"
  description = "Role for managing incidents with AWS Support (Security Hub IAM.18)"

  policies = {
    "AWSSupportAccess" = "arn:aws:iam::aws:policy/AWSSupportAccess"
  }

  trust_policy_permissions = {
    AllowAccountAssume = {
      actions = ["sts:AssumeRole"]
      principals = [{
        type        = "AWS"
        identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
      }]
    }
  }
}
