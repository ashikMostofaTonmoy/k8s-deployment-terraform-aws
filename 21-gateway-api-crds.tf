# Gateway API CRDs (standard channel, vendored in gateway-api/). Helm cannot
# own these cleanly, so apply them with kubectl server-side (the bundle is
# >1MB, too big for client-side apply's last-applied annotation).
#
# They must exist BEFORE the AWS Load Balancer Controller and cert-manager
# start: both only enable their Gateway controllers if the CRDs are present
# at startup. Needs `aws` and `kubectl` on the machine running terraform.
resource "terraform_data" "gateway_api_crds" {
  triggers_replace = [filemd5("${path.module}/gateway-api/standard-install.yaml")]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --name ${aws_eks_cluster.eks.name} --region ${local.region} --profile ostad --kubeconfig ${path.module}/.terraform/kubeconfig && kubectl --kubeconfig ${path.module}/.terraform/kubeconfig apply --server-side --force-conflicts -f ${path.module}/gateway-api/standard-install.yaml"
  }

  depends_on = [aws_autoscaling_group.nodes]
}
