locals {
  # Per-env VPC sizing. Collapsed from the real multi-country layout
  # (4 countries x dev/qa/preprod/prod) to two standard envs for this showcase.
  envs = {
    acme-dev = {
      cidr_prefix = "10.0"
      azs         = ["${var.region}a", "${var.region}c"]
    }

    acme-prod = {
      cidr_prefix = "10.1"
      azs         = ["${var.region}a", "${var.region}b"]
    }
  }
}

module "vpc" {
  count   = var.enable_vpc && !var.use_existing_vpc ? 1 : 0
  source  = var.module_sources.vpc.source
  version = var.module_sources.vpc.version
  name    = "${var.tags.project}-${var.tags.environment}-vpc"
  azs     = local.envs["${var.tags.project}-${var.tags.environment}"]["azs"]
  cidr    = "${local.envs["${var.tags.project}-${var.tags.environment}"]["cidr_prefix"]}.0.0/16"
  private_subnets = [
    "${local.envs["${var.tags.project}-${var.tags.environment}"]["cidr_prefix"]}.0.0/19",
    "${local.envs["${var.tags.project}-${var.tags.environment}"]["cidr_prefix"]}.32.0/19"
  ]
  public_subnets = [
    "${local.envs["${var.tags.project}-${var.tags.environment}"]["cidr_prefix"]}.96.0/19",
    "${local.envs["${var.tags.project}-${var.tags.environment}"]["cidr_prefix"]}.128.0/19"
  ]
  enable_nat_gateway     = local.is_prod && var.enable_ecs
  single_nat_gateway     = local.is_prod && var.enable_ecs
  one_nat_gateway_per_az = false

  enable_flow_log                      = var.enable_vpc_flow_logs
  create_flow_log_cloudwatch_iam_role  = false
  create_flow_log_cloudwatch_log_group = false
  flow_log_destination_type            = "s3"
  flow_log_destination_arn             = try(module.vpc_flow_logs_bucket[0].s3_bucket_arn, null)
  flow_log_max_aggregation_interval    = 600
  flow_log_file_format                 = "parquet"
  flow_log_per_hour_partition          = true
  flow_log_hive_compatible_partitions  = true
}

# Flow log against the legacy (pre-tofu) VPC referenced via existing_vpc_details.
# Only one env per shared legacy VPC should set manage_existing_vpc_flow_log=true.
resource "aws_flow_log" "legacy_vpc" {
  count                    = var.enable_vpc_flow_logs && var.use_existing_vpc && var.manage_existing_vpc_flow_log ? 1 : 0
  vpc_id                   = var.existing_vpc_details.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = module.vpc_flow_logs_bucket[0].s3_bucket_arn
  max_aggregation_interval = 600

  destination_options {
    file_format                = "parquet"
    per_hour_partition         = true
    hive_compatible_partitions = true
  }
}

# non-prod envs use fck-nat instead of NAT Gateway for cost (https://fck-nat.dev)
resource "aws_eip" "fck_nat" {
  count = var.enable_vpc && !var.use_existing_vpc && !local.is_prod ? 1 : 0
}

module "fck_nat" {
  count                = var.enable_vpc && !var.use_existing_vpc && !local.is_prod ? 1 : 0
  source               = var.module_sources.fck_nat.source
  version              = var.module_sources.fck_nat.version
  name                 = "${var.tags.project}-${var.tags.environment}-fck-nat"
  vpc_id               = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
  subnet_id            = try(module.vpc[0].public_subnets[0], var.existing_vpc_details.public_subnet_ids[0])
  use_cloudwatch_agent = true
  update_route_tables  = true
  use_spot_instances   = false
  eip_allocation_ids   = [aws_eip.fck_nat[0].id]

  route_tables_ids = {
    "private-a" = try(module.vpc[0].private_route_table_ids[0], var.existing_vpc_details.private_route_table_ids[0])
    "private-b" = try(module.vpc[0].private_route_table_ids[1], var.existing_vpc_details.private_route_table_ids[1])
  }
}

# Look up NAT Gateways in the legacy pre-existing VPC for envs with use_existing_vpc=true.
# tofu-managed envs (prod NAT GW, qa/dev fck-nat) skip these via the count guard.
data "aws_nat_gateways" "legacy" {
  count  = var.use_existing_vpc ? 1 : 0
  vpc_id = var.existing_vpc_details.id

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "aws_nat_gateway" "legacy" {
  for_each = var.use_existing_vpc ? toset(data.aws_nat_gateways.legacy[0].ids) : toset([])
  id       = each.value
}

output "nat_public_ips" {
  description = "Public egress IP(s) for this environment. Sourced from the tofu-managed NAT Gateway (prod), the fck-nat EIP (dev), or pre-existing NAT Gateways in the shared legacy VPC. Envs sharing a legacy VPC report identical IPs because they share the egress."
  value = sort(compact(concat(
    try(module.vpc[0].nat_public_ips, []),
    try([aws_eip.fck_nat[0].public_ip], []),
    [for ngw in data.aws_nat_gateway.legacy : ngw.public_ip],
  )))
}

module "vpc_peering_for_legacy_db_redis_servers" {
  count                           = var.enable_vpc && var.use_legacy_db || var.use_legacy_redis ? 1 : 0
  source                          = "./modules/vpc-peering-for-legacy-db-redis-servers"
  new_vpc_id                      = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
  new_vpc_cidr_block              = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
  new_vpc_private_route_table_ids = try(module.vpc[0].private_route_table_ids, var.existing_vpc_details.private_route_table_ids)
  use_legacy_db                   = var.use_legacy_db
  use_legacy_redis                = var.use_legacy_redis

  legacy_db_redis_server_details = {
    vpc = {
      rt_ids     = var.legacy_db_redis_server_details.vpc.rt_ids
      cidr_block = var.legacy_db_redis_server_details.vpc.cidr_block
      id         = var.legacy_db_redis_server_details.vpc.id
      owner_id   = var.legacy_db_redis_server_details.vpc.owner_id
    }

    db = {
      sg_id = var.legacy_db_redis_server_details.db.sg_id
    }

    redis = {
      sg_id = var.legacy_db_redis_server_details.redis.sg_id
    }
  }
}

# Twingate TGW lives in the master payer account (Acme AWS) - created manually there
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  for_each           = var.enable_vpc && var.use_twingate_transit_gateway ? toset(["${var.tags.project}-${var.tags.environment}-vpc"]) : toset([])
  subnet_ids         = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
  transit_gateway_id = var.twingate_transit_gateway_id
  vpc_id             = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
  tags               = { Name = "${var.tags.project}-${var.tags.environment}-vpc" }
}

resource "aws_route" "client_vpc" {
  count = var.enable_vpc && var.use_twingate_transit_gateway ? (
    var.use_existing_vpc
    ? length(var.existing_vpc_details.private_route_table_ids)
    : (local.is_prod ? 1 : length(local.envs["${var.tags.project}-${var.tags.environment}"]["azs"]))
  ) : 0
  route_table_id         = try(module.vpc[0].private_route_table_ids, var.existing_vpc_details.private_route_table_ids)[count.index]
  destination_cidr_block = var.twingate_vpc_cidr_block
  transit_gateway_id     = var.twingate_transit_gateway_id
}

resource "aws_route" "twingate_vpc" {
  count                  = var.enable_vpc && var.use_twingate_transit_gateway ? length(var.twingate_vpc_route_table_ids) : 0
  provider               = aws.main
  route_table_id         = var.twingate_vpc_route_table_ids[count.index]
  destination_cidr_block = try(module.vpc[0].vpc_cidr_block, var.existing_vpc_details.cidr_block)
  transit_gateway_id     = var.twingate_transit_gateway_id
}

# retroactively tag legacy VPC resources so they show up in cost reports
locals {
  legacy_vpc_tag_resources = var.use_existing_vpc ? merge(
    { vpc = var.existing_vpc_details.id },
    { for i, id in var.existing_vpc_details.private_subnet_ids : "private-subnet-${i}" => id },
    { for i, id in var.existing_vpc_details.public_subnet_ids : "public-subnet-${i}" => id },
    { for i, id in var.existing_vpc_details.private_route_table_ids : "private-rtb-${i}" => id },
    { for i, id in var.existing_vpc_details.public_route_table_ids : "public-rtb-${i}" => id },
  ) : {}
}

resource "aws_ec2_tag" "legacy_vpc_project" {
  for_each    = local.legacy_vpc_tag_resources
  resource_id = each.value
  key         = "project"
  value       = var.tags.project
}

resource "aws_ec2_tag" "legacy_vpc_environment" {
  for_each    = local.legacy_vpc_tag_resources
  resource_id = each.value
  key         = "environment"
  value       = var.tags.environment
}

resource "aws_ec2_tag" "legacy_vpc_tf" {
  for_each    = local.legacy_vpc_tag_resources
  resource_id = each.value
  key         = "tf"
  value       = "true"
}
