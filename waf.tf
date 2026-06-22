# Route 53 health checker IPs — published by AWS so dashboard uptime probes aren't blocked by WAF
data "aws_ip_ranges" "route53_healthchecks" {
  regions  = ["global"]
  services = ["route53_healthchecks"]
}

locals {
  # Number of low-priority path-restriction block rules (phpmyadmin, iso8583). The fixed
  # rules below start right after these, so their priorities shift with the count. This is
  # priority-neutral for any env where iso8583 is off (count == enable_phpmyadmin ? 1 : 0).
  waf_protection_rule_count = (var.enable_phpmyadmin ? 1 : 0) + (var.enable_iso8583_playground ? 1 : 0)

  # AWS Managed Rule groups applied in order; priority = waf_protection_rule_count + 3 + index.
  waf_managed_rule_groups = [
    { name = "aws-managed-rules-common", metric_name = "aws-managed-rules-common", managed_group = "AWSManagedRulesCommonRuleSet" },
    { name = "aws-managed-rules-sqli", metric_name = "aws-managed-rules-sqli", managed_group = "AWSManagedRulesSQLiRuleSet" },
    { name = "aws-managed-rules-known-bad-inputs", metric_name = "aws-managed-rules-known-bad-inputs", managed_group = "AWSManagedRulesKnownBadInputsRuleSet" },
  ]
}

resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_waf && var.enable_cloudfront ? 1 : 0
  provider          = aws.us-east-1
  name              = "aws-waf-logs-${var.tags.project}-${var.tags.environment}"
  retention_in_days = var.tags.environment == "prod" ? 90 : 7
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.enable_waf && var.enable_cloudfront ? 1 : 0
  provider                = aws.us-east-1
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]
  resource_arn            = [for acl in aws_wafv2_web_acl.web_acl : acl.arn][0]
}

resource "aws_wafv2_ip_set" "phpmyadmin_whitelist" {
  provider           = aws.us-east-1
  for_each           = var.enable_phpmyadmin ? aws_wafv2_ip_set.ip_whitelist : {}
  name               = "${each.key}-phpmyadmin-whitelist"
  description        = "IPs allowed to access phpMyAdmin"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = [var.twingate_ip]
}

resource "aws_wafv2_ip_set" "iso8583_whitelist" {
  provider           = aws.us-east-1
  for_each           = var.enable_iso8583_playground ? aws_wafv2_ip_set.ip_whitelist : {}
  name               = "${each.key}-iso8583-playground-whitelist"
  description        = "IPs allowed to access iso8583-playground"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = [var.twingate_ip]
}

resource "aws_wafv2_ip_set" "ip_whitelist" {
  provider           = aws.us-east-1
  for_each           = var.enable_waf && var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if service == "central" || service == "pr" || service == "authenticator"]) : toset([])
  name               = "${var.tags.project}-${var.tags.environment}-ip-whitelist"
  description        = "List of IP addresses allowed to access ${var.tags.project}-${var.tags.environment}"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = concat([var.twingate_ip], var.allowed_ip_addresses, var.waf_allowed_ip_addresses)
}

# IPv4 only; Route 53 checkers publish only IPv4 ranges today. CIDR list is snapshotted at plan time —
# re-run plan on a schedule (or subscribe to the AmazonIpSpaceChanged SNS topic) to catch AWS-side updates.
resource "aws_wafv2_ip_set" "route53_healthchecks" {
  provider           = aws.us-east-1
  for_each           = var.enable_waf && var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if service == "central" || service == "pr" || service == "authenticator"]) : toset([])
  name               = "${var.tags.project}-${var.tags.environment}-route53-healthchecks"
  description        = "Route 53 health checker IPs allowed to probe ${local.fargate_probe_paths[0]} and peers"
  scope              = "CLOUDFRONT"
  ip_address_version = "IPV4"
  addresses          = data.aws_ip_ranges.route53_healthchecks.cidr_blocks
}

resource "aws_wafv2_web_acl" "web_acl" {
  provider    = aws.us-east-1
  for_each    = var.enable_waf && var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if service == "central" || service == "pr" || service == "authenticator"]) : toset([])
  name        = "${var.tags.project}-${var.tags.environment}-web-acls"
  description = "Web ACL for ${var.tags.project}-${var.tags.environment}"
  scope       = "CLOUDFRONT"

  # rename destroys-and-recreates the ACL; CBD lets CloudFront swap to the new ARN before the old one goes away
  lifecycle {
    create_before_destroy = true
  }

  default_action {
    block {}
  }

  # Block phpMyAdmin access from non-Twingate IPs.
  dynamic "rule" {
    for_each = var.enable_phpmyadmin ? [1] : []
    content {
      name     = "phpmyadmin-ip-restriction"
      priority = 0

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              positional_constraint = "STARTS_WITH"
              search_string         = "/phpmyadmin/"
              field_to_match {
                uri_path {}
              }
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.phpmyadmin_whitelist[each.key].arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "phpmyadmin-ip-restriction"
        sampled_requests_enabled   = true
      }
    }
  }

  # Block iso8583-playground access from non-Twingate IPs.
  dynamic "rule" {
    for_each = var.enable_iso8583_playground ? [1] : []
    content {
      name     = "iso8583-playground-ip-restriction"
      priority = var.enable_phpmyadmin ? 1 : 0

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              positional_constraint = "STARTS_WITH"
              search_string         = "/iso8583-playground/"
              field_to_match {
                uri_path {}
              }
              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = aws_wafv2_ip_set.iso8583_whitelist[each.key].arn
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "iso8583-playground-ip-restriction"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "general-rate-limit"
    priority = local.waf_protection_rule_count + 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = 300
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "general-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "ip-whitelist"
    priority = local.waf_protection_rule_count

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.ip_whitelist["${var.tags.project}-${var.tags.environment}"].arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "ip-whitelist"
      sampled_requests_enabled   = true
    }
  }

  # allow Route 53 checker IPs only on the specific Fargate probe paths — not the whole site
  rule {
    name     = "route53-healthcheck-allow"
    priority = local.waf_protection_rule_count + 1

    action {
      allow {}
    }

    statement {
      and_statement {
        statement {
          regex_match_statement {
            regex_string = "^(${join("|", local.fargate_probe_paths)})$"
            field_to_match {
              uri_path {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.route53_healthchecks[each.key].arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "route53-healthcheck-allow"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Rules — OWASP/SQLi/Known-Bad-Inputs; block vs count controlled by waf_managed_rules_block_mode.
  dynamic "rule" {
    for_each = { for idx, r in local.waf_managed_rule_groups : r.name => merge(r, { priority = local.waf_protection_rule_count + 3 + idx }) }
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        dynamic "count" {
          for_each = var.waf_managed_rules_block_mode ? [] : [1]
          content {}
        }
        dynamic "none" {
          for_each = var.waf_managed_rules_block_mode ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.managed_group
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric_name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.tags.project}-${var.tags.environment}-web-acls"
    sampled_requests_enabled   = true
  }
}
