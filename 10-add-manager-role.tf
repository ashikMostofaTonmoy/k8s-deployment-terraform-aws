# LEGACY access model (access_model = "legacy"). See 11-access-groups.tf.

resource "aws_iam_role" "eks_admin" {
  count = local.legacy_access ? 1 : 0

  name = "${local.env}-${local.eks_name}-eks-admin"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
    }
  ]
}
POLICY
}

resource "aws_iam_policy" "eks_admin" {
  count = local.legacy_access ? 1 : 0

  name = "AmazonEKSAdminPolicy"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:*"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "iam:PassedToService": "eks.amazonaws.com"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "eks_admin" {
  count = local.legacy_access ? 1 : 0

  role       = aws_iam_role.eks_admin[0].name
  policy_arn = aws_iam_policy.eks_admin[0].arn
}

resource "aws_iam_user" "manager" {
  count = local.legacy_access ? 1 : 0

  name = "manager"
}

resource "aws_iam_policy" "eks_assume_admin" {
  count = local.legacy_access ? 1 : 0

  name = "AmazonEKSAssumeAdminPolicy"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole"
            ],
            "Resource": "${aws_iam_role.eks_admin[0].arn}"
        }
    ]
}
POLICY
}

resource "aws_iam_user_policy_attachment" "manager" {
  count = local.legacy_access ? 1 : 0

  user       = aws_iam_user.manager[0].name
  policy_arn = aws_iam_policy.eks_assume_admin[0].arn
}

# Best practice: use IAM roles due to temporary credentials
resource "aws_eks_access_entry" "manager" {
  count = local.legacy_access ? 1 : 0

  cluster_name      = aws_eks_cluster.eks.name
  principal_arn     = aws_iam_role.eks_admin[0].arn
  kubernetes_groups = ["my-admin"]
}

# for temporary access
resource "aws_eks_access_entry" "manager_user" {
  count = local.legacy_access ? 1 : 0

  cluster_name      = aws_eks_cluster.eks.name
  principal_arn     = aws_iam_user.manager[0].arn
  kubernetes_groups = ["my-admin"]
}
