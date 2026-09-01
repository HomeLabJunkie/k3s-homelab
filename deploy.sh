#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3S_DIR="${K3S_DIR:-$SCRIPT_DIR}"
ENV_FILE="${ENV_FILE:-$K3S_DIR/config/cluster.env}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "ERROR: cluster environment file is missing or unreadable: $ENV_FILE"
  exit 1
fi

# Export cluster configuration for Ansible lookup('env', ...) expressions.
set -a
source "$ENV_FILE"
set +a

KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE:-$K3S_DIR/kubeconfig}"
KUBECONFIG_TARGET="${KUBECONFIG_TARGET:-$HOME/.kube/config}"

CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.21.1}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-41.2.0}"
RANCHER_CHART_VERSION="${RANCHER_CHART_VERSION:-2.14.3}"
LONGHORN_CHART_VERSION="${LONGHORN_CHART_VERSION:-1.12.0}"

RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.example.invalid}"
RANCHER_ADMIN_USER="${RANCHER_ADMIN_USER:-admin}"

TRAEFIK_VALUES="${TRAEFIK_VALUES:-$K3S_DIR/traefik-values.yaml}"
CLUSTERISSUER_MANIFEST="${CLUSTERISSUER_MANIFEST:-$K3S_DIR/clusterissuer-letsencrypt.yaml}"
TRAEFIK_DASHBOARD_MANIFEST="${TRAEFIK_DASHBOARD_MANIFEST:-$K3S_DIR/traefik-dashboard.yaml}"
TRAEFIK_DASHBOARD_CERT_MANIFEST="${TRAEFIK_DASHBOARD_CERT_MANIFEST:-$K3S_DIR/traefik-dashboard-cert.yaml}"
CLOUDFLARED_MANIFEST="${CLOUDFLARED_MANIFEST:-$K3S_DIR/cloudflared.yaml}"
LONGHORN_HOST_PREP_PLAYBOOK="${LONGHORN_HOST_PREP_PLAYBOOK:-$K3S_DIR/longhorn-host-prep.yml}"
LONGHORN_VALUES="${LONGHORN_VALUES:-$K3S_DIR/longhorn-values.yaml}"
LONGHORN_INGRESS_MANIFEST="${LONGHORN_INGRESS_MANIFEST:-$K3S_DIR/longhorn-ingress.yaml}"
LONGHORN_HOSTNAME="${LONGHORN_HOSTNAME:-longhorn.example.invalid}"
TRILIUM_MANIFEST="${TRILIUM_MANIFEST:-$K3S_DIR/trilium-longhorn-v2.yaml}"
TRILIUM_HOSTNAME="${TRILIUM_HOSTNAME:-trilium.example.invalid}"
VAULTWARDEN_MANIFEST="${VAULTWARDEN_MANIFEST:-$K3S_DIR/vaultwarden-longhorn-v2.yaml}"
VAULTWARDEN_HOSTNAME="${VAULTWARDEN_HOSTNAME:-vaultwarden.example.invalid}"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-87.21.0}"
MONITORING_VALUES="${MONITORING_VALUES:-$K3S_DIR/monitoring-values.yaml}"
MONITORING_INGRESS="${MONITORING_INGRESS:-$K3S_DIR/monitoring-ingress.yaml}"
MONITORING_LONGHORN="${MONITORING_LONGHORN:-$K3S_DIR/monitoring-longhorn-v2.yaml}"
MONITORING_DASHBOARDS="${MONITORING_DASHBOARDS:-$K3S_DIR/monitoring-dashboards.yaml}"
GRAFANA_HOSTNAME="${GRAFANA_HOSTNAME:-grafana.example.invalid}"
PORTAINER_CHART_VERSION="${PORTAINER_CHART_VERSION:-245.0.0}"
PORTAINER_VALUES="${PORTAINER_VALUES:-$K3S_DIR/portainer-values.yaml}"
PORTAINER_INGRESS="${PORTAINER_INGRESS:-$K3S_DIR/portainer-ingress.yaml}"
PORTAINER_HOSTNAME="${PORTAINER_HOSTNAME:-portainer.example.invalid}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-18.9.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.11.1}"
LOKI_VALUES="${LOKI_VALUES:-$K3S_DIR/loki-values.yaml}"
ALLOY_VALUES="${ALLOY_VALUES:-$K3S_DIR/alloy-values.yaml}"
LOKI_DATASOURCE="${LOKI_DATASOURCE:-$K3S_DIR/monitoring-loki-datasource.yaml}"
MONITORING_DASHBOARDS_V2="${MONITORING_DASHBOARDS_V2:-$K3S_DIR/monitoring-dashboards-v3.yaml}"
LONGHORN_STORAGE_RESERVED_BYTES="${LONGHORN_STORAGE_RESERVED_BYTES:-53687091200}"

PF_PID=""

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

on_error() {
  local line="$1"
  echo
  echo "ERROR: deployment failed near line ${line}."
  echo "Fix the reported error, then rerun this script; Helm/kubectl steps are designed to be idempotent."
}
trap 'on_error "$LINENO"' ERR

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $cmd"
    exit 1
  }
}

require_file() {
  local file="$1"
  [[ -r "$file" ]] || {
    echo "ERROR: required file not found or unreadable: $file"
    exit 1
  }
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || {
    echo "ERROR: required secret/environment variable is empty: $name"
    exit 1
  }
}

ensure_namespace() {
  local ns="$1"
  [[ -n "$ns" ]] || return 0
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

apply_manifest() {
  local file="$1"
  local output ns attempt
  require_file "$file"

  for attempt in {1..10}; do
    if output="$(kubectl apply -f "$file" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi

    printf '%s\n' "$output"

    if [[ "$output" =~ namespaces\ \"([^\"]+)\"\ not\ found ]]; then
      ns="${BASH_REMATCH[1]}"
      echo "==> Creating missing namespace: $ns"
      ensure_namespace "$ns"
      continue
    fi

    return 1
  done

  echo "ERROR: could not apply $file after creating missing namespaces."
  return 1
}

cd "$K3S_DIR"

PREFLIGHT_ONLY=false
DEPLOY_MODE="existing"

while (( $# > 0 )); do
  case "$1" in
    --preflight-only)
      PREFLIGHT_ONLY=true
      shift
      ;;
    --bootstrap)
      DEPLOY_MODE="bootstrap"
      shift
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

echo "Deployment mode: $DEPLOY_MODE"

for cmd in ansible ansible-playbook ansible-galaxy kubectl helm curl python3 envsubst; do
  require_command "$cmd"
done

echo "==> Validating Ansible/Python toolchain..."
"$K3S_DIR/scripts/check-ansible-toolchain.sh"

echo "==> Verifying project-local Ansible collections..."
"$K3S_DIR/scripts/ensure-ansible-collections.sh"

if [[ -f "$K3S_DIR/.secrets.enc" ]]; then
  require_command sops
fi

echo "==> Validating cluster environment..."
for var in \
  BASE_DOMAIN \
  KUBE_VIP \
  K3S_NODE_0 \
  K3S_NODE_1 \
  K3S_NODE_2 \
  K3S_NODE_3 \
  K3S_NODE_4 \
  K3S_NODE_5 \
  METALLB_IP_RANGE
do
  require_var "$var"
done

python3 - "$KUBE_VIP" <<'PY_VALIDATE_VIP'
import ipaddress
import sys

value = sys.argv[1].strip()

try:
    ip = ipaddress.ip_address(value)
except ValueError:
    raise SystemExit(f"ERROR: KUBE_VIP is not a valid IP address: {value!r}")

if ip.version != 4:
    raise SystemExit(f"ERROR: KUBE_VIP must currently be IPv4: {value}")

if ip.is_unspecified or ip.is_multicast or ip.is_loopback:
    raise SystemExit(f"ERROR: KUBE_VIP is not a usable cluster VIP: {value}")

if ip in ipaddress.ip_network("192.0.2.0/24"):
    raise SystemExit(
        f"ERROR: KUBE_VIP {value} is in the TEST-NET documentation range"
    )

print(f"Validated KUBE_VIP: {ip}")
PY_VALIDATE_VIP

echo "==> Rendering cluster environment..."
ENV_FILE="$ENV_FILE" "$K3S_DIR/scripts/prepare-env.sh"

for file in \
  "$TRAEFIK_VALUES" \
  "$CLUSTERISSUER_MANIFEST" \
  "$TRAEFIK_DASHBOARD_MANIFEST" \
  "$TRAEFIK_DASHBOARD_CERT_MANIFEST" \
  "$CLOUDFLARED_MANIFEST" \
  "$LONGHORN_HOST_PREP_PLAYBOOK" \
  "$LONGHORN_VALUES" \
  "$LONGHORN_INGRESS_MANIFEST" \
  "$TRILIUM_MANIFEST" \
  "$VAULTWARDEN_MANIFEST" \
  "$MONITORING_VALUES" \
  "$MONITORING_INGRESS" \
  "$MONITORING_LONGHORN" \
  "$MONITORING_DASHBOARDS" \
  "$PORTAINER_VALUES" \
  "$PORTAINER_INGRESS" \
  "$LOKI_VALUES" \
  "$ALLOY_VALUES" \
  "$LOKI_DATASOURCE" \
  "$MONITORING_DASHBOARDS_V2" \
  "$K3S_DIR/website.yaml"
do
  require_file "$file"
done

echo "==> Loading secrets..."
set -a
if [[ -f "$K3S_DIR/.secrets.enc" ]]; then
  source <(sops --decrypt "$K3S_DIR/.secrets.enc")
elif [[ -f "$K3S_DIR/.secrets" ]]; then
  source "$K3S_DIR/.secrets"
else
  echo "ERROR: neither $K3S_DIR/.secrets.enc nor $K3S_DIR/.secrets exists"
  exit 1
fi
set +a

for var in \
  KUBE_VIP \
  K3S_TOKEN \
  RANCHER_BOOTSTRAP_PASSWORD \
  RANCHER_ADMIN_PASSWORD \
  CLOUDFLARE_API_TOKEN \
  CLOUDFLARE_TUNNEL_TOKEN \
  VAULTWARDEN_ADMIN_TOKEN \
  VAULTWARDEN_INITIAL_EMAIL \
  VAULTWARDEN_SMTP_USERNAME \
  VAULTWARDEN_SMTP_PASSWORD \
  VAULTWARDEN_YUBICO_SECRET_KEY \
  GRAFANA_ADMIN_PASSWORD
do
  require_var "$var"
done

if (( ${#RANCHER_ADMIN_PASSWORD} < 12 )); then
  echo "ERROR: RANCHER_ADMIN_PASSWORD must be at least 12 characters."
  exit 1
fi

if [[ "$DEPLOY_MODE" == "bootstrap" ]]; then
  ANSIBLE_PLAYBOOK="site.yml"
else
  ANSIBLE_PLAYBOOK="maintenance/reconcile-existing-cluster.yml"
fi

echo "==> Validating Ansible syntax: $ANSIBLE_PLAYBOOK"
ansible-playbook   -i inventory/k3s-ansible/hosts.ini   "$ANSIBLE_PLAYBOOK"   --syntax-check

echo "==> Validating rendered control-plane configuration..."
ansible-playbook   -i inventory/k3s-ansible/hosts.ini   /dev/stdin <<'ANSIBLE_PREFLIGHT'
---
- name: Validate rendered K3s control-plane configuration
  hosts: master
  gather_facts: true
  tasks:
    - name: Validate critical rendered values
      ansible.builtin.assert:
        that:
          - apiserver_endpoint == lookup('env', 'KUBE_VIP')
          - apiserver_endpoint | trim | length > 0
          - k3s_node_ip | trim | length > 0
          - ('--tls-san=' + apiserver_endpoint) in extra_server_args
          - ('--node-ip=' + k3s_node_ip) in extra_server_args
          - "'--disable-agent' not in extra_server_args"
          - "'--disable-kube-proxy' not in extra_server_args"
        fail_msg: >-
          Rendered K3s configuration is unsafe. Deployment will not proceed.

    - name: Show validated configuration
      ansible.builtin.debug:
        msg:
          - "node={{ inventory_hostname }}"
          - "node_ip={{ k3s_node_ip }}"
          - "api_vip={{ apiserver_endpoint }}"
          - "server_args={{ extra_server_args }}"
ANSIBLE_PREFLIGHT

if [[ "$PREFLIGHT_ONLY" == true ]]; then
  echo
  echo "============================================"
  echo " DEPLOYMENT PREFLIGHT PASSED"
  echo "============================================"
  echo "No cluster changes were made."
  exit 0
fi

if [[ "$DEPLOY_MODE" == "bootstrap" ]]; then
  echo "==> Running INITIAL CLUSTER BOOTSTRAP..."
  echo "WARNING: bootstrap mode was explicitly requested."
  ansible-playbook     -i inventory/k3s-ansible/hosts.ini     site.yml "$@"
else
  echo "==> Reconciling EXISTING K3s cluster..."
  ansible-playbook     -i inventory/k3s-ansible/hosts.ini     maintenance/reconcile-existing-cluster.yml "$@"
fi

echo "==> Preparing all nodes for Longhorn..."
ansible-playbook -i inventory/k3s-ansible/hosts.ini "$LONGHORN_HOST_PREP_PLAYBOOK"

echo "==> Updating local kubeconfig..."
mkdir -p "$(dirname "$KUBECONFIG_TARGET")"
cp "$KUBECONFIG_SOURCE" "$KUBECONFIG_TARGET"
chmod 600 "$KUBECONFIG_TARGET"
sed -i -E \
  "s#server: https://([0-9]{1,3}\.){3}[0-9]{1,3}:6443#server: https://${KUBE_VIP}:6443#" \
  "$KUBECONFIG_TARGET"
export KUBECONFIG="$KUBECONFIG_TARGET"

echo "==> Waiting for Kubernetes API..."
for i in {1..60}; do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Kubernetes API did not become ready at https://${KUBE_VIP}:6443"
    exit 1
  fi
  sleep 5
done

echo "==> Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "==> Configuring Helm repositories..."
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo add longhorn https://charts.longhorn.io --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add portainer https://portainer.github.io/k8s/ --force-update
helm repo add grafana-community https://grafana-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update >/dev/null

echo "==> Installing cert-manager ${CERT_MANAGER_CHART_VERSION}..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_CHART_VERSION" \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout=300s

kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s

echo "==> Creating/updating Cloudflare API token secret..."
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token="$CLOUDFLARE_API_TOKEN" \
  --namespace cert-manager \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating ClusterIssuer..."
apply_manifest "$CLUSTERISSUER_MANIFEST"
kubectl wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=180s

echo "==> Validating Traefik Helm values against chart ${TRAEFIK_CHART_VERSION}..."
helm template traefik traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik \
  --values "$TRAEFIK_VALUES" >/dev/null

echo "==> Installing Traefik ${TRAEFIK_CHART_VERSION}..."
helm upgrade --install traefik traefik/traefik \
  --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik \
  --create-namespace \
  --values "$TRAEFIK_VALUES" \
  --wait \
  --timeout=300s

kubectl -n traefik rollout status deployment/traefik --timeout=180s
kubectl -n traefik get svc traefik

echo "==> Deploying Traefik dashboard and certificate..."
apply_manifest "$TRAEFIK_DASHBOARD_MANIFEST"
apply_manifest "$TRAEFIK_DASHBOARD_CERT_MANIFEST"
if kubectl -n traefik get certificate tls-traefik-dashboard >/dev/null 2>&1; then
  kubectl -n traefik wait --for=condition=Ready certificate/tls-traefik-dashboard --timeout=300s
fi

# ------------------------------------------------------------------------------
# Longhorn
# ------------------------------------------------------------------------------

echo "==> Configuring all Kubernetes nodes for dedicated Longhorn storage..."
LONGHORN_DISK_CONFIG="$(python3 -c 'import json,sys; reserved=int(sys.argv[1]); print(json.dumps([{"name":"storage","path":"/var/lib/storage/longhorn","allowScheduling":True,"storageReserved":reserved,"tags":["ssd"]}], separators=(",",":")))' "$LONGHORN_STORAGE_RESERVED_BYTES")"
while read -r NODE; do
  [[ -n "$NODE" ]] || continue
  kubectl annotate node "$NODE" node.longhorn.io/default-disks-config="$LONGHORN_DISK_CONFIG" --overwrite
  kubectl label node "$NODE" node.longhorn.io/create-default-disk=config --overwrite
done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

echo "==> Installing Longhorn ${LONGHORN_CHART_VERSION}..."
helm upgrade --install longhorn longhorn/longhorn \
  --version "$LONGHORN_CHART_VERSION" \
  --namespace longhorn-system \
  --create-namespace \
  --values "$LONGHORN_VALUES" \
  --wait \
  --timeout=600s

echo "==> Waiting for Longhorn core components..."
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout=600s
kubectl -n longhorn-system rollout status deployment/longhorn-driver-deployer --timeout=600s
kubectl -n longhorn-system rollout status deployment/longhorn-ui --timeout=600s

echo "==> Waiting for Longhorn pods to become Ready..."
kubectl -n longhorn-system wait \
  --for=condition=Ready \
  pod \
  --all \
  --timeout=600s

echo "==> Deploying Longhorn HTTPS ingress..."
apply_manifest "$LONGHORN_INGRESS_MANIFEST"
kubectl -n longhorn-system wait --for=condition=Ready certificate/tls-longhorn-ingress --timeout=300s

echo "==> Verifying all Longhorn nodes have the dedicated storage disk..."
EXPECTED_LONGHORN_NODES="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
for i in {1..60}; do
  READY_LONGHORN_NODES="$(kubectl -n longhorn-system get nodes.longhorn.io -o json 2>/dev/null | python3 -c 'import json,sys
try: data=json.load(sys.stdin)
except Exception: print(0); raise SystemExit
count=0
for item in data.get("items",[]):
    disks=item.get("spec",{}).get("disks",{})
    if any(d.get("path")=="/var/lib/storage/longhorn" and d.get("allowScheduling") is True for d in disks.values()): count += 1
print(count)' || true)"
  if [[ "$READY_LONGHORN_NODES" == "$EXPECTED_LONGHORN_NODES" ]]; then break; fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Expected ${EXPECTED_LONGHORN_NODES} Longhorn nodes with dedicated storage; found ${READY_LONGHORN_NODES}."
    kubectl -n longhorn-system get nodes.longhorn.io -o yaml || true
    exit 1
  fi
  echo "  waiting for Longhorn disks... ${READY_LONGHORN_NODES}/${EXPECTED_LONGHORN_NODES}"
  sleep 5
done
kubectl -n longhorn-system get nodes.longhorn.io
kubectl get storageclass longhorn

echo "==> Making Longhorn the default StorageClass..."
kubectl patch storageclass longhorn \
  --type merge \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

if kubectl get storageclass local-path >/dev/null 2>&1; then
  kubectl patch storageclass local-path \
    --type merge \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

# ------------------------------------------------------------------------------
# Monitoring - kube-prometheus-stack
# ------------------------------------------------------------------------------

echo "==> Preparing monitoring namespace and Grafana credentials..."
ensure_namespace monitoring

kubectl create secret generic grafana-admin \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}..."
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$KUBE_PROMETHEUS_STACK_VERSION" \
  --namespace monitoring \
  --create-namespace \
  --values "$MONITORING_VALUES" \
  --wait \
  --timeout=900s

echo "==> Applying Longhorn monitoring, dashboards, alerts, and Grafana HTTPS..."
apply_manifest "$MONITORING_LONGHORN"
apply_manifest "$MONITORING_DASHBOARDS"
apply_manifest "$MONITORING_INGRESS"

echo "==> Waiting for Grafana TLS certificate..."
kubectl -n monitoring wait \
  --for=condition=Ready \
  certificate/tls-grafana-ingress \
  --timeout=300s

echo "==> Waiting for monitoring deployments..."
kubectl -n monitoring rollout status deployment/monitoring-grafana --timeout=600s
kubectl -n monitoring rollout status deployment/monitoring-kube-prometheus-operator --timeout=600s
kubectl -n monitoring rollout status deployment/monitoring-kube-state-metrics --timeout=600s

echo "==> Waiting for Prometheus and Alertmanager..."
for i in {1..120}; do
  PROM_READY="$(
    kubectl -n monitoring get pods \
      -l app.kubernetes.io/name=prometheus \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
      2>/dev/null | grep -c '^true$' || true
  )"

  AM_READY="$(
    kubectl -n monitoring get pods \
      -l app.kubernetes.io/name=alertmanager \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
      2>/dev/null | grep -c '^true$' || true
  )"

  if [[ "$PROM_READY" -ge 1 && "$AM_READY" -ge 1 ]]; then
    break
  fi

  if [[ "$i" -eq 120 ]]; then
    echo "ERROR: Prometheus or Alertmanager did not become Ready."
    kubectl -n monitoring get pods -o wide || true
    exit 1
  fi

  echo "  waiting for monitoring stateful workloads..."
  sleep 5
done

echo "==> Verifying monitoring PVCs are Longhorn-backed..."
kubectl -n monitoring get pvc -o wide

NON_LONGHORN_PVCS="$(
  kubectl -n monitoring get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.storageClassName}{"\n"}{end}' \
  | grep -v '=longhorn$' || true
)"

if [[ -n "$NON_LONGHORN_PVCS" ]]; then
  echo "ERROR: One or more monitoring PVCs are not using Longhorn:"
  printf '%s\n' "$NON_LONGHORN_PVCS"
  exit 1
fi

echo "==> Verifying Longhorn ServiceMonitor and baseline alert rules..."
kubectl -n monitoring get servicemonitor longhorn-prometheus-servicemonitor
kubectl -n monitoring get prometheusrule homelab-baseline-alerts

echo "==> Monitoring stack is ready."

# ------------------------------------------------------------------------------
# Logging - Loki + Alloy
# ------------------------------------------------------------------------------

echo "==> Preparing logging namespace..."
ensure_namespace logging

echo "==> Installing Loki ${LOKI_CHART_VERSION}..."
helm upgrade --install loki grafana-community/loki \
  --version "$LOKI_CHART_VERSION" \
  --namespace logging \
  --create-namespace \
  --values "$LOKI_VALUES" \
  --wait --timeout=900s

echo "==> Installing Grafana Alloy ${ALLOY_CHART_VERSION}..."
helm upgrade --install alloy grafana/alloy \
  --version "$ALLOY_CHART_VERSION" \
  --namespace logging \
  --create-namespace \
  --values "$ALLOY_VALUES" \
  --wait --timeout=600s

echo "==> Adding Loki datasource and expanded dashboards..."
apply_manifest "$LOKI_DATASOURCE"
apply_manifest "$MONITORING_DASHBOARDS_V2"

echo "==> Verifying Loki storage..."
kubectl -n logging get pvc -o wide
if ! kubectl -n logging get pvc -o jsonpath='{range .items[*]}{.status.phase}{"="}{.spec.storageClassName}{"\n"}{end}' | grep -q '^Bound=longhorn$'; then
  echo "ERROR: Loki PVC is not Bound on Longhorn."
  exit 1
fi

echo "==> Waiting for Loki and Alloy..."
kubectl -n logging rollout status statefulset/loki --timeout=600s
kubectl -n logging rollout status deployment/alloy --timeout=600s

echo "==> Logging stack is ready."

echo "==> Preparing Portainer namespace..."
ensure_namespace portainer

echo "==> Installing Portainer CE chart ${PORTAINER_CHART_VERSION}..."
helm upgrade --install portainer portainer/portainer \
  --version "$PORTAINER_CHART_VERSION" \
  --namespace portainer \
  --create-namespace \
  --values "$PORTAINER_VALUES" \
  --wait \
  --timeout=600s

echo "==> Applying Portainer HTTPS ingress..."
apply_manifest "$PORTAINER_INGRESS"

echo "==> Waiting for Portainer TLS certificate..."
kubectl -n portainer wait \
  --for=condition=Ready \
  certificate/tls-portainer-ingress \
  --timeout=300s

echo "==> Waiting for Portainer deployment..."
kubectl -n portainer rollout status deployment/portainer --timeout=600s

echo "==> Verifying Portainer PVC is Bound and Longhorn-backed..."
PORTAINER_PVC="$(
  kubectl -n portainer get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"="}{.spec.storageClassName}{"\n"}{end}'
)"
printf '%s\n' "$PORTAINER_PVC"

if ! printf '%s\n' "$PORTAINER_PVC" | grep -q '=Bound=longhorn$'; then
  echo "ERROR: Portainer PVC is not Bound on Longhorn."
  kubectl -n portainer get pvc -o wide || true
  exit 1
fi

echo "==> Verifying Portainer service endpoints..."
for i in {1..60}; do
  endpoints="$(
    kubectl -n portainer get endpointslice \
      -l kubernetes.io/service-name=portainer \
      -o go-template='{{range .items}}{{range .endpoints}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}' \
      2>/dev/null || true
  )"
  if [[ -n "$endpoints" ]]; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Portainer service has no ready endpoints."
    kubectl -n portainer get pods,svc,endpointslice -o wide || true
    exit 1
  fi
  sleep 5
done

echo "==> Portainer is ready."

echo "==> Preparing Rancher namespace..."
ensure_namespace cattle-system

echo "==> Creating Rancher TLS certificate..."
kubectl apply -f - <<EOF_RANCHER_CERT
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
spec:
  secretName: tls-rancher-ingress
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
    group: cert-manager.io
  dnsNames:
    - ${RANCHER_HOSTNAME}
EOF_RANCHER_CERT

kubectl -n cattle-system wait --for=condition=Ready certificate/tls-rancher-ingress --timeout=300s

echo "==> Installing Rancher ${RANCHER_CHART_VERSION}..."
helm upgrade --install rancher rancher-stable/rancher \
  --version "$RANCHER_CHART_VERSION" \
  --namespace cattle-system \
  --create-namespace \
  --set-string hostname="$RANCHER_HOSTNAME" \
  --set ingress.tls.source=secret \
  --set ingress.ingressClassName=traefik \
  --set replicas=2 \
  --set-string bootstrapPassword="$RANCHER_BOOTSTRAP_PASSWORD" \
  --wait \
  --timeout=600s

kubectl -n cattle-system rollout status deployment/rancher --timeout=600s

kubectl -n cattle-system get ingress rancher \
  -o jsonpath='{.spec.ingressClassName}{" "}{.spec.tls[0].secretName}{"\n"}' \
  | grep -qx 'traefik tls-rancher-ingress'

echo "==> Deploying Cloudflare tunnel..."
ensure_namespace cloudflared
kubectl create secret generic tunnel-token \
  --from-literal=token="$CLOUDFLARE_TUNNEL_TOKEN" \
  --namespace cloudflared \
  --dry-run=client -o yaml | kubectl apply -f -
apply_manifest "$CLOUDFLARED_MANIFEST"
kubectl -n cloudflared rollout status deployment/cloudflared --timeout=180s

echo "==> Configuring Rancher admin credentials..."
kubectl port-forward -n cattle-system svc/rancher 8443:443 >/dev/null 2>&1 &
PF_PID=$!

for i in {1..30}; do
  if curl -sk --connect-timeout 2 https://localhost:8443/ping >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

ACTUAL_BOOTSTRAP="$(
  kubectl get secret -n cattle-system bootstrap-secret \
    -o go-template='{{.data.bootstrapPassword|base64decode}}' \
    2>/dev/null || printf '%s' "$RANCHER_BOOTSTRAP_PASSWORD"
)"

LOGIN_PAYLOAD="$(python3 -c 'import json,sys; print(json.dumps({"username":"admin","password":sys.argv[1]}))' "$ACTUAL_BOOTSTRAP")"
LOGIN_TOKEN=""

for i in {1..20}; do
  LOGIN_TOKEN="$(
    curl -sk -X POST \
      "https://localhost:8443/v3-public/localProviders/local?action=login" \
      -H "Content-Type: application/json" \
      -d "$LOGIN_PAYLOAD" 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' || true
  )"

  if [[ -n "$LOGIN_TOKEN" ]]; then
    echo "  Rancher API ready"
    break
  fi

  echo "  waiting for Rancher API... ($i/20)"
  sleep 15
done

if [[ -n "$LOGIN_TOKEN" ]]; then
  ADMIN_USER_ID="$(
    kubectl get users.management.cattle.io \
      -o jsonpath='{range .items[?(@.username=="admin")]}{.metadata.name}{"\n"}{end}' \
    | head -n1
  )"

  if [[ -z "$ADMIN_USER_ID" ]]; then
    echo "ERROR: Could not determine Rancher admin user ID."
    exit 1
  fi

  echo "==> Changing Rancher admin password for ${ADMIN_USER_ID}..."

  kubectl create -f - <<EOF
apiVersion: ext.cattle.io/v1
kind: PasswordChangeRequest
metadata:
  generateName: admin-password-change-
spec:
  userID: "${ADMIN_USER_ID}"
  currentPassword: "${ACTUAL_BOOTSTRAP}"
  newPassword: "${RANCHER_ADMIN_PASSWORD}"
EOF

  echo "==> Setting Rancher server URL..."

  SERVER_URL_PAYLOAD="$(
    python3 -c 'import json,sys; print(json.dumps({"value":sys.argv[1]}))' \
      "https://${RANCHER_HOSTNAME}"
  )"

  curl -fsSk -X PUT \
    "https://localhost:8443/v3/settings/server-url" \
    -H "Authorization: Bearer ${LOGIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$SERVER_URL_PAYLOAD" \
    >/dev/null

  echo "==> Rancher admin credentials configured successfully"
else
  echo "WARNING: Could not configure Rancher credentials automatically."
  echo "         Rancher itself remains installed; configure the admin account manually."
fi

cleanup
PF_PID=""

echo "==> Deploying Trilium with Longhorn storage..."
apply_manifest "$TRILIUM_MANIFEST"

echo "==> Waiting for Trilium Longhorn PVC to bind..."
for i in {1..60}; do
  phase="$(kubectl -n trilium get pvc trilium-data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Bound" ]]; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Trilium PVC did not become Bound."
    kubectl -n trilium describe pvc trilium-data || true
    exit 1
  fi
  echo "  waiting for Trilium PVC... ${phase:-Pending}"
  sleep 5
done

echo "==> Waiting for Trilium deployment..."
kubectl -n trilium rollout status deployment/trilium --timeout=600s

echo "==> Waiting for Trilium TLS certificate..."
kubectl -n trilium wait \
  --for=condition=Ready \
  certificate/tls-trilium-ingress \
  --timeout=300s

echo "==> Verifying Trilium service endpoints..."
for i in {1..60}; do
  endpoints="$(
    kubectl -n trilium get endpointslice \
      -l kubernetes.io/service-name=trilium \
      -o go-template='{{range .items}}{{range .endpoints}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}' \
      2>/dev/null || true
  )"
  if [[ -n "$endpoints" ]]; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Trilium service has no ready endpoints."
    kubectl -n trilium get pods,svc,endpointslice -o wide || true
    exit 1
  fi
  sleep 5
done

echo "==> Creating/updating Vaultwarden admin secret..."
ensure_namespace vaultwarden

kubectl create secret generic vaultwarden-admin \
  --namespace vaultwarden \
  --from-literal=admin-token="$VAULTWARDEN_ADMIN_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Creating/updating Vaultwarden integration secret..."
kubectl create secret generic vaultwarden-integrations \
  --namespace vaultwarden \
  --from-literal=SMTP_USERNAME="$VAULTWARDEN_SMTP_USERNAME" \
  --from-literal=SMTP_PASSWORD="$VAULTWARDEN_SMTP_PASSWORD" \
  --from-literal=YUBICO_SECRET_KEY="$VAULTWARDEN_YUBICO_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Deploying Vaultwarden with Longhorn storage..."
apply_manifest "$VAULTWARDEN_MANIFEST"

echo "==> Waiting for Vaultwarden Longhorn PVC to bind..."
for i in {1..60}; do
  phase="$(kubectl -n vaultwarden get pvc vaultwarden-data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == "Bound" ]]; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Vaultwarden PVC did not become Bound."
    kubectl -n vaultwarden describe pvc vaultwarden-data || true
    exit 1
  fi
  echo "  waiting for Vaultwarden PVC... ${phase:-Pending}"
  sleep 5
done

echo "==> Waiting for Vaultwarden deployment..."
kubectl -n vaultwarden rollout status deployment/vaultwarden --timeout=600s

echo "==> Waiting for Vaultwarden TLS certificate..."
kubectl -n vaultwarden wait \
  --for=condition=Ready \
  certificate/tls-vaultwarden-ingress \
  --timeout=300s

echo "==> Verifying Vaultwarden service endpoints..."
for i in {1..60}; do
  endpoints="$(
    kubectl -n vaultwarden get endpointslice \
      -l kubernetes.io/service-name=vaultwarden \
      -o go-template='{{range .items}}{{range .endpoints}}{{range .addresses}}{{.}}{{"\n"}}{{end}}{{end}}{{end}}' \
      2>/dev/null || true
  )"
  if [[ -n "$endpoints" ]]; then
    break
  fi
  if [[ "$i" -eq 60 ]]; then
    echo "ERROR: Vaultwarden service has no ready endpoints."
    kubectl -n vaultwarden get pods,svc,endpointslice -o wide || true
    exit 1
  fi
  sleep 5
done

echo "==> Seeding Vaultwarden initial invitation for ${VAULTWARDEN_INITIAL_EMAIL}..."

kubectl port-forward -n vaultwarden svc/vaultwarden 8081:80 >/dev/null 2>&1 &
PF_PID=$!

for i in {1..30}; do
  if curl -fsS --connect-timeout 2 http://127.0.0.1:8081/alive >/dev/null 2>&1; then
    break
  fi
  if [[ "$i" -eq 30 ]]; then
    echo "ERROR: Vaultwarden local port-forward did not become ready."
    exit 1
  fi
  sleep 2
done

VW_COOKIE_JAR="$(mktemp)"
VW_ADMIN_LOGIN_CODE="$(
  curl -sS \
    -o /tmp/vaultwarden-admin-login.out \
    -w '%{http_code}' \
    -c "$VW_COOKIE_JAR" \
    -X POST \
    'http://127.0.0.1:8081/admin' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "token=${VAULTWARDEN_ADMIN_TOKEN}"
)"

if [[ "$VW_ADMIN_LOGIN_CODE" != "200" && "$VW_ADMIN_LOGIN_CODE" != "302" ]]; then
  echo "ERROR: Vaultwarden admin login failed with HTTP ${VW_ADMIN_LOGIN_CODE}."
  cat /tmp/vaultwarden-admin-login.out || true
  rm -f "$VW_COOKIE_JAR" /tmp/vaultwarden-admin-login.out
  exit 1
fi

VW_INVITE_PAYLOAD="$(
  python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1]}))' \
    "$VAULTWARDEN_INITIAL_EMAIL"
)"

VW_INVITE_CODE="$(
  curl -sS \
    -o /tmp/vaultwarden-invite.out \
    -w '%{http_code}' \
    -b "$VW_COOKIE_JAR" \
    -X POST \
    'http://127.0.0.1:8081/admin/invite' \
    -H 'Content-Type: application/json' \
    -d "$VW_INVITE_PAYLOAD"
)"

case "$VW_INVITE_CODE" in
  200|201)
    echo "==> Vaultwarden invitation created for ${VAULTWARDEN_INITIAL_EMAIL}"
    ;;
  409)
    echo "==> Vaultwarden user/invitation already exists for ${VAULTWARDEN_INITIAL_EMAIL}; continuing"
    ;;
  *)
    echo "ERROR: Vaultwarden invite failed with HTTP ${VW_INVITE_CODE}."
    cat /tmp/vaultwarden-invite.out || true
    rm -f "$VW_COOKIE_JAR" /tmp/vaultwarden-admin-login.out /tmp/vaultwarden-invite.out
    exit 1
    ;;
esac

rm -f "$VW_COOKIE_JAR" /tmp/vaultwarden-admin-login.out /tmp/vaultwarden-invite.out

cleanup
PF_PID=""

echo "==> Deploying application ingress and certificates..."
apply_manifest "$K3S_DIR/website.yaml"

echo
echo "===== NODES ====="
kubectl get nodes -o wide

echo
echo "===== HELM RELEASES ====="
helm list -A

echo
echo "===== CERTIFICATES ====="
kubectl get certificates -A

echo
echo "===== CLUSTER ISSUERS ====="
kubectl get clusterissuer

echo
echo "===== TRAEFIK ====="
kubectl -n traefik get pods,svc

echo
echo "===== RANCHER ====="
kubectl -n cattle-system get pods,svc,ingress

echo
echo "===== VAULTWARDEN ====="
kubectl -n vaultwarden get pods,svc,pvc,ingress
kubectl -n vaultwarden get certificate tls-vaultwarden-ingress

echo
echo "===== TRILIUM ====="
kubectl -n trilium get pods,svc,pvc,ingress
kubectl -n trilium get certificate tls-trilium-ingress

echo
echo "===== LONGHORN ====="
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get ingress
kubectl -n longhorn-system get certificate tls-longhorn-ingress
kubectl get storageclass longhorn
echo
echo "===== MONITORING ====="
kubectl -n monitoring get pods
kubectl -n monitoring get pvc -o wide
kubectl -n monitoring get ingress
kubectl -n monitoring get certificate tls-grafana-ingress
kubectl -n monitoring get servicemonitor longhorn-prometheus-servicemonitor
kubectl -n monitoring get prometheusrule homelab-baseline-alerts

echo
echo "===== PORTAINER ====="
kubectl -n portainer get pods,svc,pvc,ingress
kubectl -n portainer get certificate tls-portainer-ingress

echo
echo "===== LOGGING ====="
kubectl -n logging get pods,svc,pvc
helm -n logging list

echo
echo "===== GRAFANA LOGGING ====="
kubectl -n monitoring get configmap grafana-loki-datasource
kubectl -n monitoring get configmap -l grafana_dashboard=1

echo
echo "===== CLOUDFLARED ====="
kubectl -n cloudflared get pods

kubectl -n cattle-system wait --for=condition=Ready certificate/tls-rancher-ingress --timeout=30s
kubectl -n traefik wait --for=condition=Ready certificate/tls-traefik-dashboard --timeout=30s

echo
kubectl -n longhorn-system wait --for=condition=Ready certificate/tls-longhorn-ingress --timeout=30s

echo "============================================================================"
echo " Deployment complete"
echo "============================================================================"
echo " Kubernetes API: https://${KUBE_VIP}:6443"
echo " Rancher:        https://${RANCHER_HOSTNAME}"
echo " Longhorn:       https://${LONGHORN_HOSTNAME}"
echo " Trilium:        https://${TRILIUM_HOSTNAME}"
echo " Vaultwarden:    https://${VAULTWARDEN_HOSTNAME}"
echo " Grafana:        https://${GRAFANA_HOSTNAME}"
echo " Grafana user:   admin"
echo " Portainer:      https://${PORTAINER_HOSTNAME}"
echo " Loki:           internal only; use Grafana Explore and dashboards"
echo " EndpointSlice:  app health checks + Longhorn ServiceMonitor use EndpointSlice"
echo " Vaultwarden invite: ${VAULTWARDEN_INITIAL_EMAIL}"
echo " Vaultwarden signups/invitations: disabled except seeded admin invite"

echo
echo "============================================================================"
echo " Vaultwarden first-time setup"
echo "============================================================================"
echo " Initial invited account: ${VAULTWARDEN_INITIAL_EMAIL}"
echo
echo " Create the initial Vaultwarden account and choose your MASTER PASSWORD here:"
echo " https://${VAULTWARDEN_HOSTNAME}/#/signup"
echo
echo " IMPORTANT:"
echo "   - Use ${VAULTWARDEN_INITIAL_EMAIL} when creating the account."
echo "   - The Vaultwarden master password is created by YOU on the signup page."
echo "   - VAULTWARDEN_ADMIN_TOKEN is NOT your master password."
echo
echo " Vaultwarden Administration:"
echo " https://${VAULTWARDEN_HOSTNAME}/admin"
echo
echo " Use VAULTWARDEN_ADMIN_TOKEN from .secrets.enc to log into the admin page."
echo " To retrieve only that token later:"
echo "   sops --decrypt ${K3S_DIR}/.secrets.enc | grep '^VAULTWARDEN_ADMIN_TOKEN='"
echo
echo " General signups:     DISABLED"
echo " General invitations: DISABLED"
echo "============================================================================"

echo
echo "============================================================================"
echo " Portainer first-time setup"
echo "============================================================================"
echo " Portainer URL:"
echo " https://${PORTAINER_HOSTNAME}"
echo
echo " Portainer 2.45.0 protects new installations with a one-time setup token."
echo " Retrieve the current setup token from the Portainer pod logs:"
echo "   kubectl -n portainer logs deployment/portainer | grep 'setup_token='"
echo
echo " Open the Portainer URL, enter that setup token when prompted, then create"
echo " the first administrator account. The administrator password must be at"
echo " least 12 characters."
echo
echo " Portainer data is stored on a 20Gi Longhorn PVC."
echo "============================================================================"
echo " Rancher user:   ${RANCHER_ADMIN_USER}"
echo "============================================================================"
