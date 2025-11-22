#!/bin/bash

# Troubleshooting script for guestbook-test application
# Run this to diagnose deployment issues

echo "=========================================="
echo "Guestbook Test Application Diagnostics"
echo "=========================================="
echo ""

# Check if namespace exists
echo "1. Checking namespace..."
kubectl get namespace guestbook-test 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ Namespace 'guestbook-test' does not exist!"
    exit 1
fi
echo "✅ Namespace exists"
echo ""

# Check Argo CD application status
echo "2. Checking Argo CD Application..."
kubectl get application guestbook-test -n argocd -o wide 2>/dev/null
echo ""
kubectl describe application guestbook-test -n argocd 2>/dev/null | grep -A 5 "Status:"
echo ""

# Check all pods
echo "3. Checking Pods..."
kubectl get pods -n guestbook-test -o wide
echo ""

# Check pod details if any are not running
echo "4. Checking Pod Events..."
kubectl get pods -n guestbook-test --no-headers 2>/dev/null | while read pod rest; do
    status=$(echo $rest | awk '{print $3}')
    if [[ "$status" != "Running" ]]; then
        echo "--- Pod: $pod (Status: $status) ---"
        kubectl describe pod $pod -n guestbook-test | tail -20
        echo ""
    fi
done

# Check PVC status
echo "5. Checking Persistent Volume Claims..."
kubectl get pvc -n guestbook-test
echo ""

# Check services
echo "6. Checking Services..."
kubectl get svc -n guestbook-test -o wide
echo ""

# Check LoadBalancer IP
echo "7. Checking LoadBalancer External IP..."
LB_IP=$(kubectl get svc guestbook-frontend -n guestbook-test -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$LB_IP" ]; then
    echo "❌ No External IP assigned yet!"
    echo "   Checking Cilium LoadBalancer IPAM..."
    kubectl get ippools -n kube-system
    echo ""
    kubectl get ciliuml2announcementpolicy -n kube-system
else
    echo "✅ External IP: $LB_IP"
    echo "   Try accessing: http://$LB_IP"
fi
echo ""

# Check HTTPRoute
echo "8. Checking HTTPRoute..."
kubectl get httproute -n guestbook-test
echo ""
kubectl describe httproute guestbook -n guestbook-test 2>/dev/null | grep -A 10 "Status:"
echo ""

# Check if gateways exist
echo "9. Checking Gateway API Gateways..."
kubectl get gateway -n gateway 2>/dev/null
if [ $? -ne 0 ]; then
    echo "⚠️  Gateway namespace might not exist"
    echo "   Checking for gateways in other namespaces..."
    kubectl get gateway -A
fi
echo ""

# Check certificate
echo "10. Checking Certificate..."
kubectl get certificate -n guestbook-test
echo ""
kubectl describe certificate guestbook-cert -n guestbook-test 2>/dev/null | grep -A 5 "Status:"
echo ""

# Check cert-manager
echo "11. Checking cert-manager..."
kubectl get pods -n cert-manager
echo ""

# Check Cloudflare secrets
echo "12. Checking Cloudflare secrets..."
kubectl get secret cloudflare-api-token -n cert-manager 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ Cloudflare API token secret not found in cert-manager namespace"
fi
echo ""

# Check ClusterIssuer
echo "13. Checking ClusterIssuer..."
kubectl get clusterissuer cloudflare-cluster-issuer 2>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ cloudflare-cluster-issuer not found!"
fi
echo ""

# Check endpoints
echo "14. Checking Service Endpoints..."
kubectl get endpoints -n guestbook-test
echo ""

# Recent events
echo "15. Recent Events in guestbook-test namespace..."
kubectl get events -n guestbook-test --sort-by='.lastTimestamp' | tail -20
echo ""

echo "=========================================="
echo "Diagnostics Complete"
echo "=========================================="
echo ""
echo "Common Issues to Check:"
echo "1. If pods are Pending - check PVC and Longhorn"
echo "2. If no External IP - check Cilium L2 announcement and IP pools"
echo "3. If certificate is not ready - check cert-manager logs"
echo "4. If gateway-api/gateway-external not found - check gateway namespace"
echo ""
echo "Next Steps:"
echo "- Check pod logs: kubectl logs -n guestbook-test <pod-name>"
echo "- Check Cilium: cilium status"
echo "- Check Longhorn: kubectl get pods -n longhorn-system"
echo "- Check gateway: kubectl get gateway -A"