# pr/authenticator/eg/apigw consume raw file contents (JSON/YAML); other services get key-value secrets elsewhere
module "secrets_manager" {
  source        = var.module_sources.secrets_manager.source
  version       = var.module_sources.secrets_manager.version
  for_each      = var.enable_ecs ? toset([for service in var.services : service if service == "pr" || service == "authenticator" || service == "eg" || strcontains(service, "apigw")]) : toset([])
  name_prefix   = "${var.tags.project}-${var.tags.environment}-${each.key}-"
  description   = "Config for ${var.tags.project}-${var.tags.environment}-${each.key}"
  secret_string = strcontains(each.key, "apigw") ? file("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.yaml") : file("service-configs/${var.tags.project}-${var.tags.environment}/${each.key}.json")
}
