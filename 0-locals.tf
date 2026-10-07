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

variable "access_model" {
  description = "How people get into the cluster. \"groups\" (default, recommended): IAM groups -> IAM roles -> EKS access policies. \"legacy\": IAM users mapped to Kubernetes groups (files 9 and 10)."
  type        = string
  default     = "groups"

  validation {
    condition     = contains(["groups", "legacy"], var.access_model)
    error_message = "access_model must be \"groups\" or \"legacy\"."
  }
}

variable "eks_viewer_users" {
  description = "IAM users to create and place in the viewers group (read-only cluster access). Only used when access_model = \"groups\"."
  type        = list(string)
  default     = ["demo-viewer"]
}

variable "eks_admin_users" {
  description = "IAM users to create and place in the admins group (cluster-admin). Only used when access_model = \"groups\"."
  type        = list(string)
  default     = ["demo-admin"]
}

locals {
  legacy_access = var.access_model == "legacy"
  groups_access = var.access_model == "groups"
}

data "aws_caller_identity" "current" {}

variable "enable_spot_nodes" {
  description = "Also create a Spot node group (1 node) next to the On-Demand one. Needs Spot capacity in the account."
  type        = bool
  default     = false
}

variable "enable_managed_node_groups" {
  description = "Also create EKS managed node groups (On-Demand + Spot, 1 node each). Needs the EC2 Fleet API and Spot capacity in the account."
  type        = bool
  default     = false
}
