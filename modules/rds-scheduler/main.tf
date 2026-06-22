module "iam_policy" {
  count       = var.enabled ? 1 : 0
  source      = var.module_sources.iam_policy.source
  version     = var.module_sources.iam_policy.version
  name_prefix = "${var.name}-"
  path        = "/"
  description = "IAM policy for ${var.name}."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RdsStartStop"
        Effect = "Allow"
        Action = [
          "rds:StopDBInstance",
          "rds:StartDBInstance"
        ]
        Resource = "*"
      },
      {
        Sid      = "RdsDescribe"
        Effect   = "Allow"
        Action   = ["rds:DescribeDBInstances"]
        Resource = "*"
      },
    ]
  })
}

module "iam_role" {
  count           = var.enabled ? 1 : 0
  source          = var.module_sources.iam_role.source
  version         = var.module_sources.iam_role.version
  name            = "${var.name}-"
  use_name_prefix = true
  description     = "IAM role for ${var.name} to manage RDS instances."

  policies = {
    "RdsScheduler" = module.iam_policy[0].arn
  }

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
      principals = [{
        type = "Service"
        identifiers = [
          "ssm.amazonaws.com",
        ]
      }]
    }
  }
}

resource "aws_resourcegroups_group" "this" {
  count       = var.enabled ? 1 : 0
  name        = "${var.name}-start-stop-resource-group"
  description = "Resource group for RDS instances managed by ${var.name}."

  resource_query {
    query = <<-JSON
    {
      "ResourceTypeFilters": [
        "AWS::RDS::DBInstance"
      ],
      "TagFilters": [
        {
          "Key": "Action",
          "Values": ["StartStop"]
        }
      ]
    }
    JSON
  }
}

locals {
  # Per-action values that differ between start and stop windows/tasks.
  schedule_actions = var.enabled ? {
    start = {
      schedule = var.cron_start_time
      task_arn = "AWS-StartRdsInstance"
    }
    stop = {
      schedule = var.cron_stop_time
      task_arn = "AWS-StopRdsInstance"
    }
  } : {}
}

resource "aws_ssm_maintenance_window" "this" {
  for_each    = local.schedule_actions
  name        = "${var.name}-${each.key}"
  description = "Maintenance window for ${each.key == "start" ? "starting" : "stopping"} RDS instances."
  schedule    = each.value.schedule
  duration    = 1
  cutoff      = 0
}

resource "aws_ssm_maintenance_window_target" "this" {
  for_each      = local.schedule_actions
  window_id     = aws_ssm_maintenance_window.this[each.key].id
  name          = "${var.name}-${each.key}-target"
  description   = "This is the target for the RDS ${each.key} operation."
  resource_type = "RESOURCE_GROUP"

  targets {
    key    = "resource-groups:Name"
    values = [aws_resourcegroups_group.this[0].name]
  }
}

resource "aws_ssm_maintenance_window_task" "this" {
  for_each        = local.schedule_actions
  name            = "${var.name}-${each.key}-task"
  description     = "Task to ${each.key} RDS instances."
  max_concurrency = 2
  max_errors      = 1
  priority        = 1
  task_arn        = each.value.task_arn
  task_type       = "AUTOMATION"
  window_id       = aws_ssm_maintenance_window.this[each.key].id

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.this[each.key].id]
  }

  task_invocation_parameters {
    automation_parameters {
      document_version = "$LATEST"

      parameter {
        name   = "AutomationAssumeRole"
        values = [module.iam_role[0].arn]
      }

      parameter {
        name   = "InstanceId"
        values = ["{{ RESOURCE_ID }}"]
      }
    }
  }
}

moved {
  from = aws_ssm_maintenance_window.start[0]
  to   = aws_ssm_maintenance_window.this["start"]
}

moved {
  from = aws_ssm_maintenance_window.stop[0]
  to   = aws_ssm_maintenance_window.this["stop"]
}

moved {
  from = aws_ssm_maintenance_window_target.start[0]
  to   = aws_ssm_maintenance_window_target.this["start"]
}

moved {
  from = aws_ssm_maintenance_window_target.stop[0]
  to   = aws_ssm_maintenance_window_target.this["stop"]
}

moved {
  from = aws_ssm_maintenance_window_task.start[0]
  to   = aws_ssm_maintenance_window_task.this["start"]
}

moved {
  from = aws_ssm_maintenance_window_task.stop[0]
  to   = aws_ssm_maintenance_window_task.this["stop"]
}
