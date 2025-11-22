#!/bin/bash

# Script to create all guestbook-test application files
# Usage: bash create-guestbook-app.sh

set -e

TARGET_DIR="my-apps/guestbook-test"

echo "Creating directory: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# 1. namespace.yaml
cat > "$TARGET_DIR/namespace.yaml" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: guestbook-test
  labels:
    name: guestbook-test
    app: guestbook-test
EOF

# 2. kustomization.yaml
cat > "$TARGET_DIR/kustomization.yaml" << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: guestbook-test

resources:
  - namespace.yaml
  - pvc.yaml
  - redis-deployment.yaml
  - redis-service.yaml
  - deployment.yaml
  - service.yaml
  - http-route.yaml
  - certificate.yaml
EOF

# 3. pvc.yaml
cat > "$TARGET_DIR/pvc.yaml" << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-pvc
  namespace: guestbook-test
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
EOF

# 4. redis-deployment.yaml
cat > "$TARGET_DIR/redis-deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: guestbook-test
  labels:
    app: redis
    tier: backend
spec:
  replicas: 1
  strategy:
    type: Recreate  # Required for ReadWriteOnce PVC
  selector:
    matchLabels:
      app: redis
      tier: backend
  template:
    metadata:
      labels:
        app: redis
        tier: backend
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
          name: redis
        volumeMounts:
        - name: redis-data
          mountPath: /data
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "200m"
      volumes:
      - name: redis-data
        persistentVolumeClaim:
          claimName: redis-pvc
EOF

# 5. redis-service.yaml
cat > "$TARGET_DIR/redis-service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: guestbook-test
  labels:
    app: redis
    tier: backend
spec:
  type: ClusterIP
  ports:
  - port: 6379
    targetPort: redis
  selector:
    app: redis
    tier: backend
EOF

# 6. deployment.yaml
cat > "$TARGET_DIR/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: guestbook-frontend
  namespace: guestbook-test
  labels:
    app: guestbook
    tier: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: guestbook
      tier: frontend
  template:
    metadata:
      labels:
        app: guestbook
        tier: frontend
    spec:
      containers:
      - name: guestbook
        image: gcr.io/google-samples/gb-frontend:v5
        ports:
        - containerPort: 80
          name: http
        env:
        - name: GET_HOSTS_FROM
          value: "env"
        - name: REDIS_MASTER_SERVICE_HOST
          value: "redis.guestbook-test.svc.cluster.local"
        resources:
          requests:
            memory: "64Mi"
            cpu: "50m"
          limits:
            memory: "256Mi"
            cpu: "200m"
EOF

# 7. service.yaml
cat > "$TARGET_DIR/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: guestbook-frontend
  namespace: guestbook-test
  labels:
    app: guestbook
    tier: frontend
  annotations:
    # Cilium L2 will assign an IP from your pool
    io.cilium/lb-ipam-ips: "auto"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: http
    protocol: TCP
    name: http
  selector:
    app: guestbook
    tier: frontend
EOF

# 8. http-route.yaml
cat > "$TARGET_DIR/http-route.yaml" << 'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: guestbook
  namespace: guestbook-test
spec:
  parentRefs:
  - name: gateway-api
    namespace: gateway
  - name: gateway-external
    namespace: gateway
  hostnames:
  - "guestbook.homelabjunkie.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: guestbook-frontend
      port: 80
EOF

# 9. certificate.yaml
cat > "$TARGET_DIR/certificate.yaml" << 'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: guestbook-cert
  namespace: guestbook-test
spec:
  secretName: guestbook-tls
  issuerRef:
    name: cloudflare-cluster-issuer
    kind: ClusterIssuer
  dnsNames:
  - "guestbook.homelabjunkie.com"
EOF

# 10. application.yaml
cat > "$TARGET_DIR/application.yaml" << 'EOF'
# ===========================================
# Argo CD Application for Guestbook Test
# ===========================================
# Place this in: my-apps/guestbook-test/application.yaml
# 
# This defines the application to be managed by Argo CD
# Compatible with your ApplicationSet pattern
# ===========================================

apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook-test
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: applications  # Uses your applications project
  
  source:
    repoURL: https://github.com/homelabjunkie/k3s-homelab
    targetRevision: main
    path: my-apps/guestbook-test
    kustomize:
      version: v5.0.0
  
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook-test
  
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    - RespectIgnoreDifferences=true
    - ApplyOutOfSyncOnly=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

# 11. README.md
cat > "$TARGET_DIR/README.md" << 'EOF'
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
EOF

echo ""
echo "✅ All files created successfully in: $TARGET_DIR"
echo ""
echo "Next steps:"
echo "1. cd $TARGET_DIR"
echo "2. Review the files"
echo "3. git add ."
echo "4. git commit -m 'Add guestbook test application'"
echo "5. git push"
echo "6. kubectl apply -f application.yaml"
echo ""
echo "Access: https://guestbook.homelabjunkie.com"