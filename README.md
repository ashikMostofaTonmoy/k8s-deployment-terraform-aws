# Terraform AWS EKS Deployment

This repository provisions a Kubernetes platform on AWS using Terraform. It creates the network layer, an Amazon EKS cluster, a managed node group, IAM access entries, storage integrations, and a small set of operational add-ons installed with Helm.

The current default configuration builds a development environment in `ap-northeast-2` with the cluster name `development-demo`.

## What This Project Creates

- A dedicated VPC with public and private subnets across two availability zones
- Internet gateway, NAT gateway, route tables, and subnet associations
- An Amazon EKS control plane
- One EKS managed node group for general workloads
- IAM users, roles, and EKS access entries for developer and manager access
- EKS Pod Identity Agent
- Metrics Server
- Cluster Autoscaler
- AWS Load Balancer Controller
- NGINX Ingress Controller
- Amazon EBS CSI driver and a default `gp3` storage class
- Amazon EFS file system, EFS CSI driver, and an `efs` storage class

## Architecture Summary

The infrastructure is organized in a straightforward build order:

1. Networking: VPC, subnets, internet gateway, NAT gateway, and routing
2. Compute: EKS control plane and managed worker nodes
3. Access: IAM users, IAM roles, and EKS access entries
4. Platform add-ons: Helm charts and AWS-managed EKS add-ons
5. Storage: EBS and EFS integrations for persistent workloads

## Repository Structure

- `0-locals.tf`: environment, AWS region, AZs, cluster name, and Kubernetes version
- `1-providers.tf`: Terraform version and AWS/Kubernetes providers
- `2-vpc.tf` to `6-routes.tf`: networking resources
- `7-eks.tf`: EKS control plane
- `8-nodes.tf`: EKS managed node group
- `9-add-developer-user.tf`: developer IAM user and EKS viewer access
- `10-add-manager-role.tf`: admin role, manager IAM user, and admin access mappings
- `11-helm-provider.tf`: Helm provider configuration
- `12-metrics-server.tf`: Metrics Server Helm release
- `13-pod-Identity-addon.tf`: EKS Pod Identity Agent add-on
- `14-cluster-autoscaler.tf`: Cluster Autoscaler IAM and Helm release
- `15-aws-lbc.tf`: AWS Load Balancer Controller IAM and Helm release
- `16-nginx-ingress.tf`: NGINX Ingress Controller Helm release
- `17-cert-manager.tf`: optional cert-manager example, currently commented out
- `18-ebs-csi-driver.tf`: EBS CSI driver and default `gp3` storage class
- `19-openid-connect-provider.tf`: OIDC provider for IRSA-style integrations
- `20-efs.tf`: EFS resources, CSI driver, and `efs` storage class
- `values/`: Helm values files
- `iam/AWSLoadBalancerController.json`: IAM policy document for AWS Load Balancer Controller

## Default Configuration

The current values in `0-locals.tf` are:

- Environment: `development`
- AWS region: `ap-northeast-2`
- Availability zones: `ap-northeast-2a`, `ap-northeast-2b`
- Cluster name: `development-demo`
- Kubernetes version: `1.33`

## Prerequisites

Before applying this project, make sure you have:

- Terraform `>= 1.0`
- AWS CLI installed and configured
- `kubectl` installed
- Helm installed
- An AWS CLI profile configured for your own AWS account
- Sufficient AWS permissions to create VPC, EKS, IAM, EC2, EFS, and related resources

## Important Notes Before You Apply

- The AWS provider is currently hardcoded to use the `ostad` profile in `1-providers.tf`. Update this to your own AWS CLI profile before running Terraform.
- The node group is configured as `SPOT` with instance type `t3a.xlarge`.
- The node group's desired size is ignored by Terraform after creation, which is useful if Cluster Autoscaler changes it.
- `cert-manager` exists only as a commented example and is not deployed.
- The Cluster Autoscaler chart currently sets `awsRegion = ap-southeast-1`, while the rest of the project defaults to `ap-northeast-2`. This should be corrected before production use in `14-cluster-autoscaler.tf`.

## Local Environment Checks

Before deployment, verify that your local machine can access AWS and pull Helm charts.

### 1. Confirm Your AWS Profile

List your available AWS CLI profiles:

```bash
aws configure list-profiles
```

Then update `1-providers.tf` to use the profile you want for deployment.

### 2. Verify Helm Repository Access

Add and refresh the required Helm repositories:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add eks https://aws.github.io/eks-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update
```

If `helm repo update` completes successfully, your machine can reach the chart repositories used by this project.

## Deployment Steps

### 1. Initialize Terraform

```bash
terraform init
```

### 2. Review the Plan

```bash
terraform plan
```

### 3. Apply the Infrastructure

```bash
terraform apply
```

## Configure kubectl

After the cluster is created, update your kubeconfig:

```bash
aws eks update-kubeconfig --region ap-northeast-2 --name development-demo --profile ostad --alias development-demo
```

Replace `ostad` with your own AWS CLI profile name.

Then verify access:

```bash
kubectl get nodes
kubectl get pods -A
```

## Installed Add-ons

### Metrics Server

- Installed into `kube-system`
- Uses custom values from `values/metrics-server.yaml`

### EKS Pod Identity Agent

- Installed as an AWS-managed EKS add-on
- Used by add-ons such as Cluster Autoscaler and AWS Load Balancer Controller

### Cluster Autoscaler

- Installed into `kube-system`
- Uses Pod Identity with a dedicated IAM role
- Automatically discovers the cluster by name

### AWS Load Balancer Controller

- Installed into `kube-system`
- Uses a custom IAM policy from `iam/AWSLoadBalancerController.json`
- Enables AWS load balancer integration for Kubernetes services and ingresses

### NGINX Ingress Controller

- Installed into namespace `ingress`
- Uses custom values from `values/nginx-ingress.yaml`
- Configured with an internet-facing NLB service
- Sets `external-nginx` as the default ingress class

## Storage

### EBS

The project installs the AWS EBS CSI driver and creates a default storage class:

- Storage class name: `gp3`
- Provisioner: `ebs.csi.aws.com`
- Expansion enabled: `true`
- Binding mode: `WaitForFirstConsumer`

### EFS

The project also provisions an encrypted EFS file system and installs the EFS CSI driver:

- Storage class name: `efs`
- Provisioner: `efs.csi.aws.com`
- Provisioning mode: `efs-ap`

Use `gp3` for regular block storage and `efs` for shared file storage across pods.

## Access Model

This repository creates two example access paths:

- Developer user: `demo-developer`
  - Attached policy allows EKS describe/list actions and S3 access
  - Added to Kubernetes group `my-viewer`
- Manager user: `manager`
  - Can assume the EKS admin IAM role
  - Also mapped directly to Kubernetes group `my-admin` for temporary access

These Kubernetes groups only become meaningful if you bind them to Kubernetes RBAC roles inside the cluster.

## Customization

The most common things to change are:

- Environment name in `0-locals.tf`
- Region and availability zones in `0-locals.tf`
- Cluster name and Kubernetes version in `0-locals.tf`
- Node instance type, capacity type, disk size, and scaling settings in `8-nodes.tf`
- AWS profile in `1-providers.tf`
- Helm chart values in the `values/` directory

## Useful Commands

```bash
terraform fmt
terraform validate
terraform plan
kubectl get nodes
kubectl get storageclass
helm list -A
```

## Cleanup

To remove all created infrastructure:

```bash
terraform destroy
```

If ingress-related resources block cleanup, destroy the ingress release first:

```bash
terraform destroy --target helm_release.external_nginx
terraform destroy
```

## Future Improvements

- Move hardcoded values such as AWS profile and autoscaler region into variables
- Add outputs for cluster name, endpoint, and kubeconfig command
- Replace inline IAM JSON with reusable policy documents where practical
- Add Kubernetes RBAC manifests for `my-viewer` and `my-admin`
- Optionally enable `cert-manager`

## License

This project is licensed under the MIT License. See the `LICENSE` file for details.
