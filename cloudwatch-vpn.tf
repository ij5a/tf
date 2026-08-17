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
  alarm_description   = "The VPN link to ${each.value.peer} is down. Traffic to ${each.value.peer} cannot get through. This VPN is built with only one link on purpose, so there is no backup."
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
