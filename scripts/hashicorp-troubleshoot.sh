#!/bin/bash

echo "=== Vault Troubleshooting Script ==="
echo ""

echo "1. Checking Vault pods status:"
kubectl get pods -n hashicorp -l app.kubernetes.io/name=vault
echo ""

echo "2. Checking Vault status (sealed/unsealed):"
kubectl exec -n hashicorp vault-0 -- vault status
echo ""

echo "3. Checking Vault services:"
kubectl get svc -n hashicorp -l app.kubernetes.io/name=vault
echo ""

echo "4. Checking ingress resources:"
kubectl get ingress -n hashicorp
echo ""

echo "5. Describing ingress (if exists):"
kubectl describe ingress -n hashicorp 2>/dev/null
echo ""

echo "6. Checking recent vault-0 logs:"
kubectl logs -n hashicorp vault-0 --tail=50
echo ""

echo "=== Troubleshooting Complete ==="
echo ""
echo "If Vault shows 'Sealed: true', you need to unseal it first:"
echo "  kubectl exec -n hashicorp vault-0 -- vault operator init"
echo "  (Save the unseal keys and root token!)"
echo "  kubectl exec -n hashicorp vault-0 -- vault operator unseal <key1>"
echo "  kubectl exec -n hashicorp vault-0 -- vault operator unseal <key2>"
echo "  kubectl exec -n hashicorp vault-0 -- vault operator unseal <key3>"
