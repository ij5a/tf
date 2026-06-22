resource "aws_vpc_peering_connection" "new_to_old_vpc" {
  peer_owner_id = var.legacy_db_redis_server_details.vpc.owner_id
  peer_vpc_id   = var.legacy_db_redis_server_details.vpc.id
  vpc_id        = var.new_vpc_id
  auto_accept   = true
}

resource "aws_route" "old_to_new_vpc" {
  count                     = length(var.legacy_db_redis_server_details.vpc.rt_ids)
  route_table_id            = var.legacy_db_redis_server_details.vpc.rt_ids[count.index]
  destination_cidr_block    = var.new_vpc_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.new_to_old_vpc.id
}

resource "aws_route" "new_to_old_vpc" {
  count                     = length(var.new_vpc_private_route_table_ids)
  route_table_id            = var.new_vpc_private_route_table_ids[count.index]
  destination_cidr_block    = var.legacy_db_redis_server_details.vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.new_to_old_vpc.id
}

# ingress on legacy DB/Redis SGs permitting the new VPC CIDR
locals {
  sg_rules = merge(
    var.use_legacy_db ? {
      "db" = {
        port  = 3306
        sg_id = var.legacy_db_redis_server_details.db.sg_id
      }
    } : {},
    var.use_legacy_redis ? {
      "redis" = {
        port  = 6379
        sg_id = var.legacy_db_redis_server_details.redis.sg_id
      }
    } : {}
  )
}

resource "aws_security_group_rule" "ingress_new_vpc" {
  for_each          = local.sg_rules
  type              = "ingress"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = "tcp"
  cidr_blocks       = [var.new_vpc_cidr_block]
  security_group_id = each.value.sg_id
  description       = "Allow traffic from the new VPC - ${var.new_vpc_cidr_block} (${var.new_vpc_id})"
}
