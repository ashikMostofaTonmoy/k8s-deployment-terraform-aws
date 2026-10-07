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
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Lets you open a shell on a node with `aws ssm start-session` instead of
    # running a bastion host. Invaluable when nodes fail to join.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  policy_arn = each.value
  role       = aws_iam_role.nodes.name
}

# ---------------------------------------------------------------------------
# SELF-MANAGED NODES
#
# This account cannot call the EC2 Fleet API -- every attempt returns
# "MaxFleetCountExceeded", with zero fleets in existence, in every region.
# An EKS *managed* node group is unusable here because EKS always builds its
# ASG with a MixedInstancesPolicy (confirmed: it does so even with a single
# instance type), and a MixedInstancesPolicy launches via CreateFleet.
#
# A plain ASG with a launch template and no mixed-instances policy launches
# via RunInstances instead, which this account can do.
#
# Switch back to aws_eks_node_group once AWS Support raises the EC2 Fleet
# limit -- it is less code and handles the access entry and bootstrap for you.
# ---------------------------------------------------------------------------

resource "aws_iam_instance_profile" "nodes" {
  name = "${local.env}-${local.eks_name}-eks-nodes"
  role = aws_iam_role.nodes.name
}

data "aws_ami" "eks_node" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amazon-eks-node-al2023-x86_64-standard-${local.eks_version}-*"]
  }
}

# A managed node group creates this for its role automatically. A self-managed
# one does not, and without it kubelet cannot authenticate to an API-auth
# cluster -- the nodes boot fine and simply never register.
resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.nodes.arn
  type          = "EC2_LINUX"
}

locals {
  # One user-data document per capacity type; only the node label differs, so
  # pods can pick a pool with nodeSelector `capacity: on-demand | spot`.
  node_user_data = {
    for capacity in ["on-demand", "spot"] : capacity => base64encode(<<-EOT
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="//"

      --//
      Content-Type: application/node.eks.aws

      ---
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        cluster:
          name: ${aws_eks_cluster.eks.name}
          apiServerEndpoint: ${aws_eks_cluster.eks.endpoint}
          certificateAuthority: ${aws_eks_cluster.eks.certificate_authority[0].data}
          cidr: ${aws_eks_cluster.eks.kubernetes_network_config[0].service_ipv4_cidr}
        kubelet:
          flags:
            - --node-labels=role=general,capacity=${capacity}

      --//--
    EOT
    )
  }
}

resource "aws_launch_template" "nodes" {
  name_prefix   = "${local.env}-${local.eks_name}-general-"
  image_id      = data.aws_ami.eks_node.id
  instance_type = "t3a.large"

  iam_instance_profile {
    arn = aws_iam_instance_profile.nodes.arn
  }

  # Without this, nodes land in the VPC default SG. The cluster has private
  # endpoint access on, so the API server resolves to ENIs guarded by the
  # cluster SG -- nodes outside it can never register. Managed node groups
  # attach this SG automatically; self-managed ones must do it by hand.
  vpc_security_group_ids = [aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # keep pods away from node credentials
    http_endpoint               = "enabled"
  }

  # AL2023 boots through nodeadm, which needs the cluster details up front --
  # it deliberately does not call DescribeCluster the way AL2 did.
  user_data = local.node_user_data["on-demand"]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.env}-${local.eks_name}-general"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "nodes" {
  name_prefix = "${local.env}-${local.eks_name}-general-"

  vpc_zone_identifier = [
    aws_subnet.private_zone1.id,
    aws_subnet.private_zone2.id
  ]

  desired_capacity = 1
  max_size         = 10
  min_size         = 0

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # NOTE: no mixed_instances_policy block. Adding one routes launches through
  # CreateFleet, which is exactly what is blocked in this account.
  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  dynamic "tag" {
    for_each = {
      "Name"                                                  = "${local.env}-${local.eks_name}-general"
      "kubernetes.io/cluster/${aws_eks_cluster.eks.name}"     = "owned"
      "k8s.io/cluster-autoscaler/enabled"                     = "true"
      "k8s.io/cluster-autoscaler/${aws_eks_cluster.eks.name}" = "owned"
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_eks_access_entry.nodes,
    # Nodes report NotReady until the CNI is present.
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  # Allow cluster-autoscaler to change this without a plan difference
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# ---------------------------------------------------------------------------
# SPOT NODE GROUP
#
# Same recipe, but the launch template asks for Spot capacity. Spot is up to
# ~70% cheaper, but AWS can reclaim the instance with 2 minutes' notice, so run
# only interruption-tolerant pods here (pick it with nodeSelector capacity=spot).
# Still no mixed_instances_policy: that would route through CreateFleet.
#
# Off by default (enable_spot_nodes). Some accounts have no Spot capacity
# until AWS raises the limit: launches fail with "Max spot instance count
# exceeded" even though Service Quotas shows 32. Test with:
#   aws ec2 run-instances ... --instance-market-options MarketType=spot
# ---------------------------------------------------------------------------

resource "aws_launch_template" "spot" {
  count = var.enable_spot_nodes ? 1 : 0

  name_prefix   = "${local.env}-${local.eks_name}-spot-"
  image_id      = data.aws_ami.eks_node.id
  instance_type = "t3a.large"

  iam_instance_profile {
    arn = aws_iam_instance_profile.nodes.arn
  }

  vpc_security_group_ids = [aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id]

  instance_market_options {
    market_type = "spot"

    spot_options {
      spot_instance_type = "one-time"
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  user_data = local.node_user_data["spot"]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.env}-${local.eks_name}-spot"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "spot" {
  count = var.enable_spot_nodes ? 1 : 0

  name_prefix = "${local.env}-${local.eks_name}-spot-"

  vpc_zone_identifier = [
    aws_subnet.private_zone1.id,
    aws_subnet.private_zone2.id
  ]

  desired_capacity = 1
  max_size         = 5
  min_size         = 0

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.spot[0].id
    version = aws_launch_template.spot[0].latest_version
  }

  dynamic "tag" {
    for_each = {
      "Name"                                                  = "${local.env}-${local.eks_name}-spot"
      "kubernetes.io/cluster/${aws_eks_cluster.eks.name}"     = "owned"
      "k8s.io/cluster-autoscaler/enabled"                     = "true"
      "k8s.io/cluster-autoscaler/${aws_eks_cluster.eks.name}" = "owned"
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_eks_access_entry.nodes,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}
