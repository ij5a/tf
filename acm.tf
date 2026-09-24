# us-east-1 cert required by CloudFront
module "acm_cert_us_east_1" {
  count                  = var.enable_acm ? 1 : 0
  source                 = "./modules/tls-cert/"
  domain_name            = var.domain_name
  additional_domain_name = local.enable_additional_domain ? var.additional_domain_name : ""

  providers = {
    aws = aws.us-east-1
  }

  depends_on = [aws_route53_zone.domain, aws_route53_zone.additional_domain]
}

# Cert for the manual NLBs: old example.com names plus the env's aws.example.com wildcard.
resource "aws_acm_certificate" "nlb" {
  count                     = var.nlb_cert_wildcard != "" ? 1 : 0
  domain_name               = "example.com"
  subject_alternative_names = ["*.example.com", var.nlb_cert_wildcard]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# NOTE: only aws.example.com records are managed. The example.com CNAME is shared with the live cert, so it stays unmanaged.
resource "aws_route53_record" "nlb_validation" {
  for_each = toset(var.nlb_cert_wildcard != "" ? [var.nlb_cert_wildcard] : [])
  provider = aws.main
  name     = one([for d in aws_acm_certificate.nlb[0].domain_validation_options : d.resource_record_name if d.domain_name == each.key])
  records  = [one([for d in aws_acm_certificate.nlb[0].domain_validation_options : d.resource_record_value if d.domain_name == each.key])]
  ttl      = 60
  type     = one([for d in aws_acm_certificate.nlb[0].domain_validation_options : d.resource_record_type if d.domain_name == each.key])
  zone_id  = var.additional_main_route_53_zone_id
}

resource "aws_acm_certificate_validation" "nlb" {
  count           = var.nlb_cert_wildcard != "" ? 1 : 0
  certificate_arn = aws_acm_certificate.nlb[0].arn
  depends_on      = [aws_route53_record.nlb_validation]
}

module "acm_cert" {
  count                  = var.enable_acm ? 1 : 0
  source                 = "./modules/tls-cert/"
  domain_name            = var.domain_name
  additional_domain_name = local.enable_additional_domain ? var.additional_domain_name : ""
  depends_on             = [aws_route53_zone.domain, aws_route53_zone.additional_domain]
}
