resource "aws_ecr_repository" "webapp" {
  name         = "webapp"
  force_delete = true
}

import {
  to = aws_ecr_repository.webapp
  id = "webapp"
}
