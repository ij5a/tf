locals {
  # Services that need an ElastiCache replication group: all eligible services when no legacy Redis,
  # or only "central" when use_legacy_redis=true (de shares the legacy node in that case).
  elasticache_keys = var.enable_elasticache && !var.use_legacy_redis ? toset([for service in var.services : service if service == "central" || service == "de"]) : var.enable_elasticache && var.use_legacy_redis ? toset(["central"]) : toset([])
}

resource "random_password" "this" {
  for_each = local.elasticache_keys
  length   = 16
  special  = false
}

module "valkey_auth_token" {
  source        = var.module_sources.secrets_manager.source
  version       = var.module_sources.secrets_manager.version
  for_each      = local.elasticache_keys
  name_prefix   = "${var.tags.project}-${var.tags.environment}-${each.key}-valkey-auth-token-"
  description   = "Valkey auth token for ${var.tags.project}-${var.tags.environment}-${each.key}"
  secret_string = random_password.this[each.key].result
}

module "elasticache" {
  source                      = var.module_sources.elasticache.source
  version                     = var.module_sources.elasticache.version
  for_each                    = local.elasticache_keys
  replication_group_id        = "${var.tags.project}-${var.tags.environment}-${each.key}"
  engine                      = "valkey"
  engine_version              = "8.2"
  node_type                   = "cache.t4g.small"
  transit_encryption_enabled  = true
  auth_token                  = module.valkey_auth_token[each.key].secret_string
  maintenance_window          = "sun:05:00-sun:09:00"
  automatic_failover_enabled  = var.tags.environment == "prod"
  multi_az_enabled            = var.tags.environment == "prod"
  num_cache_clusters          = var.tags.environment == "prod" ? 2 : 1
  cluster_mode                = each.key == "de" ? "enabled" : null
  cluster_mode_enabled        = each.key == "de"
  replicas_per_node_group     = each.key == "de" && var.tags.environment == "prod" ? 1 : null
  apply_immediately           = true
  vpc_id                      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
  subnet_group_name           = "${var.tags.project}-${var.tags.environment}-${each.key}"
  subnet_group_description    = "Valkey replication group subnet group"
  subnet_ids                  = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  create_parameter_group      = true
  parameter_group_family      = "valkey8"
  parameter_group_description = "Valkey replication group parameter group"

  security_group_rules = {
    ingress_vpc = {
      description = "VPC traffic"
      cidr_ipv4   = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
    }
  }

  parameters = [
    {
      name  = "latency-tracking"
      value = "yes"
    }
  ]
}

output "elasticache_endpoints" {
  description = "ElastiCache (Valkey) endpoints keyed by service. 'central' is cluster-mode-disabled (primary + reader populated, configuration is null). 'de' is cluster-mode-enabled (configuration populated, primary/reader are null). Empty for envs with enable_elasticache=false (chl-preprod, per-preprod, chl-prod, per-prod, col-prod). Legacy Redis hostname (use_legacy_redis=true) is not surfaced — it lives outside tofu."
  value = {
    for k, v in module.elasticache : k => {
      primary       = v.replication_group_primary_endpoint_address
      reader        = v.replication_group_reader_endpoint_address
      configuration = v.replication_group_configuration_endpoint_address
      port          = v.replication_group_port
    }
  }
}

output "valkey_auth_token_secret_arns" {
  description = "Valkey auth-token secret ARNs keyed by service ('central', 'de'). Used by scripts/acme-sandbox-post-apply.sh to fetch the auth token without listing secrets."
  value = {
    for k, v in module.valkey_auth_token : k => v.secret_arn
  }
}
