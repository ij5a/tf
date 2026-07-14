# slack-webhook-urls secret is created manually in the AWS Console
data "aws_secretsmanager_secret_version" "slack" {
  count     = var.enable_slack_notifications ? 1 : 0
  secret_id = "slack-webhook-urls"
}

data "aws_secretsmanager_secret_version" "slack_us_east_1" {
  count     = var.enable_slack_notifications ? 1 : 0
  provider  = aws.us-east-1
  secret_id = "slack-webhook-urls"
}

# alerts only; deployments are handled by the Go codepipeline-slack Lambda below
locals {
  slack_webhook_urls = var.enable_slack_notifications && var.enable_alert_notifications ? {
    alerts = jsondecode(data.aws_secretsmanager_secret_version.slack[0].secret_string)["alerts"]
  } : {}
}

# KMS key required so the Slack webhook URL isn't exposed in state file or logs
resource "aws_kms_key" "notify_slack" {
  count               = var.enable_slack_notifications ? 1 : 0
  description         = "KMS key for notify-slack module."
  enable_key_rotation = true
}

resource "aws_kms_ciphertext" "slack_webhook_url" {
  for_each  = var.enable_slack_notifications ? local.slack_webhook_urls : {}
  plaintext = each.value
  key_id    = aws_kms_key.notify_slack[0].arn
}

resource "aws_kms_key" "notify_slack_us_east_1" {
  count               = var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  provider            = aws.us-east-1
  description         = "KMS key for notify-slack module."
  enable_key_rotation = true
}

resource "aws_kms_ciphertext" "slack_webhook_url_us_east_1" {
  count     = var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  provider  = aws.us-east-1
  plaintext = jsondecode(data.aws_secretsmanager_secret_version.slack_us_east_1[0].secret_string)["alerts"]
  key_id    = aws_kms_key.notify_slack_us_east_1[0].arn
}

module "notify_slack" {
  source                                 = var.module_sources.notify_slack.source
  version                                = var.module_sources.notify_slack.version
  for_each                               = var.enable_slack_notifications ? local.slack_webhook_urls : {}
  slack_channel                          = !local.is_prod ? "${var.tags.project}-dev-${each.key}" : "${var.tags.project}-${var.tags.environment}-${each.key}"
  slack_username                         = var.slack_username
  kms_key_arn                            = aws_kms_key.notify_slack[0].arn
  slack_webhook_url                      = aws_kms_ciphertext.slack_webhook_url[each.key].ciphertext_blob
  sns_topic_name                         = "${var.tags.project}-${var.tags.environment}-${each.key}-alert"
  lambda_function_name                   = "${var.tags.project}-${var.tags.environment}-${each.key}-alert"
  architectures                          = ["arm64"]
  cloudwatch_log_group_retention_in_days = 1
  recreate_missing_package               = false
}

module "notify_slack_alerts_us_east_1" {
  count                                  = var.enable_slack_notifications && var.enable_alert_notifications ? 1 : 0
  source                                 = var.module_sources.notify_slack.source
  version                                = var.module_sources.notify_slack.version
  slack_channel                          = !local.is_prod ? "${var.tags.project}-dev-alerts" : "${var.tags.project}-${var.tags.environment}-alerts"
  slack_username                         = var.slack_username
  kms_key_arn                            = aws_kms_key.notify_slack_us_east_1[0].arn
  slack_webhook_url                      = aws_kms_ciphertext.slack_webhook_url_us_east_1[0].ciphertext_blob
  sns_topic_name                         = "${var.tags.project}-${var.tags.environment}-alerts-us-east-1-alert"
  lambda_function_name                   = "${var.tags.project}-${var.tags.environment}-alerts-us-east-1-alert"
  architectures                          = ["arm64"]
  cloudwatch_log_group_retention_in_days = 1
  recreate_missing_package               = false

  providers = {
    aws = aws.us-east-1
  }
}

# PagerDuty URL lives in the main env secret (sa-east-1); SNS subscription below is us-east-1
data "aws_secretsmanager_secret_version" "pagerduty" {
  count     = var.enable_pagerduty ? 1 : 0
  secret_id = "${var.tags.project}-${var.tags.environment}"
}

resource "aws_sns_topic_subscription" "pagerduty" {
  count     = var.enable_pagerduty ? 1 : 0
  provider  = aws.us-east-1
  topic_arn = module.notify_slack_alerts_us_east_1[0].slack_topic_arn
  protocol  = "https"
  endpoint  = jsondecode(data.aws_secretsmanager_secret_version.pagerduty[0].secret_string)["pagerduty_integration_url"]
}

# sa-east-1 PD fan-out for regional alarms (VPN, etc.). CloudWatch alarm
# actions are region-local — the us-east-1 subscription above can't be reached
# by sa-east-1 alarms. Same integration URL, distinct AlarmArn keeps PD dedup
# honest.
resource "aws_sns_topic_subscription" "pagerduty_sa_east_1" {
  count     = var.enable_pagerduty && var.enable_slack_notifications ? 1 : 0
  topic_arn = module.notify_slack["alerts"].slack_topic_arn
  protocol  = "https"
  endpoint  = jsondecode(data.aws_secretsmanager_secret_version.pagerduty[0].secret_string)["pagerduty_integration_url"]
}

# stores Slack message timestamps so the Lambda can update existing messages in-place
resource "aws_dynamodb_table" "slack_messages" {
  count        = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  name         = "${var.tags.project}-${var.tags.environment}-slack-messages"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "execution_id"

  attribute {
    name = "execution_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

resource "null_resource" "build_codepipeline_slack" {
  count = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0

  triggers = {
    go_mod_sha512   = filesha512("lambda-functions/go/codepipeline-slack/go.mod")
    go_sum_sha512   = filesha512("lambda-functions/go/codepipeline-slack/go.sum")
    code_sha512     = filesha512("lambda-functions/go/codepipeline-slack/main.go")
    makefile_sha512 = filesha512("lambda-functions/go/codepipeline-slack/Makefile")
  }

  provisioner "local-exec" {
    command = "make -C lambda-functions/go/codepipeline-slack"
  }
}

module "codepipeline_slack" {
  count                             = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  source                            = var.module_sources.lambda.source
  version                           = var.module_sources.lambda.version
  function_name                     = "${var.tags.project}-${var.tags.environment}-codepipeline-slack"
  description                       = "Formats CodePipeline events and sends to Slack"
  handler                           = "bootstrap"
  runtime                           = "provided.al2023"
  memory_size                       = 128
  timeout                           = 30
  cloudwatch_logs_retention_in_days = local.is_prod ? 90 : 7
  create_package                    = false
  local_existing_package            = "lambda-functions/go/codepipeline-slack/lambda-handler.zip"
  architectures                     = ["arm64"]
  attach_policy_statements          = true

  policy_statements = {
    codepipeline = {
      effect    = "Allow"
      actions   = ["codepipeline:GetPipelineExecution", "codepipeline:ListActionExecutions"]
      resources = ["arn:aws:codepipeline:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:${var.tags.project}-${var.tags.environment}-*"]
    }
    ecr = {
      effect    = "Allow"
      actions   = ["ecr:DescribeImages"]
      resources = ["arn:aws:ecr:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:repository/${var.image_repository_name}"]
    }
    dynamodb = {
      effect    = "Allow"
      actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:DeleteItem"]
      resources = [aws_dynamodb_table.slack_messages[0].arn]
    }
  }

  environment_variables = {
    SLACK_BOT_TOKEN = jsondecode(data.aws_secretsmanager_secret_version.slack[0].secret_string)["bot_token"]
    SLACK_CHANNEL   = !local.is_prod ? "acme-dev-deployments" : "acme-${var.tags.environment}-deployments"
    SLACK_USERNAME  = var.slack_username
    SLACK_ICON_URL  = "https://upload.wikimedia.org/wikipedia/commons/thumb/9/93/Amazon_Web_Services_Logo.svg/512px-Amazon_Web_Services_Logo.svg.png"
    ECR_REPOSITORY  = var.image_repository_name
    DYNAMODB_TABLE  = aws_dynamodb_table.slack_messages[0].name
  }

  depends_on = [null_resource.build_codepipeline_slack]
}

resource "aws_cloudwatch_event_rule" "codepipeline_state_change" {
  count       = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-codepipeline-state-change"
  description = "Capture CodePipeline execution state changes for Slack notification"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    detail = {
      state    = ["STARTED", "FAILED", "CANCELED"]
      pipeline = [for svc in var.services : "${var.tags.project}-${var.tags.environment}-${svc}"]
    }
  })
}

# separate Deploy-stage rule so we fire SUCCESS after deploy, not after downstream approval stages
resource "aws_cloudwatch_event_rule" "codepipeline_deploy_stage" {
  count       = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-codepipeline-deploy-stage"
  description = "Capture Deploy stage completion for Slack notification"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Stage Execution State Change"]
    detail = {
      state    = ["SUCCEEDED", "FAILED"]
      stage    = ["Deploy", "CloudFrontInvalidation"]
      pipeline = [for svc in var.services : "${var.tags.project}-${var.tags.environment}-${svc}"]
    }
  })
}

resource "aws_cloudwatch_event_target" "codepipeline_to_lambda" {
  count     = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  rule      = aws_cloudwatch_event_rule.codepipeline_state_change[0].name
  target_id = "codepipeline-to-slack"
  arn       = module.codepipeline_slack[0].lambda_function_arn
}

resource "aws_cloudwatch_event_target" "codepipeline_deploy_to_lambda" {
  count     = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  rule      = aws_cloudwatch_event_rule.codepipeline_deploy_stage[0].name
  target_id = "codepipeline-deploy-to-slack"
  arn       = module.codepipeline_slack[0].lambda_function_arn
}

resource "aws_lambda_permission" "codepipeline_eventbridge" {
  count         = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  statement_id  = "AllowEventBridgeInvokePipeline"
  action        = "lambda:InvokeFunction"
  function_name = module.codepipeline_slack[0].lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.codepipeline_state_change[0].arn
}

resource "aws_lambda_permission" "codepipeline_deploy_eventbridge" {
  count         = var.enable_slack_notifications && var.enable_deployment_notifications && var.enable_codepipeline ? 1 : 0
  statement_id  = "AllowEventBridgeInvokeDeployStage"
  action        = "lambda:InvokeFunction"
  function_name = module.codepipeline_slack[0].lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.codepipeline_deploy_stage[0].arn
}
