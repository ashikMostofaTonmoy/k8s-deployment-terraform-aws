# Terraform AWS EKS Deployment

Terraform for a development EKS platform on AWS: network, cluster, self-managed worker nodes, access mappings, storage, ingress and Gateway API. Every section also has a **Console** version, so you can build or inspect the same thing by clicking through the AWS web console.

Default config (`0-locals.tf`): environment `development`, region `ap-south-1` (zones `a`/`b`), cluster `development-demo`, Kubernetes `1.36`.

## What gets created

| Layer | Resources | File |
|---|---|---|
| Network | VPC `10.0.0.0/16`, 2 public + 2 private subnets, IGW, 1 NAT gateway, route tables | `2-vpc.tf` .. `6-routes.tf` |
| Control plane | EKS cluster (API auth mode), IAM role, CloudWatch log group (14-day retention) | `7-eks.tf` |
| Core add-ons | `vpc-cni`, `kube-proxy`, `coredns` (EKS managed add-ons) | `7a-core-addons.tf` |
| Nodes | Launch template + Auto Scaling group (2x `t3a.large`, AL2023), access entry, instance profile | `8-nodes.tf` |
| Access | IAM user `demo-developer` (group `my-viewer`), IAM user `manager` + role (group `my-admin`) | `9-`, `10-` |
| Platform | Metrics Server, Pod Identity Agent, Cluster Autoscaler | `12-`, `13-`, `14-` |
| Traffic | AWS Load Balancer Controller, ingress-nginx (NLB), Gateway API CRDs, cert-manager | `15-` .. `17-`, `21-` |
| Storage | EBS CSI add-on + `gp3` default class, EFS + CSI driver + `efs` class, OIDC provider | `18-` .. `20-` |
| Demos | Two-version sample app, Ingress example, Gateway API example | `examples/` |

Build order: network → control plane → add-ons → nodes → access → platform charts → traffic → storage.

### Why self-managed nodes instead of a managed node group

Some AWS accounts cannot call the EC2 **Fleet** API (the symptom is a node group stuck in `CREATING` and an Auto Scaling activity saying *"You've reached your quota for maximum Fleet Requests for this account"*). Managed node groups always launch through Fleet, so no node ever appears. A plain Auto Scaling group with a launch template uses `RunInstances` instead and works. If your account does not have this limit, you may switch back to `aws_eks_node_group`, which is less code. Raising the limit needs an AWS Support case.

Self-managed nodes need three things a managed node group does for you, all handled in `8-nodes.tf`:

1. an **EKS access entry** of type `EC2_LINUX` for the node role (otherwise kubelet cannot authenticate);
2. the **cluster security group** on the launch template (otherwise nodes cannot reach the private API endpoint — this was the original "nodes don't join" bug);
3. a `NodeConfig` in user data with the cluster name, endpoint, CA and service CIDR (AL2023 does not look these up itself).

## Prerequisites

- Terraform `>= 1.5.7`, AWS CLI v2, `kubectl`, Helm (only for manual inspection)
- An AWS profile with admin-level rights (VPC, EKS, IAM, EC2, EFS)
- `aws` and `kubectl` on the PATH of the machine running Terraform: `21-gateway-api-crds.tf` shells out to them

The AWS profile name is hardcoded as `ostad` in `1-providers.tf` and in `21-gateway-api-crds.tf`. Change both if yours differs.

---

## 1. Deploy

### Terraform

```bash
terraform init
terraform plan
terraform apply        # ~20 min: EKS control plane ~10 min, NAT/nodes/charts the rest
```

Connect and check:

```bash
aws eks update-kubeconfig --region ap-south-1 --name development-demo --profile ostad --alias development-demo
kubectl get nodes          # 2 nodes, Ready
kubectl get pods -A        # everything Running
```

### Console

Build the same stack by hand, in this order. Region selector (top right) = **Asia Pacific (Mumbai) ap-south-1** throughout.

1. **VPC** — *VPC → Create VPC → VPC and more*. Name `development`, IPv4 `10.0.0.0/16`, 2 AZs, 2 public + 2 private subnets, **NAT gateways: 1 per VPC**, DNS hostnames and DNS resolution enabled. Then tag the subnets (*VPC → Subnets → select → Tags*):
   - public subnets: `kubernetes.io/role/elb = 1`
   - private subnets: `kubernetes.io/role/internal-elb = 1`
   - all four: `kubernetes.io/cluster/development-demo = owned`

   The role tags are what the load balancer controller uses to pick subnets for an internet-facing vs. internal load balancer.
2. **Cluster IAM role** — *IAM → Roles → Create role → AWS service → EKS → EKS - Cluster*. Name `development-demo-eks-cluster`. Attach `AmazonEKSClusterPolicy` (the Terraform also attaches the four extra `AmazonEKS…Policy` managed policies; only needed for EKS Auto Mode).
3. **Cluster** — *EKS → Clusters → Create cluster → Custom configuration*. Name `development-demo`, version `1.36`, the role from step 2. Turn **EKS Auto Mode off**. Networking: the VPC, the two **private** subnets, endpoint access **Public and private**. Access: **EKS API** authentication, and keep *Allow cluster administrator access* ticked. Logging: API server, Audit, Authenticator. Add-ons: the console preselects VPC CNI, kube-proxy and CoreDNS; leave them on (Terraform instead sets `bootstrap_self_managed_addons = false` and manages them as EKS add-ons in `7a-core-addons.tf`, with the same result). Add the rest in step 4.
4. **Core add-ons** — *Cluster → Add-ons → Get more add-ons*: select **Amazon VPC CNI**, **kube-proxy**, **CoreDNS**, **Amazon EKS Pod Identity Agent**, **Amazon EBS CSI Driver** (the last needs a role, see Storage). Accept default versions. CoreDNS stays *Degraded* until nodes exist — that is expected.
5. **Node IAM role** — *IAM → Create role → AWS service → EC2*. Name `development-demo-eks-nodes`. Attach `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`.
6. **Nodes**
   - *If Fleet works in your account:* *Cluster → Compute → Add node group* with the node role, the private subnets, `t3a.large`, 2/0/10 nodes. Done.
   - *If it does not (this account):* build a self-managed group.
     1. *Cluster → Access → Create access entry*: principal = the node role, type **EC2 Linux**.
     2. *EC2 → Launch templates → Create*: AMI = *Amazon EKS-optimized AL2023* (search AMI catalog for `amazon-eks-node-al2023-x86_64-standard-1.36`), type `t3a.large`, **IAM instance profile** = the node role, **security group = the cluster security group** (EKS → cluster → Networking → *Cluster security group*), storage 100 GiB gp3 encrypted, metadata *IMDSv2 required*. Under *Advanced details → User data* paste:
        ```
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
     3. *EC2 → Auto Scaling groups → Create*: the launch template, the two private subnets, desired 2 / min 0 / max 10, health check EC2. Add tags `kubernetes.io/cluster/development-demo = owned`, `k8s.io/cluster-autoscaler/enabled = true`, `k8s.io/cluster-autoscaler/development-demo = owned` (all *propagate at launch*). **Do not enable a mixed-instances policy or Spot** — that routes through Fleet again.
7. **Verify** — *Cluster → Compute* lists the nodes as *Ready* after ~2 min. If they never appear: check the security group (step 6.2), the access entry (6.1), and the user data.

---

## 2. Access for people (`9-`, `10-`)

Terraform creates:

- **`demo-developer`** (IAM user) → Kubernetes group `my-viewer`
- **`manager`** (IAM user) → may assume role `development-demo-eks-admin`, which maps to group `my-admin`. The user is also mapped directly, for temporary access.

An access entry only says *who* someone is. What they may *do* comes from Kubernetes RBAC, and **this repo does not ship RBAC bindings**, so both groups can log in but are denied everything until you bind them:

```bash
kubectl create clusterrolebinding my-viewer --clusterrole=view          --group=my-viewer
kubectl create clusterrolebinding my-admin  --clusterrole=cluster-admin --group=my-admin
```

Alternatively, drop `kubernetes_groups` and attach an EKS **access policy** (`AmazonEKSViewPolicy` / `AmazonEKSClusterAdminPolicy`) to the entry, which needs no RBAC at all.

### Log in as each user

```bash
# 1. as an admin, create keys
aws iam create-access-key --user-name demo-developer
aws iam create-access-key --user-name manager

# 2. ~/.aws/config + credentials
#    [profile dev]      -> demo-developer keys
#    [profile manager]  -> manager keys
#    [profile eks-admin]
#    role_arn = arn:aws:iam::<account-id>:role/development-demo-eks-admin
#    source_profile = manager

aws eks update-kubeconfig --name development-demo --region ap-south-1 --profile dev       --alias dev
aws eks update-kubeconfig --name development-demo --region ap-south-1 --profile eks-admin --alias admin
kubectl --context dev get pods -A
```

The developer IAM policy grants `s3:*` on `*`; tighten it if that is not intended.

### Console

1. *IAM → Users → Create user* (`demo-developer`, `manager`). Developer: attach a policy with `eks:DescribeCluster`, `eks:ListClusters`. Manager: attach a policy allowing `sts:AssumeRole` on the admin role.
2. *IAM → Roles → Create role → AWS account → This account* → name `development-demo-eks-admin`, attach a policy with `eks:*` and `iam:PassRole` (condition `iam:PassedToService = eks.amazonaws.com`).
3. *EKS → cluster → Access → IAM access entries → Create access entry*: pick the principal, type *Standard*, add **Kubernetes groups** `my-viewer` / `my-admin` (or pick an access policy instead).
4. Create access keys: *IAM → Users → user → Security credentials → Create access key*.
5. Apply the two `kubectl create clusterrolebinding` commands above from a session that is already cluster admin (CloudShell works, see below).

> **No local tools?** Open **AWS CloudShell** (icon in the console top bar), then run `aws eks update-kubeconfig --name development-demo --region ap-south-1` and use `kubectl` there. Your signed-in console identity is used. Note: with the private endpoint plus a restricted public CIDR list, CloudShell must be inside the allowed CIDRs.

---

## 3. Platform add-ons

| Component | Installed by | Notes |
|---|---|---|
| Metrics Server | Helm, `kube-system` | values in `values/metrics-server.yaml`; enables `kubectl top` and HPA |
| Pod Identity Agent | EKS add-on | gives pods AWS credentials without IRSA annotations |
| Cluster Autoscaler | Helm, Pod Identity role | finds the ASG by the `k8s.io/cluster-autoscaler/*` tags; region follows `local.region` |
| AWS Load Balancer Controller (LBC) | Helm `3.6.0`, Pod Identity role | builds NLBs/ALBs for Services, Ingresses and Gateways |
| ingress-nginx | Helm `4.15.1`, namespace `ingress` | class `external-nginx` (default), internet-facing NLB via LBC |
| Gateway API CRDs | `kubectl apply --server-side` | v1.6.3 standard channel, vendored in `gateway-api/` |
| cert-manager | Helm `v1.21.2` | CRDs on, Gateway API support on |

**Order matters:** Gateway API CRDs must exist *before* LBC and cert-manager start, because both only enable their Gateway controllers when they detect the CRDs at startup. If you ever install the CRDs later, restart them: `kubectl -n kube-system rollout restart deploy aws-load-balancer-controller`.

### Keep the LBC IAM policy current

`iam/AWSLoadBalancerController.json` is the official policy. New LBC releases call new AWS APIs; with a stale policy a Service stays `<pending>` and `kubectl describe svc` shows `AccessDenied … DescribeListenerAttributes`. Refresh it with:

```bash
curl -fL https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json -o iam/AWSLoadBalancerController.json
terraform apply
```

### Helm repositories (only needed for manual `helm` use)

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

The console can install the *EKS add-ons* (VPC CNI, kube-proxy, CoreDNS, Pod Identity Agent, EBS CSI, and also Metrics Server) from *Cluster → Add-ons*. The Helm charts (LBC, ingress-nginx, cert-manager, autoscaler, EFS CSI) have no console button — run `helm install` from CloudShell or your laptop. For the AWS-side permissions:

1. *IAM → Policies → Create policy → JSON*: paste `iam/AWSLoadBalancerController.json`, name `AWSLoadBalancerControllerIAMPolicy`.
2. *IAM → Roles → Create role → Custom trust policy*: principal `pods.eks.amazonaws.com`, actions `sts:AssumeRole` and `sts:TagSession`. Attach the policy. (Same shape for the autoscaler and EBS CSI roles.)
3. *EKS → cluster → Access → Pod Identity associations → Create*: role from step 2, namespace `kube-system`, service account `aws-load-balancer-controller`.
4. In CloudShell: `helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --version 3.6.0 --set clusterName=development-demo --set serviceAccount.name=aws-load-balancer-controller --set vpcId=<vpc-id>`
5. Gateway CRDs: `kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.3/standard-install.yaml` — **before** step 4.
6. ingress-nginx: `helm install external ingress-nginx/ingress-nginx -n ingress --create-namespace --version 4.15.1 -f values/nginx-ingress.yaml`
7. cert-manager: `helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.21.2 --set crds.enabled=true --set config.enableGatewayAPI=true`

---

## 4. Test ingress and Gateway API

`examples/` deploys two versions of Argo's `rollouts-demo` app (blue, yellow) and exposes them two ways. Details in [examples/README.md](examples/README.md).

```bash
kubectl apply -f examples/00-apps.yaml
kubectl apply -f examples/10-ingress.yaml        # nginx -> NLB
kubectl apply -f examples/20-gateway-api.yaml    # LBC Gateway -> ALB

kubectl -n ingress get svc external-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
kubectl -n demo get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}'
# wait 2-3 min for the load balancers, then:
for i in $(seq 10); do curl -s http://<hostname>/color; done
```

Expected: the Ingress always answers `"blue"`; the Gateway answers a mix of `"blue"` and `"yellow"` (50/50 `HTTPRoute` weights).

| | Ingress | Gateway API |
|---|---|---|
| Load balancer | NLB → nginx pods → app | ALB → app pods directly (`targetType: ip`) |
| Routing config | `Ingress` + nginx annotations | `Gateway` + `HTTPRoute` (+ AWS `LoadBalancerConfiguration`, `TargetGroupConfiguration`) |
| Traffic split | needs canary annotations | built-in `weight` |
| Controller | ingress-nginx | AWS LBC only |

> ingress-nginx has been announced for retirement upstream. For new workloads prefer the Gateway API path.

### Console

- Load balancers: *EC2 → Load Balancing → Load Balancers* — one NLB `k8s-ingress-external-…` and one ALB `k8s-demo-demogate-…`, state *Active*.
- Target groups: *EC2 → Target Groups → select → Targets* — pod IPs should be *healthy*. The ALB listener's *Rules* tab shows the 50/50 weighted forward to the blue and yellow target groups.
- Open the DNS name from the load balancer's *Description* tab in a browser.
- Applying the YAML: CloudShell → `kubectl apply -f …` (upload the `examples/` files with *Actions → Upload file*).

---

## 5. Storage

- **EBS** (`gp3`, default): EBS CSI add-on + Pod Identity role. `WaitForFirstConsumer`, volume expansion on.
- **EFS** (`efs`): encrypted file system with mount targets in both private subnets (cluster security group), EFS CSI driver chart, `efs-ap` provisioning. Use for shared `ReadWriteMany` storage.

```bash
kubectl get storageclass
```

**Console:** EBS → *Cluster → Add-ons → Amazon EBS CSI Driver*, choose/create the Pod Identity role (`AmazonEBSCSIDriverPolicy`). EFS → *EFS → Create file system*, then *Network → Mount targets* in the two private subnets with the cluster security group (needs NFS 2049 from nodes — the cluster SG allows its own members).

---

## 6. Customization

| Change | Where |
|---|---|
| env, region, zones, cluster name, Kubernetes version | `0-locals.tf` |
| API access CIDRs (narrow `0.0.0.0/0` before real use) | `api_allowed_cidrs` in `0-locals.tf` |
| node type, size, disk, scaling | `8-nodes.tf` |
| AWS profile | `1-providers.tf`, `21-gateway-api-crds.tf` |
| Helm values | `values/` |
| Gateway API version | replace `gateway-api/standard-install.yaml` |

Core add-ons are deliberately unpinned so EKS picks the compatible default when you bump `eks_version`.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Managed node group stuck `CREATING`, ASG says *quota for maximum Fleet Requests* | Account cannot use EC2 Fleet. Use the self-managed ASG (default here) or open an AWS Support case. |
| Nodes launch but never join | Missing cluster security group on the launch template, missing `EC2_LINUX` access entry, or wrong user-data. Check with `aws ssm start-session` on the node (`journalctl -u kubelet`, `nodeadm` logs). |
| Service `EXTERNAL-IP <pending>` | `kubectl describe svc`. `AccessDenied` ⇒ refresh the LBC IAM policy (see above). |
| `helm_release` fails with *cannot re-use a name that is still in use* | A failed release exists in the cluster: `helm uninstall <name> -n <ns>`, then `terraform apply`. |
| LBC ignores Gateways | CRDs were installed after LBC started — restart the LBC deployment. |
| CoreDNS add-on `Degraded` | Normal until nodes are Ready. |
| `terraform destroy` hangs on subnets/VPC | Leftover LBs/ENIs/security groups from LBC. Delete the demo and ingress first (below). |

## 8. Cleanup

```bash
kubectl delete -f examples/                              # removes the NLB/ALB-backed objects
terraform destroy -target=helm_release.external_nginx    # releases the NLB
terraform destroy
```

If destroy still fails on the VPC, look in *EC2 → Load Balancers*, *EC2 → Network Interfaces* and *EC2 → Security Groups* for `k8s-…` leftovers and delete them. Costs while running: EKS control plane, NAT gateway, EC2 nodes, NLB, ALB, EFS.

**Console:** delete the load balancers, then *EC2 → Auto Scaling groups* (set desired 0, delete), then the EKS node group/cluster, then the VPC (*VPC → Delete VPC* removes subnets, route tables, IGW; release the NAT gateway and its Elastic IP first), then IAM roles/users.

## License

MIT. See `LICENSE`.
