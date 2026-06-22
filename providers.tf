provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

provider "aws" {
  alias   = "us-east-1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = var.tags
  }
}

# master payer account (profile=default), used for cross-account NS delegation
provider "aws" {
  alias   = "main"
  region  = "sa-east-1"
  profile = "default"

  default_tags {
    tags = var.tags
  }
}
