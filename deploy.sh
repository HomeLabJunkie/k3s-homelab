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
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE:-$K3S_DIR/kubeconfig}"
KUBECONFIG_TARGET="${KUBECONFIG_TARGET:-$HOME/.kube/config}"

TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-41.7.1}"
RANCHER_CHART_VERSION="${RANCHER_CHART_VERSION:-2.15.2}"
LONGHORN_CHART_VERSION="${LONGHORN_CHART_VERSION:-1.12.1}"

# Ingress hostnames default to <app>.$BASE_DOMAIN from cluster.env. Without
# BASE_DOMAIN they fall back to *.example.invalid, which the guard below refuses.
HOSTNAME_DOMAIN="${BASE_DOMAIN:-example.invalid}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.${HOSTNAME_DOMAIN}}"
# Rancher's bootstrap always creates the local admin as "admin"; the name is
# not configurable, so refuse a different value instead of printing it.
if [[ -n "${RANCHER_ADMIN_USER:-}" && "$RANCHER_ADMIN_USER" != "admin" ]]; then
  echo "ERROR: RANCHER_ADMIN_USER=$RANCHER_ADMIN_USER is not supported: Rancher's bootstrap admin is always 'admin'."
  echo "Remove RANCHER_ADMIN_USER from $ENV_FILE."
  exit 1
fi
RANCHER_ADMIN_USER="admin"

TRAEFIK_VALUES="${TRAEFIK_VALUES:-$K3S_DIR/traefik-values.yaml}"
LONGHORN_HOST_PREP_PLAYBOOK="${LONGHORN_HOST_PREP_PLAYBOOK:-$K3S_DIR/longhorn-host-prep.yml}"
LONGHORN_VALUES="${LONGHORN_VALUES:-$K3S_DIR/longhorn-values.yaml}"
LONGHORN_HOSTNAME="${LONGHORN_HOSTNAME:-longhorn.${HOSTNAME_DOMAIN}}"
TRILIUM_HOSTNAME="${TRILIUM_HOSTNAME:-trilium.${HOSTNAME_DOMAIN}}"
VAULTWARDEN_HOSTNAME="${VAULTWARDEN_HOSTNAME:-vaultwarden.${HOSTNAME_DOMAIN}}"
AUTHELIA_HOSTNAME="${AUTHELIA_HOSTNAME:-auth.${HOSTNAME_DOMAIN}}"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-92.2.0}"
MONITORING_VALUES="${MONITORING_VALUES:-$K3S_DIR/monitoring-values.yaml}"
GRAFANA_HOSTNAME="${GRAFANA_HOSTNAME:-grafana.${HOSTNAME_DOMAIN}}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.10.2}"
ARGOCD_VALUES="${ARGOCD_VALUES:-$K3S_DIR/apps/argocd/values.yaml}"
ARGOCD_HOSTNAME="${ARGOCD_HOSTNAME:-argocd.${HOSTNAME_DOMAIN}}"
ARGOCD_PROJECT="${ARGOCD_PROJECT:-$K3S_DIR/apps/argocd/project.yaml}"
ARGOCD_ROOT_APP="${ARGOCD_ROOT_APP:-$K3S_DIR/apps/argocd/root.yaml}"
# What Argo CD deploys on this cluster. The defaults are production. A test
# cluster sets these in its own config/cluster.env so that it never deploys
# production's settings and Secrets: a branch of this repository, a directory
# of the configuration repository such as "envs/test/" (with the trailing
# slash), and a comma-separated list of applications to leave out.
ARGOCD_APPS_REVISION="${ARGOCD_APPS_REVISION:-main}"
ARGOCD_APPS_CONFIG_PATH="${ARGOCD_APPS_CONFIG_PATH:-}"
ARGOCD_APPS_DISABLED="${ARGOCD_APPS_DISABLED:-}"
# The private repository holding this cluster's own settings (its domain).
ARGOCD_CONFIG_REPO_URL="${ARGOCD_CONFIG_REPO_URL:-git@github.com:HomeLabJunkie/k3s-homelab-config.git}"
LONGHORN_STORAGE_RESERVED_BYTES="${LONGHORN_STORAGE_RESERVED_BYTES:-53687091200}"

# Refuse to push a placeholder hostname into the cluster.
for hostname_var in RANCHER_HOSTNAME LONGHORN_HOSTNAME TRILIUM_HOSTNAME \
  VAULTWARDEN_HOSTNAME GRAFANA_HOSTNAME AUTHELIA_HOSTNAME ARGOCD_HOSTNAME; do
  if [[ "${!hostname_var}" == *.invalid ]]; then
    echo "ERROR: $hostname_var is the placeholder ${!hostname_var}."
    echo "Set BASE_DOMAIN (or $hostname_var) in $ENV_FILE."
    exit 1
  fi
done

PF_PID=""
VW_TMP=""
DEPLOY_LOCK_HELD=false

cleanup() {
  if [[ -n "${PF_PID:-}" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  # Holds the Vaultwarden admin session cookie; remove it on every exit path.
  if [[ -n "${VW_TMP:-}" ]]; then
    rm -rf -- "$VW_TMP"
    VW_TMP=""
  fi
  if [[ "$DEPLOY_LOCK_HELD" == true ]]; then
    KUBECONFIG="$KUBECONFIG_TARGET" kubectl -n kube-system delete configmap deploy-lock \
      --ignore-not-found >/dev/null 2>&1 ||
      echo "WARNING: could not release the deploy lock; remove it with: kubectl -n kube-system delete configmap deploy-lock"
    DEPLOY_LOCK_HELD=false
  fi
}
trap cleanup EXIT

# Only one workstation may change the cluster at a time. The lock lives in the
# cluster, so every laptop sees it.
acquire_deploy_lock() {
  local output holder
  if output="$(KUBECONFIG="$KUBECONFIG_TARGET" kubectl -n kube-system create configmap deploy-lock \
      --from-literal=holder="$(uname -n)" \
      --from-literal=since="$(date -Iseconds)" 2>&1)"; then
    DEPLOY_LOCK_HELD=true
    return 0
  fi
  # Ask for the lock directly instead of matching kubectl's error wording.
  if holder="$(KUBECONFIG="$KUBECONFIG_TARGET" kubectl -n kube-system get configmap deploy-lock \
      -o jsonpath='{.data.holder}, started {.data.since}' 2>/dev/null)"; then
    echo "ERROR: another deployment is changing the cluster:"
    echo "  $holder"
    echo "If that run is no longer active, release the lock with:"
    echo "  kubectl -n kube-system delete configmap deploy-lock"
  else
    echo "ERROR: could not take the cluster deploy lock: $output"
  fi
  exit 1
}

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

verify_kubeconfig_server() {
  local server
  server="$(KUBECONFIG="$KUBECONFIG_TARGET" kubectl config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  [[ "$server" == "https://${KUBE_VIP}:6443" ]] || {
    echo "ERROR: $KUBECONFIG_TARGET current context points to ${server:-nothing}, not https://${KUBE_VIP}:6443."
    echo "Switch context with 'kubectl config use-context', or run --bootstrap to fetch a new kubeconfig."
    exit 1
  }
}

ensure_namespace() {
  local ns="$1"
  [[ -n "$ns" ]] || return 0
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Routes that use a Traefik middleware are IngressRoutes of the same name. Remove
# the Ingress they replaced once the IngressRoute is applied, so the hostname
# is never left without a route.
remove_replaced_ingress() {
  local ns="$1" name="$2"
  kubectl -n "$ns" delete ingress "$name" --ignore-not-found
}

# Wait for a rollout to finish. A deployment that was stuck before this run
# still carries its old "progress deadline exceeded" status for a moment after
# it is fixed, and kubectl gives up at once on seeing it; keep waiting until
# the timeout instead.
wait_for_rollout() {
  local ns="$1" name="$2" timeout="$3"
  local deadline=$((SECONDS + timeout)) output
  while true; do
    if output="$(kubectl -n "$ns" rollout status "deployment/$name" \
        --timeout="$((deadline - SECONDS))s" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    printf '%s\n' "$output"
    if [[ "$output" != *"exceeded its progress deadline"* ]] || (( SECONDS + 10 >= deadline )); then
      return 1
    fi
    sleep 10
  done
}

# Wait until Argo CD reports an Application both in sync with git and healthy.
# Let's Encrypt now and then fails one certificate order at its last step
# with an error that is not about this cluster ("Certificate not found",
# "orderNotReady"). cert-manager then waits an hour before trying again,
# which is longer than this script waits. Clearing the recorded failure makes
# it try again at once. Each certificate gets three such retries, so a real
# problem still stops the deploy.
declare -A CERTIFICATE_RETRIES=()
retry_failed_certificates() {
  local namespace name key
  while read -r namespace name; do
    [[ -n "$name" ]] || continue
    key="$namespace/$name"
    (( ${CERTIFICATE_RETRIES[$key]:-0} < 3 )) || continue
    CERTIFICATE_RETRIES[$key]=$(( ${CERTIFICATE_RETRIES[$key]:-0} + 1 ))
    echo "    certificate $key failed at the issuer; retrying now (retry ${CERTIFICATE_RETRIES[$key]} of 3)"
    kubectl -n "$namespace" get certificaterequest -o json 2>/dev/null |
      python3 -c '
import json, sys
name = sys.argv[1]
for item in json.load(sys.stdin).get("items", []):
    owned = any(o.get("name") == name for o in item["metadata"].get("ownerReferences", []))
    for cond in item.get("status", {}).get("conditions", []):
        if owned and cond.get("type") == "Ready" and cond.get("reason") == "Failed":
            print("      " + cond.get("message", "")[:300])' "$name" || true
    kubectl -n "$namespace" patch certificate "$name" --subresource=status --type=json \
      -p '[{"op":"remove","path":"/status/lastFailureTime"}]' >/dev/null || true
  done < <(
    kubectl get certificates --all-namespaces -o json 2>/dev/null |
      python3 -c '
import json, sys
for item in json.load(sys.stdin).get("items", []):
    status = item.get("status", {})
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in status.get("conditions", []))
    if not ready and status.get("lastFailureTime"):
        print(item["metadata"]["namespace"], item["metadata"]["name"])' || true
  )
}

wait_for_certificate() {
  local namespace="$1" name="$2" timeout="$3"
  local deadline=$((SECONDS + timeout)) ready=""
  while (( SECONDS < deadline )); do
    ready="$(kubectl -n "$namespace" get certificate "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "$ready" == "True" ]]; then
      echo "certificate $namespace/$name is ready."
      return 0
    fi
    retry_failed_certificates
    sleep 5
  done
  echo "ERROR: certificate $namespace/$name is not ready after ${timeout}s."
  kubectl -n "$namespace" describe certificate "$name" | tail -n 20 || true
  return 1
}

wait_for_argocd_app() {
  local app="$1" timeout="$2"
  local deadline=$((SECONDS + timeout)) sync="" health=""
  while (( SECONDS < deadline )); do
    retry_failed_certificates
    sync="$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "$sync" == "Synced" && "$health" == "Healthy" ]]; then
      echo "Argo CD application $app is Synced and Healthy."
      return 0
    fi
    sleep 10
  done
  echo "ERROR: Argo CD application $app is '${sync:-missing}' / '${health:-unknown}' after ${timeout}s."
  kubectl -n argocd get application "$app" \
    -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' || true
  return 1
}

# Installs or upgrades the Argo CD release. Its values ask for ServiceMonitors,
# which need the monitoring CRDs; on a new cluster those arrive later, so the
# first call leaves the ServiceMonitors out and a second call adds them.
install_argocd() {
  local without_monitors=()
  if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo "    monitoring CRDs not installed yet: leaving out Argo CD's ServiceMonitors for now"
    without_monitors=(
      --set controller.metrics.serviceMonitor.enabled=false
      --set server.metrics.serviceMonitor.enabled=false
      --set repoServer.metrics.serviceMonitor.enabled=false
      --set applicationSet.metrics.serviceMonitor.enabled=false
    )
  fi
  helm upgrade --install argocd argo/argo-cd \
    --version "$ARGOCD_CHART_VERSION" \
    --namespace argocd \
    --create-namespace \
    --values "$ARGOCD_VALUES" \
    "${without_monitors[@]}" \
    --wait --timeout=600s
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

for cmd in ansible ansible-playbook ansible-galaxy kubectl helm curl python3 envsubst openssl argon2; do
  require_command "$cmd"
done

echo "==> Validating Ansible/Python toolchain..."
"$K3S_DIR/scripts/check-ansible-toolchain.sh"

echo "==> Verifying project-local Ansible collections..."
"$K3S_DIR/scripts/ensure-ansible-collections.sh"

# Refuse to deploy from a laptop with old private files (secrets, cluster.env) or an
# old checkout: an outdated .secrets.enc would push stale credentials to the cluster.
# k3s-sync lives in the private companion repo (see its GUIDE.md).
echo "==> Checking this laptop is up to date (k3s-sync check)..."
K3S_SYNC="${K3S_SYNC:-$(command -v k3s-sync || echo "$K3S_DIR/../k3s-homelab-private/k3s-sync")}"
if [[ "${SKIP_SYNC_CHECK:-false}" == true ]]; then
  echo "  skipped (SKIP_SYNC_CHECK=true)"
elif [[ ! -x "$K3S_SYNC" ]]; then
  echo "  k3s-sync not found; skipping (set K3S_SYNC to its path to enable this check)"
else
  sync_rc=0
  K3S_REPO="$K3S_DIR" "$K3S_SYNC" check || sync_rc=$?
  case "$sync_rc" in
    0) ;;
    2) echo "  WARNING: this k3s-sync has no 'check' command yet; run k3s-sync pull to update it" ;;
    3) echo "  WARNING: could not reach GitHub to confirm; continuing with this laptop's files" ;;
    *)
      echo "ERROR: this laptop is behind GitHub. Run k3s-sync pull, then deploy again."
      echo "       (To deploy anyway: SKIP_SYNC_CHECK=true)"
      exit 1
      ;;
  esac
fi

if [[ -f "$K3S_DIR/.secrets.enc" ]]; then
  require_command sops
fi

echo "==> Validating cluster environment..."
for var in \
  BASE_DOMAIN \
  ADMIN_EMAIL \
  KUBE_VIP \
  K3S_NODE_0 \
  K3S_NODE_1 \
  K3S_NODE_2 \
  K3S_NODE_3 \
  K3S_NODE_4 \
  K3S_NODE_5 \
  METALLB_IP_RANGE \
  BACKUP_NAS_IP \
  BACKUP_NFS_VERSION \
  CLUSTER_BACKUP_EXPORT \
  LONGHORN_BACKUP_SHARE \
  LONGHORN_BACKUP_CREDENTIAL_SECRET \
  CLOUDFLARE_ACCOUNT_ID
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
  "$LONGHORN_HOST_PREP_PLAYBOOK" \
  "$LONGHORN_VALUES" \
  "$MONITORING_VALUES" \
  "$ARGOCD_VALUES" \
  "$ARGOCD_PROJECT" \
  "$ARGOCD_ROOT_APP"
do
  require_file "$file"
done

echo "==> Loading secrets..."
set -a
if [[ -f "$K3S_DIR/.secrets.enc" ]]; then
  decrypted_secrets="$(sops --decrypt "$K3S_DIR/.secrets.enc")" || {
    echo "ERROR: sops could not decrypt $K3S_DIR/.secrets.enc"
    exit 1
  }
  # shellcheck disable=SC1090
  source <(printf '%s\n' "$decrypted_secrets")
  unset decrypted_secrets
elif [[ -f "$K3S_DIR/.secrets" ]]; then
  # shellcheck disable=SC1090,SC1091
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
  GRAFANA_ADMIN_PASSWORD \
  LONGHORN_CIFS_USERNAME \
  LONGHORN_CIFS_PASSWORD \
  ADMIN_UI_USERNAME \
  ADMIN_UI_PASSWORD \
  AUTHELIA_SESSION_SECRET \
  AUTHELIA_STORAGE_ENCRYPTION_KEY \
  AUTHELIA_JWT_SECRET \
  AUTHELIA_OIDC_HMAC_SECRET \
  AUTHELIA_OIDC_JWKS_KEY_B64 \
  GRAFANA_OIDC_CLIENT_SECRET \
  DUO_API_HOSTNAME \
  DUO_INTEGRATION_KEY \
  DUO_SECRET_KEY \
  WEBSITE_DEPLOY_KEY_B64 \
  ARGOCD_CONFIG_REPO_KEY_B64 \
  ARGOCD_SOPS_AGE_KEY \
  CLOUDFLARE_ANALYTICS_TOKEN
do
  require_var "$var"
done

if (( ${#RANCHER_ADMIN_PASSWORD} < 12 )); then
  echo "ERROR: RANCHER_ADMIN_PASSWORD must be at least 12 characters."
  exit 1
fi

if (( ${#ADMIN_UI_PASSWORD} < 12 )); then
  echo "ERROR: ADMIN_UI_PASSWORD must be at least 12 characters."
  exit 1
fi

if [[ "$ADMIN_UI_USERNAME" == *:* ]]; then
  echo "ERROR: ADMIN_UI_USERNAME must not contain ':'."
  exit 1
fi

for var in AUTHELIA_SESSION_SECRET AUTHELIA_STORAGE_ENCRYPTION_KEY AUTHELIA_JWT_SECRET \
  AUTHELIA_OIDC_HMAC_SECRET GRAFANA_OIDC_CLIENT_SECRET; do
  value="${!var}"
  if (( ${#value} < 32 )); then
    echo "ERROR: $var must be at least 32 characters (openssl rand -hex 32)."
    exit 1
  fi
done
unset value

if ! printf '%s' "$AUTHELIA_OIDC_JWKS_KEY_B64" | base64 -d 2>/dev/null |
  openssl pkey -noout 2>/dev/null; then
  echo "ERROR: AUTHELIA_OIDC_JWKS_KEY_B64 is not a base64-encoded private key."
  echo "  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 | base64 -w0"
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
  vars:
    expected_server_service_args: >-
      {% if groups['master'] | length > 1 and inventory_hostname != groups['master'][0] %}
        --server https://{{ hostvars[groups['master'][0]].ansible_host | default(groups['master'][0]) | ansible.utils.ipwrap }}:6443
        --token-file /var/lib/rancher/k3s/server/token
      {% endif %}
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
          - >-
            inventory_hostname == groups['master'][0]
            or ('--server https://' in expected_server_service_args and
                '--token-file /var/lib/rancher/k3s/server/token' in expected_server_service_args)
        fail_msg: >-
          Rendered K3s configuration is unsafe. Deployment will not proceed.

    - name: Show validated configuration
      ansible.builtin.debug:
        msg:
          - "node={{ inventory_hostname }}"
          - "node_ip={{ k3s_node_ip }}"
          - "api_vip={{ apiserver_endpoint }}"
          - "server_args={{ extra_server_args }}"
          - "service_join_args={{ expected_server_service_args }}"
ANSIBLE_PREFLIGHT

# Existing mode reuses the operator's kubeconfig (only bootstrap fetches a new
# one), so check it before any node is touched.
if [[ "$DEPLOY_MODE" == "existing" ]]; then
  echo "==> Validating local kubeconfig..."
  require_file "$KUBECONFIG_TARGET"
  verify_kubeconfig_server
fi

if [[ "$PREFLIGHT_ONLY" == true ]]; then
  echo
  echo "============================================"
  echo " DEPLOYMENT PREFLIGHT PASSED"
  echo "============================================"
  echo "No cluster changes were made."
  exit 0
fi

# Bootstrap has no cluster to hold the lock yet.
if [[ "$DEPLOY_MODE" == "existing" ]]; then
  echo "==> Taking the cluster deploy lock..."
  acquire_deploy_lock
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

if [[ "$DEPLOY_MODE" == "bootstrap" ]]; then
  echo "==> Installing kubeconfig fetched by bootstrap..."
  require_file "$KUBECONFIG_SOURCE"
  mkdir -p "$(dirname "$KUBECONFIG_TARGET")"
  # Rewrite only the fresh copy, never other clusters in the existing target.
  kubeconfig_tmp="$(mktemp "$(dirname "$KUBECONFIG_TARGET")/.kubeconfig.XXXXXX")"
  sed -E \
    "s#server: https://([0-9]{1,3}\.){3}[0-9]{1,3}:6443#server: https://${KUBE_VIP}:6443#" \
    "$KUBECONFIG_SOURCE" >"$kubeconfig_tmp"
  chmod 600 "$kubeconfig_tmp"
  if [[ -e "$KUBECONFIG_TARGET" ]]; then
    kubeconfig_backup="${KUBECONFIG_TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$KUBECONFIG_TARGET" "$kubeconfig_backup"
    echo "    previous kubeconfig saved to $kubeconfig_backup"
  fi
  mv -f "$kubeconfig_tmp" "$KUBECONFIG_TARGET"
  verify_kubeconfig_server
else
  echo "==> Using existing kubeconfig: $KUBECONFIG_TARGET"
fi
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
helm repo add traefik https://traefik.github.io/charts --force-update
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
helm repo add longhorn https://charts.longhorn.io --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update >/dev/null

# ------------------------------------------------------------------------------
# GitOps - Argo CD
# ------------------------------------------------------------------------------

# Argo CD is installed first, because it deploys nearly everything else,
# cert-manager included. deploy.sh installs the engine; Argo CD then deploys
# what the Application manifests in apps/argocd/applications describe, from
# GitHub, not from this working copy. On a new cluster most applications
# cannot sync yet, because what they need (CRDs, storage, Traefik) is
# installed further down; each keeps retrying, and this script waits for
# each one at the point where it must be ready.
# The repo server mounts this key to decrypt the Secrets in the private
# configuration repository (KSOPS), so it must exist before the install.
echo "==> Creating/updating the Argo CD sops key..."
ensure_namespace argocd
kubectl create secret generic sops-age \
  --namespace argocd \
  --from-file=keys.txt=<(printf '%s\n' "$ARGOCD_SOPS_AGE_KEY") \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing Argo CD ${ARGOCD_CHART_VERSION}..."
install_argocd

# Argo CD reads the private configuration repository with a read-only deploy
# key. The URL must match the one in the Application manifests.
echo "==> Creating/updating the Argo CD credential for the configuration repository..."
kubectl create secret generic repo-k3s-homelab-config \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url="$ARGOCD_CONFIG_REPO_URL" \
  --from-file=sshPrivateKey=<(printf '%s' "$ARGOCD_CONFIG_REPO_KEY_B64" | base64 -d) \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

# The website's pods cannot start without this key, so it is in place before
# Argo CD creates them.
echo "==> Creating/updating jeffriffle.com git-sync deploy key..."
ensure_namespace website
kubectl create secret generic jeffriffle-git \
  --namespace website \
  --from-file=ssh=<(printf '%s' "$WEBSITE_DEPLOY_KEY_B64" | base64 -d) \
  --dry-run=client -o yaml | kubectl apply -f -

# Two applications place objects in namespaces that the Helm installs further
# down would otherwise create. Argo CD checks a whole application before
# applying any of it, so a missing namespace would hold back the rest.
for platform_namespace in traefik longhorn-system monitoring logging; do
  ensure_namespace "$platform_namespace"
done

echo "==> Handing the Argo CD applications to Argo CD..."
kubectl apply -f "$ARGOCD_PROJECT"
echo "    revision: ${ARGOCD_APPS_REVISION}, settings: ${ARGOCD_APPS_CONFIG_PATH:-(top level)}, left out: ${ARGOCD_APPS_DISABLED:-(none)}"
ARGOCD_APPS_REVISION="$ARGOCD_APPS_REVISION" \
  ARGOCD_APPS_CONFIG_PATH="$ARGOCD_APPS_CONFIG_PATH" \
  ARGOCD_APPS_DISABLED="$ARGOCD_APPS_DISABLED" \
  python3 - "$ARGOCD_ROOT_APP" <<'PYTHON' | kubectl apply -f -
import os, sys, yaml

root = yaml.safe_load(open(sys.argv[1]))
revision = os.environ["ARGOCD_APPS_REVISION"]
config_path = os.environ["ARGOCD_APPS_CONFIG_PATH"]
disabled = [name for name in os.environ["ARGOCD_APPS_DISABLED"].split(",") if name]

source = root["spec"]["source"]
source["targetRevision"] = revision
values = {}
if revision != "main":
    values["revision"] = revision
if config_path:
    values["config"] = {"path": config_path}
if disabled:
    values["disabled"] = disabled
if values:
    source["helm"] = {"valuesObject": values}
print(yaml.safe_dump(root, sort_keys=False))
PYTHON

# cert-manager, its ClusterIssuer and the Cloudflare API token the issuer
# uses come from Argo CD (apps/cert-manager, charts/cert-manager-config).
echo "==> Waiting for Argo CD to deploy cert-manager..."
wait_for_argocd_app cert-manager 900
wait_for_argocd_app cert-manager-config 900
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

# The routes and certificates of the admin UIs come from Argo CD (the routes
# application, charts/routes). It can sync now that Traefik's CRDs exist.
echo "==> Waiting for Argo CD to deploy the admin UI routes..."
wait_for_argocd_app routes 900
wait_for_certificate traefik tls-traefik-dashboard 300

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
# Skip finished recurring-job pods (backups, snapshots); they never report Ready.
kubectl -n longhorn-system wait \
  --for=condition=Ready \
  pod \
  --all \
  --field-selector=status.phase!=Succeeded,status.phase!=Failed \
  --timeout=600s

echo "==> Creating/updating Longhorn CIFS backup credentials..."
kubectl create secret generic "$LONGHORN_BACKUP_CREDENTIAL_SECRET" \
  --from-file=CIFS_USERNAME=<(printf '%s' "$LONGHORN_CIFS_USERNAME") \
  --from-file=CIFS_PASSWORD=<(printf '%s' "$LONGHORN_CIFS_PASSWORD") \
  --namespace longhorn-system \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Configuring Longhorn CIFS backup target..."
LONGHORN_BACKUP_TARGET="cifs://${BACKUP_NAS_IP}/${LONGHORN_BACKUP_SHARE}?cifsOptions=vers%3D3.0"
wait_longhorn_backup_target_available() {
  local target_name="$1" target_label="$2" available i

  for i in {1..60}; do
    available="$(
      kubectl -n longhorn-system get backuptarget "$target_name" \
        -o jsonpath='{.status.available}' 2>/dev/null || true
    )"
    [[ "$available" == "true" ]] && return 0
    sleep 5
  done

  echo "ERROR: Longhorn ${target_label} backup target did not become available."
  kubectl -n longhorn-system get backuptarget "$target_name" -o yaml || true
  return 1
}

CURRENT_LONGHORN_BACKUP_TARGET="$(
  kubectl -n longhorn-system get backuptarget default \
    -o jsonpath='{.spec.backupTargetURL}' 2>/dev/null || true
)"

# Validate a changed destination while the current default remains usable. The
# probe must be removed before cutover because Longhorn requires target URLs to
# be unique across BackupTarget objects.
if [[ "$CURRENT_LONGHORN_BACKUP_TARGET" != "$LONGHORN_BACKUP_TARGET" ]]; then
  LONGHORN_BACKUP_PROBE=default-migration-probe
  python3 - "$LONGHORN_BACKUP_PROBE" "$LONGHORN_BACKUP_TARGET" \
    "$LONGHORN_BACKUP_CREDENTIAL_SECRET" <<'PY_LONGHORN_PROBE' | kubectl apply -f -
import json
import sys

name, url, secret = sys.argv[1:]
print(json.dumps({
    "apiVersion": "longhorn.io/v1beta2",
    "kind": "BackupTarget",
    "metadata": {"name": name, "namespace": "longhorn-system"},
    "spec": {
        "backupTargetURL": url,
        "credentialSecret": secret,
        "pollInterval": "30s",
    },
}))
PY_LONGHORN_PROBE
  wait_longhorn_backup_target_available "$LONGHORN_BACKUP_PROBE" "migration probe"
  kubectl -n longhorn-system delete backuptarget "$LONGHORN_BACKUP_PROBE" --wait=true
fi

LONGHORN_BACKUP_PATCH="$(
  python3 -c 'import json,sys; print(json.dumps({"spec":{"backupTargetURL":sys.argv[1],"credentialSecret":sys.argv[2]}}))' \
    "$LONGHORN_BACKUP_TARGET" "$LONGHORN_BACKUP_CREDENTIAL_SECRET"
)"
kubectl -n longhorn-system patch backuptarget default \
  --type=merge \
  --patch "$LONGHORN_BACKUP_PATCH"
wait_longhorn_backup_target_available default "CIFS"

echo "==> Waiting for the Longhorn HTTPS certificate..."
remove_replaced_ingress longhorn-system longhorn-frontend
wait_for_certificate longhorn-system tls-longhorn-ingress 300

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

# Authelia, which the admin-ui-auth middleware on the routes below asks about
# every request, is deployed by Argo CD further down. Until then those routes
# fail closed.

# ------------------------------------------------------------------------------
# Monitoring - kube-prometheus-stack
# ------------------------------------------------------------------------------

echo "==> Preparing monitoring namespace and Grafana credentials..."
ensure_namespace monitoring

kubectl create secret generic grafana-admin \
  --namespace monitoring \
  --from-literal=admin-user=admin \
  --from-file=admin-password=<(printf '%s' "$GRAFANA_ADMIN_PASSWORD") \
  --dry-run=client -o yaml | kubectl apply -f -

# Read-only Cloudflare Web Analytics token for Grafana's Infinity data source
kubectl create secret generic grafana-cloudflare \
  --namespace monitoring \
  --from-file=token=<(printf '%s' "$CLOUDFLARE_ANALYTICS_TOKEN") \
  --dry-run=client -o yaml | kubectl apply -f -

# Single sign-on through Authelia (see auth.generic_oauth in monitoring-values.yaml).
# Grafana reads these as environment variables; the hash below restarts it when
# they change, since envFrom is only read at start-up.
kubectl create secret generic grafana-oidc \
  --namespace monitoring \
  --from-literal=GF_SERVER_ROOT_URL="https://${GRAFANA_HOSTNAME}/" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_AUTH_URL="https://${AUTHELIA_HOSTNAME}/api/oidc/authorization" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_TOKEN_URL="https://${AUTHELIA_HOSTNAME}/api/oidc/token" \
  --from-literal=GF_AUTH_GENERIC_OAUTH_API_URL="https://${AUTHELIA_HOSTNAME}/api/oidc/userinfo" \
  --from-literal=GF_AUTH_SIGNOUT_REDIRECT_URL="https://${AUTHELIA_HOSTNAME}/logout?rd=https%3A%2F%2F${GRAFANA_HOSTNAME}%2F" \
  --from-file=GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<(printf '%s' "$GRAFANA_OIDC_CLIENT_SECRET") \
  --dry-run=client -o yaml | kubectl apply -f -
GRAFANA_OIDC_HASH="$(
  kubectl -n monitoring get secret grafana-oidc -o jsonpath='{.data}' | sha256sum | cut -c1-16
)"

echo "==> Configuring Alertmanager SMTP delivery..."
kubectl create secret generic alertmanager-smtp \
  --namespace monitoring \
  --from-file=alertmanager.yaml=<("$K3S_DIR/scripts/render-alertmanager-config.sh") \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_VERSION}..."
# hostAliases sends Grafana's server-side OIDC calls (token, userinfo) for the
# Authelia hostname straight to Traefik on the LAN instead of out through
# Cloudflare, whose bot check can reject non-browser clients.
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --version "$KUBE_PROMETHEUS_STACK_VERSION" \
  --namespace monitoring \
  --create-namespace \
  --values "$MONITORING_VALUES" \
  --set-string "grafana.podAnnotations.homelab/oidc-config-hash=${GRAFANA_OIDC_HASH}" \
  --set-json "grafana.hostAliases=[{\"ip\":\"${CLOUDFLARE_ORIGIN_IP}\",\"hostnames\":[\"${AUTHELIA_HOSTNAME}\"]}]" \
  --wait \
  --timeout=900s

remove_replaced_ingress monitoring grafana
remove_replaced_ingress monitoring prometheus

echo "==> Waiting for Grafana TLS certificate..."
wait_for_certificate monitoring tls-grafana-ingress 300

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
# Both come from the monitoring-extras application, which on a new cluster
# syncs on its next retry after the monitoring CRDs appear.
for monitoring_object in servicemonitor/longhorn-prometheus-servicemonitor prometheusrule/homelab-baseline-alerts; do
  for i in {1..180}; do
    kubectl -n monitoring get "$monitoring_object" >/dev/null 2>&1 && break
    if [[ "$i" -eq 180 ]]; then
      echo "ERROR: $monitoring_object did not appear in the monitoring namespace."
      kubectl -n argocd get applications.argoproj.io monitoring-extras || true
      exit 1
    fi
    sleep 5
  done
  kubectl -n monitoring get "$monitoring_object"
done
kubectl -n monitoring get secret alertmanager-smtp >/dev/null

echo "==> Monitoring stack is ready."

# ------------------------------------------------------------------------------
# Logging - Loki + Alloy
# ------------------------------------------------------------------------------

# Argo CD deploys Loki and Alloy (apps/loki, apps/alloy). Loki needs Longhorn
# for its volume, which exists by now.
echo "==> Waiting for Argo CD to deploy Loki and Alloy..."
wait_for_argocd_app loki 900
wait_for_argocd_app alloy 900

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

# ------------------------------------------------------------------------------
# GitOps - Argo CD: full settings and HTTPS route
# ------------------------------------------------------------------------------

# The first install, above, left out Argo CD's ServiceMonitors if the
# monitoring CRDs did not exist yet. They do now.
echo "==> Applying Argo CD's full settings..."
install_argocd

echo "==> Waiting for the Argo CD HTTPS certificate..."
wait_for_certificate argocd tls-argocd-ingress 300


# network-policies is not in this list: it names namespaces that are created
# further down, and is checked at the end.
echo "==> Waiting for Argo CD to deploy Trivy Operator and Kyverno..."
for argocd_app in trivy-operator kyverno kyverno-policies kyverno-custom-policies; do
  wait_for_argocd_app "$argocd_app" 900
done

# Authelia's Secret comes from the private configuration repository, already
# encrypted; scripts/render-argocd-secrets.sh writes it from .secrets.enc.
echo "==> Waiting for Argo CD to deploy Authelia..."
wait_for_argocd_app authelia 900

# admin-ui-auth now asks Authelia; the old basic-auth users are unused.
kubectl -n traefik delete secret admin-ui-basic-auth --ignore-not-found

echo "==> Verifying the admin UIs redirect anonymous visitors to Authelia..."
for protected_host in "traefik.${HOSTNAME_DOMAIN}" "$LONGHORN_HOSTNAME"; do
  for i in {1..30}; do
    auth_response="$(
      curl -ks -o /dev/null -w '%{http_code} %{redirect_url}' \
        --resolve "${protected_host}:443:${CLOUDFLARE_ORIGIN_IP}" \
        "https://${protected_host}/" || true
    )"
    if [[ "$auth_response" == "302 https://${AUTHELIA_HOSTNAME}/"* ]]; then
      break
    fi
    if [[ "$i" -eq 30 ]]; then
      echo "ERROR: https://${protected_host}/ answered '${auth_response}', not a redirect to Authelia."
      kubectl -n authelia get pods,svc,endpointslice -o wide || true
      kubectl -n authelia logs deployment/authelia --tail=50 || true
      exit 1
    fi
    sleep 2
  done
  echo "  ${protected_host}: redirects to ${AUTHELIA_HOSTNAME}"
done

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

wait_for_certificate cattle-system tls-rancher-ingress 300

echo "==> Installing Rancher ${RANCHER_CHART_VERSION}..."
helm upgrade --install rancher rancher-stable/rancher \
  --version "$RANCHER_CHART_VERSION" \
  --namespace cattle-system \
  --create-namespace \
  --set-string hostname="$RANCHER_HOSTNAME" \
  --set ingress.tls.source=secret \
  --set ingress.ingressClassName=traefik \
  --set replicas=2 \
  --set-file bootstrapPassword=<(printf '%s' "$RANCHER_BOOTSTRAP_PASSWORD") \
  --wait \
  --timeout=600s

kubectl -n cattle-system rollout status deployment/rancher --timeout=600s

kubectl -n cattle-system get ingress rancher \
  -o jsonpath='{.spec.ingressClassName}{" "}{.spec.tls[0].secretName}{"\n"}' \
  | grep -qx 'traefik tls-rancher-ingress'

echo "==> Waiting for Argo CD to deploy the Cloudflare tunnel..."
wait_for_argocd_app cloudflared 600

# Alert rules, scrape targets, the Loki data source and the dashboards come
# from Argo CD (the monitoring-extras application). It needs the monitoring
# CRDs and every namespace it scrapes, all of which exist by now.
echo "==> Waiting for Argo CD to deploy the monitoring extras..."
wait_for_argocd_app monitoring-extras 900
# The MetalLB monitor moved to the monitoring namespace with MetalLB 0.16.
kubectl -n metallb-system delete podmonitor metallb --ignore-not-found

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

# Sets LOGIN_TOKEN (empty on failure) and RANCHER_LOGIN_HTTP for password $1.
# Secrets travel through the environment and stdin, never process arguments,
# which any local user can read in ps.
rancher_login() {
  local payload response
  payload="$(RANCHER_LOGIN_USER="$RANCHER_ADMIN_USER" RANCHER_LOGIN_PASSWORD="$1" \
    python3 -c 'import json,os; print(json.dumps({"username":os.environ["RANCHER_LOGIN_USER"],"password":os.environ["RANCHER_LOGIN_PASSWORD"]}))')"
  response="$(
    curl -sk -X POST \
      "https://localhost:8443/v3-public/localProviders/local?action=login" \
      -H "Content-Type: application/json" \
      -w '\n%{http_code}' \
      --data @- <<<"$payload" 2>/dev/null || true
  )"
  RANCHER_LOGIN_HTTP="${response##*$'\n'}"
  LOGIN_TOKEN="$(
    printf '%s' "${response%$'\n'*}" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("token",""))
except Exception:
    print("")' || true
  )"
}

# Redeploys: the admin password is already set and the bootstrap password is
# stale, so try the configured password first instead of retrying for minutes.
LOGIN_TOKEN=""
RANCHER_PASSWORD_ALREADY_SET=false
for i in {1..20}; do
  rancher_login "$RANCHER_ADMIN_PASSWORD"
  if [[ -n "$LOGIN_TOKEN" ]]; then
    RANCHER_PASSWORD_ALREADY_SET=true
    echo "  Rancher API ready; admin password already configured"
    break
  fi
  admin_login_http="$RANCHER_LOGIN_HTTP"

  rancher_login "$ACTUAL_BOOTSTRAP"
  if [[ -n "$LOGIN_TOKEN" ]]; then
    echo "  Rancher API ready"
    break
  fi

  # A responding API that rejects both passwords will not change by waiting.
  if [[ "$admin_login_http" == "401" && "$RANCHER_LOGIN_HTTP" == "401" ]]; then
    echo "  Rancher rejected both RANCHER_ADMIN_PASSWORD and the bootstrap password."
    break
  fi

  echo "  waiting for Rancher API... ($i/20)"
  sleep 15
done

if [[ -n "$LOGIN_TOKEN" && "$RANCHER_PASSWORD_ALREADY_SET" == true ]]; then
  echo "==> Rancher admin password already set; skipping password change"
elif [[ -n "$LOGIN_TOKEN" ]]; then
  ADMIN_USER_ID="$(
    kubectl get users.management.cattle.io \
      -o jsonpath="{range .items[?(@.username==\"${RANCHER_ADMIN_USER}\")]}{.metadata.name}{\"\\n\"}{end}" \
    | head -n1
  )"

  if [[ -z "$ADMIN_USER_ID" ]]; then
    echo "ERROR: Could not determine Rancher admin user ID."
    exit 1
  fi

  echo "==> Changing Rancher admin password for ${ADMIN_USER_ID}..."

  # Serialize with json.dumps so quotes, backslashes, or newlines in a password
  # cannot break or alter the manifest; env vars keep them out of ps output.
  PCR_USER_ID="$ADMIN_USER_ID" \
  PCR_CURRENT_PASSWORD="$ACTUAL_BOOTSTRAP" \
  PCR_NEW_PASSWORD="$RANCHER_ADMIN_PASSWORD" \
    python3 - <<'PY_PASSWORD_CHANGE' | kubectl create -f -
import json
import os

print(json.dumps({
    "apiVersion": "ext.cattle.io/v1",
    "kind": "PasswordChangeRequest",
    "metadata": {"generateName": "admin-password-change-"},
    "spec": {
        "userID": os.environ["PCR_USER_ID"],
        "currentPassword": os.environ["PCR_CURRENT_PASSWORD"],
        "newPassword": os.environ["PCR_NEW_PASSWORD"],
    },
}))
PY_PASSWORD_CHANGE
fi

if [[ -n "$LOGIN_TOKEN" ]]; then
  echo "==> Setting Rancher server URL..."

  SERVER_URL_PAYLOAD="$(
    python3 -c 'import json,sys; print(json.dumps({"value":sys.argv[1]}))' \
      "https://${RANCHER_HOSTNAME}"
  )"

  curl -fsSk -X PUT \
    "https://localhost:8443/v3/settings/server-url" \
    -H @<(printf 'Authorization: Bearer %s\n' "$LOGIN_TOKEN") \
    -H "Content-Type: application/json" \
    -d "$SERVER_URL_PAYLOAD" \
    >/dev/null

  echo "==> Rancher admin credentials configured successfully"
else
  echo "WARNING: Could not log in to Rancher with RANCHER_ADMIN_PASSWORD or the bootstrap password."
  echo "         Rancher itself remains installed; if the admin password was changed in the UI,"
  echo "         update RANCHER_ADMIN_PASSWORD in .secrets.enc to match."
fi

cleanup
PF_PID=""

# Argo CD deploys Trilium (charts/trilium); the checks below confirm what it
# deployed.
echo "==> Waiting for Argo CD to deploy Trilium..."
wait_for_argocd_app trilium 900

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
wait_for_certificate trilium tls-trilium-ingress 300

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

# Argo CD deploys Vaultwarden (charts/vaultwarden) and its two Secrets, which
# scripts/render-argocd-secrets.sh writes to the private configuration
# repository. The checks below confirm what it deployed.
echo "==> Waiting for Argo CD to deploy Vaultwarden..."
wait_for_argocd_app vaultwarden 900

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
wait_for_rollout vaultwarden vaultwarden 600

echo "==> Waiting for Vaultwarden TLS certificate..."
wait_for_certificate vaultwarden tls-vaultwarden-ingress 300

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

VW_TMP="$(mktemp -d)"
VW_COOKIE_JAR="$VW_TMP/cookies"
VW_ADMIN_LOGIN_CODE="$(
  curl -sS \
    -o "$VW_TMP/admin-login.out" \
    -w '%{http_code}' \
    -c "$VW_COOKIE_JAR" \
    -X POST \
    'http://127.0.0.1:8081/admin' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "token@-" < <(printf '%s' "$VAULTWARDEN_ADMIN_TOKEN")
)"

if [[ "$VW_ADMIN_LOGIN_CODE" != "200" && "$VW_ADMIN_LOGIN_CODE" != "302" ]]; then
  echo "ERROR: Vaultwarden admin login failed with HTTP ${VW_ADMIN_LOGIN_CODE}."
  cat "$VW_TMP/admin-login.out" || true
  exit 1
fi

VW_INVITE_PAYLOAD="$(
  python3 -c 'import json,sys; print(json.dumps({"email": sys.argv[1]}))' \
    "$VAULTWARDEN_INITIAL_EMAIL"
)"

VW_INVITE_CODE="$(
  curl -sS \
    -o "$VW_TMP/invite.out" \
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
    cat "$VW_TMP/invite.out" || true
    exit 1
    ;;
esac

cleanup
PF_PID=""

# Argo CD deploys the website (charts/website) and waits for its pods and
# certificate. The chart rolls the pods when the nginx config changes; the
# deploy key is not in the chart, so roll them here when it changes. Argo CD
# leaves an annotation it did not set alone.
echo "==> Waiting for Argo CD to deploy jeffriffle.com..."
wait_for_argocd_app website 900

WEBSITE_KEY_HASH="$(kubectl -n website get secret jeffriffle-git -o jsonpath='{.data}' | sha256sum | cut -c1-16)"
kubectl -n website patch deployment jeffriffle --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"homelab/deploy-key-hash\":\"${WEBSITE_KEY_HASH}\"}}}}}"
unset WEBSITE_KEY_HASH
wait_for_rollout website jeffriffle 300

# Checked last, once every namespace the policies name exists.
echo "==> Waiting for Argo CD to apply the network policies..."
wait_for_argocd_app network-policies 900

# The Secrets Argo CD deploys are generated from .secrets.enc. Say so if a
# value changed there and the generated copy was not refreshed.
echo "==> Comparing Argo CD's Secrets with .secrets.enc..."
"$K3S_DIR/scripts/render-argocd-secrets.sh" --check ||
  echo "WARNING: a Secret differs. Run scripts/render-argocd-secrets.sh, then commit and push the configuration repository."

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
echo "===== AUTHELIA ====="
kubectl -n authelia get pods,svc,pvc,ingress
kubectl -n authelia get certificate tls-authelia-ingress

echo
echo "===== VAULTWARDEN ====="
kubectl -n vaultwarden get pods,svc,pvc,ingress
kubectl -n vaultwarden get certificate tls-vaultwarden-ingress

echo
echo "===== TRILIUM ====="
kubectl -n trilium get pods,svc,pvc,ingressroute
kubectl -n trilium get certificate tls-trilium-ingress

echo
echo "===== LONGHORN ====="
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get nodes.longhorn.io
kubectl -n longhorn-system get ingressroute
kubectl -n longhorn-system get certificate tls-longhorn-ingress
kubectl get storageclass longhorn
echo
echo "===== MONITORING ====="
kubectl -n monitoring get pods
kubectl -n monitoring get pvc -o wide
kubectl -n monitoring get ingressroute
kubectl -n monitoring get certificate tls-grafana-ingress
kubectl -n monitoring get servicemonitor longhorn-prometheus-servicemonitor
kubectl -n monitoring get prometheusrule homelab-baseline-alerts

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

wait_for_certificate cattle-system tls-rancher-ingress 30
wait_for_certificate traefik tls-traefik-dashboard 30

echo
wait_for_certificate longhorn-system tls-longhorn-ingress 30

echo "============================================================================"
echo " Deployment complete"
echo "============================================================================"
echo " Kubernetes API: https://${KUBE_VIP}:6443"
echo " Rancher:        https://${RANCHER_HOSTNAME}"
echo " Longhorn:       https://${LONGHORN_HOSTNAME}"
echo " Argo CD:        https://${ARGOCD_HOSTNAME}"
echo " Authelia:       https://${AUTHELIA_HOSTNAME}"
echo " Trilium:        https://${TRILIUM_HOSTNAME}"
echo " Vaultwarden:    https://${VAULTWARDEN_HOSTNAME}"
echo " Grafana:        https://${GRAFANA_HOSTNAME}"
echo " Grafana user:   admin"
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
echo " Authelia (login for Traefik dashboard, Longhorn, Prometheus)"
echo "============================================================================"
echo " Log in at https://${AUTHELIA_HOSTNAME} as ADMIN_UI_USERNAME / ADMIN_UI_PASSWORD."
echo " These admin UIs require two-factor auth. On first login, register a TOTP"
echo " app or security key: Authelia emails a one-time code to ${ADMIN_EMAIL}."
echo " Change the password in .secrets.enc (ADMIN_UI_PASSWORD) and redeploy."
echo "============================================================================"

echo
echo "============================================================================"
echo " Rancher user:   ${RANCHER_ADMIN_USER}"
echo "============================================================================"
