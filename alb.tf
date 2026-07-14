data "aws_ec2_managed_prefix_list" "cf" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

module "alb" {
  source                     = var.module_sources.alb.source
  version                    = var.module_sources.alb.version
  for_each                   = var.enable_alb ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if strcontains(service, "apigw")]) : toset([])
  drop_invalid_header_fields = true
  enable_deletion_protection = false
  internal                   = true
  name                       = "${var.tags.project}-${var.tags.environment}-alb"
  subnets                    = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  vpc_id                     = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  security_group_ingress_rules = {
    http = {
      prefix_list_id = data.aws_ec2_managed_prefix_list.cf.id
      description    = "CloudFront managed prefix list"
      from_port      = 80
      ip_protocol    = "tcp"
      to_port        = 80
    }
  }

  security_group_egress_rules = merge(
    {
      apigw = {
        cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
        description = "ECS - apigw service"
        from_port   = var.service_ports["apigw-central"]
        ip_protocol = "tcp"
        to_port     = var.service_ports["apigw-central"]
      }
    },
    contains(var.services, "de") ? {
      de = {
        cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
        description = "ECS - de service"
        from_port   = var.service_ports["de"]
        ip_protocol = "tcp"
        to_port     = var.service_ports["de"]
      }
    } : {},
    var.enable_phpmyadmin ? {
      phpmyadmin = {
        cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
        description = "ECS - phpmyadmin service"
        from_port   = 80
        ip_protocol = "tcp"
        to_port     = 80
      }
    } : {},
    var.enable_iso8583_playground ? {
      iso8583 = {
        cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
        description = "ECS - iso8583 service"
        from_port   = 3000
        ip_protocol = "tcp"
        to_port     = 3000
      }
    } : {}
  )

  access_logs = local.is_prod ? {
    bucket  = module.elb_access_logs[0].s3_bucket_id
    prefix  = "alb"
    enabled = true
  } : null

  listeners = {
    apigw-central = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "apigw-central"
      }
    }
  }

  target_groups = {
    apigw-central = {
      port                              = var.service_ports["apigw-central"]
      protocol                          = "HTTP"
      create_attachment                 = false
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true
      target_type                       = "ip"
      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        matcher             = "200"
        path                = "/echo"
        port                = "traffic-port"
        protocol            = "HTTP"
        timeout             = 5
        unhealthy_threshold = 2
      }
    }
  }
}

resource "aws_lb_target_group" "this" {
  for_each    = var.enable_alb ? toset([for service in var.services : service if service == "apigw-pr" || service == "de"]) : toset([])
  name        = "${var.tags.project}-${var.tags.environment}-${each.key}"
  port        = var.service_ports[each.key]
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  health_check {
    enabled             = true
    healthy_threshold   = 5
    interval            = 30
    matcher             = "200"
    path                = "/echo"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  depends_on = [module.alb]
}

resource "aws_lb_listener_rule" "host_based_weighted_routing" {
  for_each     = var.enable_alb ? toset([for service in var.services : service if service == "apigw-pr" || service == "de"]) : toset([])
  listener_arn = module.alb["${var.tags.project}-${var.tags.environment}"].listeners["apigw-central"].arn
  priority     = each.key == "apigw-pr" ? 10 : 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  dynamic "condition" {
    for_each = each.key == "apigw-pr" ? [1] : []
    content {
      path_pattern {
        values = var.enable_external_processor ? [
          "/api/v1/login",
          "/api/v1/refreshToken",
          "/api/v1/issuer",
          "/api/v1/issuer/${var.issuer_code}",
          "/api/v1/transactions*",
          ] : [
          "/api/v1/login",
          "/api/v1/refreshToken",
        ]
      }
    }
  }

  dynamic "condition" {
    for_each = each.key == "de" ? [1] : []
    content {
      path_pattern {
        values = [
          "/decision",
          "/update"
        ]
      }
    }
  }

  depends_on = [module.alb, aws_lb_target_group.this]
}

# EG-only NLB (also used for direct testing)
module "nlb" {
  source                     = var.module_sources.alb.source
  version                    = var.module_sources.alb.version
  for_each                   = var.enable_nlb ? toset([for service in var.services : "${var.tags.project}-${var.tags.environment}" if strcontains(service, "eg")]) : toset([])
  enable_deletion_protection = false
  internal                   = var.use_private_nlb_for_eg
  name                       = var.nlb_name_suffix != "" ? "${var.tags.project}-${var.tags.environment}-nlb-${var.nlb_name_suffix}" : "${var.tags.project}-${var.tags.environment}-nlb"
  load_balancer_type         = "network"
  subnets                    = var.use_private_nlb_for_eg ? try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids) : try(module.vpc[0].public_subnets, var.existing_vpc_details.public_subnet_ids)
  vpc_id                     = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  security_group_ingress_rules = merge(
    var.use_private_nlb_for_eg ? {
      "twingate" = {
        cidr_ipv4   = var.twingate_vpc_cidr_block
        description = "Twingate VPC CIDR block"
        from_port   = var.service_ports["eg"]
        ip_protocol = "tcp"
        to_port     = var.service_ports["eg"]
      }
    } : {},
    var.use_public_nlb_for_eg ? merge(
      {
        "twingate" = {
          from_port   = var.service_ports["eg"]
          to_port     = var.service_ports["eg"]
          ip_protocol = "tcp"
          description = "Twingate Public IP"
          cidr_ipv4   = var.twingate_ip
        },
      },
      {
        for idx, ip in var.allowed_ip_addresses : "allowed_ip_${idx}" => {
          from_port   = var.service_ports["eg"]
          to_port     = var.service_ports["eg"]
          ip_protocol = "tcp"
          description = "Allowed IP: ${ip}"
          cidr_ipv4   = ip
        }
      }
    ) : {}
  )

  security_group_egress_rules = {
    "eg" = {
      cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
      description = "ECS - eg service"
      from_port   = var.service_ports["eg"]
      ip_protocol = "tcp"
      to_port     = var.service_ports["eg"]
    }
  }

  # NLB access logs require a TLS listener; the TCP listener below produces nothing. VPC flow logs cover the TCP path.

  listeners = {
    "eg" = {
      port     = var.service_ports["eg"]
      protocol = "TCP"
      forward = {
        target_group_key = "eg"
      }
    }
  }

  target_groups = {
    "eg" = {
      port                              = var.service_ports["eg"]
      protocol                          = "TCP"
      create_attachment                 = false
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true
      target_type                       = "ip"
      preserve_client_ip                = true
      health_check = {
        enabled             = true
        healthy_threshold   = 5
        interval            = 30
        port                = "traffic-port"
        protocol            = "TCP"
        timeout             = 5
        unhealthy_threshold = 2
      }
    }
  }
}

# phpmyadmin target group; attached to apigw-central ALB via listener rule below
resource "aws_lb_target_group" "phpmyadmin" {
  count       = var.enable_alb && var.enable_phpmyadmin ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-phpmyadmin"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  health_check {
    enabled             = true
    healthy_threshold   = 5
    interval            = 30
    matcher             = "200"
    path                = "/phpmyadmin/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }

  depends_on = [module.alb]
}

resource "aws_lb_listener_rule" "phpmyadmin" {
  count        = var.enable_alb && var.enable_phpmyadmin ? 1 : 0
  listener_arn = module.alb["${var.tags.project}-${var.tags.environment}"].listeners["apigw-central"].arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.phpmyadmin[0].arn
  }

  condition {
    path_pattern {
      values = ["/phpmyadmin/*"]
    }
  }

  depends_on = [module.alb, aws_lb_target_group.phpmyadmin]
}

# Standalone phpMyAdmin front door: own internal ALB fronted by its own public CloudFront + CF-WAF,
# independent of the apigw ALB. Interim tool for the prod Aurora migration; tears down via the
# gate when the full compute stack (enable_alb/enable_cloudfront) lands.
resource "aws_security_group" "phpmyadmin_standalone_alb" {
  count       = var.enable_standalone_phpmyadmin ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-phpmyadmin-alb"
  description = "Standalone phpMyAdmin ALB - CloudFront in, ECS task out"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  ingress {
    description     = "CloudFront managed prefix list"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cf.id]
  }

  egress {
    description = "phpMyAdmin ECS task"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)]
  }
}

resource "aws_lb" "phpmyadmin_standalone" {
  count              = var.enable_standalone_phpmyadmin ? 1 : 0
  name               = "${var.tags.project}-${var.tags.environment}-phpmyadmin"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.phpmyadmin_standalone_alb[0].id]
  subnets            = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
}

resource "aws_lb_target_group" "phpmyadmin_standalone" {
  count       = var.enable_standalone_phpmyadmin ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-phpmyadmin-sa"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  health_check {
    enabled             = true
    healthy_threshold   = 5
    interval            = 30
    matcher             = "200"
    path                = "/phpmyadmin/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "phpmyadmin_standalone" {
  count             = var.enable_standalone_phpmyadmin ? 1 : 0
  load_balancer_arn = aws_lb.phpmyadmin_standalone[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.phpmyadmin_standalone[0].arn
  }
}

# iso8583-playground target group; attached to apigw-central ALB via listener rule below.
# Relaxed thresholds for a Node SSR app (slower to come healthy than the phpMyAdmin image).
resource "aws_lb_target_group" "iso8583" {
  count       = var.enable_alb && var.enable_iso8583_playground ? 1 : 0
  name        = "${var.tags.project}-${var.tags.environment}-iso8583"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200"
    path                = "/iso8583-playground/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 10
    unhealthy_threshold = 3
  }

  depends_on = [module.alb]
}

resource "aws_lb_listener_rule" "iso8583" {
  count        = var.enable_alb && var.enable_iso8583_playground ? 1 : 0
  listener_arn = module.alb["${var.tags.project}-${var.tags.environment}"].listeners["apigw-central"].arn
  priority     = 110

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.iso8583[0].arn
  }

  # Bare path redirects to the slash form instead of 404ing on apigw.
  condition {
    path_pattern {
      values = ["/iso8583-playground/*", "/iso8583-playground"]
    }
  }

  depends_on = [module.alb, aws_lb_target_group.iso8583]
}
