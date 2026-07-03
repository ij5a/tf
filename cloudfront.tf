locals {
  path_patterns = [
    "/api/*",
    "/decision",
    "/update",
    "/phpmyadmin/*",
    "/iso8583-playground/*",
    "/iso8583-playground",
  ]
}

# SPA routing rewrite at viewer-request; leaves paths with extensions alone so API 4XX stays 4XX
resource "aws_cloudfront_function" "spa_router" {
  for_each = var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if service == "spa"]) : toset([])
  name     = "${var.tags.project}-${var.tags.environment}-spa-router"
  runtime  = "cloudfront-js-2.0"
  comment  = "Rewrites SPA requests to /index.html for client-side routing"
  publish  = true
  code     = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;

      // If URI has a file extension, serve it as-is (e.g., .js, .css, .png)
      if (uri.includes('.')) {
        return request;
      }

      // If URI doesn't have a file extension (SPA route), rewrite to /index.html
      request.uri = '/index.html';
      return request;
    }
  EOT
}

resource "aws_cloudfront_cache_policy" "this" {
  for_each    = var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if strcontains(service, "apigw") || service == "spa"]) : toset([])
  name        = "${var.tags.project}-${var.tags.environment}-cache-policy"
  comment     = "Custom cache policy with a lower default TTL."
  default_ttl = 300
  max_ttl     = 300
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# adds security headers + strips X-Amz-* and X-Amz-Meta-Codebuild-* that leak backend details
resource "aws_cloudfront_response_headers_policy" "this" {
  for_each = var.enable_cloudfront ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if strcontains(service, "apigw") || service == "spa"]) : toset([])
  name     = "${var.tags.project}-${var.tags.environment}-security-headers-policy"
  comment  = "Custom security headers to every response"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = "31536000"
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "SAMEORIGIN"
      override     = true
    }

    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }

  remove_headers_config {
    items {
      header = "X-Amz-Server-Side-Encryption"
    }

    items {
      header = "X-Amz-Server-Side-encryption-Aws-Kms-Key-Id"
    }

    items {
      header = "X-Amz-Server-Side-Encryption-Bucket-Key-Enabled"
    }

    items {
      header = "X-Amz-Meta-Codebuild-Content-Sha256"
    }

    items {
      header = "X-Amz-Meta-Codebuild-Buildarn"
    }

    items {
      header = "X-Amz-Meta-Codebuild-Content-Md5"
    }
  }
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host_header" {
  name = "Managed-AllViewerExceptHostHeader"
}

data "aws_cloudfront_origin_request_policy" "user_agent_referer_headers" {
  name = "Managed-UserAgentRefererHeaders"
}

data "aws_cloudfront_response_headers_policy" "simple_cors" {
  name = "Managed-SimpleCORS"
}

module "cdn" {
  source  = var.module_sources.cloudfront.source
  version = var.module_sources.cloudfront.version

  for_each = var.enable_cloudfront ? {
    "${var.tags.project}-${var.tags.environment}" = [
      for service in var.services : service
      if strcontains(service, "apigw") || service == "spa"
    ]
  } : {}

  aliases             = var.use_legacy_endpoints ? concat([var.domain_name, "www.${var.domain_name}"], var.legacy_endpoints) : [var.domain_name, "www.${var.domain_name}"]
  comment             = var.domain_name
  default_root_object = "index.html"
  enabled             = true
  price_class         = "PriceClass_All"
  web_acl_id          = aws_wafv2_web_acl.web_acl["${var.tags.project}-${var.tags.environment}"].arn
  vpc_origin = {
    alb = {
      name                   = "${var.tags.project}-${var.tags.environment}-alb"
      arn                    = module.alb["${var.tags.project}-${var.tags.environment}"].arn
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = {
        items    = ["TLSv1.2"]
        quantity = 1
      }
    }
  }

  origin_access_control = contains(each.value, "spa") ? {
    "${var.tags.project}-${var.tags.environment}-s3-oac" = {
      description      = "CloudFront access to S3"
      origin_type      = "s3"
      signing_behavior = "always"
      signing_protocol = "sigv4"
    }
  } : {}

  origin = merge(
    contains(each.value, "apigw-central") || contains(each.value, "apigw-pr") ? {
      api = {
        domain_name = module.alb["${var.tags.project}-${var.tags.environment}"].dns_name
        vpc_origin_config = {
          vpc_origin_key           = "alb"
          origin_keepalive_timeout = 60
          origin_read_timeout      = 60
        }
        origin_shield = {
          enabled              = true
          origin_shield_region = "us-east-1"
        }
      }
    } : {},
    contains(each.value, "spa") ? {
      spa = {
        domain_name               = module.s3_bucket["spa"].s3_bucket_bucket_domain_name
        origin_access_control_key = "${var.tags.project}-${var.tags.environment}-s3-oac"
        origin_shield = {
          enabled              = true
          origin_shield_region = "us-east-1"
        }
      }
    } : {}
  )

  default_cache_behavior = contains(each.value, "spa") ? {
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cache_policy_id            = aws_cloudfront_cache_policy.this["${var.tags.project}-${var.tags.environment}"].id
    cached_methods             = ["GET", "HEAD", "OPTIONS"]
    compress                   = true
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.user_agent_referer_headers.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this["${var.tags.project}-${var.tags.environment}"].id
    target_origin_id           = "spa"
    use_forwarded_values       = false
    viewer_protocol_policy     = "https-only"
    function_association = {
      viewer-request = {
        function_arn = aws_cloudfront_function.spa_router["${var.tags.project}-${var.tags.environment}"].arn
      }
    }
    } : {
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    cached_methods             = ["GET", "HEAD", "OPTIONS"]
    compress                   = true
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.simple_cors.id
    target_origin_id           = "api"
    use_forwarded_values       = false
    viewer_protocol_policy     = "https-only"
    function_association       = {}
  }

  ordered_cache_behavior = contains(each.value, "apigw-central") || contains(each.value, "apigw-pr") ? [
    for path_pattern in local.path_patterns : {
      allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
      cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
      cached_methods             = ["GET", "HEAD", "OPTIONS"]
      compress                   = true
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
      path_pattern               = path_pattern
      response_headers_policy_id = data.aws_cloudfront_response_headers_policy.simple_cors.id
      target_origin_id           = "api"
      use_forwarded_values       = false
      viewer_protocol_policy     = "https-only"
    }
  ] : []

  viewer_certificate = {
    acm_certificate_arn      = module.acm_cert_us_east_1[0].cert_arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }

  # Removed custom_error_response to prevent API 4XX errors from being converted to 200.
  # SPA routing is now handled by the CloudFront Function (spa_router) which rewrites
  # requests without file extensions to /index.html at the viewer-request stage.
  # Omitted entirely as the module doesn't handle null or empty values well.
}

# Standalone phpMyAdmin front door. Separate from module.cdn (apigw): single default behavior to
# the dedicated internal ALB, gated by its own CF-WAF. Interim - destroys when enable_standalone_phpmyadmin flips.
module "cdn_phpmyadmin" {
  source  = var.module_sources.cloudfront.source
  version = var.module_sources.cloudfront.version

  count = var.enable_standalone_phpmyadmin ? 1 : 0

  aliases     = [var.domain_name]
  comment     = "phpMyAdmin - ${var.domain_name}"
  enabled     = true
  price_class = "PriceClass_100" # ponytail: interim internal tool gated to one Twingate IP, not the global client front door
  web_acl_id  = aws_wafv2_web_acl.phpmyadmin_standalone[0].arn

  vpc_origin = {
    alb = {
      name                   = aws_lb.phpmyadmin_standalone[0].name
      arn                    = aws_lb.phpmyadmin_standalone[0].arn
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols = {
        items    = ["TLSv1.2"]
        quantity = 1
      }
    }
  }

  origin = {
    phpmyadmin = {
      domain_name = aws_lb.phpmyadmin_standalone[0].dns_name
      vpc_origin_config = {
        vpc_origin_key           = "alb"
        origin_keepalive_timeout = 60
        origin_read_timeout      = 60
      }
    }
  }

  # ponytail: single default behavior to the ALB - no ordered behaviors, no SPA function, no second origin
  default_cache_behavior = {
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_disabled.id
    cached_methods             = ["GET", "HEAD", "OPTIONS"]
    compress                   = true
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host_header.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.simple_cors.id
    target_origin_id           = "phpmyadmin"
    viewer_protocol_policy     = "redirect-to-https"
    function_association       = {}
  }

  viewer_certificate = {
    acm_certificate_arn      = module.acm_cert_us_east_1[0].cert_arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }
}
