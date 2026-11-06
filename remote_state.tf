resource "aws_s3_bucket" "state" {
  bucket = "tbell-elsev-terraform-state"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json
}

import {
  to = aws_s3_bucket.state
  id = "tbell-elsev-terraform-state"
}

import {
  to = aws_s3_bucket_versioning.state
  id = "tbell-elsev-terraform-state"
}

import {
  to = aws_s3_bucket_public_access_block.state
  id = "tbell-elsev-terraform-state"
}

import {
  to = aws_s3_bucket_server_side_encryption_configuration.state
  id = "tbell-elsev-terraform-state"
}

import {
  to = aws_s3_bucket_policy.state
  id = "tbell-elsev-terraform-state"
}
