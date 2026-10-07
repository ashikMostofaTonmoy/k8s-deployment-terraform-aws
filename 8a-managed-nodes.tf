# ---------------------------------------------------------------------------
# OPTIONAL: EKS MANAGED NODE GROUPS (enable_managed_node_groups)
#
# The "normal" way to run nodes, for accounts where EC2 Fleet works. AWS
# creates the access entry, security group and bootstrap for you and drains
# nodes on upgrade. Same labels as above (capacity=on-demand | spot), so the
# examples and nodeSelectors work unchanged. Off by default because in a
# Fleet-blocked account these groups stay CREATING forever (see README).
#
# Do not run these AND the self-managed groups for the same workload unless you
# want both; set desired size 0 on one of them if you switch over.
# ---------------------------------------------------------------------------

locals {
  managed_node_groups = var.enable_managed_node_groups ? {
    on-demand = {
      capacity_type  = "ON_DEMAND"
      instance_types = ["t3a.large"]
      max_size       = 10
    }
    spot = {
      capacity_type = "SPOT"
      # Several types: Spot capacity is per instance type, so more types means
      # fewer interruptions and failed launches.
      instance_types = ["t3a.large", "t3.large", "m5a.large"]
      max_size       = 5
    }
  } : {}
}

resource "aws_eks_node_group" "managed" {
  for_each = local.managed_node_groups

  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "${each.key}-managed"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [aws_subnet.private_zone1.id, aws_subnet.private_zone2.id]

  capacity_type  = each.value.capacity_type
  instance_types = each.value.instance_types
  disk_size      = 100

  scaling_config {
    desired_size = 1
    min_size     = 0
    max_size     = each.value.max_size
  }

  labels = {
    role     = "general"
    capacity = each.key
  }

  lifecycle {
    # Cluster Autoscaler changes the size at runtime.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}
