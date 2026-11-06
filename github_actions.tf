resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# Pull requests can run arbitrary workflow code before review, so they only get
# read access. Admin is limited to workflows running on main.
locals {
  github_actions_subjects = {
    plan  = "repo:${var.github_repository}:pull_request"
    admin = "repo:${var.github_repository}:ref:refs/heads/main"
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
