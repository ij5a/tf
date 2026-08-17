# must be created in us-east-1 (same region as the CloudFront distribution)
module "cloudfront_alarm" {
  for_each            = var.enable_cloudwatch_alarms && var.enable_cloudfront ? local.cloudfront_alarm_config : {}
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-high-${each.key}-alarm"
  alarm_description   = each.value.description
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = each.value.threshold
  period              = 60
  unit                = each.value.unit
  namespace           = "AWS/CloudFront"
  metric_name         = each.value.metric_name
  statistic           = "Average"
  alarm_actions       = var.enable_slack_notifications ? [module.notify_slack_alerts_us_east_1[0].slack_topic_arn] : []
  ok_actions          = var.enable_slack_notifications ? [module.notify_slack_alerts_us_east_1[0].slack_topic_arn] : []
  treat_missing_data  = "notBreaching"

  dimensions = {
    Region         = "Global"
    DistributionId = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_id
  }

  providers = {
    aws = aws.us-east-1
  }
}

# ecs cpu/memory alarm for all services except spa (spa is static files on S3)
module "high_usage_alarm" {
  for_each = var.enable_cloudwatch_alarms ? {
    for pair in setproduct(["ecs-cpu", "ecs-memory"], var.services) :
    "${pair[0]}-${pair[1]}" => {
      metric  = pair[0]
      service = pair[1]
    } if pair[1] != "spa"
  } : {}

  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-high-${each.key}-alarm"
  alarm_description   = "Service ${each.value.service} is using more than half its ${strcontains(each.key, "cpu") ? "CPU" : "memory"} for 3 minutes. It may slow down if this keeps climbing."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 50
  period              = 60
  unit                = "Percent"
  namespace           = "AWS/ECS"
  metric_name         = strcontains(each.key, "cpu") ? "CPUUtilization" : "MemoryUtilization"
  statistic           = "Average"
  alarm_actions       = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions          = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = "${var.tags.project}-${var.tags.environment}"
    ServiceName = each.value.service
  }
}

# per-service zero-task alarm; prod-only because dev/qa clusters disable Container Insights
# (metric absent) and scale to zero off-hours by design
module "low_usage_alarm" {
  for_each            = var.enable_cloudwatch_alarms && var.enable_ecs && !var.enable_standalone_phpmyadmin && local.is_prod && local.container_insights != "disabled" ? toset(local.ecs_services_no_spa) : toset([])
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-low-ecs-taskcount-${each.key}-alarm"
  alarm_description   = "Service ${each.key} has no copies running for 3 minutes. This part of the app is down."
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 0
  period              = 60
  unit                = null
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  alarm_actions       = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions          = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = "${var.tags.project}-${var.tags.environment}"
    ServiceName = each.key
  }
}

locals {
  # per-alarm config for cloudfront_alarm; keys must match the for_each set exactly
  cloudfront_alarm_config = {
    "cloudfront-total4xxerrorrate" = {
      metric_name = "4xxErrorRate", threshold = 70, unit = "Percent"
      description = "Website: most requests are being rejected as bad (70%+ for 3 minutes). Users likely see errors."
    }
    "cloudfront-total5xxerrorrate" = {
      metric_name = "5xxErrorRate", threshold = 70, unit = "Percent"
      description = "Website: most requests are failing on our side (70%+ for 3 minutes). The site is likely down for users."
    }
  }

  # single source of truth for Fargate uptime paths: probed by Route 53, allowed through WAF, shown in the overview dashboard
  fargate_probe_paths = ["/api/v1/version", "/call-center/log-in"]
  # Probe one domain only: the client-facing additional domain when set, else the legacy primary.
  fargate_probe_domain = local.enable_additional_domain ? var.additional_domain_name : var.domain_name

  # gated on enable_cloudfront: these probe through CloudFront, so when it's off (idle) the checks would only false-alarm.
  fargate_health_check_urls = var.enable_cloudfront && var.domain_name != "" && var.domain_name != "example.com" ? [
    for path in local.fargate_probe_paths : "https://${local.fargate_probe_domain}${path}"
  ] : []
  # Full set of URLs to create as Route 53 health checks: Fargate standard paths + any legacy/extra URLs from tfvars
  route_53_health_check_urls = distinct(concat(local.fargate_health_check_urls, var.route_53_health_check_urls))

  # PCI: hide card numbers in the Aurora logs that carry SQL statement text. AWS needs both an Audit and a Deidentify statement.
  # CardShapedNumber catches bare digit runs the managed identifier misses; keep Visa longest-first or a 19-digit card matches only its first 16.
  aurora_statement_log_masking_policy = jsonencode({
    Name    = "mask-card-numbers"
    Version = "2021-06-01"
    Configuration = {
      CustomDataIdentifier = [
        {
          Name  = "CardShapedNumber"
          Regex = "4[0-9]{18}|4[0-9]{15}|5[1-5][0-9]{14}|2[2-7][0-9]{14}|3[47][0-9]{13}|6011[0-9]{12}|64[4-9][0-9]{13}|65[0-9]{14}|30[0-5][0-9]{11}|3[689][0-9]{12}|35[2-8][0-9]{13}|62[0-9]{14,17}"
        }
      ]
    }
    Statement = [
      {
        Sid            = "Audit"
        DataIdentifier = ["arn:aws:dataprotection::aws:data-identifier/CreditCardNumber", "CardShapedNumber"]
        Operation      = { Audit = { FindingsDestination = {} } }
      },
      {
        Sid            = "Redact"
        DataIdentifier = ["arn:aws:dataprotection::aws:data-identifier/CreditCardNumber", "CardShapedNumber"]
        Operation      = { Deidentify = { MaskConfig = {} } }
      }
    ]
  })
}

# Route 53 metrics are always in us-east-1. Alarm names carry the check's fqdn:
# path-only names collided when two domains shared a path, and the colliding alarms overwrote each other on every apply.
module "route53_health_check_alarm" {
  for_each = length(local.route_53_health_check_urls) > 0 ? aws_route53_health_check.url : {}

  source  = var.module_sources.cloudwatch.source
  version = var.module_sources.cloudwatch.version

  alarm_name          = "${var.tags.project}-${var.tags.environment}-route53-unhealthy-${replace(each.value.fqdn, ".", "-")}-${replace(trim(each.value.resource_path, "/"), "/", "-")}-alarm"
  alarm_description   = "${each.value.fqdn}${each.value.resource_path} is not answering from the internet. Users cannot reach this page or API."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  period              = 60
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  treat_missing_data  = "breaching"

  dimensions = {
    HealthCheckId = each.value.id
  }

  alarm_actions = var.enable_slack_notifications ? [module.notify_slack_alerts_us_east_1[0].slack_topic_arn] : []
  ok_actions    = var.enable_slack_notifications ? [module.notify_slack_alerts_us_east_1[0].slack_topic_arn] : []

  providers = {
    aws = aws.us-east-1
  }
}

# Critical: client and Acme cannot sync data when a Data Replication Failure/Error line appears in central logs.
resource "aws_cloudwatch_log_metric_filter" "data_replication_failure" {
  count          = var.enable_cloudwatch_alarms && var.enable_cloudwatch_logging && contains(var.services, "central") ? 1 : 0
  name           = "${var.tags.project}-${var.tags.environment}-data-replication-failure"
  log_group_name = "${var.tags.project}-${var.tags.environment}-central"
  pattern        = "%[Dd]ata\\s[Rr]eplication\\s[Ff]ailure|[Dd]ata\\s[Rr]eplication\\s[Ee]rror%"

  metric_transformation {
    name          = "DataReplicationFailures"
    namespace     = "acme/${var.tags.project}-${var.tags.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }

  # log_group_name is a plain string; the upstream ecs/container-definition module owns the real CW log group.
  depends_on = [module.ecs_service]
}

module "data_replication_failure_alarm" {
  count               = var.enable_cloudwatch_alarms && var.enable_cloudwatch_logging && contains(var.services, "central") ? 1 : 0
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-data-replication-failure-alarm"
  alarm_description   = "Data replication error: Central -> PR -> the upstream API."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  period              = 60
  namespace           = "acme/${var.tags.project}-${var.tags.environment}"
  metric_name         = "DataReplicationFailures"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions    = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []

  depends_on = [aws_cloudwatch_log_metric_filter.data_replication_failure]
}

# Alarms when the PR service can't reach the upstream API: refreshExternalInfo calls time out (10s axios timeout).
resource "aws_cloudwatch_log_metric_filter" "pr_upstream_api_timeout" {
  count          = var.enable_cloudwatch_alarms && var.enable_cloudwatch_logging && contains(var.services, "pr") ? 1 : 0
  name           = "${var.tags.project}-${var.tags.environment}-pr-upstream-api-timeout"
  log_group_name = "${var.tags.project}-${var.tags.environment}-pr"
  pattern        = "{ $.msg = \"refreshExternalInfo error\" }"

  metric_transformation {
    name          = "PrUpstreamApiConnectionTimeouts"
    namespace     = "acme/${var.tags.project}-${var.tags.environment}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }

  depends_on = [module.ecs_service]
}

module "pr_upstream_api_timeout_alarm" {
  count               = var.enable_cloudwatch_alarms && var.enable_cloudwatch_logging && contains(var.services, "pr") ? 1 : 0
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-pr-upstream-api-timeout-alarm"
  alarm_description   = "The PR service cannot reach the upstream API. Calls keep timing out after 10 seconds, so PR is not getting updated external-processor info."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 10
  period              = 60
  namespace           = "acme/${var.tags.project}-${var.tags.environment}"
  metric_name         = "PrUpstreamApiConnectionTimeouts"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions    = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []

  depends_on = [aws_cloudwatch_log_metric_filter.pr_upstream_api_timeout]
}

resource "aws_cloudwatch_dashboard" "route53_health_checks" {
  count    = length(var.cloudwatch_route53_dashboard) > 0 ? 1 : 0
  provider = aws.us-east-1

  dashboard_name = "acme-uptime-percentage"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 3
        properties = {
          metrics = [
            for label, id in var.cloudwatch_route53_dashboard : [
              "AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", id, { label = label }
            ]
          ]
          view   = "singleValue"
          region = "us-east-1"
          stat   = "Average"
          period = 2592000
          title  = "acme-uptime-percentage"
          yAxis  = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 3
        width  = 24
        height = 5
        properties = {
          metrics = [
            for label, id in var.cloudwatch_route53_dashboard : [
              "AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", id, { label = label }
            ]
          ]
          view   = "timeSeries"
          region = "us-east-1"
          stat   = "Average"
          period = 300
          title  = "acme-uptime-percentage"
          yAxis  = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 24
        height = 5
        properties = {
          metrics = [
            for label, id in var.cloudwatch_route53_dashboard : [
              "AWS/Route53", "TimeToFirstByte", "HealthCheckId", id, "Region", "sa-east-1", { label = label }
            ]
          ]
          view    = "timeSeries"
          stacked = true
          region  = "us-east-1"
          stat    = "Average"
          period  = 300
          title   = "acme-ping-latency"
          yAxis   = { left = { min = 0, max = 100 } }
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 24
        height = 4
        properties = {
          metrics = [
            for label, id in var.cloudwatch_route53_dashboard : [
              "AWS/Route53", "TimeToFirstByte", "HealthCheckId", id, "Region", "sa-east-1", { label = label }
            ]
          ]
          view   = "singleValue"
          region = "us-east-1"
          stat   = "Average"
          period = 2592000
          title  = "acme-ping-latency"
          yAxis  = { left = { min = 0, max = 100 } }
        }
      }
    ]
  })
}

# ALB 5xx alarms — ALB-generated (502/503/504) and app-returned 5xx (dashboard-only before this). qa/preprod/prod only — dev is noise.
module "alb_5xx_alarm" {
  for_each = var.enable_cloudwatch_alarms && var.enable_alb && local.alb_arn_suffix != null && contains(["qa", "preprod", "prod"], var.tags.environment) ? {
    "elb-5xx" = {
      metric_name = "HTTPCode_ELB_5XX_Count", threshold = 5, datapoints_to_alarm = 3
      description = "Requests could not reach the app, so users got errors back (5+ every minute for 3 minutes straight)."
    }
    "target-5xx" = {
      metric_name = "HTTPCode_Target_5XX_Count", threshold = var.alb_target_5xx_alarm_threshold, datapoints_to_alarm = 2
      description = "The app returned server errors to users (${var.alb_target_5xx_alarm_threshold}+ per minute in 2 of the last 3 minutes). The app is up but failing on some requests."
    }
  } : {}

  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-alb-${each.key}-alarm"
  alarm_description   = each.value.description
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = each.value.datapoints_to_alarm
  threshold           = each.value.threshold
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = each.value.metric_name
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions          = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []

  dimensions = {
    LoadBalancer = local.alb_arn_suffix
  }
}

# ALB unhealthy-host alarm — per target group (apigw-central / apigw-pr / de). qa/preprod/prod only — dev is noise.
module "alb_unhealthy_host_alarm" {
  for_each = var.enable_cloudwatch_alarms && var.enable_alb && contains(["qa", "preprod", "prod"], var.tags.environment) ? {
    for k, suffix in {
      "apigw-central" = local.alb_apigw_central_tg
      "apigw-pr"      = local.alb_apigw_pr_tg
      "de"            = local.alb_de_tg
    } : k => suffix if suffix != null
  } : {}

  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-alb-${each.key}-unhealthy-host-alarm"
  alarm_description   = "At least one copy of ${each.key} stopped responding for 3 minutes. Traffic goes to the copies that still work."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  period              = 60
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions          = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []

  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = each.value
  }
}

# audit carries the statement text; slowquery is covered up front so it is masked from day one if slow query logging is ever turned on.
# Both groups are only created in prod, so the masking shares that gate. error is left out — no statement text in it.
resource "aws_cloudwatch_log_data_protection_policy" "aurora_statement_logs" {
  for_each = local.is_prod && var.enable_aurora_statement_log_masking ? {
    for pair in setproduct(local.aurora_cluster_keys, ["audit", "slowquery"]) :
    "${pair[0]}-${pair[1]}" => {
      cluster  = pair[0]
      log_type = pair[1]
    }
  } : {}

  log_group_name  = module.aurora_mysql_v2[each.value.cluster].db_cluster_cloudwatch_log_groups[each.value.log_type].name
  policy_document = local.aurora_statement_log_masking_policy
}

# The legacy central cluster is not tofu-owned, so its log groups are named by hand here. Drop this at cutover.
resource "aws_cloudwatch_log_data_protection_policy" "aurora_statement_logs_legacy" {
  for_each        = local.is_prod && var.enable_aurora_statement_log_masking && var.enable_legacy_aurora_audit_masking ? toset(["audit", "slowquery"]) : toset([])
  log_group_name  = "/aws/rds/cluster/${var.tags.project}-${var.tags.environment}-central/${each.key}"
  policy_document = local.aurora_statement_log_masking_policy

  lifecycle {
    precondition {
      condition     = var.aurora_cluster_identifier_random_suffix
      error_message = "enable_legacy_aurora_audit_masking needs aurora_cluster_identifier_random_suffix = true. Without the suffix the tofu-managed cluster owns this same log group name, so both resources would manage one policy."
    }
  }
}
