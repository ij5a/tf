resource "null_resource" "build_cf_invalidator" {
  count = var.enable_codepipeline && var.enable_lambda && var.enable_cloudfront ? 1 : 0

  triggers = {
    go_mod_sha512 = filesha512("lambda-functions/go/cf-invalidator/go.mod"),
    go_sum_sha512 = filesha512("lambda-functions/go/cf-invalidator/go.sum"),
    code_sha512   = filesha512("lambda-functions/go/cf-invalidator/invalidate.go")
  }

  provisioner "local-exec" {
    command = "make -C lambda-functions/go/cf-invalidator"
  }
}

module "cf_invalidator" {
  count                             = var.enable_codepipeline && var.enable_lambda && var.enable_cloudfront ? 1 : 0
  source                            = var.module_sources.lambda.source
  version                           = var.module_sources.lambda.version
  function_name                     = "${var.tags.project}-${var.tags.environment}-cf-invalidator"
  description                       = "This function invalidates the CloudFront cache."
  handler                           = "bootstrap"
  runtime                           = "provided.al2023"
  memory_size                       = 128
  timeout                           = 30
  cloudwatch_logs_retention_in_days = local.is_prod ? 90 : 7
  create_package                    = false
  local_existing_package            = "lambda-functions/go/cf-invalidator/lambda-handler.zip"
  architectures                     = ["arm64"]
  attach_policy_statements          = true

  policy_statements = {
    cloudfront = {
      effect    = "Allow"
      actions   = ["cloudfront:CreateInvalidation"]
      resources = [module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_arn]
    },

    codepipeline = {
      effect = "Allow"
      actions = [
        "codepipeline:PutJobSuccessResult",
        "codepipeline:PutJobFailureResult"
      ]
      resources = ["*"]
    }
  }

  environment_variables = {
    DISTRIBUTION_ID = module.cdn["${var.tags.project}-${var.tags.environment}"].cloudfront_distribution_id
  }

  depends_on = [null_resource.build_cf_invalidator]
}
