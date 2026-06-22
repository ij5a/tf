# Two-layer design: hero status row for non-tech viewers, per-service detail below for ops drill-in.
# Widgets are concat()ed from per-section locals so disabled features don't reference missing outputs.
locals {
  dashboard_key       = "${var.tags.project}-${var.tags.environment}"
  cluster_name        = "${var.tags.project}-${var.tags.environment}"
  ecs_services_no_spa = [for s in var.services : s if s != "spa"]
  cache_services      = [for s in var.services : s if s == "central" || s == "de"]

  log_group_names = [
    for service in local.ecs_services_no_spa :
    "${var.tags.project}-${var.tags.environment}-${service}"
  ]
  log_query_sources = join(" | ", [for lg in local.log_group_names : "SOURCE '${lg}'"])

  aurora_cluster_id    = try(module.aurora_mysql_v2["central"].cluster_id, null)
  de_mysql_db_id       = try(module.de_mysql_rds[0].db_instance_identifier, null)
  cf_distribution_id   = try(module.cdn[local.dashboard_key].cloudfront_distribution_id, null)
  alb_arn_suffix       = try(module.alb[local.dashboard_key].arn_suffix, null)
  alb_apigw_central_tg = try(module.alb[local.dashboard_key].target_groups["apigw-central"].arn_suffix, null)
  alb_apigw_pr_tg      = try(aws_lb_target_group.this["apigw-pr"].arn_suffix, null)
  alb_de_tg            = try(aws_lb_target_group.this["de"].arn_suffix, null)
  nlb_arn_suffix       = try(module.nlb[local.dashboard_key].arn_suffix, null)

  alarm_arns = compact(concat(
    [for a in module.cloudfront_alarm : try(a.cloudwatch_metric_alarm_arn, "")],
    [for a in module.high_usage_alarm : try(a.cloudwatch_metric_alarm_arn, "")],
    [for a in module.low_usage_alarm : try(a.cloudwatch_metric_alarm_arn, "")],
    [for a in module.route53_health_check_alarm : try(a.cloudwatch_metric_alarm_arn, "")],
    [for a in module.data_replication_failure_alarm : try(a.cloudwatch_metric_alarm_arn, "")]
  ))

  # path → display label for the hero uptime gauges; falls back to the path itself for unmapped paths
  health_check_label_map = {
    "/api/v1/version"     = "API"
    "/call-center/log-in" = "Login"
  }

  hero_intro_text = <<-EOT
    ## ${local.dashboard_key} — overview
    Health snapshot for **${var.tags.project} ${var.tags.environment}**. The tiles below answer "is the site healthy right now?". Sections further down show per-service time-series for drill-in.
    > ⚠️ Use the **time-range picker** at the top-right (1h / 3h / 12h / 1d / ...) to change the window — every tile follows it. The **auto-refresh** dropdown next to it defaults to **off**; toggle it on for a live status board.
  EOT

  hero_widgets = concat(
    [{
      type   = "text"
      width  = 24
      height = 2
      properties = {
        markdown = local.hero_intro_text
      }
    }],
    [for url in local.fargate_health_check_urls : {
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title  = "Uptime — ${lookup(local.health_check_label_map, regex("https?://[^/]+(/.+)", url)[0], regex("https?://[^/]+(/.+)", url)[0])}"
        view   = "gauge"
        region = "us-east-1"
        metrics = [
          ["AWS/Route53", "HealthCheckPercentageHealthy", "HealthCheckId", aws_route53_health_check.url[url].id, { label = "% healthy" }]
        ]
        stat   = "Average"
        period = 3600
        yAxis  = { left = { min = 0, max = 100 } }
        annotations = {
          horizontal = [
            { value = 0, color = "#d62728" },
            { value = 99, color = "#ffbb00" },
            { value = 99.9, color = "#2ca02c" }
          ]
        }
      }
    }],
    var.enable_cloudfront && local.cf_distribution_id != null ? [{
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title  = "Requests OK"
        view   = "gauge"
        region = "us-east-1"
        metrics = [
          [{ expression = "100 - m1", label = "% of requests without errors", id = "e1" }],
          ["AWS/CloudFront", "TotalErrorRate", "DistributionId", local.cf_distribution_id, "Region", "Global", { id = "m1", visible = false, region = "us-east-1" }]
        ]
        stat   = "Average"
        period = 3600
        yAxis  = { left = { min = 0, max = 100 } }
        annotations = {
          horizontal = [
            { value = 0, color = "#d62728" },
            { value = 99, color = "#ffbb00" },
            { value = 99.5, color = "#2ca02c" }
          ]
        }
      }
    }] : [],
    var.enable_alb && local.alb_arn_suffix != null ? [{
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title  = "Response time (p95)"
        view   = "gauge"
        region = var.region
        metrics = [
          [{ expression = "m1 * 1000", label = "p95 (ms)", id = "e1" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { id = "m1", visible = false, stat = "p95" }]
        ]
        period = 3600
        yAxis  = { left = { min = 0, max = 2000 } }
        annotations = {
          horizontal = [
            { value = 0, color = "#2ca02c" },
            { value = 500, color = "#ffbb00" },
            { value = 1000, color = "#d62728" }
          ]
        }
      }
    }] : [],
    var.enable_alb && local.alb_arn_suffix != null ? [{
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title     = "5xx errors"
        view      = "singleValue"
        region    = var.region
        sparkline = true
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_arn_suffix]
        ]
        stat   = "Sum"
        period = 3600
      }
    }] : [],
    var.enable_ecs ? [{
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title     = "ECS task deficit"
        view      = "singleValue"
        region    = var.region
        sparkline = true
        metrics = [
          [{ expression = "FILL(SUM(d1), REPEAT) - FILL(SUM(r1), REPEAT)", label = "Desired - Running", id = "e1" }],
          [{ expression = "SEARCH('{ECS/ContainerInsights,ClusterName,ServiceName} ClusterName=\"${local.cluster_name}\" MetricName=\"DesiredTaskCount\"', 'Maximum', 60)", id = "d1", visible = false }],
          [{ expression = "SEARCH('{ECS/ContainerInsights,ClusterName,ServiceName} ClusterName=\"${local.cluster_name}\" MetricName=\"RunningTaskCount\"', 'Maximum', 60)", id = "r1", visible = false }]
        ]
        period = 60
        stat   = "Maximum"
      }
    }] : [],
    var.enable_serverless_aurora && local.aurora_cluster_id != null ? [{
      type   = "metric"
      width  = 6
      height = 4
      properties = {
        title  = "DB ACU utilization"
        view   = "gauge"
        region = var.region
        metrics = [
          ["AWS/RDS", "ACUUtilization", "DBClusterIdentifier", local.aurora_cluster_id]
        ]
        stat   = "Average"
        period = 300
        yAxis  = { left = { min = 0, max = 100 } }
        annotations = {
          horizontal = [
            { value = 0, color = "#2ca02c" },
            { value = 60, color = "#ffbb00" },
            { value = 85, color = "#d62728" }
          ]
        }
      }
    }] : [],
    var.enable_ecs && var.enable_cloudwatch_logging && length(local.log_group_names) > 0 ? [{
      type   = "log"
      width  = 6
      height = 4
      properties = {
        title  = "App errors"
        view   = "table"
        region = var.region
        query  = "${local.log_query_sources} | fields @timestamp, level\n| filter level >= 50\n| stats count() as errors"
      }
    }] : [],
    var.enable_ecs && var.enable_cloudwatch_logging && contains(var.services, "central") ? [{
      type   = "log"
      width  = 6
      height = 4
      properties = {
        title  = "Data replication failures (central)"
        view   = "table"
        region = var.region
        query  = "SOURCE '${var.tags.project}-${var.tags.environment}-central' | fields @timestamp\n| filter @message like /Data Replication Failure/\n| stats count() as failures"
      }
    }] : [],
    var.enable_cloudwatch_alarms && length(local.alarm_arns) > 0 ? [{
      type   = "alarm"
      width  = 24
      height = 3
      properties = {
        title  = "Active alarms (this environment)"
        alarms = local.alarm_arns
      }
    }] : []
  )

  traffic_widgets = concat(
    var.enable_cloudfront || var.enable_alb || var.enable_nlb ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Traffic\nEdge (CloudFront), application load balancer, and the EG NLB. Look here for traffic shape, error rates, and target health."
      }
    }] : [],
    var.enable_cloudfront && local.cf_distribution_id != null ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "CloudFront — requests & bandwidth"
        region = "us-east-1"
        view   = "timeSeries"
        metrics = [
          ["AWS/CloudFront", "Requests", "DistributionId", local.cf_distribution_id, "Region", "Global", { label = "Requests" }],
          ["AWS/CloudFront", "BytesDownloaded", "DistributionId", local.cf_distribution_id, "Region", "Global", { label = "Bytes downloaded", yAxis = "right" }]
        ]
        stat   = "Sum"
        period = 300
      }
    }] : [],
    var.enable_cloudfront && local.cf_distribution_id != null ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "CloudFront — error rates (%)"
        region = "us-east-1"
        view   = "timeSeries"
        metrics = [
          ["AWS/CloudFront", "4xxErrorRate", "DistributionId", local.cf_distribution_id, "Region", "Global", { label = "4xx %" }],
          ["AWS/CloudFront", "5xxErrorRate", "DistributionId", local.cf_distribution_id, "Region", "Global", { label = "5xx %" }],
          ["AWS/CloudFront", "TotalErrorRate", "DistributionId", local.cf_distribution_id, "Region", "Global", { label = "Total %" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_alb && local.alb_arn_suffix != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "ALB — requests & response time"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { label = "Requests", stat = "Sum" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { label = "Avg (s)", stat = "Average", yAxis = "right" }],
          ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { label = "p95 (s)", stat = "p95", yAxis = "right" }]
        ]
        period = 300
      }
    }] : [],
    var.enable_alb && local.alb_arn_suffix != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title   = "ALB — HTTP target codes"
        region  = var.region
        view    = "timeSeries"
        stacked = true
        metrics = [
          ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", local.alb_arn_suffix, { label = "2xx" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.alb_arn_suffix, { label = "4xx" }],
          ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { label = "5xx" }]
        ]
        stat   = "Sum"
        period = 300
      }
    }] : [],
    var.enable_alb && local.alb_arn_suffix != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "ALB — healthy / unhealthy hosts (per TG)"
        region = var.region
        view   = "timeSeries"
        metrics = concat(
          local.alb_apigw_central_tg != null ? [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_apigw_central_tg, { label = "apigw-central healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_apigw_central_tg, { label = "apigw-central unhealthy" }]
          ] : [],
          local.alb_apigw_pr_tg != null ? [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_apigw_pr_tg, { label = "apigw-pr healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_apigw_pr_tg, { label = "apigw-pr unhealthy" }]
          ] : [],
          local.alb_de_tg != null ? [
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_de_tg, { label = "de healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.alb_de_tg, { label = "de unhealthy" }]
          ] : []
        )
        stat   = "Average"
        period = 60
      }
    }] : [],
    var.enable_nlb && local.nlb_arn_suffix != null ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "NLB (eg) — flows & active connections"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/NetworkELB", "ActiveFlowCount", "LoadBalancer", local.nlb_arn_suffix, { label = "Active flows" }],
          ["AWS/NetworkELB", "NewFlowCount", "LoadBalancer", local.nlb_arn_suffix, { label = "New flows", stat = "Sum", yAxis = "right" }]
        ]
        stat   = "Average"
        period = 60
      }
    }] : [],
    var.enable_nlb && local.nlb_arn_suffix != null ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "NLB (eg) — bytes processed"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/NetworkELB", "ProcessedBytes", "LoadBalancer", local.nlb_arn_suffix, { label = "Processed bytes" }]
        ]
        stat   = "Sum"
        period = 60
      }
    }] : []
  )

  compute_widgets = concat(
    var.enable_ecs ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Compute (ECS)\nPer-service CPU and memory utilization, plus running vs desired task counts. Helps spot a service that's failing to scale, hitting CPU caps, or not running the expected number of tasks."
      }
    }] : [],
    var.enable_ecs ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "ECS — CPU utilization (%)"
        region = var.region
        view   = "timeSeries"
        metrics = [
          for service in local.ecs_services_no_spa : [
            "AWS/ECS", "CPUUtilization",
            "ClusterName", local.cluster_name,
            "ServiceName", service,
            { label = service }
          ]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_ecs ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "ECS — memory utilization (%)"
        region = var.region
        view   = "timeSeries"
        metrics = [
          for service in local.ecs_services_no_spa : [
            "AWS/ECS", "MemoryUtilization",
            "ClusterName", local.cluster_name,
            "ServiceName", service,
            { label = service }
          ]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_ecs ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "ECS — running vs desired tasks"
        region = var.region
        view   = "timeSeries"
        metrics = concat(
          [
            for service in local.ecs_services_no_spa : [
              "ECS/ContainerInsights", "RunningTaskCount",
              "ClusterName", local.cluster_name,
              "ServiceName", service,
              { label = "${service} running" }
            ]
          ],
          [
            for service in local.ecs_services_no_spa : [
              "ECS/ContainerInsights", "DesiredTaskCount",
              "ClusterName", local.cluster_name,
              "ServiceName", service,
              { label = "${service} desired", yAxis = "right" }
            ]
          ]
        )
        stat   = "Maximum"
        period = 60
      }
    }] : []
  )

  database_widgets = concat(
    var.enable_serverless_aurora && local.aurora_cluster_id != null ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Database — Aurora Serverless v2 (central)\nCapacity (ACU), connections, CPU, and freeable memory for the central Aurora cluster."
      }
    }] : [],
    var.enable_serverless_aurora && local.aurora_cluster_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "Aurora — capacity"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", local.aurora_cluster_id, { label = "ACU capacity" }],
          ["AWS/RDS", "ACUUtilization", "DBClusterIdentifier", local.aurora_cluster_id, { label = "ACU utilization %", yAxis = "right" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_serverless_aurora && local.aurora_cluster_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "Aurora — connections & CPU"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "DatabaseConnections", "DBClusterIdentifier", local.aurora_cluster_id, { label = "Connections" }],
          ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", local.aurora_cluster_id, { label = "CPU %", yAxis = "right" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_serverless_aurora && local.aurora_cluster_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "Aurora — freeable memory"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "FreeableMemory", "DBClusterIdentifier", local.aurora_cluster_id, { label = "Freeable memory (bytes)" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_de_mysql_rds && contains(var.services, "de") && local.de_mysql_db_id != null ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Database — DE MySQL RDS (standalone instance)\nCPU, connections, and freeable memory for the standalone MySQL instance backing the `de` service."
      }
    }] : [],
    var.enable_de_mysql_rds && contains(var.services, "de") && local.de_mysql_db_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "DE MySQL — CPU & connections"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.de_mysql_db_id, { label = "CPU %" }],
          ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.de_mysql_db_id, { label = "Connections", yAxis = "right" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_de_mysql_rds && contains(var.services, "de") && local.de_mysql_db_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "DE MySQL — freeable memory"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.de_mysql_db_id, { label = "Freeable memory (bytes)" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_de_mysql_rds && contains(var.services, "de") && local.de_mysql_db_id != null ? [{
      type   = "metric"
      width  = 8
      height = 6
      properties = {
        title  = "DE MySQL — read / write IOPS"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", local.de_mysql_db_id, { label = "Read IOPS" }],
          ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", local.de_mysql_db_id, { label = "Write IOPS" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : []
  )

  cache_widgets = concat(
    var.enable_elasticache && !var.use_legacy_redis && length(local.cache_services) > 0 ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Cache (ElastiCache Valkey)\nCPU, memory, network, and hit/miss ratio per replication group. Hit ratio is the easiest non-tech signal of cache health."
      }
    }] : [],
    flatten([
      for svc in(var.enable_elasticache && !var.use_legacy_redis ? local.cache_services : []) : [
        {
          type   = "metric"
          width  = 8
          height = 6
          properties = {
            title  = "Valkey ${svc} — CPU & memory (%)"
            region = var.region
            view   = "timeSeries"
            metrics = [
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"CPUUtilization\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "CPU %" }],
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"EngineCPUUtilization\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "Engine CPU %" }],
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"DatabaseMemoryUsagePercentage\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "Memory %" }]
            ]
          }
        },
        {
          type   = "metric"
          width  = 8
          height = 6
          properties = {
            title  = "Valkey ${svc} — network & connections"
            region = var.region
            view   = "timeSeries"
            metrics = [
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"NetworkBytesIn\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "Bytes in" }],
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"NetworkBytesOut\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "Bytes out" }],
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"CurrConnections\" \"${local.cluster_name}-${svc}\"', 'Average', 300)", label = "Connections", yAxis = "right" }]
            ]
          }
        },
        {
          type   = "metric"
          width  = 8
          height = 6
          properties = {
            title  = "Valkey ${svc} — cache hits / misses"
            region = var.region
            view   = "timeSeries"
            metrics = [
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"CacheHits\" \"${local.cluster_name}-${svc}\"', 'Sum', 300)", label = "Hits" }],
              [{ expression = "SEARCH('{AWS/ElastiCache,CacheClusterId} MetricName=\"CacheMisses\" \"${local.cluster_name}-${svc}\"', 'Sum', 300)", label = "Misses" }]
            ]
          }
        }
      ]
    ])
  )

  security_widgets = concat(
    var.enable_waf || var.enable_guardduty ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Security\nWAF allow/block volume and GuardDuty findings (proxy via the guardduty-slack Lambda invocation count). Click the GuardDuty link below for the actual findings list."
      }
    }] : [],
    var.enable_waf && var.enable_cloudfront ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title   = "WAF — allowed vs blocked"
        region  = "us-east-1"
        view    = "timeSeries"
        stacked = true
        metrics = [
          ["AWS/WAFV2", "AllowedRequests", "WebACL", "${local.dashboard_key}-web-acls", "Region", "Global", "Rule", "ALL", { label = "Allowed" }],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "${local.dashboard_key}-web-acls", "Region", "Global", "Rule", "ALL", { label = "Blocked" }]
        ]
        stat   = "Sum"
        period = 300
      }
    }] : [],
    var.enable_guardduty ? [{
      type   = "text"
      width  = 6
      height = 6
      properties = {
        markdown = "### GuardDuty\n[Open the GuardDuty console](https://console.aws.amazon.com/guardduty/home?region=${var.region}#/findings) to inspect findings.\n\nThe widget on the right shows the volume of `guardduty-slack` Lambda invocations as a proxy signal for finding activity."
      }
    }] : [],
    var.enable_guardduty ? [{
      type   = "metric"
      width  = 6
      height = 6
      properties = {
        title  = "guardduty-slack — invocations & errors"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", "${local.dashboard_key}-guardduty-slack", { label = "Invocations" }],
          ["AWS/Lambda", "Errors", "FunctionName", "${local.dashboard_key}-guardduty-slack", { label = "Errors", yAxis = "right" }]
        ]
        stat   = "Sum"
        period = 300
      }
    }] : []
  )

  background_widgets = concat(
    var.enable_dms || var.enable_lambda ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Background workloads\n${var.enable_dms ? "DMS replication latency and throughput, plus " : ""}Lambda invocations / errors / duration for the Go-based helper functions."
      }
    }] : [],
    var.enable_dms ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "DMS — CDC replication latency (s)"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/DMS", "CDCLatencySource", { label = "Source latency" }],
          ["AWS/DMS", "CDCLatencyTarget", { label = "Target latency" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_dms ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "DMS — throughput"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/DMS", "NetworkReceiveThroughput", { label = "Network receive (bytes/s)" }],
          ["AWS/DMS", "FullLoadThroughputRowsTarget", { label = "Full load rows/s", yAxis = "right" }]
        ]
        stat   = "Average"
        period = 300
      }
    }] : [],
    var.enable_lambda && var.enable_codepipeline && var.enable_cloudfront ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "Lambda — invocations & errors"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", "${local.dashboard_key}-cf-invalidator", { label = "cf-invalidator invocations" }],
          ["AWS/Lambda", "Errors", "FunctionName", "${local.dashboard_key}-cf-invalidator", { label = "cf-invalidator errors", yAxis = "right" }]
        ]
        stat   = "Sum"
        period = 300
      }
    }] : [],
    var.enable_lambda && var.enable_codepipeline && var.enable_cloudfront ? [{
      type   = "metric"
      width  = 12
      height = 6
      properties = {
        title  = "Lambda — duration (avg / p95, ms)"
        region = var.region
        view   = "timeSeries"
        metrics = [
          ["AWS/Lambda", "Duration", "FunctionName", "${local.dashboard_key}-cf-invalidator", { label = "cf-invalidator avg", stat = "Average" }],
          ["AWS/Lambda", "Duration", "FunctionName", "${local.dashboard_key}-cf-invalidator", { label = "cf-invalidator p95", stat = "p95" }]
        ]
        period = 300
      }
    }] : []
  )

  logs_enabled = var.enable_ecs && var.enable_cloudwatch_logging && length(local.log_group_names) > 0

  logs_widgets = concat(
    local.logs_enabled ? [{
      type   = "text"
      width  = 24
      height = 1
      properties = {
        markdown = "## Application errors\nCounts and details of error/fatal log entries from every backend service. Time range follows the picker at the top-right. Auto-refresh re-runs each query, so leave it off unless actively investigating — Logs Insights bills per GB scanned."
      }
    }] : [],
    local.logs_enabled ? [{
      type   = "log"
      width  = 24
      height = 6
      properties = {
        title   = "Error rate by service"
        region  = var.region
        view    = "timeSeries"
        stacked = true
        query   = "${local.log_query_sources} | fields @timestamp, name, level\n| filter level >= 50\n| stats count() as errors by bin(5m), name"
      }
    }] : [],
    local.logs_enabled ? [{
      type   = "log"
      width  = 24
      height = 8
      properties = {
        title  = "Recent errors"
        region = var.region
        view   = "table"
        query  = "${local.log_query_sources} | fields @timestamp, name, msg, err.code, err.message, url, extproc, processor, executionLogic\n| filter level >= 50\n| sort @timestamp desc\n| limit 100"
      }
    }] : [],
    local.logs_enabled ? [{
      type   = "log"
      width  = 12
      height = 6
      properties = {
        title  = "Top error messages"
        region = var.region
        view   = "table"
        query  = "${local.log_query_sources} | fields msg\n| filter level >= 50\n| stats count() as errors by msg, err.code\n| sort errors desc\n| limit 20"
      }
    }] : [],
    local.logs_enabled ? [{
      type   = "log"
      width  = 12
      height = 6
      properties = {
        title  = "Error codes breakdown"
        region = var.region
        view   = "pie"
        query  = "${local.log_query_sources} | fields err.code\n| filter level >= 50 and ispresent(err.code)\n| stats count() as errors by err.code"
      }
    }] : [],
    local.logs_enabled && contains(var.services, "central") ? [{
      type   = "log"
      width  = 24
      height = 6
      properties = {
        title  = "Recent data replication failures (central)"
        region = var.region
        view   = "table"
        query  = "SOURCE '${var.tags.project}-${var.tags.environment}-central' | fields @timestamp, msg, err.code, err.message, extproc\n| filter @message like /Data Replication Failure/\n| sort @timestamp desc\n| limit 50"
      }
    }] : []
  )
}

locals {
  dashboard_widgets = concat(
    local.hero_widgets,
    local.traffic_widgets,
    local.compute_widgets,
    local.database_widgets,
    local.cache_widgets,
    local.security_widgets,
    local.background_widgets,
    local.logs_widgets
  )
}

resource "aws_cloudwatch_dashboard" "main" {
  count = var.enable_cloudwatch_dashboard ? 1 : 0

  dashboard_name = "${local.dashboard_key}-overview"
  dashboard_body = jsonencode({
    periodOverride = "auto"
    widgets        = local.dashboard_widgets
  })
}

output "dashboard_url" {
  description = "Console URL for the per-environment CloudWatch overview dashboard"
  value       = var.enable_cloudwatch_dashboard ? "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.main[0].dashboard_name}" : null
}
