data "aws_region" "current" {}

# findings flow: GuardDuty → EventBridge rule → Lambda (guardduty_slack) → Slack
resource "aws_guardduty_detector" "this" {
  count                        = var.enable_guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# detector feature resources replace the deprecated datasources block
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_detector_feature
resource "aws_guardduty_detector_feature" "this" {
  for_each    = var.enable_guardduty ? toset(["S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION", "EKS_AUDIT_LOGS", "RDS_LOGIN_EVENTS", "LAMBDA_NETWORK_LOGS"]) : toset([])
  detector_id = aws_guardduty_detector.this[0].id
  name        = each.key
  status      = "ENABLED"
}

# Note: Only one of EKS_RUNTIME_MONITORING or RUNTIME_MONITORING can be enabled.
# RUNTIME_MONITORING is more comprehensive (covers EKS, ECS Fargate, and EC2).
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count       = var.enable_guardduty ? 1 : 0
  detector_id = aws_guardduty_detector.this[0].id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }

  additional_configuration {
    name   = "ECS_FARGATE_AGENT_MANAGEMENT"
    status = "ENABLED"
  }

  additional_configuration {
    name   = "EC2_AGENT_MANAGEMENT"
    status = "ENABLED"
  }
}

resource "null_resource" "build_guardduty_slack" {
  count = var.enable_guardduty && var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0

  triggers = {
    go_mod_sha512   = filesha512("lambda-functions/go/guardduty-slack/go.mod")
    go_sum_sha512   = filesha512("lambda-functions/go/guardduty-slack/go.sum")
    code_sha512     = filesha512("lambda-functions/go/guardduty-slack/main.go")
    makefile_sha512 = filesha512("lambda-functions/go/guardduty-slack/Makefile")
  }

  provisioner "local-exec" {
    command = "make -C lambda-functions/go/guardduty-slack"
  }
}

module "guardduty_slack" {
  count                             = var.enable_guardduty && var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  source                            = var.module_sources.lambda.source
  version                           = var.module_sources.lambda.version
  function_name                     = "${var.tags.project}-${var.tags.environment}-guardduty-slack"
  description                       = "Formats GuardDuty findings and sends to Slack"
  handler                           = "bootstrap"
  runtime                           = "provided.al2023"
  memory_size                       = 128
  timeout                           = 30
  cloudwatch_logs_retention_in_days = local.is_prod ? 90 : 7
  create_package                    = false
  local_existing_package            = "lambda-functions/go/guardduty-slack/lambda-handler.zip"
  architectures                     = ["arm64"]
  attach_policy_statements          = true

  policy_statements = {
    secrets_manager = {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:slack-webhook-urls*"]
    }
  }

  environment_variables = {
    SECRET_NAME = "slack-webhook-urls"
  }

  depends_on = [null_resource.build_guardduty_slack]
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  count       = var.enable_guardduty && var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-guardduty-findings"
  description = "Capture GuardDuty findings for Slack notification"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [
        { numeric = [">=", 4] } # Medium (4-6.9), High (7-8.9), Critical (9-10)
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_to_lambda" {
  count     = var.enable_guardduty && var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  rule      = aws_cloudwatch_event_rule.guardduty_findings[0].name
  target_id = "guardduty-to-slack"
  arn       = module.guardduty_slack[0].lambda_function_arn
}

resource "aws_lambda_permission" "guardduty_eventbridge" {
  count         = var.enable_guardduty && var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.guardduty_slack[0].lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_findings[0].arn
}
