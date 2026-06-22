# us-east-1 cert required by CloudFront
module "acm_cert_us_east_1" {
  count       = var.enable_acm ? 1 : 0
  source      = "./modules/tls-cert/"
  domain_name = var.domain_name

  providers = {
    aws = aws.us-east-1
  }

  depends_on = [aws_route53_zone.domain]
}

module "acm_cert" {
  count       = var.enable_acm ? 1 : 0
  source      = "./modules/tls-cert/"
  domain_name = var.domain_name
  depends_on  = [aws_route53_zone.domain]
}
