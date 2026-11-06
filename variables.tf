variable "name" {
  description = "Prefix for resource names."
  type        = string
  default     = "elsev"
}

variable "github_repository" {
  description = "GitHub repository, as owner/name, allowed to assume the GitHub Actions roles."
  type        = string
  default     = "tbell83@4740866/elsev@1447778563" # you have to include the full subject claim or the role assumption will fail
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. The AMI is x86_64, so this must be an x86_64 type."
  type        = string
  default     = "t2.micro"
}

# Network
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public subnets. An ALB requires subnets in at least two AZs, so exactly two are expected."
  type        = list(string)
  default     = ["10.10.0.0/24", "10.10.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Exactly two public subnet CIDRs are required."
  }
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet that hosts the EC2 instances."
  type        = string
  default     = "10.10.10.0/24"
}

