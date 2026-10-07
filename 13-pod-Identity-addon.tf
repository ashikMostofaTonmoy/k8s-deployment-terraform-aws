resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.eks.name
  addon_name   = "eks-pod-identity-agent"

  # DaemonSet: needs nodes before it can become ACTIVE.
  depends_on = [aws_autoscaling_group.nodes]
}
