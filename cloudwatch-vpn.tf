locals {
  # Legacy single-tunnel VPNs — only the "active" tunnel per VPN is in service.
  # The second AWS-default tunnel is DOWN by design (customer-gateway side never
  # terminated it). DO NOT add alarms for 203.0.113.10 / 203.0.113.11.
  vpn_legacy_active_tunnels = var.enable_vpn_alarms ? {
    site-a = { vpn_id = "vpn-0aaaaaaaaaaaaaaa1", tunnel_ip = "203.0.113.20", peer = "SITE-A" }
    site-b = { vpn_id = "vpn-0aaaaaaaaaaaaaaa2", tunnel_ip = "203.0.113.21", peer = "SITE-B" }
  } : {}
}

module "vpn_tunnel_down_alarm" {
  for_each            = local.vpn_legacy_active_tunnels
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-legacy-vpn-${each.key}-tunnel-down-alarm"
  alarm_description   = "Legacy VPN ${each.value.peer} (${each.value.vpn_id}) active tunnel ${each.value.tunnel_ip} is DOWN. This VPN runs single-tunnel by design; the other AWS-default tunnel is DOWN intentionally."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 1
  period              = 300
  namespace           = "AWS/VPN"
  metric_name         = "TunnelState"
  statistic           = "Minimum"
  treat_missing_data  = "breaching"

  dimensions = {
    VpnId           = each.value.vpn_id
    TunnelIpAddress = each.value.tunnel_ip
  }

  alarm_actions = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions    = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
}

resource "aws_cloudwatch_log_metric_filter" "vpn_ike_dpd_events" {
  for_each       = local.vpn_legacy_active_tunnels
  name           = "${var.tags.project}-${var.tags.environment}-legacy-vpn-${each.key}-ike-dpd-events"
  log_group_name = var.vpn_log_group_name
  pattern        = "?\"DPD timeout\" ?\"IKE SA deleted\" ?\"Phase 2 down\" ?\"rekey failed\""

  # Dimensions intentionally omitted: AWS rejects dimensions on simple
  # text-match filter patterns (only JSON $-field patterns support them).
  # The metric_name already encodes the VPN (-dcc / -cdlv suffix).
  metric_transformation {
    name          = "VpnIkeDpdEvents-${each.key}"
    namespace     = "acme/${var.tags.project}-${var.tags.environment}/vpn"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

module "vpn_ike_dpd_alarm" {
  for_each            = local.vpn_legacy_active_tunnels
  source              = var.module_sources.cloudwatch.source
  version             = var.module_sources.cloudwatch.version
  alarm_name          = "${var.tags.project}-${var.tags.environment}-legacy-vpn-${each.key}-ike-dpd-events-alarm"
  alarm_description   = "Legacy VPN ${each.value.peer} (${each.value.vpn_id}) IKE/DPD churn — possible precursor to active-tunnel drop. Single-tunnel VPN by design."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 3
  period              = 300
  namespace           = "acme/${var.tags.project}-${var.tags.environment}/vpn"
  metric_name         = "VpnIkeDpdEvents-${each.key}"
  statistic           = "Sum"
  treat_missing_data  = "notBreaching"

  alarm_actions = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []
  ok_actions    = var.enable_slack_notifications ? [module.notify_slack["alerts"].slack_topic_arn] : []

  depends_on = [aws_cloudwatch_log_metric_filter.vpn_ike_dpd_events]
}
