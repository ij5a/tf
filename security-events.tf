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

  event_pattern = jsonencode({
    "$or" = [
      { source = ["aws.signin"], detail = { responseElements = { ConsoleLogin = ["Failure"] } } },
      {
        source = ["aws.signin"]
        detail = {
          userIdentity        = { type = ["IAMUser"] }
          additionalEventData = { MFAUsed = ["No"] }
          responseElements    = { ConsoleLogin = ["Success"] }
        }
      },
      { detail = { userIdentity = { type = ["Root"], invokedBy = [{ exists = false }] }, eventType = [{ "anything-but" = "AwsServiceEvent" }] } },
      { detail = { errorCode = [{ suffix = "UnauthorizedOperation" }, { prefix = "AccessDenied" }], eventCategory = ["Management"] } },
      { source = ["aws.iam"], detail = { eventName = [{ "anything-but" = { prefix = "List" } }], readOnly = [false] } },
      { source = ["aws.cloudtrail"], detail = { eventName = ["CreateTrail", "UpdateTrail", "DeleteTrail", "StartLogging", "StopLogging", "PutEventSelectors"] } },
      { source = ["aws.kms"], detail = { eventName = ["DisableKey", "ScheduleKeyDeletion"] } },
      { source = ["aws.s3"], detail = { eventName = ["PutBucketAcl", "PutBucketPolicy", "PutBucketCors", "PutBucketLifecycle", "PutBucketReplication", "DeleteBucketPolicy", "DeleteBucketCors", "DeleteBucketLifecycle", "DeleteBucketReplication"] } },
      { source = ["aws.config"], detail = { eventName = ["StopConfigurationRecorder", "DeleteDeliveryChannel", "PutDeliveryChannel", "PutConfigurationRecorder"] } },
      {
        source = ["aws.ec2"]
        detail = {
          eventName = [
            "AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress", "RevokeSecurityGroupIngress", "RevokeSecurityGroupEgress",
            "ModifySecurityGroupRules", "CreateSecurityGroup", "DeleteSecurityGroup", "CreateNetworkAcl", "CreateNetworkAclEntry",
            "DeleteNetworkAcl", "DeleteNetworkAclEntry", "ReplaceNetworkAclEntry", "ReplaceNetworkAclAssociation", "CreateCustomerGateway",
            "DeleteCustomerGateway", "AttachInternetGateway", "CreateInternetGateway", "DeleteInternetGateway", "DetachInternetGateway",
            "CreateRoute", "CreateRouteTable", "ReplaceRoute", "ReplaceRouteTableAssociation", "DeleteRouteTable", "DeleteRoute",
            "DisassociateRouteTable", "CreateVpc", "DeleteVpc", "ModifyVpcAttribute", "AcceptVpcPeeringConnection",
            "CreateVpcPeeringConnection", "DeleteVpcPeeringConnection", "RejectVpcPeeringConnection",
          ]
        }
      },
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

  input_transformer {
    input_paths = {
      eventName = "$.detail.eventName"
      who       = "$.detail.userIdentity.arn"
      ip        = "$.detail.sourceIPAddress"
      region    = "$.detail.awsRegion"
      time      = "$.time"
      error     = "$.detail.errorCode"
    }
    input_template = "{\"text\": \"Security event: <eventName> by <who> from <ip> in <region> at <time> <error>\"}"
  }
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
