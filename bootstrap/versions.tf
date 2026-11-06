# Uses local state, since the bucket for the remote state doesn't exist yet.
terraform {
  required_version = ">= 1.17.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>6,<7"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = "elsev"
      ManagedBy = "terraform"
    }
  }
}
