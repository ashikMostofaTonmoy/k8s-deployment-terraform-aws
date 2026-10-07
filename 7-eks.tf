resource "aws_iam_role" "eks" {
  name = "${local.env}-${local.eks_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "eks.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicyV2",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy",
  ])

  policy_arn = each.value
  role       = aws_iam_role.eks.name
}

# Keep existing state: single attachment became for_each.
moved {
  from = aws_iam_role_policy_attachment.eks
  to   = aws_iam_role_policy_attachment.eks["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"]
}

# Create the log group ourselves so it carries a retention period. If EKS
# creates it, the logs are kept forever and quietly cost money.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.env}-${local.eks_name}/cluster"
  retention_in_days = 14
}

resource "aws_eks_cluster" "eks" {
  name     = "${local.env}-${local.eks_name}"
  version  = local.eks_version
  role_arn = aws_iam_role.eks.arn

  # We manage vpc-cni / kube-proxy / coredns as addons in 7a-core-addons.tf.
  bootstrap_self_managed_addons = false

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  vpc_config {
    # Nodes reach the API server over the VPC instead of hairpinning through
    # the NAT gateway; public access stays on so kubectl works from a laptop.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = local.api_allowed_cidrs

    subnet_ids = [
      aws_subnet.private_zone1.id,
      aws_subnet.private_zone2.id
    ]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks,
    aws_cloudwatch_log_group.eks,
  ]
}
