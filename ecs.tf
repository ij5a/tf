resource "aws_service_discovery_private_dns_namespace" "this" {
  count       = var.enable_ecs ? 1 : 0
  description = "CloudMap namespace for ${var.tags.project}-${var.tags.environment}"
  name        = "${var.tags.project}-${var.tags.environment}"
  vpc         = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
}

module "ecs" {
  count   = var.enable_ecs ? 1 : 0
  source  = var.module_sources.ecs_cluster.source
  version = var.module_sources.ecs_cluster.version
  name    = "${var.tags.project}-${var.tags.environment}"

  service_connect_defaults = {
    namespace = aws_service_discovery_private_dns_namespace.this[0].arn
  }

  setting = [{
    "name" : "containerInsights",
    "value" : local.container_insights
  }]

  cluster_capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy = {
    FARGATE_SPOT = {
      weight = 1
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  config_names = {
    apigw-central = "api-gateway"
    apigw-pr      = "api-gateway"
    authenticator = "acme-saas"
    eg            = "acme-eg.encrypted.json"
    pr            = "acme-saas"
  }

  client_code = split("-", var.tags.project)[0]

  # Shared IAM statement required by App Auto Scaling on all ECS services.
  autoscaling_exec_iam_statement = [{
    sid    = "AppAutoScaling"
    effect = "Allow"
    actions = [
      "application-autoscaling:*",
      "cloudwatch:DeleteAlarms",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DisableAlarmActions",
      "cloudwatch:EnableAlarmActions",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:PutMetricAlarm",
      "ecs:DescribeServices",
      "ecs:UpdateService",
      "iam:CreateServiceLinkedRole",
      "sns:CreateTopic",
      "sns:Get*",
      "sns:List*",
      "sns:Subscribe",
    ]
    resources = ["*"]
  }]
}

locals {
  dotenv_services = [
    for service in var.services : service
    if service != "pr" && service != "authenticator" && service != "spa" && !strcontains(service, "apigw")
  ]
  env_vars = {
    for service in local.dotenv_services : service =>
    try(
      [
        for line in split("\n", file("service-configs/${var.tags.project}-${var.tags.environment}/${service == "api-reconciler" ? "api" : service}.env")) :
        {
          name = split("=", line)[0]
          value = replace(
            join("=", slice(split("=", line), 1, length(split("=", line)))),
            "/^\"(.*)\"$/", "$1"
          )
        }
        if length(split("=", line)) > 1 && !startswith(trimspace(line), "#")
      ],
      []
    )
  }

  # When enable_de_mysql_rds is on, the DB_HOST and DB_PASSWORD values parsed
  # from de.env are stale (they still point at the legacy legacy-mysql). Filter
  # them out and append fresh entries pointing at the per-env RDS instance.
  # ECS rejects task definitions with duplicate env var names, so the filter
  # is required — we can't just append and hope the last value wins.
  de_mysql_rds_env_overrides = var.enable_de_mysql_rds && contains(var.services, "de") ? [
    {
      name  = "DB_HOST"
      value = module.de_mysql_rds[0].db_instance_address
    },
    {
      name  = "DB_PASSWORD"
      value = random_password.de_mysql_rds_master_password[0].result
    },
  ] : []

  env_vars_with_de_overrides = {
    for service, vars in local.env_vars : service => (
      service == "de" && var.enable_de_mysql_rds && contains(var.services, "de") ?
      concat(
        [for v in vars : v if v.name != "DB_HOST" && v.name != "DB_PASSWORD"],
        local.de_mysql_rds_env_overrides
      ) : vars
    )
  }

}

# Self-signed cert for the ALB->ECS TLS sidecars. The ALB never validates target certs, so
# self-signed is the functionally correct ceiling; the key lives in state (encrypted S3 backend).
# 10-year validity is the deliberate ceiling — rotation = new secret version + redeploy.
locals {
  tls_lb_services = ["apigw-central", "apigw-pr", "de"]
}

resource "tls_private_key" "alb_to_ecs" {
  count     = var.enable_tls_to_ecs ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "alb_to_ecs" {
  count           = var.enable_tls_to_ecs ? 1 : 0
  private_key_pem = tls_private_key.alb_to_ecs[0].private_key_pem

  subject {
    common_name = var.domain_name
  }

  validity_period_hours = 87600
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

module "alb_tls_cert_secret" {
  source      = var.module_sources.secrets_manager.source
  version     = var.module_sources.secrets_manager.version
  count       = var.enable_tls_to_ecs ? 1 : 0
  name_prefix = "${var.tags.project}-${var.tags.environment}-alb-tls-"
  description = "Self-signed cert + key for the ALB->ECS TLS sidecars"
  secret_string = jsonencode({
    cert = tls_self_signed_cert.alb_to_ecs[0].cert_pem
    key  = tls_private_key.alb_to_ecs[0].private_key_pem
  })
}

# CPU + memory combinations must match valid Fargate pairs:
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
module "ecs_service" {
  source                   = var.module_sources.ecs_service.source
  version                  = var.module_sources.ecs_service.version
  for_each                 = var.enable_ecs && !var.enable_standalone_phpmyadmin ? toset([for service in var.services : service if service != "spa"]) : toset([])
  cluster_arn              = module.ecs[0].arn
  cpu                      = var.service_overall_cpu_mem_combination.cpu
  enable_execute_command   = true
  memory                   = var.service_overall_cpu_mem_combination.mem
  name                     = each.key
  family                   = "${var.tags.project}-${var.tags.environment}-${each.key}"
  desired_count            = split(":", var.service_task_count[each.key])[0]
  autoscaling_min_capacity = split(":", var.service_task_count[each.key])[1]
  autoscaling_max_capacity = split(":", var.service_task_count[each.key])[2]
  force_new_deployment     = true
  propagate_tags           = "SERVICE"

  capacity_provider_strategy = local.fargate_spot_strategy

  task_exec_iam_statements = concat(local.autoscaling_exec_iam_statement, var.enable_tls_to_ecs && contains(local.tls_lb_services, each.key) ? [
    {
      sid       = "TlsSidecarCertSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [module.alb_tls_cert_secret[0].secret_arn]
    }
  ] : [])

  tasks_iam_role_statements = [
    {
      sid    = "S3Access"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = [
        module.s3_bucket["storage"].s3_bucket_arn,
        "${module.s3_bucket["storage"].s3_bucket_arn}/*"
      ]
    },
    {
      sid    = "SecretsManagerAccess"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue"
      ]
      resources = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.tags.project}-${var.tags.environment}-*"
      ]
    }
  ]

  container_definitions = merge({
    (each.key) = {
      cpu                       = var.use_service_specs ? split(":", var.service_specs[each.key])[0] : null
      memory                    = var.use_service_specs ? split(":", var.service_specs[each.key])[1] : null
      memoryReservation         = var.use_service_specs ? split(":", var.service_specs[each.key])[1] : null
      enable_cloudwatch_logging = var.enable_cloudwatch_logging
      cloudwatch_log_group_name = "${var.tags.project}-${var.tags.environment}-${each.key}"
      essential                 = true
      image                     = var.tags.environment == "dev" ? "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/acme-platform-image:${var.service_repositories[each.key]}-latest" : "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/acme-platform-image:${var.tags.environment}-${var.service_repositories[each.key]}-latest"
      readonlyRootFilesystem    = false

      environment = each.key != "pr" && each.key != "authenticator" && !strcontains(each.key, "apigw") ? concat(
        local.env_vars_with_de_overrides[each.key],
        [
          {
            name  = "ENV_SHA512",
            value = filesha512("service-configs/${var.tags.project}-${var.tags.environment}/${each.key == "api-reconciler" ? "api" : each.key}.env")
          },
          {
            name  = each.key == "api-reconciler" ? "ACME_API_RECONCILER" : null
            value = each.key == "api-reconciler" ? true : null
          },
          {
            name  = "MEM_LIMIT",
            value = var.use_service_specs ? split(":", var.service_specs[each.key])[1] * 1024 * 1024 : var.service_overall_cpu_mem_combination.mem * 1024 * 1024
          }
        ]) : each.key == "acme-eg" ? [
        {
          name  = "SAAS_ENABLED"
          value = "true"
        },
        {
          name  = "SINGLE_PROCESS"
          value = "true"
        },
        {
          name  = "ENV_SHA512"
          value = filesha512("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.env")
        },
        {
          name  = "JSON_SHA512"
          value = filesha512("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.json")
        },
        {
          name  = "MEM_LIMIT",
          value = var.use_service_specs ? split(":", var.service_specs[each.key])[1] * 1024 * 1024 : var.service_overall_cpu_mem_combination.mem * 1024 * 1024
        }
        ] : [
        {
          name  = "APP_CONFIG_SOURCE"
          value = module.secrets_manager[each.key].secret_arn
        },
        {
          name  = "APP_CONFIG_NOTE"
          value = "Please check the AWS Secrets Manager for the config. See APP_CONFIG_SOURCE variable."
        },
        {
          name  = "APP_CONFIG_REASON"
          value = "Not .env hence env vars are not shown here but they are loaded in the container and can be found in the AWS Secrets Manager."
        },
        {
          name  = "SAAS_ENABLED"
          value = "true"
        },
        {
          name  = "CUSTOM_NODE_COMMAND"
          value = "true"
        },
        {
          name  = !strcontains(each.key, "apigw") ? "JSON_SHA512" : "YAML_SHA512"
          value = !strcontains(each.key, "apigw") ? filesha512("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.json") : filesha512("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.yaml")
        },
        {
          name  = "MEM_LIMIT",
          value = var.use_service_specs ? split(":", var.service_specs[each.key])[1] * 1024 * 1024 : var.service_overall_cpu_mem_combination.mem * 1024 * 1024
        }
      ]

      entrypoint = each.key != "pr" && each.key != "authenticator" && each.key != "eg" && !strcontains(each.key, "apigw") ? [
        "/bin/bash", "-c",
        "aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.key\"' | base64 -d > /var/app/config/encrypt.key && aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.pub\"' | base64 -d > /var/app/config/encrypt.pub && ${(var.require_secure_transport && contains(["api", "api-reconciler", "de"], each.key)) ? "curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /var/app/config/rds-ca-bundle.pem && " : ""}/sbin/tini -sv -- /var/app/current/entrypoint.sh"
        ] : each.key == "eg" ? [
        "/bin/bash", "-c",
        "aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.key\"' | base64 -d > /var/app/config/encrypt.key && aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.pub\"' | base64 -d > /var/app/config/encrypt.pub && aws secretsmanager get-secret-value --secret-id ${module.secrets_manager[each.key].secret_name} --region ${var.region} --query SecretString --output text > /var/app/config/${local.config_names[each.key]} && cp -r /var/app/current/config/eg-stream-${local.client_code}/* /var/app/config/ && /sbin/tini -sv -- /var/app/current/entrypoint.sh"
        ] : strcontains(each.key, "apigw") ? [
        "/bin/sh", "-c",
        "aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"jwtSecret.pub\"' | base64 -d > /var/app/config/jwtSecret.pub && aws secretsmanager get-secret-value --secret-id ${module.secrets_manager[each.key].secret_name} --region ${var.region} --query SecretString --output text > /var/app/config/${local.config_names[each.key]} && ./entrypoint.sh"
        ] : [
        "/bin/bash", "-c",
        "aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.key\"' | base64 -d > /var/app/config/encrypt.key && aws secretsmanager get-secret-value --secret-id ${var.tags.project}-${var.tags.environment} --region ${var.region} --query SecretString --output text | jq -r '.\"encrypt.pub\"' | base64 -d > /var/app/config/encrypt.pub && aws secretsmanager get-secret-value --secret-id ${module.secrets_manager[each.key].secret_name} --region ${var.region} --query SecretString --output text > /var/app/config/${local.config_names[each.key]} && /sbin/tini -sv -- /var/app/current/entrypoint.sh"
      ]

      portMappings = [{
        name          = each.key
        containerPort = var.service_ports[each.key]
        protocol      = "tcp"
      }]

      healthCheck = each.key != "api-reconciler" ? {
        command = each.key != "eg" ? [
          "CMD-SHELL",
          "curl -f http://localhost:${var.service_ports[each.key]}/echo || exit 1"
          ] : [
          "CMD-SHELL",
          "nc -zv localhost ${var.service_ports[each.key]} || exit 1"
        ]
        interval    = 10
        retries     = 3
        timeout     = 2
        startPeriod = 30
        } : {
        command     = ["CMD-SHELL", "exit 0"]
        interval    = 10
        retries     = 3
        timeout     = 2
        startPeriod = 30
      }
    }
    },
    var.enable_tls_to_ecs && contains(local.tls_lb_services, each.key) ? {
      tls-proxy = {
        create_cloudwatch_log_group = false
        essential                   = true
        image                       = var.tls_proxy_image
        readonlyRootFilesystem      = false

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-region        = var.region
            awslogs-group         = "${var.tags.project}-${var.tags.environment}-${each.key}"
            awslogs-stream-prefix = "ecs"
          }
        }

        command = [
          "/bin/sh", "-c",
          "printf '%s' \"$TLS_CERT\" > /tmp/tls.crt && printf '%s' \"$TLS_KEY\" > /tmp/tls.key && printf 'pid /tmp/nginx.pid;\\nerror_log /dev/stderr;\\nevents {}\\nhttp { access_log off; server { listen 8443 ssl; ssl_certificate /tmp/tls.crt; ssl_certificate_key /tmp/tls.key; ssl_protocols TLSv1.2 TLSv1.3; ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384; ssl_prefer_server_ciphers on; location / { proxy_pass http://127.0.0.1:${var.service_ports[each.key]}; proxy_http_version 1.1; proxy_set_header Host $http_host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto https; proxy_read_timeout 60s; } } }\\n' > /tmp/nginx.conf && exec nginx -c /tmp/nginx.conf -g 'daemon off;'"
        ]

        secrets = [
          {
            name      = "TLS_CERT"
            valueFrom = "${module.alb_tls_cert_secret[0].secret_arn}:cert::"
          },
          {
            name      = "TLS_KEY"
            valueFrom = "${module.alb_tls_cert_secret[0].secret_arn}:key::"
          }
        ]

        portMappings = [{
          name          = "tls-proxy"
          containerPort = 8443
          protocol      = "tcp"
        }]

        healthCheck = {
          command     = ["CMD-SHELL", "nc -z localhost 8443 || exit 1"]
          interval    = 10
          retries     = 3
          timeout     = 2
          startPeriod = 10
        }
      }
  } : {})

  deployment_circuit_breaker = local.ecs_circuit_breaker

  service_connect_configuration = {
    namespace = aws_service_discovery_private_dns_namespace.this[0].arn
    service = [{
      client_alias = {
        port     = var.service_ports[each.key]
        dns_name = each.key
      }

      port_name      = each.key
      discovery_name = each.key
    }]
  }

  # Second (break-glass ALB) and third (TLS-sidecar TG) entries are additional registrations of
  # the same service — an in-place service update with a rolling redeploy, never a replace.
  load_balancer = merge(
    strcontains(each.key, "apigw") || each.key == "de" || (each.key == "eg" && var.enable_nlb) ? {
      (each.key) = {
        target_group_arn = each.key == "apigw-central" ? module.alb["${var.tags.project}-${var.tags.environment}"].target_groups[each.key].arn : each.key == "eg" ? module.nlb["${var.tags.project}-${var.tags.environment}"].target_groups[each.key].arn : aws_lb_target_group.this[each.key].arn
        container_name   = each.key
        container_port   = var.service_ports[each.key]
      }
    } : {},
    local.enable_breakglass && (strcontains(each.key, "apigw") || each.key == "de") ? {
      "${each.key}-bg" = {
        target_group_arn = module.alb_breakglass[0].target_groups[each.key].arn
        container_name   = each.key
        container_port   = var.service_ports[each.key]
      }
    } : {},
    var.enable_tls_to_ecs && contains(local.tls_lb_services, each.key) ? {
      "${each.key}-tls" = {
        target_group_arn = each.key == "apigw-central" ? module.alb["${var.tags.project}-${var.tags.environment}"].target_groups["apigw-central-tls"].arn : aws_lb_target_group.this_tls[each.key].arn
        container_name   = "tls-proxy"
        container_port   = 8443
      }
    } : {}
  )

  subnet_ids = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)

  security_group_ingress_rules = merge({
    "vpc_ingress_${var.service_ports[each.key]}" = {
      from_port   = var.service_ports[each.key]
      to_port     = var.service_ports[each.key]
      ip_protocol = "tcp"
      description = "${var.tags.project}-${var.tags.environment}-vpc"
      cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
    }
    },
    var.enable_tls_to_ecs && contains(local.tls_lb_services, each.key) ? {
      vpc_ingress_8443 = {
        from_port   = 8443
        to_port     = 8443
        ip_protocol = "tcp"
        description = "${var.tags.project}-${var.tags.environment}-vpc TLS sidecar"
        cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
      }
    } : {},
    var.use_private_nlb_for_eg && var.use_twingate_transit_gateway && each.key == "eg" ? {
      "twingate_ingress_${var.service_ports["eg"]}" = {
        from_port   = var.service_ports["eg"]
        to_port     = var.service_ports["eg"]
        ip_protocol = "tcp"
        description = "Twingate VPC CIDR block"
        cidr_ipv4   = var.twingate_vpc_cidr_block
      }
    } : {},
    var.use_public_nlb_for_eg && each.key == "eg" ? {
      for idx, ip in var.allowed_ip_addresses : "allowed_ip_${idx}" => {
        from_port   = var.service_ports["eg"]
        to_port     = var.service_ports["eg"]
        ip_protocol = "tcp"
        description = "Allowed IP: ${ip}"
        cidr_ipv4   = ip
      }
    } : {},
    var.use_public_nlb_for_eg && each.key == "eg" ? {
      "twingate" = {
        from_port   = var.service_ports["eg"]
        to_port     = var.service_ports["eg"]
        ip_protocol = "tcp"
        description = "Twingate Public IP"
        cidr_ipv4   = var.twingate_ip
      }
    } : {}
  )

  security_group_egress_rules = {
    "egress_all" = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  autoscaling_policies = merge(
    {
      "cpu" : {
        "policy_type" : "TargetTrackingScaling",
        "target_tracking_scaling_policy_configuration" : {
          "predefined_metric_specification" : {
            "predefined_metric_type" : "ECSServiceAverageCPUUtilization"
          },
          "target_value" : 50,
          "scale_in_cooldown" : 300,
          "scale_out_cooldown" : 300
        }
      },
      "memory" : {
        "policy_type" : "TargetTrackingScaling",
        "target_tracking_scaling_policy_configuration" : {
          "predefined_metric_specification" : {
            "predefined_metric_type" : "ECSServiceAverageMemoryUtilization"
          },
          "target_value" : 50,
          "scale_in_cooldown" : 300,
          "scale_out_cooldown" : 300
        }
      }
    },
    strcontains(each.key, "apigw") ? {
      "request_count" : {
        "policy_type" : "TargetTrackingScaling",
        "target_tracking_scaling_policy_configuration" : {
          "predefined_metric_specification" : {
            "predefined_metric_type" : "ALBRequestCountPerTarget",
            "resource_label" : each.key == "apigw-central" ? "${replace(module.alb["${var.tags.project}-${var.tags.environment}"].id, "/^.*loadbalancer//", "")}/targetgroup${replace(module.alb["${var.tags.project}-${var.tags.environment}"].target_groups[each.key].arn, "/^.*targetgroup/", "")}" : "${replace(module.alb["${var.tags.project}-${var.tags.environment}"].id, "/^.*loadbalancer//", "")}/targetgroup${replace(aws_lb_target_group.this[each.key].arn, "/^.*targetgroup/", "")}"
          },
          "target_value" : 3000,
          "scale_in_cooldown" : 300,
          "scale_out_cooldown" : 300
        }
      }
    } : {}
  )

  autoscaling_scheduled_actions = local.is_prod ? {
    business_hours = {
      schedule         = var.autoscaling_schedule.business_hours
      desired_capacity = split(":", var.service_task_count[each.key])[0]
      min_capacity     = split(":", var.service_task_count[each.key])[1]
      max_capacity     = split(":", var.service_task_count[each.key])[2]
    },
    off_hours = {
      schedule         = var.autoscaling_schedule.off_hours
      desired_capacity = ceil(split(":", var.service_task_count[each.key])[0] / 2)
      min_capacity     = ceil(split(":", var.service_task_count[each.key])[1] / 2)
      max_capacity     = ceil(split(":", var.service_task_count[each.key])[2] / 2)
    }
    } : merge({
      business_hours = {
        schedule         = var.autoscaling_schedule.business_hours
        desired_capacity = split(":", var.service_task_count[each.key])[0]
        min_capacity     = split(":", var.service_task_count[each.key])[1]
        max_capacity     = split(":", var.service_task_count[each.key])[2]
      },
      off_hours = {
        schedule         = var.autoscaling_schedule.off_hours
        desired_capacity = 0
        min_capacity     = 0
        max_capacity     = 0
      }
      }, var.autoscaling_schedule.weekend_guard ? {
      weekend_guard = {
        schedule         = local.weekend_guard_schedule
        desired_capacity = 0
        min_capacity     = 0
        max_capacity     = 0
      }
  } : {})
}

# phpMyAdmin dropdown servers - the PMA_* env lists join these positionally, so all fields stay equal length.
# Reader entry only when a reader exists: at aurora_instance_count = 1 the -ro endpoint silently routes to the writer.
# The legacy shared MySQL entry is non-prod only; its TLS turns on with require_secure_transport
# (CA fetched by the container entrypoint).
locals {
  pma_servers = concat(
    [{
      host       = module.aurora_mysql_v2["central"].cluster_endpoint
      port       = tostring(module.aurora_mysql_v2["central"].cluster_port)
      verbose    = module.aurora_mysql_v2["central"].cluster_id
      ssl        = "0"
      ssl_verify = "0"
      ssl_ca     = ""
    }],
    var.aurora_instance_count > 1 ? [{
      host       = module.aurora_mysql_v2["central"].cluster_reader_endpoint
      port       = tostring(module.aurora_mysql_v2["central"].cluster_port)
      verbose    = "${module.aurora_mysql_v2["central"].cluster_id}-ro"
      ssl        = "0"
      ssl_verify = "0"
      ssl_ca     = ""
    }] : [],
    var.enable_pr_serverless_aurora && contains(var.services, "pr") ? [{
      host       = try(module.aurora_mysql_v2["pr"].cluster_endpoint, "")
      port       = try(tostring(module.aurora_mysql_v2["pr"].cluster_port), "3306")
      verbose    = try(module.aurora_mysql_v2["pr"].cluster_id, "pr")
      ssl        = "0"
      ssl_verify = "0"
      ssl_ca     = ""
    }] : [],
    var.enable_pr_serverless_aurora && contains(var.services, "pr") && var.pr_aurora_instance_count > 1 ? [{
      host       = try(module.aurora_mysql_v2["pr"].cluster_reader_endpoint, "")
      port       = try(tostring(module.aurora_mysql_v2["pr"].cluster_port), "3306")
      verbose    = try("${module.aurora_mysql_v2["pr"].cluster_id}-ro", "pr-ro")
      ssl        = "0"
      ssl_verify = "0"
      ssl_ca     = ""
    }] : [],
    !local.is_prod ? [{
      host       = "legacy-mysql.cluster-aaaaexample0.sa-east-1.rds.amazonaws.com"
      port       = "3306"
      verbose    = "legacy-mysql"
      ssl        = var.require_secure_transport ? "1" : "0"
      ssl_verify = var.require_secure_transport ? "1" : "0"
      ssl_ca     = var.require_secure_transport ? "/etc/phpmyadmin/rds-ca-bundle.pem" : ""
    }] : []
  )
}

module "phpmyadmin" {
  source                   = var.module_sources.ecs_service.source
  version                  = var.module_sources.ecs_service.version
  count                    = var.enable_ecs && var.enable_phpmyadmin ? 1 : 0
  cluster_arn              = module.ecs[0].arn
  cpu                      = 512
  enable_execute_command   = true
  memory                   = 1024
  name                     = "phpmyadmin"
  family                   = "${var.tags.project}-${var.tags.environment}-phpmyadmin"
  desired_count            = 1
  autoscaling_min_capacity = 1
  autoscaling_max_capacity = 2
  force_new_deployment     = true
  propagate_tags           = "SERVICE"

  capacity_provider_strategy = local.fargate_spot_strategy

  task_exec_iam_statements = concat(local.autoscaling_exec_iam_statement, [
    {
      sid    = "SecretsManagerAccess"
      effect = "Allow"
      actions = [
        "secretsmanager:GetSecretValue"
      ]
      resources = [
        module.aurora_mysql_v2["central"].cluster_master_user_secret[0]["secret_arn"]
      ]
    },
  ])

  container_definitions = {
    "phpmyadmin" = {
      cpu                                    = 512
      memory                                 = 1024
      memoryReservation                      = 1024
      enable_cloudwatch_logging              = var.enable_cloudwatch_logging
      cloudwatch_log_group_name              = "${var.tags.project}-${var.tags.environment}-phpmyadmin"
      cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
      essential                              = true
      image                                  = var.phpmyadmin_image
      readonlyRootFilesystem                 = false

      # When require_secure_transport is on (non-prod), fetch the RDS CA bundle at start so phpMyAdmin can verify TLS to legacy-mysql.
      entrypoint = var.require_secure_transport && !local.is_prod ? [
        "/bin/sh",
        "-c",
        "mkdir -p /etc/phpmyadmin && curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /etc/phpmyadmin/rds-ca-bundle.pem && exec /docker-entrypoint.sh apache2-foreground"
      ] : null

      environment = [
        {
          name  = "PMA_HOSTS"
          value = join(",", local.pma_servers[*].host)
        },
        {
          name  = "PMA_VERBOSES"
          value = join(",", local.pma_servers[*].verbose)
        },
        {
          name  = "PMA_PORTS"
          value = join(",", local.pma_servers[*].port)
        },
        {
          name  = "PMA_SSLS"
          value = join(",", local.pma_servers[*].ssl)
        },
        {
          name  = "PMA_SSL_VERIFIES"
          value = join(",", local.pma_servers[*].ssl_verify)
        },
        {
          name  = "PMA_SSL_CAS"
          value = join(",", local.pma_servers[*].ssl_ca)
        },
        {
          name  = "PMA_ABSOLUTE_URI"
          value = "http://${local.enable_additional_domain ? var.additional_domain_name : var.domain_name}/phpmyadmin/"
        },
        {
          name  = "UPLOAD_LIMIT"
          value = "512M"
        },
        {
          name  = "MAX_EXECUTION_TIME"
          value = "600"
        },
        {
          name  = "MEMORY_LIMIT"
          value = "1024M"
        },
        {
          name  = "POST_MAX_SIZE"
          value = "512M"
        }
      ]

      secrets = [
        {
          name      = "MYSQL_ROOT_PASSWORD"
          valueFrom = "${module.aurora_mysql_v2["central"].cluster_master_user_secret[0]["secret_arn"]}:password::"
        }
      ]

      portMappings = [{
        name          = "phpmyadmin"
        containerPort = 80
        protocol      = "tcp"
      }]

      healthCheck = {
        command = [
          "CMD-SHELL",
          "curl http://localhost/phpmyadmin/ || exit 1"
        ]
        interval    = 10
        retries     = 3
        timeout     = 2
        startPeriod = 30
      }
    }
  }

  deployment_circuit_breaker = local.ecs_circuit_breaker

  service_connect_configuration = {
    namespace = aws_service_discovery_private_dns_namespace.this[0].arn
    service = [{
      client_alias = {
        port     = 80
        dns_name = "phpmyadmin"
      }

      port_name      = "phpmyadmin"
      discovery_name = "phpmyadmin"
    }]
  }

  # apigw ALB TG when enable_alb, else the standalone TG. Same apigw TG for enable_alb envs - no diff.
  load_balancer = merge(
    {
      "phpmyadmin" = {
        target_group_arn = coalesce(try(aws_lb_target_group.phpmyadmin[0].arn, null), try(aws_lb_target_group.phpmyadmin_standalone[0].arn, null))
        container_name   = "phpmyadmin"
        container_port   = 80
      }
    },
    local.enable_breakglass ? {
      "phpmyadmin-bg" = {
        target_group_arn = module.alb_breakglass[0].target_groups["phpmyadmin"].arn
        container_name   = "phpmyadmin"
        container_port   = 80
      }
    } : {}
  )

  subnet_ids = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)

  security_group_ingress_rules = {
    "vpc_ingress_phpmyadmin" = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "${var.tags.project}-${var.tags.environment}-vpc"
      cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
    }
  }

  security_group_egress_rules = {
    "egress_all" = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  autoscaling_policies = {
    "cpu" : {
      "policy_type" : "TargetTrackingScaling",
      "target_tracking_scaling_policy_configuration" : {
        "predefined_metric_specification" : {
          "predefined_metric_type" : "ECSServiceAverageCPUUtilization"
        },
        "target_value" : 50,
        "scale_in_cooldown" : 300,
        "scale_out_cooldown" : 300
      }
    },
    "memory" : {
      "policy_type" : "TargetTrackingScaling",
      "target_tracking_scaling_policy_configuration" : {
        "predefined_metric_specification" : {
          "predefined_metric_type" : "ECSServiceAverageMemoryUtilization"
        },
        "target_value" : 50,
        "scale_in_cooldown" : 300,
        "scale_out_cooldown" : 300
      }
    }
  }

  autoscaling_scheduled_actions = local.is_prod ? {
    business_hours = {
      schedule     = var.autoscaling_schedule.business_hours
      min_capacity = 1
      max_capacity = 2
    },
    off_hours = {
      schedule     = var.autoscaling_schedule.off_hours
      min_capacity = 1
      max_capacity = 1
    }
    } : merge({
      business_hours = {
        schedule     = var.autoscaling_schedule.business_hours
        min_capacity = 1
        max_capacity = 2
      },
      off_hours = {
        schedule     = var.autoscaling_schedule.off_hours
        min_capacity = 0
        max_capacity = 0
      }
      }, var.autoscaling_schedule.weekend_guard ? {
      weekend_guard = {
        schedule     = local.weekend_guard_schedule
        min_capacity = 0
        max_capacity = 0
      }
  } : {})
}

# iso8583-playground: internal Nuxt SSR load-test tool (no DB, no secrets). Idle-sized — raise cpu/memory before a load test.
module "iso8583" {
  source                   = var.module_sources.ecs_service.source
  version                  = var.module_sources.ecs_service.version
  count                    = var.enable_ecs && var.enable_iso8583_playground ? 1 : 0
  cluster_arn              = module.ecs[0].arn
  cpu                      = 1024
  enable_execute_command   = true
  memory                   = 2048
  name                     = "iso8583"
  family                   = "${var.tags.project}-${var.tags.environment}-iso8583"
  desired_count            = 1
  autoscaling_min_capacity = 1
  autoscaling_max_capacity = 1
  force_new_deployment     = true
  propagate_tags           = "SERVICE"

  capacity_provider_strategy = local.fargate_spot_strategy

  task_exec_iam_statements = local.autoscaling_exec_iam_statement

  container_definitions = {
    "iso8583" = {
      cpu                                    = 1024
      memory                                 = 2048
      memoryReservation                      = 2048
      enable_cloudwatch_logging              = var.enable_cloudwatch_logging
      cloudwatch_log_group_name              = "${var.tags.project}-${var.tags.environment}-iso8583"
      cloudwatch_log_group_retention_in_days = var.cloudwatch_log_group_retention_in_days
      essential                              = true
      image                                  = var.iso8583_playground_image
      readonlyRootFilesystem                 = false

      environment = [
        {
          name  = "NUXT_APP_BASE_URL"
          value = "/iso8583-playground/"
        }
      ]

      portMappings = [{
        name          = "iso8583"
        containerPort = 3000
        protocol      = "tcp"
      }]

      # node http check — the node:22-slim runtime has neither wget nor curl.
      # Longer grace window than the phpMyAdmin image for Node SSR cold start.
      healthCheck = {
        command = [
          "CMD-SHELL",
          "node -e \"require('http').get('http://localhost:3000/iso8583-playground/',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))\""
        ]
        interval    = 10
        retries     = 3
        timeout     = 5
        startPeriod = 60
      }
    }
  }

  deployment_circuit_breaker = local.ecs_circuit_breaker

  service_connect_configuration = {
    namespace = aws_service_discovery_private_dns_namespace.this[0].arn
    service = [{
      client_alias = {
        port     = 3000
        dns_name = "iso8583"
      }

      port_name      = "iso8583"
      discovery_name = "iso8583"
    }]
  }

  load_balancer = {
    "iso8583" = {
      target_group_arn = aws_lb_target_group.iso8583[0].arn
      container_name   = "iso8583"
      container_port   = 3000
    }
  }

  subnet_ids = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)

  security_group_ingress_rules = {
    "vpc_ingress_iso8583" = {
      from_port   = 3000
      to_port     = 3000
      ip_protocol = "tcp"
      description = "${var.tags.project}-${var.tags.environment}-vpc"
      cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
    }
  }

  security_group_egress_rules = {
    "egress_all" = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  # Single-task load generator: no target-tracking policies (max=1 can't scale out;
  # a load run would otherwise trip a pointless scale attempt). Keep off-hours scale-to-0 for cost.
  autoscaling_policies = {}

  autoscaling_scheduled_actions = merge({
    business_hours = {
      schedule     = var.autoscaling_schedule.business_hours
      min_capacity = 1
      max_capacity = 1
    },
    off_hours = {
      schedule     = var.autoscaling_schedule.off_hours
      min_capacity = 0
      max_capacity = 0
    }
    }, var.autoscaling_schedule.weekend_guard ? {
    weekend_guard = {
      schedule     = local.weekend_guard_schedule
      min_capacity = 0
      max_capacity = 0
    }
  } : {})
}
