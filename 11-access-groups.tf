# RECOMMENDED access model (access_model = "groups").
#
#   IAM user --member of--> IAM group --may assume--> IAM role --access entry-->
#   EKS access policy (View / ClusterAdmin)
#
# Grant access  : add the user to the IAM group.
# Revoke access : remove the user from the IAM group (an already-issued role
#                 session ends within max_session_duration).
# No Kubernetes groups and no RBAC bindings are needed: EKS access policies
# carry the permissions. People never get their own access entry.

locals {
  access_roles = local.groups_access ? {
    viewer = { policy = "AmazonEKSViewPolicy", users = var.eks_viewer_users }
    admin  = { policy = "AmazonEKSClusterAdminPolicy", users = var.eks_admin_users }
  } : {}

  access_user_groups = local.groups_access ? merge(
    { for u in var.eks_viewer_users : u => "viewer" },
    { for u in var.eks_admin_users : u => "admin" },
  ) : {}
}

resource "aws_iam_role" "cluster_access" {
  for_each = local.access_roles

  name                 = "${local.env}-${local.eks_name}-cluster-${each.key}"
  max_session_duration = 3600

  # Trust the account; WHO may assume it is decided by the group policy below.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
    }]
  })
}

# Just enough AWS permission to run `aws eks update-kubeconfig`. What the person
# can do INSIDE the cluster comes from the access policy, not from here.
resource "aws_iam_role_policy" "cluster_access" {
  for_each = local.access_roles

  name = "describe-cluster"
  role = aws_iam_role.cluster_access[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.eks.arn
    }]
  })
}

resource "aws_eks_access_entry" "cluster_access" {
  for_each = local.access_roles

  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.cluster_access[each.key].arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "cluster_access" {
  for_each = local.access_roles

  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.cluster_access[each.key].arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/${each.value.policy}"

  # For least privilege use type = "namespace" and
  # namespaces = ["dev", "demo"] instead of cluster-wide access.
  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cluster_access]
}

resource "aws_iam_group" "cluster_access" {
  for_each = local.access_roles

  name = "${local.env}-${local.eks_name}-${each.key}s"
}

resource "aws_iam_group_policy" "cluster_access" {
  for_each = local.access_roles

  name  = "assume-${each.key}-role"
  group = aws_iam_group.cluster_access[each.key].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.cluster_access[each.key].arn
    }]
  })
}

# Demo users. In a real account these usually exist already (or come from
# IAM Identity Center); then drop this resource and manage only the membership.
resource "aws_iam_user" "cluster_access" {
  for_each = local.access_user_groups

  name = each.key
}

resource "aws_iam_user_group_membership" "cluster_access" {
  for_each = local.access_user_groups

  user   = aws_iam_user.cluster_access[each.key].name
  groups = [aws_iam_group.cluster_access[each.value].name]
}

output "cluster_access_roles" {
  description = "Role ARNs people assume to use kubectl (access_model = groups)."
  value       = { for k, r in aws_iam_role.cluster_access : k => r.arn }
}
