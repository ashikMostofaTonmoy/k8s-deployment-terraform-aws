# LEGACY access model (access_model = "legacy"): IAM users mapped straight to
# Kubernetes groups. See 11-access-groups.tf for the recommended model.

resource "aws_iam_user" "developer" {
  count = local.legacy_access ? 1 : 0

  name = "demo-developer"
}

resource "aws_iam_policy" "developer_eks" {
  count = local.legacy_access ? 1 : 0

  name = "AmazonEKSDeveloperPolicy"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:DescribeCluster",
                "eks:ListClusters",
                "s3:*"
            ],
            "Resource": "*"
        }
    ]
}
POLICY
}

resource "aws_iam_user_policy_attachment" "developer_eks" {
  count = local.legacy_access ? 1 : 0

  user       = aws_iam_user.developer[0].name
  policy_arn = aws_iam_policy.developer_eks[0].arn
}

resource "aws_eks_access_entry" "developer" {
  count = local.legacy_access ? 1 : 0

  cluster_name      = aws_eks_cluster.eks.name
  principal_arn     = aws_iam_user.developer[0].arn
  kubernetes_groups = ["my-viewer"]
}
