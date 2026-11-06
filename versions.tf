terraform {
  required_version = ">= 1.17.1"

  backend "s3" {
    bucket         = "terraform-state-tbell-elsev" # this is the bucket created when bootstrapping the remote state
    key            = "tbell83/elsev/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~>6,<7"
    }
  }
}

provider "aws" {
  default_tags {
    tags = {
      Project   = "elsev"
      ManagedBy = "terraform"
    }
  }
}
