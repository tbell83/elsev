resource "aws_ecr_repository" "webapp" {
  name = "webapp"
}

import {
  to = aws_ecr_repository.webapp
  id = "webapp"
}
