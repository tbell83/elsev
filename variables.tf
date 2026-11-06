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
