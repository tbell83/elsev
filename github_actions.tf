resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Pull requests can run arbitrary workflow code before review, so they only get
# read access. Admin and the site check are limited to workflows running on main.
locals {
  github_actions_subjects = {
    plan       = "repo:${var.github_repository}:pull_request"
    admin      = "repo:${var.github_repository}:ref:refs/heads/main"
    site_check = "repo:${var.github_repository}:ref:refs/heads/main"
  }
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  for_each = local.github_actions_subjects

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "github_actions_plan" {
  name               = "${var.name}-github-actions-plan"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role["plan"].json
}

# Also covers reading the state bucket and the lock table's state digest.
resource "aws_iam_role_policy_attachment" "github_actions_plan_read_only" {
  role       = aws_iam_role.github_actions_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role["admin"].json
}

resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role" "github_actions_site_check" {
  name               = "${var.name}-github-actions-site-check"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role["site_check"].json
}

# Commands run as root on the bastion, so this allows only the site check
# document rather than AWS-RunShellScript or an interactive session.
data "aws_iam_policy_document" "github_actions_site_check" {
  statement {
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.bastion.arn,
      aws_ssm_document.site_check.arn,
    ]
  }

  # These actions don't support resource-level permissions.
  statement {
    actions = [
      "ec2:DescribeInstances",
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_site_check" {
  name   = "site-check"
  role   = aws_iam_role.github_actions_site_check.id
  policy = data.aws_iam_policy_document.github_actions_site_check.json
}
