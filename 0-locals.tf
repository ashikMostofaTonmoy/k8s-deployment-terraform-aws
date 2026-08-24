locals {
  env         = "development"
  region      = "ap-south-1"
  zone1       = "ap-south-1a"
  zone2       = "ap-south-1b"
  eks_name    = "demo"
  eks_version = "1.36"

  # Public API server access. Narrow this to your office/VPN egress IPs before
  # using the cluster for anything real.
  api_allowed_cidrs = ["0.0.0.0/0"]
}
