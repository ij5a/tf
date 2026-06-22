# default VPC SG for CodeBuild, egress all
data "aws_security_group" "default" {
  filter {
    name   = "vpc-id"
    values = [try(module.vpc[0].vpc_id, var.existing_vpc_details.id)]
  }
  filter {
    name   = "group-name"
    values = ["default"]
  }
}

# trivy:ignore:AVD-AWS-0104
resource "aws_security_group_rule" "egress_allow_all" {
  count             = var.enable_codepipeline ? 1 : 0
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  protocol          = "-1"
  security_group_id = data.aws_security_group.default.id
  to_port           = 65535
  type              = "egress"
  description       = "Allow all egress"
}

resource "aws_iam_role" "this" {
  for_each = var.enable_codepipeline ? toset(["codebuild", "codepipeline"]) : toset([])
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = local.cicd_assume_role_services[each.key] }
    }]
  })
  force_detach_policies = true
  name                  = "${var.tags.project}-${var.tags.environment}-${each.key}"
}

# count-gated so the doc (and its resource refs) isn't evaluated when the pipeline is off
data "aws_iam_policy_document" "codepipeline" {
  count = var.enable_codepipeline ? 1 : 0

  # pass only the ECS task/exec roles, only to ECS — was iam:PassRole on "*" with a weak IfExists guard
  statement {
    sid     = "PassEcsRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = concat(
      [for s in module.ecs_service : s.tasks_iam_role_arn if s.tasks_iam_role_arn != null],
      [for s in module.ecs_service : s.task_exec_iam_role_arn if s.task_exec_iam_role_arn != null],
    )
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "EcrSource"
    effect    = "Allow"
    actions   = ["ecr:DescribeImages", "ecr:GetImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [data.aws_ecr_repository.this.arn]
  }

  statement {
    sid     = "InvokeCodeBuild"
    effect  = "Allow"
    actions = ["codebuild:StartBuild", "codebuild:BatchGetBuilds", "codebuild:StartBuildBatch", "codebuild:BatchGetBuildBatches"]
    # constructed ARN, not the resource attr — the projects depend_on this role policy, so referencing them cycles
    resources = ["arn:aws:codebuild:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:project/${var.tags.project}-${var.tags.environment}-*"]
  }

  # RegisterTaskDefinition/ListTasks have no resource-level scoping; PassRole above is the real guardrail
  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DescribeTasks",
      "ecs:ListTasks",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:TagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "S3Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
    ]
    resources = [
      module.s3_bucket["storage"].s3_bucket_arn,
      "${module.s3_bucket["storage"].s3_bucket_arn}/*",
      module.s3_bucket["spa"].s3_bucket_arn,
      "${module.s3_bucket["spa"].s3_bucket_arn}/*",
    ]
  }

  # the SPA CMK encrypts the artifact store + SPA bucket, so every pipeline needs it
  statement {
    sid       = "KmsArtifacts"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.cmk_s3["spa"].arn]
  }

  # guard matches module.cf_invalidator's count so the [0] ref only resolves when it exists
  dynamic "statement" {
    for_each = var.enable_lambda && var.enable_cloudfront && contains(var.services, "spa") ? [1] : []
    content {
      sid       = "InvokeCfInvalidator"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = [module.cf_invalidator[0].lambda_function_arn]
    }
  }
}

data "aws_iam_policy_document" "codebuild" {
  count = var.enable_codepipeline ? 1 : 0

  statement {
    sid     = "Logs"
    effect  = "Allow"
    actions = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.tags.project}-${var.tags.environment}-*",
      "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.tags.project}-${var.tags.environment}-*:*",
    ]
  }

  # ENI calls for vpc_config don't support resource-level perms, so Resource stays "*"
  statement {
    sid    = "VpcEni"
    effect = "Allow"
    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DescribeDhcpOptions",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "VpcEniPermission"
    effect    = "Allow"
    actions   = ["ec2:CreateNetworkInterfacePermission"]
    resources = ["arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:network-interface/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:AuthorizedService"
      values   = ["codebuild.amazonaws.com"]
    }
  }

  # GetAuthorizationToken has no resource scope, so it gets its own "*" statement
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # replaces the account-wide AmazonEC2ContainerRegistryPowerUser managed policy; the promotion dest
  # repo is added only when the promotion step is on, and still needs a matching policy on the dest account
  statement {
    sid    = "EcrRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = distinct(concat(
      [data.aws_ecr_repository.this.arn],
      var.enable_codepipeline_image_promotion_step ? [local.promotion_dest_ecr_arn] : [],
    ))
  }

  statement {
    sid    = "S3Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
    ]
    resources = [
      module.s3_bucket["storage"].s3_bucket_arn,
      "${module.s3_bucket["storage"].s3_bucket_arn}/*",
    ]
  }

  # storage bucket is aws:kms-encrypted with the SPA CMK — needed to read/write artifacts
  statement {
    sid       = "KmsArtifacts"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.cmk_s3["spa"].arn]
  }
}

locals {
  # codepipeline's role is also assumed by EventBridge — the ECR-push rules trigger the pipeline through it
  cicd_assume_role_services = {
    codebuild    = ["codebuild.amazonaws.com"]
    codepipeline = ["codepipeline.amazonaws.com", "events.amazonaws.com"]
  }

  # one() tolerates the count=0 case so this stays valid when the pipeline is disabled
  cicd_role_policy = {
    codebuild    = one(data.aws_iam_policy_document.codebuild[*].json)
    codepipeline = one(data.aws_iam_policy_document.codepipeline[*].json)
  }

  # parse the promotion dest <acct>.dkr.ecr.<region>.amazonaws.com/<repo> URI into an ARN so the
  # codebuild EcrRepo scope can allow the cross-account push (col-qa/mex-qa promote into prod's repo)
  promotion_dest_ecr_arn = format(
    "arn:aws:ecr:%s:%s:repository/%s",
    split(".", split("/", var.image_promotion_destination_ecr)[0])[3],
    split(".", split("/", var.image_promotion_destination_ecr)[0])[0],
    split("/", var.image_promotion_destination_ecr)[1],
  )
}

resource "aws_iam_role_policy" "this" {
  for_each = var.enable_codepipeline ? toset(["codebuild", "codepipeline"]) : toset([])
  name     = "${var.tags.project}-${var.tags.environment}-${each.key}"
  policy   = local.cicd_role_policy[each.key]
  role     = aws_iam_role.this[each.key].name
}

data "aws_ecr_repository" "this" {
  name = var.image_repository_name
}

# CodePipeline + ECR source via OpenTofu doesn't auto-create the image-push event rule,
# so we create the EventBridge rule + target manually to trigger the pipeline on new pushes.
resource "aws_cloudwatch_event_rule" "ecr_image_push" {
  for_each = var.enable_codepipeline ? toset(var.services) : toset([])
  name     = "${var.tags.project}-${var.tags.environment}-${each.key}-ecr-image-push"
  role_arn = aws_iam_role.this["codepipeline"].arn

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]

    detail = {
      repository-name = [data.aws_ecr_repository.this.name]
      image-tag       = [var.tags.environment == "dev" ? "${var.service_repositories[each.key]}-latest" : "${var.tags.environment}-${var.service_repositories[each.key]}-latest"]
      action-type     = ["PUSH"]
      result          = ["SUCCESS"]
    }
  })
}

resource "aws_cloudwatch_event_target" "ecr_image_push" {
  for_each = var.enable_codepipeline ? toset(var.services) : toset([])
  rule     = aws_cloudwatch_event_rule.ecr_image_push[each.key].name
  arn      = aws_codepipeline.this[each.key].arn
  role_arn = aws_iam_role.this["codepipeline"].arn
}

resource "aws_codebuild_project" "image_promotion" {
  for_each     = var.enable_codepipeline && var.enable_codepipeline_image_promotion_step ? toset(var.services) : toset([])
  name         = "${var.tags.project}-${var.tags.environment}-${each.key}-image-promotion"
  service_role = aws_iam_role.this["codebuild"].arn

  artifacts {
    name           = "${var.tags.project}-${var.tags.environment}-${each.key}-image-promotion-artifacts"
    namespace_type = "BUILD_ID"
    type           = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    buildspec = templatefile("./buildspecs/promote-image.yml", {
      image_promotion_source_environment      = var.image_promotion_source_environment
      image_promotion_destination_environment = var.image_promotion_destination_environment
      image_promotion_source_ecr              = var.image_promotion_source_ecr
      image_promotion_destination_ecr         = var.image_promotion_destination_ecr
      service_repository                      = var.service_repositories[each.key]
    })
    type = "CODEPIPELINE"
  }

  vpc_config {
    vpc_id             = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
    subnets            = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
    security_group_ids = [data.aws_security_group.default.id]
  }

  # CodeBuild CreateProject validates ec2:DescribeSecurityGroups on the role when vpc_config is set.
  # Pin order so the inline policy lands before the project is created.
  depends_on = [
    aws_iam_role_policy.this,
  ]
}

resource "aws_codebuild_project" "this" {
  for_each     = var.enable_codepipeline ? toset(var.services) : toset([])
  name         = "${var.tags.project}-${var.tags.environment}-${each.key}"
  service_role = aws_iam_role.this["codebuild"].arn

  artifacts {
    name           = "${each.key}-artifacts"
    namespace_type = "BUILD_ID"
    type           = "CODEPIPELINE"
  }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true
  }

  source {
    buildspec = each.key == "spa" ? templatefile("./buildspecs/deploy-spa.yml", {
      environment        = var.tags.environment,
      repository_url     = data.aws_ecr_repository.this.repository_url,
      repository_name    = data.aws_ecr_repository.this.name,
      service_repository = var.service_repositories[each.key]
      }) : templatefile("./buildspecs/deploy-image.yml", {
      environment        = var.tags.environment,
      repository_url     = data.aws_ecr_repository.this.repository_url,
      repository_name    = data.aws_ecr_repository.this.name,
      service_repository = var.service_repositories[each.key]
      service_name       = each.key
    })
    type = "CODEPIPELINE"
  }

  vpc_config {
    vpc_id             = try(module.vpc[0].vpc_id, var.existing_vpc_details.id)
    subnets            = try(module.vpc[0].private_subnets, var.existing_vpc_details.private_subnet_ids)
    security_group_ids = [data.aws_security_group.default.id]
  }

  # CodeBuild CreateProject validates ec2:DescribeSecurityGroups on the role when vpc_config is set.
  # Pin order so the inline policy lands before the project is created.
  depends_on = [
    aws_iam_role_policy.this,
  ]
}

resource "aws_codepipeline" "this" {
  for_each      = var.enable_codepipeline ? toset(var.services) : toset([])
  name          = "${var.tags.project}-${var.tags.environment}-${each.key}"
  role_arn      = aws_iam_role.this["codepipeline"].arn
  pipeline_type = "V2"
  artifact_store {
    location = module.s3_bucket["storage"].s3_bucket_id
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "ECR"
      version          = "1"
      output_artifacts = ["source"]
      configuration = {
        RepositoryName = data.aws_ecr_repository.this.name
        ImageTag       = var.tags.environment == "dev" ? "${var.service_repositories[each.key]}-latest" : "${var.tags.environment}-${var.service_repositories[each.key]}-latest"
      }
    }
  }

  # manual approval step (non-dev only)
  dynamic "stage" {
    for_each = var.tags.environment != "dev" ? [1] : []
    content {
      name = "Approval"
      action {
        name     = "Approval"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"
      }
    }
  }

  stage {
    name = "Build"
    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]
      version          = "1"
      run_order        = "1"
      configuration = {
        ProjectName = aws_codebuild_project.this[each.key].name
      }
    }
  }

  stage {
    name = "Deploy"
    action {
      name            = each.key == "spa" ? "DeployToS3" : "DeploytoECS"
      category        = "Deploy"
      owner           = "AWS"
      provider        = each.key == "spa" ? "S3" : "ECS"
      input_artifacts = ["build"]
      version         = "1"
      run_order       = "1"
      configuration = each.key == "spa" ? {
        BucketName = module.s3_bucket["spa"].s3_bucket_id
        Extract    = "true"
        } : {
        ClusterName = "${var.tags.project}-${var.tags.environment}"
        ServiceName = each.key
      }
    }
  }

  dynamic "stage" {
    for_each = each.key == "spa" ? [1] : []
    content {
      name = "CloudFrontInvalidation"
      action {
        name             = "CloudFrontInvalidation"
        category         = "Invoke"
        owner            = "AWS"
        provider         = "Lambda"
        input_artifacts  = ["build"]
        output_artifacts = ["invalidation"]
        version          = "1"
        run_order        = "1"
        configuration = {
          FunctionName = module.cf_invalidator[0].lambda_function_name
        }
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_codepipeline_image_promotion_step ? [1] : []
    content {
      name = "PromoteImageApproval"
      action {
        name     = "Approval"
        category = "Approval"
        owner    = "AWS"
        provider = "Manual"
        version  = "1"
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_codepipeline_image_promotion_step ? [1] : []
    content {
      name = "PromoteImage"
      action {
        name             = "PromoteImage"
        category         = "Build"
        owner            = "AWS"
        provider         = "CodeBuild"
        input_artifacts  = ["source"]
        output_artifacts = ["${var.tags.project}-${var.tags.environment}-${each.key}-image-promotion-artifacts"]
        version          = "1"
        run_order        = "1"
        configuration = {
          ProjectName = aws_codebuild_project.image_promotion[each.key].name
        }
      }
    }
  }
}
