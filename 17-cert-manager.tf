resource "helm_release" "cert_manager" {
  name = "cert-manager"

  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.21.2"

  # helm provider v3: `set` is a list attribute, not a repeated block.
  set = [
    {
      # `installCRDs` was removed; this is the current flag.
      name  = "crds.enabled"
      value = "true"
    },
    {
      # Lets cert-manager issue certs for Gateway listeners.
      name  = "config.enableGatewayAPI"
      value = "true"
    },
  ]

  depends_on = [
    helm_release.external_nginx,
    terraform_data.gateway_api_crds,
  ]
}
