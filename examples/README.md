# Ingress + Gateway API demo

```
kubectl apply -f examples/00-apps.yaml
kubectl apply -f examples/10-ingress.yaml        # via nginx NLB
kubectl apply -f examples/20-gateway-api.yaml    # via AWS ALB

# Ingress URL (NLB)
kubectl -n ingress get svc external-ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# Gateway URL (ALB)
kubectl -n demo get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}'
```

Ingress always shows blue. The Gateway shows blue/yellow 50/50.
New LBs take 2-3 minutes to become active. Cleanup: `kubectl delete -f examples/` (delete the
Gateway before destroying the cluster so the ALB is removed).

## Autoscaling demos

**HPA (pods)** - `30-hpa.yaml`: `php-apache` (500m CPU request, HPA target 50%, 1-12 pods) plus a
`load-generator` that hammers it. Needs Metrics Server.

```
kubectl apply -f examples/30-hpa.yaml
kubectl -n demo get hpa php-apache -w          # TARGETS rise above 50%, REPLICAS grows
kubectl -n demo delete deploy load-generator   # stop load; replicas fall back to 1 after ~1-5 min
```

**Cluster Autoscaler (nodes)** - `40-node-autoscaling.yaml`: 8 pods x 1 CPU cannot fit on 2 `t3a.large`
nodes, so some go `Pending` and Cluster Autoscaler raises the ASG.

```
kubectl apply -f examples/40-node-autoscaling.yaml
kubectl get nodes -w                           # new nodes appear within ~2-4 min
kubectl delete -f examples/40-node-autoscaling.yaml
kubectl get nodes -w                           # nodes removed after ~10 min unneeded
```

Tested: 2 -> 10 nodes (the ASG max) with both demos running; after deleting the load the HPA
returned to 1 pod and nodes fell back 10 -> 2 about 12 minutes later (the autoscaler's default
10-minute `scale-down-unneeded-time`, plus a few minutes to drain).
