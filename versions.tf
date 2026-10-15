terraform {
  required_version = "~> 1.13.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.69.0"
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
      version = "~> 4.4.1"
    }
  }

  backend "s3" {}
}
