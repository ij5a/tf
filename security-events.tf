locals {
  security_events_enabled = var.enable_security_event_rules && var.enable_slack_notifications && var.enable_alert_notifications
  security_event_regions  = local.security_events_enabled ? toset(data.aws_regions.enabled[0].names) : toset([])
}

data "aws_regions" "enabled" {
  count = local.security_events_enabled ? 1 : 0
}

# Regional rules forward to the us-east-1 bus, where the Slack target sits.
resource "aws_cloudwatch_event_rule" "security_events" {
  for_each    = local.security_event_regions
  region      = each.key
  name        = "${var.tags.project}-${var.tags.environment}-security-events"
  description = "Security events forwarded to Slack"

  # Without this state, read-only management events skip the rule.
  state = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"

  # NOTE: IPv4 only, as no VPC here has IPv6. Add ::/0 if one does.
  # Rule edits carry no direction, so an outbound edit to 0.0.0.0/0 alerts too.
  event_pattern = jsonencode({
    "$or" = [
      { detail = { userIdentity = { type = ["Root"], invokedBy = [{ exists = false }] }, eventType = [{ "anything-but" = "AwsServiceEvent" }], readOnly = [false] } },
      { source = ["aws.signin"], detail = { responseElements = { ConsoleLogin = ["Failure"] } } },
      {
        source = ["aws.signin"]
        detail = {
          userIdentity        = { type = ["IAMUser"] }
          additionalEventData = { MFAUsed = ["No"] }
          responseElements    = { ConsoleLogin = ["Success"] }
        }
      },
      { detail = { errorCode = [{ suffix = "UnauthorizedOperation" }, { prefix = "AccessDenied" }], eventCategory = ["Management"], readOnly = [false], userIdentity = { type = ["IAMUser"] } } },
      {
        source = ["aws.iam"]
        detail = {
          eventName = [
            "CreateUser", "CreateAccessKey", "CreateLoginProfile", "UpdateLoginProfile", "DeactivateMFADevice", "AddUserToGroup",
            "AttachUserPolicy", "PutUserPolicy",
          ]
        }
      },
      { source = ["aws.iam"], detail = { eventName = [{ prefix = "Attach" }], requestParameters = { policyArn = ["arn:aws:iam::aws:policy/AdministratorAccess"] } } },
      { source = ["aws.cloudtrail"], detail = { eventName = ["DeleteTrail", "StopLogging", "UpdateTrail", "PutEventSelectors"] } },
      { source = ["aws.config"], detail = { eventName = ["StopConfigurationRecorder", "DeleteConfigurationRecorder", "DeleteDeliveryChannel"] } },
      { source = ["aws.guardduty"], detail = { eventName = ["DeleteDetector", "UpdateDetector"] } },
      { source = ["aws.kms"], detail = { eventName = ["DisableKey", "ScheduleKeyDeletion"] } },
      {
        source = ["aws.ec2"]
        detail = {
          eventName         = ["AuthorizeSecurityGroupIngress"]
          requestParameters = { ipPermissions = { items = { ipRanges = { items = { cidrIp = ["0.0.0.0/0"] } } } } }
        }
      },
      { source = ["aws.ec2"], detail = { requestParameters = { ModifySecurityGroupRulesRequest = { SecurityGroupRule = { SecurityGroupRule = { CidrIpv4 = ["0.0.0.0/0"] } } } } } },
      { source = ["aws.ec2"], detail = { requestParameters = { cidrBlock = ["0.0.0.0/0"], egress = [false], ruleAction = ["allow"] } } },
      { source = ["aws.guardduty"], "detail-type" = ["GuardDuty Finding"], detail = { severity = [{ numeric = [">=", 7] }] } },
    ]
  })
}

resource "aws_iam_role" "security_events_forward" {
  count = local.security_events_enabled ? 1 : 0
  name  = "${var.tags.project}-${var.tags.environment}-security-events-forward"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "security_events_forward" {
  count = local.security_events_enabled ? 1 : 0
  name  = "put-events-us-east-1"
  role  = aws_iam_role.security_events_forward[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:us-east-1:${data.aws_caller_identity.current.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_target" "security_events_forward" {
  for_each  = setsubtract(local.security_event_regions, toset(["us-east-1"]))
  region    = each.key
  rule      = aws_cloudwatch_event_rule.security_events[each.key].name
  target_id = "security-events-us-east-1"
  arn       = "arn:aws:events:us-east-1:${data.aws_caller_identity.current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.security_events_forward[0].arn
}

resource "aws_cloudwatch_event_target" "security_events_slack" {
  count     = local.security_events_enabled ? 1 : 0
  region    = "us-east-1"
  rule      = aws_cloudwatch_event_rule.security_events["us-east-1"].name
  target_id = "security-events-slack"
  arn       = module.notify_slack_alerts_us_east_1[0].slack_topic_arn
}

# EventBridge needs this statement without a Condition block.
resource "aws_sns_topic_policy" "security_events" {
  provider = aws.us-east-1
  count    = local.security_events_enabled ? 1 : 0
  arn      = module.notify_slack_alerts_us_east_1[0].slack_topic_arn

  policy = jsonencode({
    Version = "2008-10-17"
    Id      = "__default_policy_ID"
    Statement = [
      {
        Sid       = "__default_statement_ID"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action = [
          "SNS:GetTopicAttributes", "SNS:SetTopicAttributes", "SNS:AddPermission", "SNS:RemovePermission", "SNS:DeleteTopic",
          "SNS:Subscribe", "SNS:ListSubscriptionsByTopic", "SNS:Publish", "SNS:Receive",
        ]
        Resource  = module.notify_slack_alerts_us_east_1[0].slack_topic_arn
        Condition = { StringEquals = { "AWS:SourceOwner" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = module.notify_slack_alerts_us_east_1[0].slack_topic_arn
      },
    ]
  })
}
