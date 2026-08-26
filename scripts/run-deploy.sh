#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/config/cluster.env}"

"$ROOT/scripts/prepare-env.sh"

set -a
source "$ENV_FILE"
set +a

export RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.${BASE_DOMAIN}}"
export LONGHORN_HOSTNAME="${LONGHORN_HOSTNAME:-longhorn.${BASE_DOMAIN}}"
export TRILIUM_HOSTNAME="${TRILIUM_HOSTNAME:-trilium.${BASE_DOMAIN}}"
export VAULTWARDEN_HOSTNAME="${VAULTWARDEN_HOSTNAME:-vaultwarden.${BASE_DOMAIN}}"
export GRAFANA_HOSTNAME="${GRAFANA_HOSTNAME:-grafana.${BASE_DOMAIN}}"
export PORTAINER_HOSTNAME="${PORTAINER_HOSTNAME:-portainer.${BASE_DOMAIN}}"

exec "$ROOT/deploy.sh" "$@"
