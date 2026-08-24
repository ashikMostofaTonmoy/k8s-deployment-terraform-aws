# Core addons. Versions are deliberately not pinned: EKS resolves the default
# version for local.eks_version, so a cluster upgrade doesn't fail on an addon
# build that was never published for the new Kubernetes minor.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

# CoreDNS pods stay Pending until there are nodes to schedule them on, so this
# has to come after the node group or the addon lands in DEGRADED.
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.eks.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.general]
}
