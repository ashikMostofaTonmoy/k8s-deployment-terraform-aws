resource "aws_iam_role" "nodes" {
  name = "${local.env}-${local.eks_name}-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Lets you open a shell on a node with `aws ssm start-session` instead of
    # running a bastion host. Invaluable when nodes fail to join.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  policy_arn = each.value
  role       = aws_iam_role.nodes.name
}

resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.eks.name
  version         = local.eks_version
  node_group_name = "general"
  node_role_arn   = aws_iam_role.nodes.arn

  subnet_ids = [
    aws_subnet.private_zone1.id,
    aws_subnet.private_zone2.id
  ]

  # AL2 EKS AMIs stopped being published on 2025-11-26, so every node group is
  # AL2023 now. AL2023 needs a Nitro instance (ENA + NVMe): previous-generation
  # Xen types such as t2.* boot but never join the cluster.
  ami_type = "AL2023_x86_64_STANDARD"

  # EXACTLY ONE instance type. More than one makes EKS build the ASG with a
  # MixedInstancesPolicy, which launches via the EC2 Fleet API (CreateFleet)
  # instead of RunInstances -- and this account is capped there
  # ("You've reached your quota for maximum Fleet Requests for this account").
  # Nitro is also mandatory: AL2023 is the only AMI family left and it needs
  # ENA + NVMe, so previous-generation Xen types such as t2.* never join.
  capacity_type  = "ON_DEMAND"
  instance_types = ["t3a.large"]

  # Spot needs several types to be useful, so it stays blocked until the Fleet
  # Requests limit is raised.
  # capacity_type  = "SPOT"
  # instance_types = ["t3a.large", "t3.large", "m6a.large", "m5.large"]

  disk_size = 100

  scaling_config {
    desired_size = 2
    max_size     = 10
    min_size     = 0
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "general"
  }

  tags = {
    Name = "${local.env}-${local.eks_name}-general"
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    # Nodes report NotReady until the CNI is present.
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  # Allow external changes (cluster-autoscaler) without a plan difference
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# NOTE: no aws_eks_access_entry for the node role. EKS creates the EC2_LINUX
# access entry for a managed node group's role by itself; declaring it here
# races with that and fails with ResourceInUseException.
