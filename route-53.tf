resource "aws_route53_zone" "domain" {
  count = var.enable_route53 ? 1 : 0
  name  = var.domain_name
}

resource "aws_route53_record" "cf" {
  count           = var.enable_route53 && var.enable_cloudfront ? 1 : 0
  allow_overwrite = true
  name            = var.domain_name
  type            = "A"
  zone_id         = aws_route53_zone.domain[0].zone_id

  alias {
    name                   = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_domain_name
    zone_id                = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_hosted_zone_id
    evaluate_target_health = true
  }
}

# Apex A record for the standalone phpMyAdmin CloudFront. allow_overwrite so it hands off cleanly
# to aws_route53_record.cf (apigw) when the full compute stack lands.
resource "aws_route53_record" "phpmyadmin_standalone" {
  count           = var.enable_route53 && var.enable_standalone_phpmyadmin ? 1 : 0
  allow_overwrite = true
  name            = var.domain_name
  type            = "A"
  zone_id         = aws_route53_zone.domain[0].zone_id

  alias {
    name                   = module.cdn_phpmyadmin[0].cloudfront_distribution_domain_name
    zone_id                = module.cdn_phpmyadmin[0].cloudfront_distribution_hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "www" {
  count           = var.enable_route53 && var.enable_cloudfront ? 1 : 0
  allow_overwrite = true
  name            = "www.${var.domain_name}"
  type            = "A"
  zone_id         = aws_route53_zone.domain[0].zone_id

  alias {
    name                   = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_domain_name
    zone_id                = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_hosted_zone_id
    evaluate_target_health = true
  }
}

# Break-glass ALB origin hostname; CloudFront validates the origin cert against this name
# (the env wildcard cert covers it). Exists only while the break-glass flag is on.
resource "aws_route53_record" "breakglass" {
  count   = var.enable_route53 && local.enable_breakglass ? 1 : 0
  name    = "bg.${local.breakglass_domain}"
  type    = "A"
  zone_id = local.enable_additional_domain ? aws_route53_zone.additional_domain[0].zone_id : aws_route53_zone.domain[0].zone_id

  alias {
    name                   = module.alb_breakglass[0].dns_name
    zone_id                = module.alb_breakglass[0].zone_id
    evaluate_target_health = true
  }
}

# delegate NS to parent domain in the main AWS account (cross-account)
resource "aws_route53_record" "ns" {
  count           = var.enable_route53 ? 1 : 0
  provider        = aws.main
  allow_overwrite = true
  name            = var.domain_name
  type            = "NS"
  zone_id         = var.main_route_53_zone_id
  ttl             = 172800
  records         = aws_route53_zone.domain[0].name_servers
}

# Env slice of the aws.example.com dual-run: second zone + delegation + CDN aliases,
# active while additional_domain_name is set in tfvars.
resource "aws_route53_zone" "additional_domain" {
  count = local.enable_additional_domain ? 1 : 0
  name  = var.additional_domain_name
}

# delegate NS to the aws.example.com parent zone in the main AWS account (cross-account)
resource "aws_route53_record" "additional_ns" {
  count           = local.enable_additional_domain ? 1 : 0
  provider        = aws.main
  allow_overwrite = true
  name            = var.additional_domain_name
  type            = "NS"
  zone_id         = local.additional_parent_zone_id
  ttl             = 172800
  records         = aws_route53_zone.additional_domain[0].name_servers
}

resource "aws_route53_record" "additional_cf" {
  count           = local.enable_additional_domain && var.enable_cloudfront ? 1 : 0
  allow_overwrite = true
  name            = var.additional_domain_name
  type            = "A"
  zone_id         = aws_route53_zone.additional_domain[0].zone_id

  alias {
    name                   = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_domain_name
    zone_id                = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "additional_www" {
  count           = local.enable_additional_domain && var.enable_cloudfront ? 1 : 0
  allow_overwrite = true
  name            = "www.${var.additional_domain_name}"
  type            = "A"
  zone_id         = aws_route53_zone.additional_domain[0].zone_id

  alias {
    name                   = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_domain_name
    zone_id                = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_hosted_zone_id
    evaluate_target_health = true
  }
}

# One-time parent zone for the aws.example.com dual-run, owned by the acme-sandbox state.
# prevent_destroy: sandbox destroy is a documented workflow and would orphan the registrar NS delegation.
resource "aws_route53_zone" "additional_parent" {
  count    = var.additional_parent_zone_name != "" ? 1 : 0
  provider = aws.main
  name     = var.additional_parent_zone_name

  lifecycle {
    prevent_destroy = true
  }
}

output "additional_parent_zone" {
  description = "Zone ID and name servers of the additional parent zone (paste the NS records at the registrar)."
  value = try({
    zone_id      = aws_route53_zone.additional_parent[0].zone_id
    name_servers = aws_route53_zone.additional_parent[0].name_servers
  }, null)
}

resource "aws_route53_health_check" "url" {
  for_each = toset(local.route_53_health_check_urls)

  fqdn              = regex("https?://([^/]+)", each.value)[0]
  port              = 443
  type              = "HTTPS"
  resource_path     = regex("https?://[^/]+(/.+)", each.value)[0]
  request_interval  = 30
  failure_threshold = 3
  measure_latency   = true
  enable_sni        = true

  tags = merge(var.tags, {
    Name = regex("https?://([^/]+)", each.value)[0]
  })
}
