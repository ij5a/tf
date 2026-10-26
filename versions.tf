terraform {
  required_version = "~> 1.13.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.3.2"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9.1"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4.2"
    }
  }

  backend "s3" {}
}
