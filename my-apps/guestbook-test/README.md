# Guestbook Test Application

A complete test application for your k3s-homelab demonstrating best practices for GitOps deployment with Argo CD.

## Architecture

This application consists of:

- **Redis Backend**: Persistent data store using Longhorn storage (1Gi PVC)
- **Frontend**: PHP web application with 2 replicas for high availability
- **LoadBalancer Service**: Exposed via Cilium L2 announcement for external access
- **Gateway API HTTPRoute**: Cloudflare Tunnel integration
- **TLS Certificate**: Automated cert-manager integration with Cloudflare DNS

## Features Demonstrated

✅ **Persistent Storage**: Uses Longhorn with `ReadWriteOnce` access mode  
✅ **Deployment Strategy**: Uses `Recreate` strategy to prevent multi-attach volume errors  
✅ **Resource Limits**: Proper CPU/memory requests and limits  
✅ **High Availability**: Frontend has 2 replicas for redundancy  
✅ **Service Mesh**: Compatible with Cilium networking  
✅ **GitOps**: Fully declarative with Argo CD auto-sync and self-heal  
✅ **Certificate Management**: Automated TLS with cert-manager  

## Directory Structure

```
my-apps/guestbook-test/
├── namespace.yaml              # Namespace definition
├── kustomization.yaml          # Kustomize configuration
├── deployment.yaml             # Frontend deployment
├── service.yaml                # Frontend LoadBalancer service
├── http-route.yaml             # Gateway API route
├── certificate.yaml            # TLS certificate
├── redis-deployment.yaml       # Redis backend deployment
├── redis-service.yaml          # Redis ClusterIP service
├── pvc.yaml                    # Redis persistent volume claim
├── application.yaml            # Argo CD Application definition
└── README.md                   # This file
```

## Deployment Instructions

### Option 1: Add to ApplicationSet (Recommended)

If you want this to be automatically discovered by your existing ApplicationSet:

1. **Copy files to repository:**
   ```bash
   # Files are already in my-apps/guestbook-test/
   ```

2. **Domain is already configured:**
   - `http-route.yaml`: Uses `guestbook.homelabjunkie.com`
   - `certificate.yaml`: Uses `guestbook.homelabjunkie.com`

3. **Commit and push:**
   ```bash
   git add my-apps/guestbook-test/
   git commit -m "Add guestbook test application"
   git push
   ```

4. **Your ApplicationSet will automatically discover and deploy it!**
   ```bash
   # Watch Argo CD sync the application
   kubectl get applications -n argocd -w
   ```

### Option 2: Manual Deployment

Apply the application directly:

```bash
# Apply the application definition
kubectl apply -f my-apps/guestbook-test/application.yaml

# Watch Argo CD sync
kubectl get application guestbook-test -n argocd -w
```

## Accessing the Application

### Via LoadBalancer IP

```bash
# Get the external IP assigned by Cilium
kubectl get svc guestbook-frontend -n guestbook-test

# Example output:
# NAME                  TYPE           CLUSTER-IP      EXTERNAL-IP      PORT(S)
# guestbook-frontend    LoadBalancer   10.43.123.45    192.168.101.100  80:30123/TCP

# Access in browser: http://192.168.101.100
```

### Via Cloudflare Tunnel (if configured)

Once DNS propagates: `https://guestbook.homelabjunkie.com`

## Verification Commands

```bash
# Check all resources
kubectl get all -n guestbook-test

# Check persistent volume
kubectl get pvc -n guestbook-test

# Check certificate status
kubectl get certificate -n guestbook-test

# View logs
kubectl logs -n guestbook-test -l app=guestbook --tail=50

# Check Argo CD sync status
kubectl describe application guestbook-test -n argocd
```

## Troubleshooting

### Pods stuck in Pending state

Check PVC binding:
```bash
kubectl describe pvc redis-pvc -n guestbook-test
```

Ensure Longhorn is running:
```bash
kubectl get pods -n longhorn-system
```

### LoadBalancer IP not assigned

Check Cilium L2 announcement policy:
```bash
kubectl get ciliuml2announcementpolicy -n kube-system
kubectl get ippools -n kube-system
```

### Certificate not issuing

Check cert-manager logs:
```bash
kubectl logs -n cert-manager -l app=cert-manager
kubectl describe certificate guestbook-cert -n guestbook-test
```

### Multi-attach volume errors

The deployment already uses `strategy: Recreate` to prevent this. If you still see errors:
```bash
# Force delete stuck pod
kubectl delete pod <pod-name> -n guestbook-test --force --grace-period=0
```

## Customization

### Change Redis Storage Size

Edit `pvc.yaml`:
```yaml
resources:
  requests:
    storage: 5Gi  # Increase from 1Gi
```

### Adjust Frontend Replicas

Edit `deployment.yaml`:
```yaml
spec:
  replicas: 3  # Increase from 2
```

### Remove Cloudflare Integration

Comment out or remove from `kustomization.yaml`:
```yaml
resources:
  # - http-route.yaml
  # - certificate.yaml
```

## Resource Usage

- **Redis**: 64Mi RAM / 50m CPU (requests), 256Mi RAM / 200m CPU (limits)
- **Frontend**: 64Mi RAM / 50m CPU per replica (requests), 256Mi RAM / 200m CPU (limits)
- **Total**: ~256Mi RAM, ~200m CPU with 2 frontend replicas
- **Storage**: 1Gi persistent volume for Redis data

## Cleanup

```bash
# Delete via Argo CD (recommended)
kubectl delete application guestbook-test -n argocd

# Or delete namespace directly
kubectl delete namespace guestbook-test
```

The persistent volume will be retained by Longhorn's default retention policy.

## Integration with Your Stack

This application integrates with your existing infrastructure:

- ✅ **Cilium**: Uses L2 LoadBalancer for external access
- ✅ **Longhorn**: Persistent storage for Redis data
- ✅ **Gateway API**: HTTPRoute for ingress traffic
- ✅ **cert-manager**: Automated TLS certificates via Cloudflare
- ✅ **Cloudflare**: DNS validation and tunnel support
- ✅ **Argo CD**: GitOps continuous deployment
- ✅ **Prometheus**: Service monitors can be added for metrics

## Next Steps

1. Add Prometheus ServiceMonitor for metrics collection
2. Create custom Grafana dashboard
3. Implement NetworkPolicy for security
4. Add Loki logging integration
5. Scale to multiple Redis replicas with StatefulSet

## References

- [Original Guestbook Example](https://kubernetes.io/docs/tutorials/stateless-application/guestbook/)
- [Your k3s-homelab Repository](https://github.com/homelabjunkie/k3s-homelab)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Cilium LoadBalancer IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
