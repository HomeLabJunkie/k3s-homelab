#!/bin/bash

echo "=========================================="
echo "HTTPRoute Debugging for Guestbook"
echo "=========================================="
echo ""

echo "1. Current HTTPRoute Configuration:"
echo "-----------------------------------"
kubectl get httproute guestbook -n guestbook-test -o yaml
echo ""

echo "2. HTTPRoute Status:"
echo "-----------------------------------"
kubectl describe httproute guestbook -n guestbook-test
echo ""

echo "3. Compare with working ProxiTok HTTPRoute:"
echo "-----------------------------------"
kubectl get httproute -n proxitok -o yaml | head -30
echo ""

echo "4. Gateway Status:"
echo "-----------------------------------"
kubectl describe gateway gateway-external -n gateway | grep -A 30 "Attached Routes"
echo ""

echo "5. Test Service Directly (cluster internal):"
echo "-----------------------------------"
kubectl run test-curl --image=curlimages/curl --rm -i --restart=Never -- curl -s -o /dev/null -w "%{http_code}" http://guestbook-frontend.guestbook-test.svc.cluster.local
echo ""

echo "6. Test via Gateway IP:"
echo "-----------------------------------"
GATEWAY_IP=$(kubectl get gateway gateway-external -n gateway -o jsonpath='{.status.addresses[0].value}')
echo "Gateway IP: $GATEWAY_IP"
echo "Testing with Host header..."
curl -s -o /dev/null -w "%{http_code}\n" -H "Host: guestbook.homelabjunkie.com" http://$GATEWAY_IP/
echo ""

echo "7. Check if HTTPRoute is in gateway-external listeners:"
echo "-----------------------------------"
kubectl get gateway gateway-external -n gateway -o yaml | grep -A 50 "attachedRoutes"
echo ""

echo "=========================================="
echo "Debugging Complete"
echo "=========================================="