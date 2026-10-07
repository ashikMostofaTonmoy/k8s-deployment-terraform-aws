# Terraform AWS EKS Deployment

A complete, working Kubernetes platform on AWS, built with Terraform: network, cluster, worker nodes, user access, autoscaling, load balancing (Ingress **and** Gateway API), TLS tooling and storage. Every step also has a **Console** version, so you can build or inspect the same thing by clicking through the AWS web console.

**Who it is for:** anyone learning EKS, from first-time students to engineers who want a reference setup. It is a *development/learning* environment. Section 9 lists what to change before using it for production.

**What you will have at the end:** a cluster with 2 worker nodes that scale automatically, two public load balancers serving a demo app, and the tooling to issue TLS certificates and attach disks.

## Contents

1. [How it fits together](#how-it-fits-together)
2. [Before you start](#before-you-start)
3. [Deploy](#1-deploy)
4. [Access for people](#2-access-for-people)
5. [Platform add-ons](#3-platform-add-ons)
6. [Test Ingress and Gateway API](#4-test-ingress-and-gateway-api)
7. [Autoscaling: pods and nodes](#5-autoscaling-pods-and-nodes)
8. [Storage](#6-storage)
9. [Customization](#7-customization)
10. [Troubleshooting](#8-troubleshooting)
11. [Production hardening checklist](#9-production-hardening-checklist)
12. [Cleanup](#10-cleanup)

---

## How it fits together

```mermaid
flowchart TB
    user([Internet users])

    subgraph aws["AWS region"]
        subgraph vpc["VPC 10.0.0.0/16"]
            subgraph pub["Public subnets (2 AZs)"]
                nlb["NLB<br/>(ingress-nginx)"]
                alb["ALB<br/>(Gateway API)"]
                nat["NAT gateway"]
            end
            subgraph priv["Private subnets (2 AZs)"]
                subgraph nodes["Worker nodes - EC2 Auto Scaling group"]
                    nginx["nginx pods"]
                    apps["your app pods"]
                    ctrl["controllers:<br/>LBC, autoscaler,<br/>cert-manager"]
                end
                efs[("EFS / EBS<br/>storage")]
            end
        end
        cp["EKS control plane<br/>(managed by AWS)"]
    end

    user --> nlb --> nginx --> apps
    user --> alb --> apps
    nodes -. outbound via .-> nat
    nodes <-->|private endpoint| cp
    apps --- efs
    ctrl -. "creates and manages" .-> nlb
    ctrl -. "creates and manages" .-> alb
```

Key ideas, in plain words:

| Term | Meaning |
|---|---|
| **EKS control plane** | The Kubernetes "brain" (API server, scheduler). AWS runs and patches it for you. |
| **Worker nodes** | The EC2 machines that actually run your containers (pods). |
| **Public / private subnet** | Public subnets host load balancers and the NAT gateway. Nodes live in private subnets, not directly reachable from the internet; the NAT gateway lets them download images. |
| **Add-on** | Extra software the cluster needs (networking, DNS, storage drivers). Either an *EKS add-on* (AWS-managed, installed by API) or a *Helm chart* (community, installed with `helm`). |
| **Ingress / Gateway API** | Two ways to describe "send web traffic for X to my service". Ingress is the older, widely used one; Gateway API is the newer, more expressive standard. |
| **Pod Identity** | Gives a single pod its own AWS permissions, instead of giving every node broad permissions. |
| **Access entry** | How EKS decides which AWS identity (user/role) may log in to the cluster. |
| **HPA vs Cluster Autoscaler** | HPA adds/removes *pods* based on CPU. Cluster Autoscaler adds/removes *nodes* when pods do not fit. |

## What gets created

| Layer | Resources | File |
|---|---|---|
| Network | VPC `10.0.0.0/16`, 2 public + 2 private subnets, internet gateway, 1 NAT gateway, route tables | `2-vpc.tf` .. `6-routes.tf` |
| Control plane | EKS cluster (API auth mode), IAM role, CloudWatch log group (14-day retention) | `7-eks.tf` |
| Core add-ons | `vpc-cni`, `kube-proxy`, `coredns` (EKS add-ons) | `7a-core-addons.tf` |
| Nodes | Launch template + Auto Scaling group (2 x `t3a.large`, Amazon Linux 2023), access entry, instance profile | `8-nodes.tf` |
| Access | IAM user `demo-developer` (group `my-viewer`), IAM user `manager` + role (group `my-admin`) | `9-`, `10-` |
| Platform | Metrics Server, Pod Identity Agent, Cluster Autoscaler | `12-`, `13-`, `14-` |
| Traffic | AWS Load Balancer Controller, ingress-nginx (NLB), Gateway API CRDs, cert-manager | `15-` .. `17-`, `21-` |
| Storage | EBS CSI add-on + `gp3` default class, EFS + CSI driver + `efs` class, OIDC provider | `18-` .. `20-` |
| Demos | Two-version sample app, Ingress, Gateway API, HPA and node-scaling examples | `examples/` |

Files are numbered in build order: network → control plane → add-ons → nodes → access → platform charts → traffic → storage.

### Choosing how worker nodes are built

There are two ways to run nodes on EKS. This repo implements **B**, which works in every account; **A** is shorter and is what you would normally pick if it works for you.

| | A. Managed node group | B. Self-managed (this repo) |
|---|---|---|
| Terraform | `aws_eks_node_group` | launch template + Auto Scaling group |
| AWS does for you | access entry, bootstrap, security group, draining on upgrade | nothing: you wire these yourself |
| Needs | EC2 Fleet API available in the account | only plain `RunInstances` |
| You patch the OS | AWS rolls updates for you on request | you replace the AMI and refresh instances |

**Why B here:** some AWS accounts (commonly new or restricted ones) cannot call the EC2 **Fleet** API. Managed node groups always launch through Fleet, so they sit in `CREATING` forever and the Auto Scaling group reports *"You've reached your quota for maximum Fleet Requests for this account"*. A plain Auto Scaling group with a launch template does not use Fleet, so it works. Fixing the account limit requires an AWS Support case.

To switch to A when your account allows it, replace the launch template, ASG and access entry in `8-nodes.tf` with:

```hcl
resource "aws_eks_node_group" "general" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = "general"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = [aws_subnet.private_zone1.id, aws_subnet.private_zone2.id]
  instance_types  = ["t3a.large"]

  scaling_config {
    desired_size = 2
    min_size     = 0
    max_size     = 10
  }

  lifecycle { ignore_changes = [scaling_config[0].desired_size] }
  depends_on = [aws_iam_role_policy_attachment.nodes, aws_eks_addon.vpc_cni, aws_eks_addon.kube_proxy]
}
```

Self-managed nodes (B) need three things that a managed node group does automatically. All three are in `8-nodes.tf`; if nodes do not join, check these first:

1. an **EKS access entry** of type `EC2_LINUX` for the node IAM role (otherwise the kubelet cannot authenticate);
2. the **cluster security group** attached to the launch template (otherwise nodes cannot reach the API server's private endpoint);
3. a `NodeConfig` in the user data holding the cluster name, endpoint, CA and service CIDR (Amazon Linux 2023 does not look these up itself).

## Before you start

You need:

- an AWS account and an AWS CLI profile with admin-level rights (VPC, EKS, IAM, EC2, EFS)
- Terraform `>= 1.5.7`, AWS CLI v2, and `kubectl` (Helm is only needed for manual experiments)
- `aws` and `kubectl` on the PATH of the machine running Terraform, because `21-gateway-api-crds.tf` calls them

Two settings are specific to the author's machine; change them to yours:

| Setting | Where | Default |
|---|---|---|
| AWS CLI profile | `1-providers.tf` and `21-gateway-api-crds.tf` | `ostad` |
| Region / zones / cluster name / Kubernetes version | `0-locals.tf` | `ap-south-1`, `a`/`b`, `development-demo`, `1.36` |

Check which Kubernetes versions your region offers before applying: `aws eks describe-cluster-versions --region <region> --query 'clusterVersions[].clusterVersion'`. Commands below use the default names; substitute your own if you changed them.

**Cost warning:** while running, this bills for the EKS control plane, a NAT gateway, EC2 nodes, a network load balancer, an application load balancer and EFS. Destroy it when you finish (section 10).

---

## 1. Deploy

### Terraform

```bash
terraform init
terraform plan         # read it: ~75 resources
terraform apply        # ~20 min: control plane ~10 min, then nodes and charts
```

Connect and check:

```bash
aws eks update-kubeconfig --region ap-south-1 --name development-demo --profile <your-profile> --alias development-demo
kubectl get nodes          # 2 nodes, STATUS Ready
kubectl get pods -A        # everything Running
```

### Console

Build the same stack by hand, in this order. Keep the region selector (top right) on one region throughout.

1. **VPC**: *VPC → Create VPC → VPC and more*. Name `development`, IPv4 `10.0.0.0/16`, 2 AZs, 2 public + 2 private subnets, **NAT gateways: 1 per VPC**, DNS hostnames and DNS resolution enabled. Then tag the subnets (*VPC → Subnets → select → Tags*):
   - public subnets: `kubernetes.io/role/elb = 1`
   - private subnets: `kubernetes.io/role/internal-elb = 1`
   - all four: `kubernetes.io/cluster/development-demo = owned`

   The role tags are how the load balancer controller picks subnets for internet-facing vs. internal load balancers.
2. **Cluster IAM role**: *IAM → Roles → Create role → AWS service → EKS → EKS - Cluster*. Name `development-demo-eks-cluster`, attach `AmazonEKSClusterPolicy`. (Terraform also attaches four extra `AmazonEKS…Policy` policies that only matter for EKS Auto Mode.)
3. **Cluster**: *EKS → Clusters → Create cluster → Custom configuration*. Name `development-demo`, your Kubernetes version, the role from step 2. Turn **EKS Auto Mode off**. Networking: the VPC, the two **private** subnets, endpoint access **Public and private**. Access: **EKS API** authentication, and keep *Allow cluster administrator access* ticked. Logging: API server, Audit, Authenticator. Add-ons: leave the preselected VPC CNI, kube-proxy and CoreDNS on (Terraform manages the same three explicitly in `7a-core-addons.tf`).
4. **More add-ons**: *Cluster → Add-ons → Get more add-ons*: **Amazon EKS Pod Identity Agent** and **Amazon EBS CSI Driver** (the latter needs a role, see section 6). CoreDNS shows *Degraded* until nodes exist; that is expected.
5. **Node IAM role**: *IAM → Create role → AWS service → EC2*. Name `development-demo-eks-nodes`, attach `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`.
6. **Nodes**
   - **Option A (managed):** *Cluster → Compute → Add node group*: the node role, private subnets, `t3a.large`, min 0 / desired 2 / max 10. Done.
   - **Option B (self-managed, what this repo does):**
     1. *Cluster → Access → Create access entry*: principal = the node role, type **EC2 Linux**. Click through the wizard without adding groups or access policies: the console does not allow policies on this type, and none are needed (EKS gives the entry group `system:nodes` and username `system:node:{{EC2PrivateDNSName}}`, which is all a kubelet needs). Access policies are only for `Standard` entries, i.e. people and tools (section 2).
     2. *EC2 → Launch templates → Create*: AMI = *Amazon EKS-optimized Amazon Linux 2023* (search the AMI catalog for `amazon-eks-node-al2023-x86_64-standard-<k8s version>`), type `t3a.large`, **IAM instance profile** = the node role, **security group = the cluster security group** (*EKS → cluster → Networking → Cluster security group*), storage 100 GiB gp3 encrypted, metadata *IMDSv2 required*. Under *Advanced details → User data* paste:

        ```text
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="//"

        --//
        Content-Type: application/node.eks.aws

        ---
        apiVersion: node.eks.aws/v1alpha1
        kind: NodeConfig
        spec:
          cluster:
            name: development-demo
            apiServerEndpoint: <API server endpoint from the cluster page>
            certificateAuthority: <Certificate authority from the cluster page>
            cidr: 172.20.0.0/16
          kubelet:
            flags:
              - --node-labels=role=general

        --//--
        ```

        (`cidr` is the cluster's *Service IPv4 range*, shown under Networking.)
     3. *EC2 → Auto Scaling groups → Create*: the launch template, the two private subnets, desired 2 / min 0 / max 10, health check EC2. Add tags `kubernetes.io/cluster/development-demo = owned`, `k8s.io/cluster-autoscaler/enabled = true`, `k8s.io/cluster-autoscaler/development-demo = owned` (all *propagate at launch*). Do **not** enable a mixed-instances policy or Spot here: that routes launches through Fleet again.
7. **Verify**: *Cluster → Compute* lists the nodes as *Ready* after about 2 minutes. If they never appear, re-check the security group (6B.2), the access entry (6B.1) and the user data.

---

## 2. Access for people

Terraform creates two example identities (`9-add-developer-user.tf`, `10-add-manager-role.tf`):

- **`demo-developer`** (IAM user) is mapped to Kubernetes group `my-viewer`.
- **`manager`** (IAM user) may assume role `development-demo-eks-admin`, which is mapped to group `my-admin`. The user is also mapped directly, for temporary access.

An access entry only says *who* someone is. What they may *do* comes from Kubernetes RBAC, and **this repo does not ship RBAC bindings**. Until you create them, both groups can log in but are denied everything:

```bash
kubectl create clusterrolebinding my-viewer --clusterrole=view          --group=my-viewer
kubectl create clusterrolebinding my-admin  --clusterrole=cluster-admin --group=my-admin
```

Alternative with no RBAC: drop `kubernetes_groups` and attach an EKS **access policy** (`AmazonEKSViewPolicy` or `AmazonEKSClusterAdminPolicy`) to the entry. This works only for `STANDARD` entries (people, tools), not the node role's `EC2_LINUX` entry.

### Log in as each user

```bash
# 1. as an admin, create access keys
aws iam create-access-key --user-name demo-developer
aws iam create-access-key --user-name manager

# 2. in ~/.aws/credentials and ~/.aws/config create profiles:
#    [profile dev]       -> the demo-developer keys
#    [profile manager]   -> the manager keys
#    [profile eks-admin]
#    role_arn       = arn:aws:iam::<account-id>:role/development-demo-eks-admin
#    source_profile = manager

# 3. build a kubeconfig context per identity
aws eks update-kubeconfig --name development-demo --region ap-south-1 --profile dev       --alias dev
aws eks update-kubeconfig --name development-demo --region ap-south-1 --profile eks-admin --alias admin
kubectl --context dev get pods -A
```

The developer IAM policy grants `s3:*` on `*`. That is convenient for a demo; tighten it for real use.

### Console

1. *IAM → Users → Create user* (`demo-developer`, `manager`). Developer: attach a policy with `eks:DescribeCluster` and `eks:ListClusters`. Manager: attach a policy allowing `sts:AssumeRole` on the admin role.
2. *IAM → Roles → Create role → AWS account → This account*, name `development-demo-eks-admin`, attach a policy with `eks:*` and `iam:PassRole` (condition `iam:PassedToService = eks.amazonaws.com`).
3. *EKS → cluster → Access → IAM access entries → Create access entry*: pick the principal, type *Standard*, then either add **Kubernetes groups** `my-viewer` / `my-admin` or pick an access policy.
4. *IAM → Users → user → Security credentials → Create access key*.
5. From a session that is already cluster admin, apply the two `clusterrolebinding` commands above (CloudShell works).

> **No local tools?** Open **AWS CloudShell** (icon in the console top bar) and run `aws eks update-kubeconfig --name development-demo --region ap-south-1`; then `kubectl` works with your console identity. If you restrict the public API CIDRs, CloudShell must be inside them.

---

## 3. Platform add-ons

| Component | Installed by | Purpose |
|---|---|---|
| Metrics Server | Helm, `kube-system` | provides CPU/memory numbers for `kubectl top` and the HPA |
| Pod Identity Agent | EKS add-on | gives pods AWS credentials without per-pod annotations |
| Cluster Autoscaler | Helm + Pod Identity role | adds/removes nodes by resizing the Auto Scaling group (found via its `k8s.io/cluster-autoscaler/*` tags) |
| AWS Load Balancer Controller (LBC) | Helm `3.6.0` + Pod Identity role | creates NLBs/ALBs for Services, Ingresses and Gateways |
| ingress-nginx | Helm `4.15.1`, namespace `ingress` | in-cluster traffic router, class `external-nginx` (default), fronted by an internet-facing NLB |
| Gateway API CRDs | `kubectl apply --server-side` | v1.6.3 standard channel, saved in `gateway-api/` |
| cert-manager | Helm `v1.21.2` | issues TLS certificates; Gateway API support on |

**Why both LBC and ingress-nginx?** They do different jobs. ingress-nginx is the traffic *router* inside the cluster. LBC is the AWS-side *builder*: when a Service asks for a load balancer, it creates the actual NLB/ALB, target groups and security groups. The annotations in `values/nginx-ingress.yaml` are instructions to LBC. Traffic flow for Ingress: internet → NLB (built by LBC) → nginx pods → your app.

**Order matters:** the Gateway API CRDs must exist *before* LBC and cert-manager start, because both only enable their Gateway features when they see the CRDs at startup. If you install the CRDs later, restart them: `kubectl -n kube-system rollout restart deploy aws-load-balancer-controller`.

### Keep the LBC IAM policy current

`iam/AWSLoadBalancerController.json` is the official policy. New LBC releases call new AWS APIs; with a stale policy a Service stays `<pending>` and `kubectl describe svc` shows `AccessDenied … DescribeListenerAttributes`. Refresh it with:

```bash
curl -fL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json -o iam/AWSLoadBalancerController.json
terraform apply
```

### Helm repositories (only for manual `helm` use)

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm repo update
```

### Console

The console installs the *EKS add-ons* (VPC CNI, kube-proxy, CoreDNS, Pod Identity Agent, EBS CSI, Metrics Server) from *Cluster → Add-ons*. The Helm charts (LBC, ingress-nginx, cert-manager, autoscaler, EFS CSI) have no console button: run `helm install` from CloudShell or your laptop. For the AWS-side permissions of the load balancer controller:

1. *IAM → Policies → Create policy → JSON*: paste `iam/AWSLoadBalancerController.json`, name it `AWSLoadBalancerControllerIAMPolicy`.
2. *IAM → Roles → Create role → Custom trust policy*: principal `pods.eks.amazonaws.com`, actions `sts:AssumeRole` and `sts:TagSession`. Attach the policy. (The autoscaler and EBS CSI roles have the same shape.)
3. *EKS → cluster → Access → Pod Identity associations → Create*: that role, namespace `kube-system`, service account `aws-load-balancer-controller`.
4. Install the Gateway API CRDs first: `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml`
5. `helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version 3.6.0 --set clusterName=development-demo --set serviceAccount.name=aws-load-balancer-controller --set vpcId=<vpc-id>`
6. `helm install external ingress-nginx/ingress-nginx -n ingress --create-namespace --version 4.15.1 -f values/nginx-ingress.yaml`
7. `helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.21.2 --set crds.enabled=true --set config.enableGatewayAPI=true`

---

## 4. Test Ingress and Gateway API

`examples/` deploys two versions of Argo's `rollouts-demo` app (blue and yellow) and exposes them two ways. More detail in [examples/README.md](examples/README.md).

```bash
kubectl apply -f examples/00-apps.yaml
kubectl apply -f examples/10-ingress.yaml        # nginx -> NLB
kubectl apply -f examples/20-gateway-api.yaml    # AWS Gateway -> ALB

kubectl -n ingress get svc external-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl -n demo get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}'

# wait 2-3 minutes for the load balancers, then (replace <hostname>):
for i in $(seq 10); do curl -s http://<hostname>/color; done
```

Expected: the Ingress always answers `"blue"`; the Gateway answers a mix of `"blue"` and `"yellow"` (the `HTTPRoute` splits 50/50).

| | Ingress | Gateway API |
|---|---|---|
| Load balancer | NLB → nginx pods → app | ALB → app pods directly (`targetType: ip`) |
| Routing config | `Ingress` + nginx annotations | `Gateway` + `HTTPRoute` (+ AWS `LoadBalancerConfiguration`, `TargetGroupConfiguration`) |
| Traffic split | needs canary annotations | built-in `weight` |
| Controller | ingress-nginx | AWS Load Balancer Controller only |

> The upstream ingress-nginx project has been announced for retirement. Prefer the Gateway API path for new workloads.

### Console

- *EC2 → Load Balancing → Load Balancers*: one NLB `k8s-ingress-external-…` and one ALB `k8s-demo-demogate-…`, state *Active*.
- *EC2 → Target Groups → select → Targets*: pod IPs should be *healthy*. The ALB listener's *Rules* tab shows the 50/50 weighted forward to the blue and yellow target groups.
- Paste a load balancer's DNS name into a browser.
- To apply the YAML without local tools: CloudShell → *Actions → Upload file* → `kubectl apply -f …`.

---

## 5. Autoscaling: pods and nodes

Two layers scale independently:

1. **HPA** adds pods when CPU rises. It needs Metrics Server and a CPU *request* on the pods (utilization is measured against the request).
2. **Cluster Autoscaler** adds nodes when pods cannot be scheduled (`Pending`), and removes nodes that stay underused.

```bash
# Pods
kubectl apply -f examples/30-hpa.yaml
kubectl -n demo get hpa php-apache -w            # TARGETS goes above 50%, REPLICAS grows
kubectl -n demo delete deploy load-generator     # stop the load; replicas fall back

# Nodes (8 pods x 1 CPU do not fit on 2 nodes)
kubectl apply -f examples/40-node-autoscaling.yaml
kubectl get nodes -w                             # new nodes within ~2-4 min
kubectl delete -f examples/40-node-autoscaling.yaml
kubectl get nodes -w                             # nodes removed after ~10 min idle
```

Measured on this setup: pods grew 1 → 5 under load and returned to 1; nodes grew 2 → 10 (the Auto Scaling group maximum) and returned to 2 about 12 minutes after the load stopped.

**Cluster Autoscaler vs Karpenter.** This repo uses the Cluster Autoscaler: it resizes an existing Auto Scaling group, so it can only add nodes of the type that group uses. Karpenter has no Auto Scaling group; it reads Pending pods and launches whichever EC2 instance type fits, which is usually faster and cheaper but needs its own controller, `NodePool`/`EC2NodeClass` objects and extra IAM/SQS setup. Karpenter launches through the EC2 Fleet API, so it will not work in accounts where Fleet is blocked (see "Choosing how worker nodes are built").

### Console

- *EC2 → Auto Scaling groups → select → Activity* shows each scale-out/in with its reason. *Instance management* shows the nodes.
- *EKS → cluster → Compute* shows nodes joining. Pods and HPA: CloudShell → `kubectl get hpa -n demo`.

---

## 6. Storage

- **EBS** (`gp3`, default class): EBS CSI add-on + Pod Identity role. `WaitForFirstConsumer`, volume expansion on. Use for one pod's disk.
- **EFS** (`efs` class): encrypted file system with mount targets in both private subnets (cluster security group), the EFS CSI driver chart, `efs-ap` provisioning. Use for shared `ReadWriteMany` storage across pods.

```bash
kubectl get storageclass
```

**Console:** EBS: *Cluster → Add-ons → Amazon EBS CSI Driver*, then choose or create the Pod Identity role (policy `AmazonEBSCSIDriverPolicy`). EFS: *EFS → Create file system*, then *Network → Mount targets* in the two private subnets using the cluster security group (NFS port 2049 must be allowed from the nodes; the cluster security group allows its own members).

---

## 7. Customization

| Change | Where |
|---|---|
| environment, region, zones, cluster name, Kubernetes version | `0-locals.tf` |
| who may reach the API server from the internet | `api_allowed_cidrs` in `0-locals.tf` |
| node type, size, disk, scaling | `8-nodes.tf` |
| AWS profile | `1-providers.tf`, `21-gateway-api-crds.tf` |
| Helm values | `values/` |
| Gateway API version | replace `gateway-api/standard-install.yaml` |

Core add-ons are deliberately unpinned so EKS picks the compatible default when you change `eks_version`.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Managed node group stuck `CREATING`; Auto Scaling activity says *quota for maximum Fleet Requests* | The account cannot use EC2 Fleet. Use the self-managed group (this repo) or open an AWS Support case. |
| Nodes launch but never join | Missing cluster security group on the launch template, missing `EC2_LINUX` access entry, or wrong user data. Open a shell with `aws ssm start-session` and read `journalctl -u kubelet`. |
| Service `EXTERNAL-IP` stays `<pending>` | `kubectl describe svc …`. `AccessDenied` means refresh the LBC IAM policy (section 3). |
| `helm_release` fails: *cannot re-use a name that is still in use* | A failed release is left in the cluster: `helm uninstall <name> -n <namespace>`, then `terraform apply`. |
| Gateways are ignored by the controller | CRDs were installed after LBC started: restart the LBC deployment. |
| CoreDNS add-on `Degraded` | Normal until nodes are Ready. |
| HPA shows `<unknown>` for CPU | Metrics Server not ready, or pods have no CPU `requests`. |
| `terraform destroy` hangs on subnets/VPC | Leftover load balancers, network interfaces or security groups created by LBC. See section 10. |

---

## 9. Production hardening checklist

This repo is tuned for learning. Before running real workloads, work through this list. "In repo" says what exists today.

### State, secrets and change control

| Do this | Why | In repo |
|---|---|---|
| Store Terraform state in S3 with locking and versioning; never in git | State contains tokens and secrets; local state is lost with the laptop and cannot be shared | local `terraform.tfstate` (git-ignored) |
| Commit `.terraform.lock.hcl` and keep provider versions pinned | Reproducible builds | providers use `~>` ranges |
| Pin EKS add-on versions and the node AMI id | `most_recent` AMI and unpinned add-ons change under you on the next apply | both unpinned |
| Split environments (dev/stage/prod) into separate state and variables | One mistake should not touch production | single environment in `locals` |
| Turn on envelope encryption of Kubernetes Secrets with a KMS key (`encryption_config`) | Secrets are otherwise only base64 in etcd | not set |

### Network and access

| Do this | Why | In repo |
|---|---|---|
| Restrict `api_allowed_cidrs` to your office/VPN, or disable public endpoint access | `0.0.0.0/0` exposes the API server to the internet | `0.0.0.0/0` |
| One NAT gateway per AZ and nodes in 3 AZs | One NAT or AZ is a single point of failure | 1 NAT, 2 AZs |
| Set `bootstrap_cluster_creator_admin_permissions = false` and grant admin to a named role | Avoid a hidden permanent admin | `true` |
| Replace broad IAM: `s3:*` on `*` (developer), `eks:*` (admin role) | Least privilege | broad |
| Kubernetes NetworkPolicies (VPC CNI supports them) and Pod Security Standards (`restricted`) | Pods can currently talk to every pod and run privileged | none |
| Keep IMDSv2 with hop limit 1 so pods cannot steal node credentials | Standard EKS hardening | already set |
| Use Pod Identity per workload, not the node role, for AWS access | Blast radius | used for all controllers |

### Reliability

| Do this | Why | In repo |
|---|---|---|
| Run at least 2 replicas of every important app, spread across zones (`topologySpreadConstraints`) and add PodDisruptionBudgets | Node drains and autoscaler scale-in otherwise cause downtime | demo apps only |
| Mix instance types and use On-Demand for critical pods, Spot for the rest | Capacity and cost; **note**: mixed/Spot groups need EC2 Fleet | single type, On-Demand |
| Patch nodes on a schedule: new AMI, then an Auto Scaling *instance refresh* | Self-managed nodes are not patched for you | manual |
| Back up persistent data (EBS snapshots, EFS backup, Velero for cluster objects) | `terraform destroy` or a bad deploy loses data | none |
| Set resource `requests`/`limits` and a `LimitRange`/`ResourceQuota` per namespace | Autoscalers and the scheduler depend on requests | demo apps only |

### Traffic and TLS

| Do this | Why | In repo |
|---|---|---|
| Serve HTTPS: ACM certificate on the ALB/NLB, or cert-manager `ClusterIssuer` (Let's Encrypt) | Demos use plain HTTP | cert-manager installed, no issuer |
| Add AWS WAF on the ALB, and consider `internal` load balancers for private services | Internet-facing by default | internet-facing |
| Plan the move from ingress-nginx to Gateway API | ingress-nginx upstream is being retired | both present |

### Observability and cost

| Do this | Why | In repo |
|---|---|---|
| Metrics and alerts: Amazon Managed Prometheus/Grafana, Container Insights or kube-prometheus-stack | You only learn about problems from users otherwise | Metrics Server only |
| Application logs to CloudWatch or Loki; keep the 14-day control-plane log retention | Debugging and audit | control-plane logs only |
| Tag everything and set an AWS Budget and billing alarm | A forgotten NAT gateway plus load balancers is the usual surprise bill | few tags |
| Keep `max_size` of the node group a deliberate cost ceiling | Autoscaler followed a load test straight to 10 nodes here | 10 |
| Add `prevent_destroy` or deletion protection on data (EFS, load balancers) | Accidents | none |

A reasonable order: remote state → restrict API access → HTTPS → least-privilege IAM → backups → observability → multi-AZ NAT and replicas.

---

## 10. Cleanup

```bash
kubectl delete -f examples/                              # removes the demo and its load balancers
terraform destroy -target=helm_release.external_nginx    # releases the NLB
terraform destroy
```

If destroy fails on the VPC, look in *EC2 → Load Balancers*, *EC2 → Network Interfaces* and *EC2 → Security Groups* for leftovers named `k8s-…` and delete them, then run `terraform destroy` again.

**Console:** delete the load balancers; then *EC2 → Auto Scaling groups* (set desired capacity to 0, then delete); then the EKS node group and cluster; then the VPC (release the NAT gateway and its Elastic IP first, then *VPC → Delete VPC*, which removes subnets, route tables and the internet gateway); finally the IAM roles and users.

## License

MIT. See `LICENSE`.
