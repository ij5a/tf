#---------------------------------------------------------------
# TFLint configuration
# https://github.com/terraform-linters/tflint
#---------------------------------------------------------------
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.38.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

#---------------------------------------------------------------
# Disabled rules
# terraform_module_pinned_source: Disabled because OpenTofu 1.10+
# supports variables in module source via static evaluation, but
# tflint doesn't recognize this feature yet.
#---------------------------------------------------------------
rule "terraform_module_pinned_source" {
  enabled = false
}
