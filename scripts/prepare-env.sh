#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/config/cluster.env}"

[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: missing $ENV_FILE"
  echo "Run: cp config/cluster.env.example config/cluster.env"
  exit 1
}

set -a
source "$ENV_FILE"
set +a

required=(
  BASE_DOMAIN KUBE_VIP
  K3S_NODE_0 K3S_NODE_1 K3S_NODE_2
  K3S_NODE_3 K3S_NODE_4 K3S_NODE_5
  METALLB_IP_RANGE CLOUDFLARE_ORIGIN_IP
  UNRAID_IP CLUSTER_BACKUP_EXPORT LONGHORN_BACKUP_EXPORT
)

for v in "${required[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "ERROR: $v is unset"; exit 1; }
done

command -v envsubst >/dev/null || {
  echo "ERROR: envsubst missing. Install: sudo apt install gettext-base"
  exit 1
}

envsubst < "$ROOT/inventory/k3s-ansible/hosts.ini.template" > "$ROOT/inventory/k3s-ansible/hosts.ini"
envsubst < "$ROOT/templates/cloudflared/cloudflared-config.yaml.template" > "$ROOT/cloudflared-config.yaml"
envsubst < "$ROOT/templates/cloudflared/cloudflared.yaml.template" > "$ROOT/cloudflared.yaml"

TEMPLATE_ROOT="$ROOT/templates/generated"
if [[ -d "$TEMPLATE_ROOT" ]]; then
  while IFS= read -r -d '' src; do
    rel="${src#$TEMPLATE_ROOT/}"
    dest="${rel%.template}"
    mkdir -p "$ROOT/$(dirname "$dest")"
    envsubst < "$src" > "$ROOT/$dest"
  done < <(find "$TEMPLATE_ROOT" -type f -name '*.template' -print0)
fi

echo "Environment rendered."
